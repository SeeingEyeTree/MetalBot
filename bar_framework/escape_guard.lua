-- bar_framework/escape_guard.lua
-- Keeps GROUND builders from being walled in by our own buildings.
--
-- The kickstart packs winds, mexes and nanos tightly around the base, and the order
-- they go up in can close a gap behind a con that is standing in it -- or seal the spot
-- a later building (the air lab) is meant to go.  A trapped con never arrives, and a
-- builder that never arrives means a build order that silently stalls.
--
-- Method: rasterise our own STRUCTURES onto a coarse grid (16 elmos, the build grid),
-- grown by the mover's half-width so a gap it cannot fit through counts as closed, then
-- flood-fill from where it stands.  If the fill reaches the ring of free cells around the
-- whole base, it is not trapped.  A few thousand cells and one pass, so it is cheap
-- enough to run every couple of seconds per builder.
--
-- What it does NOT see: terrain (cliffs), features (wrecks, trees), enemy units.  It
-- only reasons about buildings, because those are the ones we place ourselves.
--
--   EG.Check(builderID)                       -> nil if free, else {unitID, opens, cost, cells}
--   EG.WouldSeal(builderID, defID, wx, wz, planned) -> true if placing it would trap it
--   EG.OutsideReach(x, z, reach, moverHalf, planned) -> can anything outside get within reach
--
-- `planned` is an optional list of {defID, wx, wz} for buildings that are intended but
-- not standing yet, so a decision can account for the layout still to come.

local EG = {}

local CELL             = 16     -- elmos per grid cell
local MARGIN           = 96     -- free ring around the outermost structure
local SCAN_RADIUS      = 900    -- structures further than this from the builder are ignored
local MAX_CELLS_SIDE   = 240    -- hard cap on grid side, keeps a pathological scan bounded
local MAX_RECLAIM_COST = 700    -- never sacrifice anything dearer than this to free a builder
local MOVER_MIN, MOVER_MAX = 8, 32

local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function IsGroundBuilder(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.isBuilder and d.canMove and not d.canFly
end
EG.IsGroundBuilder = IsGroundBuilder

-- Half-width of the mover, in elmos.  xsize counts 8-elmo squares (a 3x3 building is 6).
local function MoverHalf(defID)
    local d = defID and UnitDefs[defID]
    local half = d and d.xsize and (d.xsize * 8) / 2 or 16
    return max(MOVER_MIN, min(MOVER_MAX, half))
end
EG.MoverHalf = MoverHalf

local function Footprint(defID)
    local d = UnitDefs[defID]
    if not d then return 0, 0 end
    return ((d.xsize or 0) * 8) / 2, ((d.zsize or d.ysize or 0) * 8) / 2
end

-- Our standing structures (nanoframes included: they occupy the ground) near a point.
local function GatherStructures(cx, cz)
    local out, n = {}, 0
    local units = Spring.GetUnitsInCylinder(cx, cz, SCAN_RADIUS)
    if not units then return out end
    local myAlly = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    for i = 1, #units do
        local uid   = units[i]
        local defID = Spring.GetUnitDefID(uid)
        local d     = defID and UnitDefs[defID]
        if d and not d.canMove and Spring.GetUnitAllyTeam(uid) == myAlly then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local hx, hz = Footprint(defID)
                local cost = d.metalCost or 0
                -- A frame is worth only what has been poured into it.
                local _, prog = Spring.GetUnitIsBeingBuilt(uid)
                if prog and prog < 1 then cost = cost * prog end
                n = n + 1
                out[n] = { id = uid, defID = defID, x = x, z = z, hx = hx, hz = hz,
                           cost = cost, factory = d.isFactory and true or false }
            end
        end
    end
    return out
end

local function PlannedObstacles(list, out)
    if not list then return out end
    for i = 1, #list do
        local p = list[i]
        local hx, hz = Footprint(p.defID)
        out[#out + 1] = { x = p.wx, z = p.wz, hx = hx, hz = hz, cost = 0, planned = true }
    end
    return out
end

-- ── Grid ─────────────────────────────────────────────────────────────────────

-- Build a blocked-cell grid covering every obstacle plus MARGIN, and any extra points.
local function BuildGrid(obstacles, moverR, ...)
    -- A cell is blocked when its CENTRE is inside the grown footprint.  Growing by the
    -- full half-width would close a gap exactly one mover wide (a con is 32 elmos wide;
    -- winds two cells apart leave a 32-elmo gap), which the engine does let it through.
    -- Backing the growth off by half a cell keeps one open cell in such a gap, while a
    -- gap one cell narrower still comes out closed.
    moverR = max(0, moverR - CELL * 0.5)
    local minx, maxx, minz, maxz = math.huge, -math.huge, math.huge, -math.huge
    local function grow(x, z, hx, hz)
        if x - hx < minx then minx = x - hx end
        if x + hx > maxx then maxx = x + hx end
        if z - hz < minz then minz = z - hz end
        if z + hz > maxz then maxz = z + hz end
    end
    for i = 1, #obstacles do
        local o = obstacles[i]
        grow(o.x, o.z, o.hx + moverR, o.hz + moverR)
    end
    local pts = { ... }
    for i = 1, #pts, 2 do grow(pts[i], pts[i + 1], 0, 0) end

    local x0, z0 = minx - MARGIN, minz - MARGIN
    local W = min(MAX_CELLS_SIDE, ceil((maxx + MARGIN - x0) / CELL))
    local H = min(MAX_CELLS_SIDE, ceil((maxz + MARGIN - z0) / CELL))
    local grid = { x0 = x0, z0 = z0, W = W, H = H, moverR = moverR, blk = {} }
    local blk = grid.blk
    for i = 1, W * H do blk[i] = 0 end
    for i = 1, #obstacles do
        local o = obstacles[i]
        o.gx0, o.gx1, o.gz0, o.gz1 = nil, nil, nil, nil
        EG._Stamp(grid, o, 1)
    end
    return grid
end

-- Add (delta=1) or remove (delta=-1) one obstacle's footprint.  A cell is blocked when
-- its CENTRE lies inside the footprint grown by the mover's half-width.
function EG._Stamp(grid, o, delta)
    local W, H, x0, z0, r = grid.W, grid.H, grid.x0, grid.z0, grid.moverR
    local ex, ez = o.hx + r, o.hz + r
    local gx0 = max(0, floor((o.x - ex - x0) / CELL))
    local gx1 = min(W - 1, floor((o.x + ex - x0) / CELL))
    local gz0 = max(0, floor((o.z - ez - z0) / CELL))
    local gz1 = min(H - 1, floor((o.z + ez - z0) / CELL))
    local blk = grid.blk
    for gz = gz0, gz1 do
        local cz = z0 + (gz + 0.5) * CELL
        if abs(cz - o.z) < ez then
            for gx = gx0, gx1 do
                local cx = x0 + (gx + 0.5) * CELL
                if abs(cx - o.x) < ex then
                    local i = gz * W + gx + 1
                    blk[i] = blk[i] + delta
                end
            end
        end
    end
end

local function CellOf(grid, x, z)
    local gx = min(grid.W - 1, max(0, floor((x - grid.x0) / CELL)))
    local gz = min(grid.H - 1, max(0, floor((z - grid.z0) / CELL)))
    return gx, gz
end

-- 4-connected flood fill.  The start cell is treated as free (a builder standing hard
-- against a building has its own cell inside that building's grown footprint).
-- Returns visited (array), escaped (reached the outer ring), count.
local function Flood(grid, sgx, sgz, wantVisited)
    local W, H, blk = grid.W, grid.H, grid.blk
    local visited, stack, sp, count, escaped = {}, {}, 0, 0, false
    -- Seed the 3x3 block round the builder, not just its own cell: it is standing there,
    -- so those cells are passable however tightly the grown footprints press on it.
    -- (A building is far thicker than this block, so it cannot leak through a wall.)
    for dz = -1, 1 do
        for dx = -1, 1 do
            local gx, gz = sgx + dx, sgz + dz
            if gx >= 0 and gx < W and gz >= 0 and gz < H then
                local i = gz * W + gx + 1
                if not visited[i] then visited[i] = true; sp = sp + 1; stack[sp] = i end
            end
        end
    end
    while sp > 0 do
        local i = stack[sp]; sp = sp - 1
        count = count + 1
        local gx, gz = (i - 1) % W, floor((i - 1) / W)
        if gx == 0 or gz == 0 or gx == W - 1 or gz == H - 1 then
            escaped = true
            if not wantVisited then return visited, true, count end
        end
        -- left, right, up, down
        if gx > 0     then local j = i - 1; if not visited[j] and blk[j] <= 0 then visited[j] = true; sp = sp + 1; stack[sp] = j end end
        if gx < W - 1 then local j = i + 1; if not visited[j] and blk[j] <= 0 then visited[j] = true; sp = sp + 1; stack[sp] = j end end
        if gz > 0     then local j = i - W; if not visited[j] and blk[j] <= 0 then visited[j] = true; sp = sp + 1; stack[sp] = j end end
        if gz < H - 1 then local j = i + W; if not visited[j] and blk[j] <= 0 then visited[j] = true; sp = sp + 1; stack[sp] = j end end
    end
    return visited, escaped, count
end
EG._Flood, EG._BuildGrid, EG._CellOf = Flood, BuildGrid, CellOf

-- ── Public API ───────────────────────────────────────────────────────────────

-- Is this ground builder boxed in?  nil when free.  Otherwise the structure to reclaim:
-- the cheapest one whose removal opens a route out, or failing that the cheapest one
-- touching the pocket (repeat calls then eat through a thick wall one piece at a time).
--
-- `protected` (optional): set of unitIDs that must never be offered as a reclaim
-- candidate, however cheap.  The caller uses this for the opening: those buildings are
-- executed literally and a half-built one abandoned to a reclaim is scarce early metal
-- thrown away, not a wall the bot can afford to eat through.  If protecting them leaves
-- no legal candidate, the builder is reported trapped rather than freed at their cost.
function EG.Check(builderID, protected)
    local defID = Spring.GetUnitDefID(builderID)
    if not IsGroundBuilder(defID) then return nil end
    local bx, _, bz = Spring.GetUnitPosition(builderID)
    if not bx then return nil end

    local obstacles = GatherStructures(bx, bz)
    if #obstacles == 0 then return nil end
    local grid = BuildGrid(obstacles, MoverHalf(defID), bx, bz)
    local sgx, sgz = CellOf(grid, bx, bz)
    local visited, escaped, cells = Flood(grid, sgx, sgz, true)
    if escaped then return nil end

    -- Candidates: structures whose grown footprint touches the pocket.
    local W, H = grid.W, grid.H
    local best, bestOpens, bestCost = nil, false, math.huge
    for k = 1, #obstacles do
        local o = obstacles[k]
        if not o.factory and o.cost <= MAX_RECLAIM_COST
           and not (protected and protected[o.id]) then
            local ex, ez = o.hx + grid.moverR, o.hz + grid.moverR
            local gx0 = max(0, floor((o.x - ex - grid.x0) / CELL) - 1)
            local gx1 = min(W - 1, floor((o.x + ex - grid.x0) / CELL) + 1)
            local gz0 = max(0, floor((o.z - ez - grid.z0) / CELL) - 1)
            local gz1 = min(H - 1, floor((o.z + ez - grid.z0) / CELL) + 1)
            local touches = false
            for gz = gz0, gz1 do
                for gx = gx0, gx1 do
                    if visited[gz * W + gx + 1] then touches = true; break end
                end
                if touches then break end
            end
            if touches then
                -- Would taking it away let the builder out?
                EG._Stamp(grid, o, -1)
                local _, opens = Flood(grid, sgx, sgz, false)
                EG._Stamp(grid, o, 1)
                if (opens and not bestOpens) or (opens == bestOpens and o.cost < bestCost) then
                    best, bestOpens, bestCost = o, opens, o.cost
                end
            end
        end
    end
    if not best then return { cells = cells } end   -- trapped, nothing we may remove
    return { unitID = best.id, defID = best.defID, opens = bestOpens,
             cost = best.cost, cells = cells, x = best.x, z = best.z }
end

-- Would putting `defID` at (wx, wz) trap this builder, when it is free right now?
-- `planned` (optional) are other intended buildings already committed to.
function EG.WouldSeal(builderID, defID, wx, wz, planned)
    local bDef = Spring.GetUnitDefID(builderID)
    if not IsGroundBuilder(bDef) then return false, 0 end
    local bx, _, bz = Spring.GetUnitPosition(builderID)
    if not bx then return false, 0 end

    local hx, hz = Footprint(defID)
    -- A builder standing on (or right beside) the site is not "sealed in" by it: the engine
    -- shoves mobile units off a build site.  Whether it ends up in a pocket is the
    -- recovery check's business, once the building stands.
    local mh = MoverHalf(bDef)
    if abs(bx - wx) < hx + mh and abs(bz - wz) < hz + mh then return false, 0 end
    local obstacles = PlannedObstacles(planned, GatherStructures(bx, bz))
    local cand = { x = wx, z = wz, hx = hx, hz = hz, cost = 0, planned = true }
    obstacles[#obstacles + 1] = cand
    -- Build the grid WITHOUT the candidate, so the "before" state is honest.
    local grid = BuildGrid(obstacles, MoverHalf(bDef), bx, bz)
    EG._Stamp(grid, cand, -1)
    local sgx, sgz = CellOf(grid, bx, bz)
    local _, freeBefore = Flood(grid, sgx, sgz, false)
    if not freeBefore then return false, 0 end       -- already trapped: not this building's doing
    EG._Stamp(grid, cand, 1)
    local _, freeAfter, cells = Flood(grid, sgx, sgz, false)
    -- Second result: how many cells the sealed-in pocket has (16-elmo cells), so a
    -- caller can tell a builder squeezed into a sliver from one boxed in a courtyard.
    return not freeAfter, cells
end

-- Can a unit coming from OUTSIDE the base get within `reach` elmos of (x, z)?  Used to
-- vet a spot for something a ground con has to build: if the ground around it is sealed
-- off, nobody can ever reach it.  `planned` folds in what is still to be built.
function EG.OutsideReach(x, z, reach, moverHalf, planned)
    local obstacles = PlannedObstacles(planned, GatherStructures(x, z))
    if #obstacles == 0 then return true end
    local grid = BuildGrid(obstacles, moverHalf or 16, x, z)
    local visited = Flood(grid, 0, 0, true)        -- (0,0) is in the free outer ring
    local W = grid.W
    local r2 = reach * reach
    local gx0, gz0 = CellOf(grid, x - reach, z - reach)
    local gx1, gz1 = CellOf(grid, x + reach, z + reach)
    for gz = gz0, gz1 do
        local cz = grid.z0 + (gz + 0.5) * CELL
        for gx = gx0, gx1 do
            if visited[gz * W + gx + 1] then
                local cx = grid.x0 + (gx + 0.5) * CELL
                local dx, dz = cx - x, cz - z
                if dx * dx + dz * dz <= r2 then return true end
            end
        end
    end
    return false
end

return EG
