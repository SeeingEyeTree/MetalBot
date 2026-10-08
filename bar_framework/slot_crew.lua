-- bar_framework/slot_crew.lua  (TILE_V2)
-- Slot tiles: lines of free SLOTS beside con lanes.  Replaces tile_crew.lua's fixed 4x4 block of
-- con_bot_grid tiles when CFG.TILE_STYLE == "slots"; the API the macro uses is the same.
--
-- STRIP (cell = 16 elmos, 16 wide x 25 tall, in block-local u (along the lane) / v' (across)):
--
--     slot row A1   4 big slots, 4x4 cells each  v' 0..64
--     slot row A2   4 big slots                  v' 64..128
--     gap A         3 cells, con lane A          v' 128..176
--     small row     3 cells, 4 small spots       v' 176..224   (a 3-cell crossing is left in the middle)
--     gap B         3 cells, con lane B          v' 224..272
--     slot row B1   4 big slots                  v' 272..336
--     slot row B2   4 big slots                  v' 336..400
--
-- EVERY slot takes build power (a nano), a mex (big slots only: a mex is 4x4) or a wind, chosen WHEN IT IS
-- BUILT from resource pressure (BP_PLACER.Utilization), never fixed by a layout order:
--     both metal and energy under BALANCE_BP_U  -> a nano, put where it is best used (see NanoScore)
--     energy about to run dry (U > windU)       -> wind (small spots first: they cannot take a mex)
--     otherwise                                 -> mex
-- A con (or the commander, which cannot build nanos) walks along a lane; from each of two stops per lane
-- every slot of its side is inside build range (tests/test_slot_tile.lua proves it).  Slots are shared
-- state: any builder takes the next free one.
--
-- The lines grow "forever": strips are added a row at a time (SC.AddStripRow) whenever the free slots run
-- low, until the map edge.  The air lab is built by the commander INSIDE a line, on 3 x 2 reserved big
-- slots (SC.ReserveLab).
--
-- Block = the commander's tile (bad_com_start, local u,v -112..128) + strips east of it.  Strip lane A of
-- the first row is lined up with the bot lab's exit (local z = 80).

local SC = {}

-- ── Geometry constants (elmos) ───────────────────────────────────────────────
SC.STRIPS_X   = 2
SC.STRIPS_Z   = 2            -- strip rows at the start; more are added as the free slots run out
SC.STRIP_W    = 256
SC.STRIP_H    = 400
SC.U0         = 144          -- first strip starts one cell past the commander tile's edge (128)
SC.COM_MIN    = -112         -- commander tile, local
SC.COM_MAX    = 128
SC.LAB_LANE_V = 80           -- local v the first strip's lane A sits on (the lab exits along z=32..128)
SC.SLOT_COLS  = { 32, 96, 160, 224 }
SC.SLOT_ROWS  = { 32, 96, 304, 368 }            -- A1, A2, B1, B2 centres (v')
SC.LANE_V     = { 152, 248 }                    -- lane A, lane B (v')
SC.SMALL_V    = 200
SC.SMALL_U    = { 24, 216, 72, 168 }            -- both ends first; a 3-cell crossing stays in the middle
SC.STOP_U     = { 64, 192 }
SC.LATTICE    = 480
SC.AIR_RING_MAX = 800
SC.COM_OFFSET = { x = 32, z = 16 }              -- commander spawn -> commander tile anchor (as tile_crew)
SC.FOOT_HALF  = 24           -- reach margin: half of a 3x3 building
SC.MAP_MARGIN = 96           -- strip rows may not come closer than this to the map edge
SC.MIN_FREE   = 12           -- add a strip row when fewer big+small slots than this (+ 4 per builder) are free
SC.NANO_R     = 300          -- a nano's useful radius for placement scoring (its real range is ~400)
SC.WIND_U     = 1.0          -- wind beats mex only when energy pressure U exceeds this

local ORDER_TIMEOUT = 450    -- frames an order may take to start a frame
local MOVE_TIMEOUT  = 600
local YIELD_TIMEOUT = 450
local MAX_RETRIES   = 3

local CMD_STOP, CMD_MOVE = 0, 10

local function Rotate(x, z, r)
    if     r == 1 then return -z,  x
    elseif r == 2 then return -x, -z
    elseif r == 3 then return  z, -x
    end
    return x, z
end
SC.Rotate = Rotate

local function Sign(v) if v < 0 then return -1 end return 1 end

-- ── Layout ───────────────────────────────────────────────────────────────────

function SC.World(L, u, v)
    local x, z = Rotate(u, v, L.rot)
    return L.anchorX + x, L.anchorZ + z
end

local function UpdateBounds(L)
    local minU, maxU = SC.COM_MIN, SC.U0 + SC.STRIP_W * SC.STRIPS_X
    local minV, maxV = SC.COM_MIN, SC.COM_MAX
    for _, s in ipairs(L.strips) do
        minV, maxV = math.min(minV, s.vStart, s.vEnd), math.max(maxV, s.vStart, s.vEnd)
    end
    -- Rows that may still be added (SC.EXTRA_ROWS) are reserved from the start so nothing else is placed there.
    if (SC.EXTRA_ROWS or 0) > 0 and not L.noMoreRows then
        local last = SC.LAB_LANE_V - L.dirV * SC.LANE_V[1] + L.dirV * SC.STRIP_H * (SC.STRIPS_Z + SC.EXTRA_ROWS)
        minV, maxV = math.min(minV, last), math.max(maxV, last)
    end
    L.local_ = { minU = minU, maxU = maxU, minV = minV, maxV = maxV }
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, c in ipairs({ { minU, minV }, { minU, maxV }, { maxU, minV }, { maxU, maxV } }) do
        local x, z = SC.World(L, c[1], c[2])
        minX, maxX, minZ, maxZ = math.min(minX, x), math.max(maxX, x), math.min(minZ, z), math.max(maxZ, z)
    end
    L.bounds = { minX, maxX, minZ, maxZ }
end

-- Add strip row j (STRIPS_X strips side by side).  Rows beyond the starting ones are refused when any
-- corner would come within MAP_MARGIN of the map edge.  Returns true if added.
local function AddStripRow(L, j)
    local vStart = SC.LAB_LANE_V - L.dirV * SC.LANE_V[1] + L.dirV * SC.STRIP_H * j
    local vEnd = vStart + L.dirV * SC.STRIP_H
    if j >= SC.STRIPS_Z + (SC.EXTRA_ROWS or 1e9) then return false end
    if j >= SC.STRIPS_Z and L.mapX then
        for _, u in ipairs({ SC.U0, SC.U0 + SC.STRIP_W * SC.STRIPS_X }) do
            for _, v in ipairs({ vStart, vEnd }) do
                local x, z = SC.World(L, u, v)
                if x < SC.MAP_MARGIN or z < SC.MAP_MARGIN
                   or x > L.mapX - SC.MAP_MARGIN or z > L.mapZ - SC.MAP_MARGIN then
                    return false
                end
            end
        end
    end
    local function V(vp) return vStart + L.dirV * vp end
    for i = 0, SC.STRIPS_X - 1 do
        local u0 = SC.U0 + SC.STRIP_W * i
        local strip = { idx = #L.strips + 1, i = i, j = j, u0 = u0, vStart = vStart, vEnd = vEnd,
                        slots = {}, nanos = {}, stops = {} }
        for r, vp in ipairs(SC.SLOT_ROWS) do
            for c, up in ipairs(SC.SLOT_COLS) do
                local u, v = u0 + up, V(vp)
                local wx, wz = SC.World(L, u, v)
                local s = { kind = "big", strip = strip.idx, u = u, v = v, wx = wx, wz = wz,
                            lane = (r <= 2) and 1 or 2, row = r, col = c, state = "free", retries = 0 }
                strip.slots[#strip.slots + 1] = s
                L.slots[#L.slots + 1] = s
                L.all[#L.all + 1] = s
            end
        end
        for _, up in ipairs(SC.SMALL_U) do
            local u, v = u0 + up, V(SC.SMALL_V)
            local wx, wz = SC.World(L, u, v)
            local s = { kind = "small", strip = strip.idx, u = u, v = v, wx = wx, wz = wz,
                        state = "free", retries = 0 }
            strip.nanos[#strip.nanos + 1] = s
            L.nanos[#L.nanos + 1] = s
            L.all[#L.all + 1] = s
        end
        -- Snake through the lanes: A out, B back, so a con never doubles back across the strip.
        local order = { {1, SC.STOP_U[1]}, {1, SC.STOP_U[2]}, {2, SC.STOP_U[2]}, {2, SC.STOP_U[1]} }
        for _, o in ipairs(order) do
            local u, v = u0 + o[2], V(SC.LANE_V[o[1]])
            local wx, wz = SC.World(L, u, v)
            strip.stops[#strip.stops + 1] = { u = u, v = v, wx = wx, wz = wz, lane = o[1] }
        end
        L.strips[#L.strips + 1] = strip
    end
    L.nextJ = j + 1
    UpdateBounds(L)
    return true
end
SC.AddStripRow = AddStripRow

-- Same orientation rules as tile_crew's Layout: the strips' columns (local +u) run toward the map
-- centre on the non-enemy axis, rows (local v) away from the centre along the enemy axis.
function SC.Layout(comX, comZ, mapX, mapZ)
    local T = 240
    local vx, vz = mapX / 2 - comX, mapZ / 2 - comZ
    local colVec, rowVec, colSign
    local zMain = math.abs(vz) >= math.abs(vx)
    local extent = SC.STRIP_H * (SC.STRIPS_Z + (SC.EXTRA_ROWS or 0)) + 100
    if zMain then
        colSign = Sign(vx)
        local rowSign = -Sign(vz)
        local reach = comZ + rowSign * extent
        if reach < 64 or reach > mapZ - 64 then rowSign = -rowSign end
        colVec = { x = colSign * T, z = 0 }
        rowVec = { x = 0, z = rowSign * T }
    else
        colSign = Sign(vz)
        local rowSign = -Sign(vx)
        local reach = comX + rowSign * extent
        if reach < 64 or reach > mapX - 64 then rowSign = -rowSign end
        colVec = { x = 0, z = colSign * T }
        rowVec = { x = rowSign * T, z = 0 }
    end
    local rot
    if zMain then rot = colSign > 0 and 0 or 2
    else          rot = colSign > 0 and 1 or 3 end

    local ox, oz = Rotate(SC.COM_OFFSET.x, SC.COM_OFFSET.z, rot)
    local L = { anchorX = math.floor(comX / 16 + 0.5) * 16 + ox,
                anchorZ = math.floor(comZ / 16 + 0.5) * 16 + oz,
                rot = rot, colVec = colVec, rowVec = rowVec,
                strips = {}, slots = {}, nanos = {}, all = {}, style = "slots",
                mapX = mapX, mapZ = mapZ, nextJ = 0 }

    -- Which way does local +v point in the world, relative to the way rows grow?  The strips are mirror
    -- symmetric about their small row, so they simply grow in whichever local direction is `dirV`.
    local dvx, dvz = Rotate(0, 1, rot)
    L.dirV = (dvx * rowVec.x + dvz * rowVec.z) >= 0 and 1 or -1

    for j = 0, SC.STRIPS_Z - 1 do AddStripRow(L, j) end
    return L
end

function SC.BlockBounds(L) return L.bounds[1], L.bounds[2], L.bounds[3], L.bounds[4] end

function SC.InBlock(L, x, z, half)
    half = half or 0
    local b = L.bounds
    return x + half > b[1] and x - half < b[2] and z + half > b[3] and z - half < b[4]
end

-- Every 480-lattice cell the block overlaps, the lattice anchored at the block's min corner (so a block
-- two strips tall and two wide fills exactly 2 x 2 cells).  Used for the cells the spine must keep clear of.
function SC.GridCells(L)
    local b, out = L.local_, {}
    local nu = math.ceil((b.maxU - b.minU) / SC.LATTICE - 1e-9)
    local nv = math.ceil((b.maxV - b.minV) / SC.LATTICE - 1e-9)
    for i = 0, nu - 1 do
        for j = 0, nv - 1 do
            local x, z = SC.World(L, b.minU + SC.LATTICE * (i + 0.5), b.minV + SC.LATTICE * (j + 0.5))
            out[#out + 1] = { anchorX = x, anchorZ = z }
        end
    end
    return out
end

-- The lattice cells just past both ends of the lanes (cons and the bot lab's units leave that way).
function SC.EndCells(L)
    local b, out = L.local_, {}
    for _, u in ipairs({ b.minU - SC.LATTICE / 2, b.maxU + SC.LATTICE / 2 }) do
        local x, z = SC.World(L, u, SC.LAB_LANE_V)
        out[#out + 1] = { anchorX = x, anchorZ = z }
    end
    return out
end

-- The macro's old "finished tiles" hand-off test does not apply to slots (see SC.Ready / SC.ReserveLab).
function SC.FinishedTiles(crew) return {} end
SC.LAB_EXIT_ROW = 0
SC.AIR_LAB = { x = 0, z = 0 }
function SC.Local(L, tile, p) return L.anchorX, L.anchorZ end

-- ── The crew ─────────────────────────────────────────────────────────────────

local function Dist(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

function SC.NewCrew(opts)
    local L = opts.layout
    -- uniform = every slot can take a nano / mex / wind (lines mode).  Off = the first slot version: nanos
    -- only on the small row, mex and wind only in the big slots.
    local crew = { BP = opts.BP, L = L, onCommanderFree = opts.onCommanderFree, uniform = opts.uniform == true,
                   expectCmdr = opts.expectCommander == true, bayWanted = opts.labBay == true,
                   cons = {}, byFrame = {}, frame = 0, exhausted = false, expand = opts.expand == true,
                   nMex = 0, nWind = 0, nNano = 0, lastLog = 0, tilesDone = 0, defs = {}, windU = SC.WIND_U }
    for cls, name in pairs({ mex = "cormex", wind = "corwin", nano = "cornanotc" }) do
        crew.defs[cls] = UnitDefNames and UnitDefNames[name]
    end
    Spring.Echo(string.format("[SC] slot block: %d strips, %d slots, %d nano spots, lattice cells %d, lines %s",
        #L.strips, #L.slots, #L.nanos, #SC.GridCells(L), crew.expand and "extend" or "fixed"))
    return crew
end

-- ── Lanes: one builder each ──────────────────────────────────────────────────
-- A lane = one side of a strip (side 1: slot rows A1/A2 and lane A, side 2: rows B1/B2 and lane B); both
-- sides share the strip's small row.  Exactly one builder works a lane.  The first con takes strip 1 side 1,
-- the commander the other side of the same small row, and each new con the free lane nearest strip 1 (so it is
-- still in range of the first nanos).  The priority order is by distance from strip 1.

local function BuildLanes(crew)
    crew.lanes, crew.laneOf = crew.lanes or {}, crew.laneOf or {}
    local added = false
    local first = crew.L.strips[1]
    for _, strip in ipairs(crew.L.strips) do
        if not strip.cx then
            local sx, sz = 0, 0
            for _, s in ipairs(strip.slots) do sx, sz = sx + s.wx, sz + s.wz end
            strip.cx, strip.cz = sx / #strip.slots, sz / #strip.slots
        end
        for side = 1, 2 do
            local key = strip.idx * 2 + side
            if not crew.laneOf[key] then
                local lane = { strip = strip, side = side, key = key,
                               stops = (side == 1) and { strip.stops[1], strip.stops[2] }
                                                   or { strip.stops[3], strip.stops[4] } }
                crew.laneOf[key] = lane
                crew.lanes[#crew.lanes + 1] = lane
                added = true
            end
        end
    end
    if added then
        for _, lane in ipairs(crew.lanes) do
            lane.rank = Dist(lane.strip.cx, lane.strip.cz, first.cx, first.cz) * 10 + lane.side
        end
        table.sort(crew.lanes, function(a, b) return a.rank < b.rank end)
    end
end

local function LaneFree(crew, lane)
    for _, c in pairs(crew.cons) do
        if c.lane == lane then return false end
    end
    return true
end

-- Free big slots on a lane's side of its strip.
local function LaneFreeSlots(lane)
    local n = 0
    for _, s in ipairs(lane.strip.slots) do
        if s.lane == lane.side and s.state == "free" then n = n + 1 end
    end
    return n
end

local function CountBuilders(crew)
    local n = 0
    for _ in pairs(crew.cons) do n = n + 1 end
    return n
end

function SC.FreeRows(crew) return SC.RowsAvailable(crew) end

-- Lanes a new builder could take.
function SC.RowsAvailable(crew)
    BuildLanes(crew)
    return math.max(0, #crew.lanes - CountBuilders(crew))
end

local function PickLane(crew, cmdr)
    BuildLanes(crew)
    local reserved = crew.lanes[2]       -- strip 1, side 2: kept for the commander while it is expected
    if cmdr then
        for _, c in pairs(crew.cons) do
            if c.lane and not c.cmdr then          -- the other side of the first con's strip
                local other = crew.laneOf[c.lane.strip.idx * 2 + (3 - c.lane.side)]
                if other and LaneFree(crew, other) then return other end
            end
        end
    end
    local keep = (not cmdr) and crew.expectCmdr and not crew.cmdr and reserved
    for _, lane in ipairs(crew.lanes) do
        if LaneFree(crew, lane) and lane ~= keep then return lane end
    end
    for _, lane in ipairs(crew.lanes) do         -- nothing else free: the reserved lane after all
        if LaneFree(crew, lane) then return lane end
    end
    return nil
end

local function AddBuilder(crew, id, cmdr)
    if crew.cons[id] then return crew.cons[id].strip end
    local lane = PickLane(crew, cmdr)
    crew.cons[id] = { id = id, cmdr = cmdr, lane = lane, strip = lane and lane.strip.idx or 1,
                      help = lane == nil, phase = "idle", target = nil }
    if cmdr then crew.cmdr = id end
    Spring.GiveOrderToUnit(id, CMD_STOP, {}, {})
    Spring.Echo(string.format("[SC] %s %d takes lane (strip %d, side %d)", cmdr and "commander" or "con", id,
        lane and lane.strip.idx or 0, lane and lane.side or 0))
    if cmdr and lane and crew.bayWanted then SC.ReserveBay(crew, lane) end
    return crew.cons[id].strip
end

-- May this builder take this slot?  Its own lane's side of its strip plus the strip's small row; a builder
-- that found no free lane ("help") may take anything.
local function Allowed(c, s)
    if c.help or not c.lane then return true end
    return s.strip == c.lane.strip.idx and (s.kind == "small" or s.lane == c.lane.side)
end

function SC.AddCon(crew, conID, takeReserved) return AddBuilder(crew, conID, false) end
function SC.AddCommander(crew, comID, skipDefIDs) return AddBuilder(crew, comID, true) end

local function FreeSlot(crew, s, why)
    if s.state == "free" or s.state == "dead" or s.state == "lab" then return end
    if s.frameID then crew.byFrame[s.frameID] = nil end
    s.state, s.owner, s.frameID, s.cls, s.defID = "free", nil, nil, nil, nil
    s.retries = s.retries + 1
    if s.retries >= MAX_RETRIES then s.state = "dead" end
end

local function DropCon(crew, id, why)
    local c = crew.cons[id]
    if not c then return end
    if c.target and (c.target.state == "ordered") then FreeSlot(crew, c.target, why) end
    crew.cons[id] = nil
    if crew.cmdr == id then crew.cmdr = nil end
end

function SC.Release(crew, conID) DropCon(crew, conID, "released") end

local function FreeCommander(crew, c, why)
    DropCon(crew, c.id, why)
    Spring.Echo(string.format("[SC] commander leaves the slots (%s)", why))
    if crew.onCommanderFree then pcall(crew.onCommanderFree, c.id) end
end

function SC.Yield(crew, id)
    local c = crew.cons[id]
    if not (c and c.cmdr) then return end
    if c.yield == nil then c.yield = true end
    if not c.target or c.phase == "idle" or c.phase == "move" then
        FreeCommander(crew, c, "yielded")
    end
end

function SC.RowDone(crew, conID) return crew.exhausted end
function SC.AllDone(crew) return crew.exhausted end

function SC.NearestBuilder(crew, x, z, maxDist, exceptID)
    local best, bestD = nil, maxDist or math.huge
    for id in pairs(crew.cons) do
        if id ~= exceptID and Spring.GetUnitDefID(id) then
            local ux, _, uz = Spring.GetUnitPosition(id)
            if ux then
                local d = Dist(ux, uz, x, z)
                if d < bestD then best, bestD = id, d end
            end
        end
    end
    return best
end

-- Hand-off readiness: enough built that the economy can carry an air lab.
function SC.Ready(crew, minSlots, minNanos)
    return crew.nMex + crew.nWind >= (minSlots or 6) and crew.nNano >= (minNanos or 1)
end

-- ── The air lab goes in a line ───────────────────────────────────────────────
-- The commander builds it (the macro puts it in the build order) on 3 x 2 reserved big slots: columns
-- 1-3 or 2-4 of the A rows or the B rows of a strip, every one of them still free.  A corap is 9 x 6 cells
-- (144 x 96 elmos); the block is 192 x 128.  Air units need no ground exit, so nothing else is reserved.
-- Returns the world centre and the facing (long side along the lane), or nil.  A repeat call (the macro
-- retries when the lab was not started) first gives the earlier reservation back.
function SC.ReserveLab(crew, nearX, nearZ)
    local L = crew.L
    -- The bay reserved when the commander took its lane (SC.ReserveBay): use it as long as it is intact.
    if crew.bay then
        local ok = true
        for _, s in ipairs(crew.bay) do if s.state ~= "lab" then ok = false end end
        local key = math.floor(crew.bayPos[1]) .. "," .. math.floor(crew.bayPos[2])
        if ok and not (crew.labBad and crew.labBad[key]) then
            crew.labSlots = crew.bay
            Spring.Echo(string.format("[SC] air lab goes in the reserved bay of strip %d at (%d, %d)",
                crew.bay[1].strip, crew.bayPos[1], crew.bayPos[2]))
            return crew.bayPos[1], crew.bayPos[2]
        end
        for _, s in ipairs(crew.bay) do if s.state == "lab" then s.state = "free" end end
        crew.bay = nil
    end
    for _, s in ipairs(L.slots) do
        if s.state == "lab" then s.state = "free" end
    end
    -- Prefer the commander's own side of its strip (it builds the lab from there, and the lines keep going) and
    -- blocks beside built nanos (the nanos help build it).
    local cm = crew.cmdr and crew.cons[crew.cmdr]
    local cmLane = cm and cm.lane
    local function Find()
        local best, bestD, bestSet, bestStrip = nil, math.huge, nil, nil
        for _, strip in ipairs(L.strips) do
            for _, rows in ipairs({ { 1, 2 }, { 3, 4 } }) do
                for _, c0 in ipairs({ 1, 2 }) do
                    local set, ok, su, sv = {}, true, 0, 0
                    for _, r in ipairs(rows) do
                        for c = c0, c0 + 2 do
                            local s = strip.slots[(r - 1) * 4 + c]
                            if s.state ~= "free" then ok = false end
                            set[#set + 1] = s
                            su, sv = su + s.u, sv + s.v
                        end
                    end
                    if ok then
                        local u, v = su / 6, sv / 6
                        local wx, wz = SC.World(L, u, v)
                        local d = Dist(wx, wz, nearX or L.anchorX, nearZ or L.anchorZ)
                        if cmLane and strip.idx == cmLane.strip.idx then
                            d = d - 100
                            if rows[1] == ((cmLane.side == 1) and 1 or 3) then d = d - 100 end
                        end
                        for _, n in ipairs(L.nanos) do
                            if n.state == "nano" and Dist(wx, wz, n.wx, n.wz) <= 250 then d = d - 150; break end
                        end
                        local bad = crew.labBad and crew.labBad[math.floor(wx) .. "," .. math.floor(wz)]
                        if not bad and d < bestD then best, bestD, bestSet, bestStrip = { wx, wz }, d, set, strip end
                    end
                end
            end
        end
        return best, bestSet
    end
    local pos, set = Find()
    if not pos and crew.expand and AddStripRow(L, L.nextJ) then
        Spring.Echo(string.format("[SC] strip row %d added for the air lab", L.nextJ))
        pos, set = Find()
    end
    if not pos then return nil end
    for _, s in ipairs(set) do s.state = "lab" end
    crew.labSlots = set
    Spring.Echo(string.format("[SC] air lab reserved on 6 slots of strip %d at (%d, %d)", set[1].strip, pos[1], pos[2]))
    return pos[1], pos[2]
end

-- The air lab's bay, kept free from the moment the commander takes its lane: columns 2-4 of its own side of the
-- strip (3 x 2 big slots, beside that strip's nanos).  By the hand-off the builders have filled everything
-- near them, so a block reserved only then would be on the far side of the block, away from the build power.
function SC.ReserveBay(crew, lane)
    if crew.bay or not lane then return false end
    local rows = (lane.side == 1) and { 1, 2 } or { 3, 4 }
    local set, su, sv = {}, 0, 0
    for _, r in ipairs(rows) do
        for c = 2, 4 do
            local s = lane.strip.slots[(r - 1) * 4 + c]
            if s.state ~= "free" then return false end
            set[#set + 1] = s
            su, sv = su + s.u, sv + s.v
        end
    end
    for _, s in ipairs(set) do s.state = "lab" end
    local x, z = SC.World(crew.L, su / 6, sv / 6)
    crew.bay, crew.bayPos = set, { x, z }
    Spring.Echo(string.format("[SC] air lab bay kept free: strip %d side %d at (%d, %d)", lane.strip.idx, lane.side, x, z))
    return true
end

-- ── Deciding what to build ───────────────────────────────────────────────────

local function ReachOf(id)
    local d = UnitDefs[Spring.GetUnitDefID(id) or -1]
    return ((d and d.buildDistance) or 128) + SC.FOOT_HALF - 8
end

-- Where is a nano best placed?  Close to other build power (a new nano is finished by the nanos around it)
-- and with the most open space around it (every free slot within NANO_R is something it can later help
-- build).  Higher is better.
local function NanoScore(crew, s)
    local open, near = 0, false
    for _, o in ipairs(crew.L.all) do
        if o ~= s then
            local d = Dist(s.wx, s.wz, o.wx, o.wz)
            if d <= SC.NANO_R then
                if o.state == "free" then open = open + 1
                elseif o.state == "nano" or o.cls == "nano" then near = true end
            end
        end
    end
    return open + (near and 10 or 0)
end

local function AnyFreeBig(crew)
    for _, s in ipairs(crew.L.slots) do
        if s.state == "free" then return true end
    end
    return false
end

local function IssueBuild(crew, c, s, cls)
    local d = crew.defs[cls]
    if not d then return false end
    local x, z = crew.BP.SnapToBuildGrid(d.id, s.wx, s.wz, 0)
    local y = Spring.GetGroundHeight(x, z) or 0
    local t = Spring.TestBuildOrder(d.id, x, y, z, 0)
    if t == 0 then return false end
    Spring.GiveOrderToUnit(c.id, -d.id, { x, y, z, 0 }, {})
    s.state, s.owner, s.cls, s.defID, s.orderFrame = "ordered", c.id, cls, d.id, crew.frame
    c.target, c.phase = s, "build"
    return true
end

-- Free slots within `reach` of (x, z), nearest first by kind: nearest big, nearest small, all of them.
local function Scan(crew, x, z, reach, c)
    local big, bigD, small, smallD, all = nil, math.huge, nil, math.huge, {}
    for _, s in ipairs(crew.L.all) do
        if s.state == "free" and (not c or Allowed(c, s)) then
            local d = Dist(x, z, s.wx, s.wz)
            if d <= reach then
                all[#all + 1] = s
                if s.kind == "big" then
                    if d < bigD then big, bigD = s, d end
                elseif d < smallD then
                    small, smallD = s, d
                end
            end
        end
    end
    return big, small, all
end

-- Next job for an idle builder.  Returns true if it ordered a build.
local function Decide(crew, c, res)
    local x, _, z = Spring.GetUnitPosition(c.id)
    if not x then return false end
    local um, ue = crew.BP.Utilization(res)
    local U = crew.BP.BALANCE_BP_U or 0.8
    local big, small, all = Scan(crew, x, z, ReachOf(c.id), c)
    if #all == 0 then return false end

    -- Build power: neither resource is under pressure, so spend capacity is the limit.  (The commander
    -- cannot build nanos.)  Uniform: any free slot, placed by NanoScore.  Otherwise the small row only.
    if not c.cmdr and um < U and ue < U then
        local best, bestScore = nil, -math.huge
        if crew.uniform then
            for _, s in ipairs(all) do
                local sc = NanoScore(crew, s) - Dist(x, z, s.wx, s.wz) / 100
                if sc > bestScore then best, bestScore = s, sc end
            end
        else
            best = small
        end
        if best then
            if IssueBuild(crew, c, best, "nano") then return true end
            best.state = "dead"
            return Decide(crew, c, res)
        end
    end

    local wantWind = ue > um and ue > (crew.windU or SC.WIND_U)
    if wantWind then
        local s = crew.uniform and (small or big) or big
        if s and IssueBuild(crew, c, s, "wind") then return true end
        if s then s.state = "dead"; return Decide(crew, c, res) end
    end
    if big then
        if IssueBuild(crew, c, big, "mex") or IssueBuild(crew, c, big, "wind") then return true end
        big.state = "dead"          -- neither fits here (blocked terrain): never offer it again
        return Decide(crew, c, res)
    end
    -- Only small spots in reach and no big slot left anywhere: build power there (wind for the commander).
    if small and not AnyFreeBig(crew) then
        local cls = c.cmdr and "wind" or "nano"
        if IssueBuild(crew, c, small, cls) then return true end
        small.state = "dead"
    end
    return false
end

-- The nearest stop from which something this builder may take is still free: on its own lane while it has
-- one, anywhere in "help" mode.  nil when there is nothing left for it.
local function NextStop(crew, c)
    local x, _, z = Spring.GetUnitPosition(c.id)
    if not x then return nil end
    local reach = ReachOf(c.id)
    local best, bestScore = nil, math.huge
    local function Consider(st, strip)
        local big, small = Scan(crew, st.wx, st.wz, reach, c)
        if big or (small and not AnyFreeBig(crew)) then
            local score = Dist(x, z, st.wx, st.wz) + ((strip.idx == c.strip) and 0 or 150)
            if score < bestScore then best, bestScore = st, score end
        end
    end
    if c.help or not c.lane then
        for _, strip in ipairs(crew.L.strips) do
            for _, st in ipairs(strip.stops) do Consider(st, strip) end
        end
    else
        for _, st in ipairs(c.lane.stops) do Consider(st, c.lane.strip) end
    end
    return best
end

-- Its lane is finished: move to the nearest free lane that still has slots (never onto an occupied one).
local function ReassignLane(crew, c)
    BuildLanes(crew)
    for _, lane in ipairs(crew.lanes) do
        local heldForCmdr = (lane == crew.lanes[2]) and crew.expectCmdr and not crew.cmdr and not c.cmdr
        if lane ~= c.lane and LaneFree(crew, lane) and LaneFreeSlots(lane) > 0 and not heldForCmdr then
            Spring.Echo(string.format("[SC] %s %d moves to lane (strip %d, side %d)", c.cmdr and "commander" or "con",
                c.id, lane.strip.idx, lane.side))
            c.lane, c.strip, c.help = lane, lane.strip.idx, false
            return true
        end
    end
    return false
end

local function Step(crew, c, res)
    if c.phase == "move" then
        local x, _, z = Spring.GetUnitPosition(c.id)
        if x and (Dist(x, z, c.stop.wx, c.stop.wz) <= 40 or crew.frame - c.moveFrame > MOVE_TIMEOUT) then
            c.phase = "idle"
        else
            return
        end
    end
    if c.phase == "build" then
        local s = c.target
        if not s then c.phase = "idle"
        elseif s.state == "ordered" then
            if crew.frame - s.orderFrame > ORDER_TIMEOUT then   -- the order never became a frame
                FreeSlot(crew, s, "order timeout")
                c.target, c.phase = nil, "idle"
            else
                return
            end
        elseif s.state == "building" then
            -- Stay on the frame until it is finished.  (The old placer left a frame at 85% for a nano to
            -- finish; a slot block has too few nanos for that, and the abandoned frames decayed.)
            return
        else
            c.target, c.phase = nil, "idle"
        end
    end
    if c.cmdr and c.yield then FreeCommander(crew, c, "yielded"); return end
    if c.help then ReassignLane(crew, c) end          -- a lane may have been freed since
    if Decide(crew, c, res) then return end
    local stop = NextStop(crew, c)
    if not stop and not c.help and ReassignLane(crew, c) then stop = NextStop(crew, c) end
    if not stop and not c.help then
        c.help = true            -- no free lane has anything left: help on whatever is left, anywhere
        stop = NextStop(crew, c)
    end
    if stop then
        c.stop, c.phase, c.moveFrame = stop, "move", crew.frame
        Spring.GiveOrderToUnit(c.id, CMD_MOVE, { stop.wx, Spring.GetGroundHeight(stop.wx, stop.wz) or 0, stop.wz }, {})
    end
end

function SC.Update(crew, frame, res)
    crew.frame, crew.res = frame, res
    local free, active, nCons = 0, 0, 0
    for _, s in ipairs(crew.L.all) do
        if s.state == "free" then free = free + 1
        elseif s.state == "ordered" or s.state == "building" then active = active + 1 end
    end
    for _ in pairs(crew.cons) do nCons = nCons + 1 end
    -- The lines grow while the free slots run low, until the map edge.
    if crew.expand and not crew.L.noMoreRows and free < SC.MIN_FREE + 4 * nCons then
        if AddStripRow(crew.L, crew.L.nextJ) then
            Spring.Echo(string.format("[SC] %d:%02d strip row %d added (free %d, slots %d)",
                math.floor(frame / 1800), math.floor(frame / 30) % 60, crew.L.nextJ - 1, free, #crew.L.all))
            free = free + 16 * SC.STRIPS_X + 4 * SC.STRIPS_X
        else
            crew.L.noMoreRows = true
            UpdateBounds(crew.L)
            Spring.Echo("[SC] the lines are complete (map edge or row cap)")
        end
    end
    crew.exhausted = (free == 0 and active == 0 and (not crew.expand or crew.L.noMoreRows))
    for id, c in pairs(crew.cons) do
        if not Spring.GetUnitDefID(id) then
            DropCon(crew, id, "died")
        elseif c.cmdr and c.yield and crew.frame - (c.yieldFrame or crew.frame) > YIELD_TIMEOUT
               and not (c.target and c.target.state == "building") then   -- never walk off a frame mid-build
            FreeCommander(crew, c, "yield timeout")
        else
            if c.cmdr and c.yield and not c.yieldFrame then c.yieldFrame = crew.frame end
            Step(crew, c, res)
        end
    end
    if frame - crew.lastLog >= 900 then
        crew.lastLog = frame
        Spring.Echo(string.format("[SC] %d:%02d slots: mex %d wind %d nano %d, free %d, active %d, builders %d",
            math.floor(frame / 1800), math.floor(frame / 30) % 60, crew.nMex, crew.nWind, crew.nNano,
            free, active, nCons))
    end
end

-- ── Unit events ──────────────────────────────────────────────────────────────

function SC.OnUnitCreated(crew, unitID, defID, builderID)
    local c = builderID and crew.cons[builderID]
    local s = c and c.target
    if s and s.state == "ordered" and s.defID == defID then
        s.state, s.frameID = "building", unitID
        crew.byFrame[unitID] = s
    end
end

function SC.OnUnitFinished(crew, unitID, defID, x, z)
    local s = crew.byFrame[unitID]
    if not s then return end
    crew.byFrame[unitID] = nil
    s.state = (s.cls == "mex" and "mex") or (s.cls == "wind" and "wind") or "nano"
    s.unitID = unitID
    crew.byUnit = crew.byUnit or {}
    crew.byUnit[unitID] = s
    if s.cls == "mex" then crew.nMex = crew.nMex + 1
    elseif s.cls == "wind" then crew.nWind = crew.nWind + 1
    else crew.nNano = crew.nNano + 1 end
    for _, c in pairs(crew.cons) do
        if c.target == s then c.target, c.phase = nil, "idle" end   -- picks its next job on the next Update
    end
end

-- A finished building leaves its slot (destroyed, or a nano lifted away): the slot is free again.
local function ReleaseBuilt(crew, s)
    if s.state == "mex" then crew.nMex = crew.nMex - 1
    elseif s.state == "wind" then crew.nWind = crew.nWind - 1
    elseif s.state == "nano" then crew.nNano = crew.nNano - 1 end
    if crew.byUnit and s.unitID then crew.byUnit[s.unitID] = nil end
    s.state, s.unitID, s.cls, s.defID, s.owner, s.frameID = "free", nil, nil, nil, nil, nil
end

function SC.ReleaseUnit(crew, unitID)
    local s = crew.byUnit and crew.byUnit[unitID]
    if s then ReleaseBuilt(crew, s) end
    return s ~= nil
end

function SC.OnUnitDestroyed(crew, unitID)
    local s = crew.byFrame[unitID]
    if s then
        FreeSlot(crew, s, "frame destroyed")
        for _, c in pairs(crew.cons) do
            if c.target == s then c.target, c.phase = nil, "idle" end
        end
    end
    SC.ReleaseUnit(crew, unitID)
    if crew.cons[unitID] then DropCon(crew, unitID, "destroyed") end
end

-- The built nanos that have the fewest free slots around them (within NANO_R): the ones about to stop being
-- useful, so the cheapest to take away.  Returns up to n of { unitID, slot, open }, fewest open first.
function SC.LeastOpenNanos(crew, n)
    local list = {}
    for _, s in ipairs(crew.L.all) do
        if s.state == "nano" and s.unitID and Spring.GetUnitDefID(s.unitID) then
            local open = 0
            for _, o in ipairs(crew.L.all) do
                if o.state == "free" and Dist(s.wx, s.wz, o.wx, o.wz) <= SC.NANO_R then open = open + 1 end
            end
            list[#list + 1] = { unitID = s.unitID, slot = s, open = open }
        end
    end
    table.sort(list, function(a, b)
        if a.open ~= b.open then return a.open < b.open end
        return a.unitID < b.unitID
    end)
    local out = {}
    for i = 1, math.min(n or 1, #list) do out[i] = list[i] end
    return out
end

return SC
