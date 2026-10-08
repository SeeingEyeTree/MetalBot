-- bar_framework/line_crew.lua  (LINE_BOT)
-- THE LINE: a strip of slots that starts at the first nano and runs away from the commander's starter,
-- four lanes (corridors), one builder per lane, nanos added only when build power is the limit.
--
-- Frame: the line_com blueprint's own frame ("b" = blueprint offsets from the anchor, 1 cell = 16 elmos;
-- b+x is right, b+z is down in the blueprint editor).  The starter (2 mex, winds, bot lab) sits LEFT of x = 112
-- and is NOT part of the line; the first nano (x 112..160) anchors it: the slot rows start at that nano's left edge.
--
--     z -432..-384   lane 4 (con 3)      outer lane, north
--     z -384..-256   two slot rows       centres -352, -288   (con 3's)
--     z -256..-128   two slot rows       centres -224, -160   (con 1's)
--     z -128..-80    lane 2 (con 1)      inner lane, north    (the only lane that reaches the nanos)
--     z  -80..-32    nano row            nano j at x = 136 + 48 j, z = -56, j = 0 .. 19  (j = 0 is the starter nano)
--     z  -32..16     lane 1 (commander)  inner lane, south
--     z   16..144    two slot rows       centres 48, 112      (the commander's)
--     z  144..272    two slot rows       centres 176, 240     (con 2's)
--     z  272..320    lane 3 (con 2)      outer lane, south
----   * a slot is 4 x 4 cells (64 elmos), 16 per row along x (x centres 144 + 64 k, k = 0 .. 15): a mex or a wind
--     (4 slots in a square would take a vehicle lab, 6 an air lab; not built yet)
--   * a lane serves the two rows beside it: 32 slots, "its section"
--   * nanos are built as needed (build power short), never up front
--   * a builder walks its corridor in ONE direction only, from the start of the line to its far end, and never
--     back; it stays in its corridor until its section is done.

local LC = {}

LC.SLOT       = 64
LC.K_FIRST    = 0              -- slot k has x centre = 144 + 64 k, k = 0 .. 15
LC.K_LAST     = 15
LC.X0         = 144
LC.SLOTS_PER_NANO = 8         -- build-power floor: one line nano per this many finished slots
LC.NANO_X0    = 136
LC.NANO_Z     = -56
LC.NANO_J     = { 0, 19 }
LC.COM_OFFSET = { x = -32, z = 16 }    -- commander spawn -> anchor.  The commander stands at b = (32, -16): 64 elmos
                                       -- from the mexes, clear of the lab and of every starter item (tested)
LC.FOOT_HALF  = 24
LC.WIND_U     = 1.0
LC.WIND_LOW_FRAC = 0.25      -- energy bank / storage under this: wind first (if energy is the more pressed resource)
-- Mex-or-wind signal (see WantWind).  Mexes cost energy upkeep and metal is rarely the limit on this line, so the
-- default is leaning to wind: a mex needs the energy to be covered, not just "not yet stalled".
LC.WIND_PULL_RATIO  = 0.90   -- energy pull / income above this: income is spoken for, the next mex would stall it
LC.WIND_BANK_OK     = 0.60   -- ...unless the energy bank is over this share of storage
LC.WIND_METAL_FLOAT = 0.30   -- metal bank over this share of storage: metal is not short, more mex only floats more
LC.WIND_BANK_RICH   = 0.85   -- energy bank over this share (and pull under income): energy is truly spare, mex again

-- z of each lane's centre line and of its two slot rows (nearest row first).
LC.LANES = {
    { id = 1, name = "commander", z =   -8, rows = {   48,  112 } },
    { id = 2, name = "con1",      z = -104, rows = { -160, -224 }, nano = true },
    { id = 3, name = "con2",      z =  296, rows = {  240,  176 } },
    { id = 4, name = "con3",      z = -408, rows = { -352, -288 } },
}LC.CON_LANES = { 2, 3, 4 }

local ORDER_TIMEOUT = 450
local MOVE_TIMEOUT  = 600
local MAX_RETRIES   = 3
local ARRIVE        = 16     -- elmos from a stop that count as standing on it
local CMD_STOP, CMD_MOVE, CMD_REPAIR = 0, 10, 40

-- Transition (line_transition.lua): an outer lane's builder places the air lab on the closest 6 open slots
-- (3 columns x 2 rows) and two nanos on open slots beside it.  Nothing is reserved ahead of time.
LC.TRANS_LANES = { 4, 3 }

local SIZE = { cormex = { 4, 4 }, corwin = { 3, 3 }, cornanotc = { 3, 3 }, corlab = { 6, 6 }, corrad = { 2, 2 },
               corestor = { 3, 3 },
               corvp = { 6, 6 }, corap = { 9, 6 } }
LC.SIZE = SIZE

local function Rotate(x, z, r)
    if     r == 1 then return -z,  x
    elseif r == 2 then return -x, -z
    elseif r == 3 then return  z, -x
    end
    return x, z
end
LC.Rotate = Rotate

local function Dist(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

function LC.World(L, bx, bz)
    local x, z = Rotate(bx, bz, L.rot)
    return L.anchorX + x, L.anchorZ + z
end

-- Footprint of a blueprint item in b-coordinates (facing 0 / 2: w x h, 1 / 3: swapped).
local function ItemBox(it)
    local s = SIZE[it.n]
    if not s and UnitDefNames and UnitDefNames[it.n] then
        local d = UnitDefNames[it.n]
        s = { (d.xsize or 2) / 2, (d.zsize or 2) / 2 }
    end
    s = s or { 2, 2 }
    local w, h = s[1] * 16, s[2] * 16
    if it.f == 1 or it.f == 3 then w, h = h, w end
    return { x0 = it.x - w / 2, x1 = it.x + w / 2, z0 = it.z - h / 2, z1 = it.z + h / 2 }
end
LC.ItemBox = ItemBox

local function Hits(a, b) return a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1 end

-- --- Layout ---

local function Sign(v) if v < 0 then return -1 end return 1 end

-- The line runs ACROSS the enemy axis (turned -90 degrees from the first version, which ran toward the map centre):
-- b+x (the line's long axis, the nano column and con 1's side) is perpendicular to the direction of the map centre.
-- The outer lane on the centre side (b-z or b+z, see line_transition's enemyLane) faces the enemy: vehicle lab and
-- spine go there; the mex grids go on the other side.
function LC.Rotation(comX, comZ, mapX, mapZ)
    local vx, vz = mapX / 2 - comX, mapZ / 2 - comZ
    local base
    if math.abs(vz) >= math.abs(vx) then
        base = Sign(vz) > 0 and 1 or 3        -- (old) b+x -> world +z / -z
    else
        base = Sign(vx) > 0 and 0 or 2        -- (old) b+x -> world +x / -x
    end
    return (base + 3) % 4                     -- -90 degrees
end

-- starter = the line_com layout (items are b-offsets from the anchor).
function LC.Layout(comX, comZ, mapX, mapZ, starter, rotOverride)
    local rot = rotOverride or LC.Rotation(comX, comZ, mapX, mapZ)
    local ox, oz = Rotate(LC.COM_OFFSET.x, LC.COM_OFFSET.z, rot)
    local L = { rot = rot, mapX = mapX, mapZ = mapZ,
                anchorX = math.floor(comX / 16 + 0.5) * 16 + ox,
                anchorZ = math.floor(comZ / 16 + 0.5) * 16 + oz,
                slots = {}, nanos = {}, lanes = {} }
    local boxes = {}
    for _, it in ipairs(starter and starter.layout or {}) do boxes[#boxes + 1] = ItemBox(it) end

    for _, def in ipairs(LC.LANES) do
        local lane = { id = def.id, name = def.name, z = def.z, nano = def.nano, rows = def.rows,
                       slots = {}, stops = {}, done = false }
        -- Walk stops: the midpoint of each pair of slot columns (0,1) (2,3) ... (14,15), in order of x.
        -- A builder only ever moves from one stop to a later one.
        for i = 1, 8 do
            local k0, k1 = 2 * (i - 1), 2 * (i - 1) + 1
            local bx = LC.X0 + 64 * (k0 + 0.5)
            local wx, wz = LC.World(L, bx, def.z)
            lane.stops[i] = { idx = i, bx = bx, bz = def.z, wx = wx, wz = wz, lane = def.id, k0 = k0, k1 = k1 }
        end
        for r, rz in ipairs(def.rows) do
            for k = LC.K_FIRST, LC.K_LAST do
                local bx = LC.X0 + 64 * k
                local wx, wz = LC.World(L, bx, rz)
                local box = { x0 = bx - 32, x1 = bx + 32, z0 = rz - 32, z1 = rz + 32 }
                local s = { kind = "slot", lane = def.id, bx = bx, bz = rz, wx = wx, wz = wz, k = k,
                            row = r, state = "free", retries = 0 }
                for _, b in ipairs(boxes) do
                    if Hits(box, b) then s.state = "starter" end
                end
                lane.slots[#lane.slots + 1] = s
                L.slots[#L.slots + 1] = s
            end
        end
        L.lanes[def.id] = lane
    end
    for j = LC.NANO_J[1], LC.NANO_J[2] do
        local bx = LC.NANO_X0 + 48 * j
        local wx, wz = LC.World(L, bx, LC.NANO_Z)
        local s = { kind = "nano", bx = bx, bz = LC.NANO_Z, wx = wx, wz = wz, j = j, state = "free", retries = 0 }
        local box = { x0 = bx - 24, x1 = bx + 24, z0 = LC.NANO_Z - 24, z1 = LC.NANO_Z + 24 }
        for _, b in ipairs(boxes) do
            if Hits(box, b) then s.state = "starter" end
        end
        L.nanos[#L.nanos + 1] = s
    end    return L
end

-- --- The crew ---

function LC.NewCrew(opts)
    local L = opts.layout
    local crew = { BP = opts.BP, L = L, cons = {}, byFrame = {}, frame = 0, onLaneDone = opts.onLaneDone,
                   nMex = 0, nWind = 0, nNano = 0, nEstor = 0, defs = {}, lanesDone = {}, laneOfBuilder = {},
                   onJobDone = opts.onJobDone, onJobStarted = opts.onJobStarted }
    for cls, name in pairs({ mex = "cormex", wind = "corwin", nano = "cornanotc", estor = "corestor" }) do
        crew.defs[cls] = UnitDefNames and UnitDefNames[name]
    end
    local free = 0
    for _, s in ipairs(L.slots) do if s.state == "free" then free = free + 1 end end
    Spring.Echo(string.format("[LN] line laid out: anchor (%d, %d) rot %d, %d slots (%d free after the starter), %d nano spots",
        L.anchorX, L.anchorZ, L.rot, #L.slots, free, #L.nanos))
    return crew
end

local function ReachOf(id)
    local d = UnitDefs[Spring.GetUnitDefID(id) or -1]
    return ((d and d.buildDistance) or 128) + LC.FOOT_HALF - 8
end

local function LaneOwner(crew, laneID)
    for _, c in pairs(crew.cons) do
        if c.lane.id == laneID then return c end
    end
    return nil
end

function LC.LaneFree(crew, laneID) return LaneOwner(crew, laneID) == nil end

-- The next lane for a con (lane 2 first: it has the nano column), or nil.
function LC.NextConLane(crew)
    for _, id in ipairs(LC.CON_LANES) do
        if LC.LaneFree(crew, id) and not (crew.reserved and crew.reserved[id]) then return id end
    end
    return nil
end

function LC.RowsAvailable(crew)
    local n = 0
    for _, id in ipairs(LC.CON_LANES) do if LC.LaneFree(crew, id) and not crew.lanesDone[id] then n = n + 1 end end
    return n
end

-- A walk a con makes before it starts on its lane, in the b-frame (world points are made by LC.World).  Con #1 leaves
-- the starter's bot lab (south of the line's start) for lane 2 (north of the nano column).  The direct way is through
-- the choke at the commander's spawn, where the commander stands building: the con walked into it and stuck.  So it
-- goes round the WEST end of the starter instead (clear of the starter mexes, which end at x = -160).
LC.LANE_ROUTES = {
    [2] = { { -208, 150 }, { -208, -120 }, { 100, -120 } },
}

function LC.LaneRoute(L, laneID)
    local r = LC.LANE_ROUTES[laneID]
    if not r then return nil end
    local out = {}
    for _, p in ipairs(r) do
        local wx, wz = LC.World(L, p[1], p[2])
        out[#out + 1] = { wx = wx, wz = wz }
    end
    return out
end

local function AddBuilder(crew, id, laneID, isCmdr, route)
    if crew.cons[id] then return end
    laneID = laneID or (isCmdr and 1 or LC.NextConLane(crew))
    local lane = laneID and crew.L.lanes[laneID]
    if not lane then return false end
    crew.cons[id] = { id = id, cmdr = isCmdr, lane = lane, phase = "idle", joinFrame = crew.frame, route = route }
    if isCmdr then crew.cmdr = id end
    Spring.GiveOrderToUnit(id, CMD_STOP, {}, {})
    -- Slots no stop of this lane can reach with THIS builder's range are marked, not left to hang the lane.
    local reach, far = ReachOf(id), 0
    for _, s in ipairs(lane.slots) do
        if s.state == "free" then
            local ok = false
            for _, st in ipairs(lane.stops) do
                if Dist(st.wx, st.wz, s.wx, s.wz) <= reach then ok = true; break end
            end
            if not ok then s.state = "far"; far = far + 1 end
        end
    end
    Spring.Echo(string.format("[LN] %s %d takes lane %d (%s), reach %d%s", isCmdr and "commander" or "con", id,
        lane.id, lane.name, reach, far > 0 and (", WARNING " .. far .. " slots out of reach") or ""))
    return true
end

function LC.AddCon(crew, id, laneID, route) return AddBuilder(crew, id, laneID, false, route) end
function LC.AddCommander(crew, id) return AddBuilder(crew, id, 1, true) end

local function FreeSlot(crew, s)
    if s.state == "free" or s.state == "dead" or s.state == "starter" or s.state == "far" then return end
    if s.frameID then crew.byFrame[s.frameID] = nil end
    s.state, s.owner, s.frameID, s.cls, s.defID = "free", nil, nil, nil, nil
    s.retries = s.retries + 1
    if s.retries >= MAX_RETRIES then s.state = "dead" end
end

function LC.Release(crew, id)
    local c = crew.cons[id]
    if not c then return end
    if c.target and c.target.state == "ordered" then FreeSlot(crew, c.target) end
    crew.cons[id] = nil
    if crew.cmdr == id then crew.cmdr = nil end
end

function LC.IsBuilder(crew, id) return crew.cons[id] ~= nil end

-- Hand a builder to someone else for a while (LINE_CLICK_v2: the commander walks away from a raid) and take it
-- back.  While suspended the crew gives it no orders.  An item it had only ordered is given up; a frame it was
-- building is kept, and on Resume it goes back to finishing it (REPAIR) if the frame still stands.
function LC.Suspend(crew, id)
    local c = crew.cons[id]
    if not c or c.phase == "suspended" then return end
    if c.target and c.target.state == "ordered" then FreeSlot(crew, c.target); c.target = nil end
    c.phase, c.hold = "suspended", nil
end

function LC.Resume(crew, id)
    local c = crew.cons[id]
    if not c or c.phase ~= "suspended" then return end
    local s = c.target
    if s and s.state == "building" and s.frameID and Spring.GetUnitDefID(s.frameID) then
        Spring.GiveOrderToUnit(id, CMD_REPAIR, { s.frameID }, {})
        c.phase = "build"
    else
        if s then FreeSlot(crew, s) end
        c.target, c.phase = nil, "idle"
    end
end

-- --- Deciding what to build ---

local function IssueBuild(crew, c, s, cls)
    local d = crew.defs[cls]
    if not d then return false end
    local x, z = crew.BP.SnapToBuildGrid(d.id, s.wx, s.wz, 0)
    local y = Spring.GetGroundHeight(x, z) or 0
    if Spring.TestBuildOrder(d.id, x, y, z, 0) == 0 then return false end
    Spring.GiveOrderToUnit(c.id, -d.id, { x, y, z, 0 }, {})
    s.state, s.owner, s.cls, s.defID, s.orderFrame = "ordered", c.id, cls, d.id, crew.frame
    c.target, c.phase = s, "build"
    return true
end

-- Free spots of `list` (slots or nano spots) within `reach` of (x, z): the nearest one.
local function Nearest(list, x, z, reach, wantLane)
    local best, bd = nil, math.huge
    for _, s in ipairs(list) do
        if s.state == "free" and (not wantLane or s.lane == wantLane) then
            local d = Dist(x, z, s.wx, s.wz)
            if d <= reach and d < bd then best, bd = s, d end
        end
    end
    return best
end

-- Wind or mex for the next slot?  Returns true for wind, plus a short reason for the log.
--   * energy stalled / draining: bank under WIND_LOW_FRAC, or utilisation over WIND_U      -> wind
--   * energy income already spoken for (pull > WIND_PULL_RATIO x income) with the bank under WIND_BANK_OK -> wind
--     (the old rule waited for the stall; the pull test sees it coming, and uses smoothed flows)
--   * metal floating (bank over WIND_METAL_FLOAT) and energy not spare                       -> wind
--     (a mex adds metal the bot is not spending; energy is what its spending lacks)
--   * otherwise mex.  Energy spare = bank over WIND_BANK_RICH and pull under income.
function LC.WantWind(crew, res)
    local um, ue = crew.BP.Utilization(res)
    local eStore = (res.energyStorage and res.energyStorage > 0) and res.energyStorage or 1
    local mStore = (res.metalStorage and res.metalStorage > 0) and res.metalStorage or 1
    local eFrac, mFrac = res.energy / eStore, res.metal / mStore
    local eInc = math.max(res.energyIncomeS or res.energyIncome or 0, 1)
    local ePull = res.energyPullS or res.energyPull or 0
    local ratio = ePull / eInc
    if eFrac < LC.WIND_LOW_FRAC or ue > LC.WIND_U then return true, "stall" end
    if ratio > LC.WIND_PULL_RATIO and eFrac < LC.WIND_BANK_OK then return true, "pull" end
    local spare = eFrac > LC.WIND_BANK_RICH and ratio < 1
    -- Float = a bank that is growing, i.e. income above pull (the opening bank with pull above income is not float).
    local mInc, mPull = res.metalIncomeS or res.metalIncome or 0, res.metalPullS or res.metalPull or 0
    if mFrac > LC.WIND_METAL_FLOAT and mInc > mPull and not spare then return true, "float" end
    return false, "mex"
end

-- True while the line has fewer nanos than the floor (one per SLOTS_PER_NANO finished slots).
function LC.NanoFloorShort(crew)
    local finished = crew.nMex + crew.nWind + crew.nEstor
    return crew.nNano < math.floor(finished / LC.SLOTS_PER_NANO)
end

-- Energy stall: energy is the more pressed resource and either at its limit or nearly empty.
local function EnergyStalled(crew, res)
    local um, ue = crew.BP.Utilization(res)
    local eFrac = (res.energyStorage and res.energyStorage > 0) and res.energy / res.energyStorage or 1
    return ue > um and (ue > LC.WIND_U or eFrac < LC.WIND_LOW_FRAC)
end

-- While energy stalls, more build power cannot be spent (the stall caps every build) -- the cure is wind.  So the
-- line's nanos in reach of a wind being built all go onto it (above the lab guard, below hand-offs).
local function FocusNanosOnWind(crew, res)
    local NANO = crew.BP.NANO
    if not (NANO and crew.BP.NanosInRange) or not EnergyStalled(crew, res) then return end
    for fid, s in pairs(crew.byFrame) do
        if s.cls == "wind" and s.state == "building" and Spring.GetUnitDefID(fid) then
            local x, _, z = Spring.GetUnitPosition(fid)
            if x then
                for _, n in ipairs(crew.BP.NanosInRange(x, z) or {}) do NANO.Assist(NANO.PRIO.CLEAR, n, fid) end
            end
        end
    end
end

-- Next job for an idle builder standing at (x, z).  Returns true if it ordered a build.
local function Decide(crew, c, res)
    local x, _, z = Spring.GetUnitPosition(c.id)
    if not x then return false end
    local reach = ReachOf(c.id)
    local um, ue = crew.BP.Utilization(res)
    local U = crew.BP.BALANCE_BP_U or 0.8
    local slot = Nearest(crew.L.slots, x, z, reach, c.lane.id)

    -- Build power: neither resource under pressure -> money goes unspent, so spend capacity is short.
    -- Only the nano lane can reach the nano column; the commander cannot build nanos at all.
    -- Floor: one nano per SLOTS_PER_NANO finished slots, so there is always build power in range of the line.
    -- Above the floor, nanos follow the utilisation rule (an energy stall means energy is short, not build power).
    local belowFloor = LC.NanoFloorShort(crew)
    if c.lane.nano and not c.cmdr and (belowFloor or (um < U and ue < U)) then
        local sp = Nearest(crew.L.nanos, x, z, reach)
        if sp then
            if IssueBuild(crew, c, sp, "nano") then return true end
            sp.state = "dead"
            return Decide(crew, c, res)
        end
    end

    if slot then
        -- Mex or wind: see LC.WantWind.  (Utilisation alone sits at ~0.99 in a stall and never clears 1.0, which is why
        -- the old rule left every slot a mex with the energy bank at 3-4%; WantWind also reads pull vs income and the
        -- metal float.)
        local wantWind, why = LC.WantWind(crew, res)
        if why ~= crew.lastWhy then
            crew.lastWhy = why
            Spring.Echo(string.format("[LN] %d:%02d slot choice -> %s (%s): energy %.0f%% inc %.0f pull %.0f | metal %.0f%% inc %.1f pull %.1f",
                math.floor(crew.frame / 1800), math.floor(crew.frame / 30) % 60, wantWind and "wind" or "mex", why,
                100 * res.energy / math.max(res.energyStorage or 1, 1), res.energyIncomeS or res.energyIncome or 0,
                res.energyPullS or res.energyPull or 0, 100 * res.metal / math.max(res.metalStorage or 1, 1),
                res.metalIncomeS or res.metalIncome or 0, res.metalPullS or res.metalPull or 0))
        end
        local first, second = "mex", "wind"
        if wantWind then first, second = "wind", "mex" end
        if IssueBuild(crew, c, slot, first) or IssueBuild(crew, c, slot, second) then return true end
        slot.state = "dead"            -- blocked terrain: never offer it again
        return Decide(crew, c, res)
    end
    return false
end

-- The first stop (outward from the centre) with something free in reach of it for this builder.
local function NextStop(crew, c)
    local reach = ReachOf(c.id)
    local x, _, z = Spring.GetUnitPosition(c.id)
    local from = c.ptr or 1          -- builders only walk AHEAD, away from the start of the line, never back
    for _, st in ipairs(c.lane.stops) do
        if st.idx >= from and not (c.skip and c.skip[st.idx])
           and Nearest(crew.L.slots, st.wx, st.wz, reach, c.lane.id) then return st end
    end
    -- Slots done.  The nano lane keeps going for nano spots while build power is short (Decide gates that).
    if c.lane.nano and not c.cmdr then
        local best, bd = nil, math.huge
        for _, st in ipairs(c.lane.stops) do
            if st.idx >= from and Nearest(crew.L.nanos, st.wx, st.wz, reach) then
                local d = x and Dist(x, z, st.wx, st.wz) or 0
                if d < bd then best, bd = st, d end
            end
        end
        return best
    end
    return nil
end

local function LaneRemaining(lane)
    local n = 0
    for _, s in ipairs(lane.slots) do
        if s.state == "free" or s.state == "ordered" or s.state == "building" then n = n + 1 end
    end
    return n
end

-- Slots still to be built on the whole line (free, ordered or being built; held lab sites are not counted).
function LC.SlotsRemaining(L)
    local n = 0
    for _, lane in ipairs(L.lanes) do n = n + LaneRemaining(lane) end
    return n
end

-- --- Jobs: one-off builds at a world position (the air lab, its nanos), run by one builder in turn ---
-- A job is issued when the builder is between items, never in place of a frame it is working on.

local JOB_TIMEOUT, JOB_TRIES = 900, 3

local function FinishJob(crew, c, j, state)
    j.state = state
    c.curJob = nil
    if c.phase == "job" then c.phase = "idle" end
    if crew.onJobDone then
        local ok, err = pcall(crew.onJobDone, j, state)
        if not ok then Spring.Echo("[LN] ERROR in job-done handler (" .. tostring(j.tag) .. "): " .. tostring(err)) end
    end
end

local function RetryJob(crew, c, j)
    j.tries = j.tries + 1
    if j.tries >= JOB_TRIES then
        FinishJob(crew, c, j, "failed")
    else
        j.state, j.unitID, c.curJob = "queued", nil, nil
        if c.phase == "job" then c.phase = "idle" end
        table.insert(c.jobs, 1, j)
    end
end

-- job = { name = unit def name, x, z = world position, f = facing, tag = anything the macro wants back }
function LC.QueueJob(crew, builderID, job)
    local c = crew.cons[builderID]
    if not c then return false end
    job.state, job.tries = "queued", 0
    c.jobs = c.jobs or {}
    c.jobs[#c.jobs + 1] = job
    if job.urgent then c.preempt = true end
    return true
end

function LC.LaneBuilder(crew, laneID) return LaneOwner(crew, laneID) end

local function StepJob(crew, c)
    local j = c.curJob
    if j then
        if j.state == "ordered" and crew.frame - j.orderFrame > JOB_TIMEOUT then
            RetryJob(crew, c, j)
        elseif j.state == "ordered" or j.state == "building" then
            return true
        else
            c.curJob = nil
        end
    end
    if not (c.jobs and #c.jobs > 0) then return false end
    j = table.remove(c.jobs, 1)
    local d = UnitDefNames and UnitDefNames[j.name]
    if not d then FinishJob(crew, c, j, "failed"); return false end
    local x, z = crew.BP.SnapToBuildGrid(d.id, j.x, j.z, j.f or 0)
    local y = Spring.GetGroundHeight(x, z) or 0
    if Spring.TestBuildOrder(d.id, x, y, z, j.f or 0) == 0 then
        c.curJob = j
        RetryJob(crew, c, j)
        return false
    end
    Spring.GiveOrderToUnit(c.id, -d.id, { x, y, z, j.f or 0 }, {})
    j.state, j.orderFrame, j.defID, j.wx, j.wz = "ordered", crew.frame, d.id, x, z
    c.curJob, c.phase = j, "job"
    return true
end

local ROUTE_ARRIVE, ROUTE_TIMEOUT = 40, 900

local function Step(crew, c, res)
    if c.phase == "help" then return end       -- guarding another builder (the macro ends it)
    if c.phase == "suspended" then return end  -- LC.Suspend: someone else commands it (the commander evading)
    -- An urgent job (the vehicle lab) drops whatever the builder is on: a slot frame it was "stuck" on stays in the
    -- world for the nanos / a later visit, and the builder goes straight to the job.
    if c.preempt and c.phase ~= "job" then
        local s = c.target
        if s and (s.state == "ordered" or s.state == "building") then
            if s.frameID then crew.byFrame[s.frameID] = nil end
            s.state, s.owner, s.frameID, s.cls, s.defID = "free", nil, nil, nil, nil
        end
        c.target, c.phase, c.preempt = nil, "idle", nil
        Spring.GiveOrderToUnit(c.id, CMD_STOP, {}, {})
    end
    -- Walk the lane's route first (see LC.LANE_ROUTES).
    if c.route then
        local wp = c.route[1]
        if not wp then
            c.route = nil
        elseif c.phase ~= "route" then
            c.phase, c.moveFrame = "route", crew.frame
            Spring.GiveOrderToUnit(c.id, CMD_MOVE, { wp.wx, Spring.GetGroundHeight(wp.wx, wp.wz) or 0, wp.wz }, {})
            return
        else
            local x, _, z = Spring.GetUnitPosition(c.id)
            if x and (Dist(x, z, wp.wx, wp.wz) <= ROUTE_ARRIVE or crew.frame - c.moveFrame > ROUTE_TIMEOUT) then
                table.remove(c.route, 1)
                c.phase = "idle"                 -- next waypoint (or the lane) on the next call
            end
            return
        end
    end
    if c.phase == "move" then
        local x, _, z = Spring.GetUnitPosition(c.id)
        if x and Dist(x, z, c.stop.wx, c.stop.wz) <= ARRIVE then
            c.phase = "idle"
        elseif x and crew.frame - c.moveFrame > MOVE_TIMEOUT then
            -- Never arrived (blocked path, cliff, wreck in the corridor).  Retrying the same stop forever left builders
            -- "walking" for minutes without placing anything; after two timeouts the stop is skipped and the builder
            -- places whatever is in reach of where it stands.
            local st = c.stop
            c.fails = c.fails or {}
            c.fails[st.idx] = (c.fails[st.idx] or 0) + 1
            Spring.Echo(string.format("[LN] builder %d did not reach stop %d of lane %d in %ds (at %d,%d; stop %d,%d; try %d)",
                c.id, st.idx, c.lane.id, MOVE_TIMEOUT / 30, x, z, st.wx, st.wz, c.fails[st.idx]))
            if c.fails[st.idx] >= 2 then
                c.skip = c.skip or {}
                c.skip[st.idx] = true
                Spring.Echo(string.format("[LN] builder %d skips stop %d of lane %d (unreachable)", c.id, st.idx, c.lane.id))
            end
            c.phase = "idle"
        else
            return
        end
    end
    if c.phase == "build" then
        local s = c.target
        if not s then c.phase = "idle"
        elseif s.state == "ordered" then
            if crew.frame - s.orderFrame > ORDER_TIMEOUT then
                FreeSlot(crew, s)
                c.target, c.phase = nil, "idle"
            else
                return
            end
        elseif s.state == "building" then
            return                       -- stay on the frame until it is finished
        else
            c.target, c.phase = nil, "idle"
        end
    end
    if c.hold then return end        -- the macro wants this builder free (after the item it just finished)
    if StepJob(crew, c) then return end
    if Decide(crew, c, res) then return end
    local stop = NextStop(crew, c)
    if stop then
        local x, _, z = Spring.GetUnitPosition(c.id)
        local d = x and Dist(x, z, stop.wx, stop.wz) or 0
        if d <= ARRIVE then
            -- Standing on the stop and Decide found nothing in reach.  Nano lane with the nano rule gated
            -- off: wait.  Otherwise the stop has nothing this builder can place (a slot Nearest sees from
            -- the stop but not from here): skip the stop for good instead of waiting on it forever.
            if not c.lane.nano or LaneRemaining(c.lane) > 0 then
                c.skip = c.skip or {}
                c.skip[stop.idx] = true
                Spring.Echo(string.format("[LN] builder %d skips stop %d of lane %d (nothing placeable from it)",
                    c.id, stop.idx, c.lane.id))
            end
            return
        end
        c.stop, c.phase, c.moveFrame, c.ptr = stop, "move", crew.frame, stop.idx
        c.walks = (c.walks or 0) + 1
        Spring.GiveOrderToUnit(c.id, CMD_MOVE, { stop.wx, Spring.GetGroundHeight(stop.wx, stop.wz) or 0, stop.wz }, {})
        return
    end
    -- Nothing ahead and nothing in reach: the builder is at the far end of its section.
    if not crew.lanesDone[c.lane.id] then
        crew.lanesDone[c.lane.id] = crew.frame
        local left = LaneRemaining(c.lane)
        Spring.Echo(string.format("[LN] %d:%02d lane %d (%s) DONE, walked %d stops%s", math.floor(crew.frame / 1800),
            math.floor(crew.frame / 30) % 60, c.lane.id, c.lane.name, c.walks or 0,
            left > 0 and (", " .. left .. " slots left behind") or ""))
        if crew.onLaneDone then pcall(crew.onLaneDone, c.lane.id, c.id) end
    end
end

function LC.Update(crew, frame, res)
    crew.frame = frame
    if frame % 30 == 0 then FocusNanosOnWind(crew, res) end
    for id, c in pairs(crew.cons) do
        if not Spring.GetUnitDefID(id) then
            Spring.Echo(string.format("[LN] builder %d on lane %d died", id, c.lane.id))
            LC.Release(crew, id)
        else
            Step(crew, c, res)
        end
    end
end

-- --- Unit events ---

function LC.OnUnitCreated(crew, unitID, defID, builderID)
    local c = builderID and crew.cons[builderID]
    local j = c and c.curJob
    if j and j.state == "ordered" and j.defID == defID then
        j.state, j.unitID = "building", unitID
        if crew.onJobStarted then
            local ok, err = pcall(crew.onJobStarted, j)
            if not ok then Spring.Echo("[LN] ERROR in job-started handler (" .. tostring(j.tag) .. "): " .. tostring(err)) end
        end
        return
    end
    local s = c and c.target
    if s and s.state == "ordered" and s.defID == defID then
        s.state, s.frameID = "building", unitID
        crew.byFrame[unitID] = s
    end
end

function LC.OnUnitFinished(crew, unitID, defID)
    for _, c in pairs(crew.cons) do
        local j = c.curJob
        if j and j.unitID == unitID then FinishJob(crew, c, j, "done"); return end
    end
    local s = crew.byFrame[unitID]
    if not s then return end
    crew.byFrame[unitID] = nil
    s.state = (s.cls == "mex" and "mex") or (s.cls == "wind" and "wind") or (s.cls == "estor" and "estor") or "nano"
    s.unitID = unitID
    if s.cls == "mex" then crew.nMex = crew.nMex + 1
    elseif s.cls == "wind" then crew.nWind = crew.nWind + 1
    elseif s.cls == "estor" then crew.nEstor = crew.nEstor + 1
    else crew.nNano = crew.nNano + 1 end
    for _, c in pairs(crew.cons) do
        if c.target == s then c.target, c.phase = nil, "idle" end
    end
end

function LC.OnUnitDestroyed(crew, unitID)
    for _, c in pairs(crew.cons) do
        local j = c.curJob
        if j and j.unitID == unitID and j.state == "building" then RetryJob(crew, c, j) end
    end
    local s = crew.byFrame[unitID]
    if s then
        FreeSlot(crew, s)
        for _, c in pairs(crew.cons) do
            if c.target == s then c.target, c.phase = nil, "idle" end
        end
    end
    for _, list in ipairs({ crew.L.slots, crew.L.nanos }) do
        for _, o in ipairs(list) do
            if o.unitID == unitID and (o.state == "mex" or o.state == "wind" or o.state == "nano" or o.state == "estor") then
                if o.state == "mex" then crew.nMex = crew.nMex - 1
                elseif o.state == "estor" then crew.nEstor = crew.nEstor - 1
                elseif o.state == "wind" then crew.nWind = crew.nWind - 1
                else crew.nNano = crew.nNano - 1 end
                o.state, o.unitID = "free", nil          -- rebuilt by its lane's builder
            end
        end
    end
    if crew.cons[unitID] then LC.Release(crew, unitID) end
end

-- --- Reporting ---

-- Per-lane counts for the [LN] log line.
function LC.LaneSummary(crew)
    local out = {}
    for _, lane in ipairs(crew.L.lanes) do
        local mex, wind, left = 0, 0, 0
        for _, s in ipairs(lane.slots) do
            if s.state == "mex" then mex = mex + 1
            elseif s.state == "wind" then wind = wind + 1
            elseif s.state == "free" or s.state == "ordered" or s.state == "building" then left = left + 1 end
        end
        out[#out + 1] = string.format("L%d m%d w%d left%d", lane.id, mex, wind, left)
    end
    return table.concat(out, " | ")
end

-- One word per builder for the [LN] status line: lane, phase, and for a walker its stop and distance to it.
function LC.BuilderSummary(crew)
    local out = {}
    for id, c in pairs(crew.cons) do
        local s = string.format("L%d:%s", c.lane.id, tostring(c.phase))
        if (c.phase == "move") and c.stop then
            local x, _, z = Spring.GetUnitPosition(id)
            s = s .. string.format(" s%d d%d", c.stop.idx, x and Dist(x, z, c.stop.wx, c.stop.wz) or -1)
        end
        out[#out + 1] = s
    end
    table.sort(out)
    return table.concat(out, ", ")
end

-- Builder time split since the last call: { build = n, walk = n, idle = n } samples.
function LC.SampleBuilders(crew)
    local t = crew.samples or { build = 0, walk = 0, idle = 0 }
    crew.samples = t
    for _, c in pairs(crew.cons) do
        if c.phase == "build" then t.build = t.build + 1
        elseif c.phase == "move" then t.walk = t.walk + 1
        else t.idle = t.idle + 1 end
    end
    return t
end

return LC
