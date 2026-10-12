-- tests/test_tile_bot.lua
-- Run from the repo root:  lua5.1 tests/test_tile_bot.lua [-v]
--
--   1. Geometry of the con-bot tile block (bar_framework/tile_crew.lua) with the blueprint
--      editor's footprints (buildings.json): no two buildings overlap anywhere in the 4x4
--      block for any spawn quadrant, the radar fits bad_com_start, an air lab fits the open
--      area of every tile outside row 0, each row keeps a corridor open end to end, and
--      every tile item is in con-bot range from the standing point.
--   2. A smoke run: TILE_BOT's three widgets against tests/spring_stub.lua.  The stub builds
--      instantly, so this checks the code paths run (cons queued one at a time, rows taken,
--      tiles finished, air lab, grids) -- not that the bot plays well.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.verbose = arg and arg[1] == "-v"

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what)
    end
end

local TC   = VFS.Include("LuaUI/Widgets/bar_framework/tile_crew.lua")
local COM  = VFS.Include("LuaUI/Widgets/blueprints/general/bad_com_start.lua")
local TILE = VFS.Include("LuaUI/Widgets/blueprints/general/con_bot_grid.lua")

-- Editor footprints in 16-elmo cells (buildings.json), {w, h} at facing 0.
local SIZE = { cormex = {4, 4}, corwin = {3, 3}, cornanotc = {3, 3}, corlab = {6, 6},
               corrad = {2, 2}, corap = {9, 6} }

local function Box(name, x, z, f)
    local s = assert(SIZE[name], "no size for " .. name)
    local w, h = s[1] * 16, s[2] * 16
    if f == 1 or f == 3 then w, h = h, w end
    return { n = name, x0 = x - w / 2, x1 = x + w / 2, z0 = z - h / 2, z1 = z + h / 2 }
end
local function Overlap(a, b)
    return a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1
end

-- Every building of the block in world space.
local function BlockBoxes(L)
    local boxes = {}
    local function add(bp, ax, az)
        for _, u in ipairs(bp.layout) do
            local rx, rz = TC.Rotate(u.x, u.z, L.rot)
            boxes[#boxes + 1] = Box(u.n, ax + rx, az + rz, (u.f - L.rot) % 4)
        end
    end
    add(COM, L.anchorX, L.anchorZ)
    for _, row in ipairs(L.rows) do
        for _, t in ipairs(row) do add(TILE, t.anchorX, t.anchorZ) end
    end
    return boxes
end

-- ── 1. Geometry ───────────────────────────────────────────────────────────────

do  -- the reference replay: spawn (3069, 5950), southern start on an 8192 map
    local L = TC.Layout(3069, 5950, 8192, 8192)
    check(L.anchorX == 3104 and L.anchorZ == 5968, "replay anchor reproduced (3104, 5968)")
    check(L.rot == 0 and L.colVec.x > 0 and L.rowVec.z > 0, "replay: columns +x, rows +z")
end

local spawns = { {1500, 1500}, {6700, 1500}, {1500, 6700}, {6700, 6700}, {4096, 600}, {600, 4096} }
for _, sp in ipairs(spawns) do
    local L = TC.Layout(sp[1], sp[2], 8192, 8192)
    local tag = string.format(" (spawn %d,%d)", sp[1], sp[2])
    local ex, ez = TC.Rotate(1, 0, L.rot)
    check(ex * L.colVec.x + ez * L.colVec.z > 0, "tile-local +x runs along the columns" .. tag)
    -- The bot lab (tile-local east) must face along the columns too.
    local lf = (1 - L.rot) % 4
    local fx = ({ [0] = 0, 1, 0, -1 })[lf]
    local fz = ({ [0] = 1, 0, -1, 0 })[lf]
    check(fx * L.colVec.x + fz * L.colVec.z > 0, "bot lab exits along the columns" .. tag)
    local boxes = BlockBoxes(L)
    check(#boxes == #COM.layout + 15 * #TILE.layout, "16 tiles laid out" .. tag)
    local clash = nil
    for i = 1, #boxes do
        for j = i + 1, #boxes do
            if Overlap(boxes[i], boxes[j]) then clash = clash or (boxes[i].n .. " / " .. boxes[j].n) end
        end
    end
    check(clash == nil, "no overlapping buildings in the block" .. tag .. (clash and (": " .. clash) or ""))
    local minX, maxX, minZ, maxZ = TC.BlockBounds(L)
    local inside = true
    for _, b in ipairs(boxes) do
        if b.x0 < minX or b.x1 > maxX or b.z0 < minZ or b.z1 > maxZ then inside = false end
    end
    check(inside, "every building inside BlockBounds" .. tag)
    check(minX > 0 and minZ > 0 and maxX < 8192 and maxZ < 8192, "block inside the map" .. tag)

    -- Air lab: fits the open area of every tile outside row 0, against everything.
    for _, row in ipairs(L.rows) do
        for _, t in ipairs(row) do
            if t.row ~= TC.LAB_EXIT_ROW then
                local x, z = TC.Local(L, t, TC.AIR_LAB)
                local lab = Box("corap", x, z, (0 - L.rot) % 4)
                local hit = nil
                for _, b in ipairs(boxes) do if Overlap(lab, b) then hit = hit or b.n end end
                check(hit == nil, "air lab fits tile " .. t.key .. tag .. (hit and (" (hits " .. hit .. ")") or ""))
            end
        end
    end

    -- Corridors: a 32-elmo con bot at tile-local z 56 crosses each row end to end.
    for ri, row in ipairs(L.rows) do
        local blocked = nil
        local first, last = row[1], row[#row]
        local x0, z0 = TC.Local(L, first, { x = -112, z = 56 })
        local x1, z1 = TC.Local(L, last,  { x = 128,  z = 56 })
        if ri == 1 then x0, z0 = TC.Local(L, { anchorX = L.anchorX, anchorZ = L.anchorZ }, { x = 112, z = 56 }) end
        local steps = 60
        for s = 0, steps do
            local px = x0 + (x1 - x0) * s / steps
            local pz = z0 + (z1 - z0) * s / steps
            local probe = { x0 = px - 16, x1 = px + 16, z0 = pz - 16, z1 = pz + 16 }
            for _, b in ipairs(boxes) do if Overlap(probe, b) then blocked = blocked or b.n end end
        end
        check(blocked == nil, "row " .. ri .. " corridor open end to end" .. tag
              .. (blocked and (" (blocked by " .. blocked .. ")") or ""))
    end
end

do  -- reach: every tile item within con range (136 + item half-size) of the standing point
    local worst = 0
    for _, u in ipairs(TILE.layout) do
        local s = SIZE[u.n]
        local d = math.sqrt((u.x - TC.STAND.x) ^ 2 + (u.z - TC.STAND.z) ^ 2) - s[1] * 8
        worst = math.max(worst, d)
    end
    check(worst <= 136, string.format("all tile items in reach of the standing point (worst %.0f)", worst))
    local stand = { x0 = TC.STAND.x - 16, x1 = TC.STAND.x + 16, z0 = TC.STAND.z - 16, z1 = TC.STAND.z + 16 }
    local onTop = false
    for _, u in ipairs(TILE.layout) do
        if Overlap(stand, Box(u.n, u.x, u.z, u.f)) then onTop = true end
    end
    check(not onTop, "standing point is clear of the tile's buildings")
end

do  -- the end cells and the block's grid cells line up with the 480 grid
    local L = TC.Layout(3069, 5950, 8192, 8192)
    local cells = TC.GridCells(L)
    check(#cells == 4, "block is 2x2 grid cells")
    local minX, maxX, minZ, maxZ = TC.BlockBounds(L)
    local okEdges = true
    for _, c in ipairs(cells) do
        local ex = math.min(math.abs(c.anchorX - 240 - minX), math.abs(c.anchorX + 240 - maxX))
        local ez = math.min(math.abs(c.anchorZ - 240 - minZ), math.abs(c.anchorZ + 240 - maxZ))
        if ex > 0.5 or ez > 0.5 then okEdges = false end
    end
    check(okEdges, "grid cells share the block's edges")
    for _, e in ipairs(TC.EndCells(L)) do
        check(not TC.InBlock(L, e.anchorX, e.anchorZ, 200), "end cell outside the block")
    end
end

-- ── 2. Smoke run ─────────────────────────────────────────────────────────────

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
-- Bank metal only when the test says so, so the con trigger can be watched.
W.res.metal.cur = 0
S.LoadWidget("TILE_BOT/macro_controller.lua")
S.LoadWidget("TILE_BOT/lab_controller.lua")
S.LoadWidget("TILE_BOT/unit_controller.lua")
S.Callin("Initialize")
S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])
S.Spawn("corcom", 1, W.start[1][1], W.start[1][2])

local conFrames = {}
local END = 14 * 60 * 30
for frame = 0, END, 10 do
    -- Metal piles up (and income rises) only every so often, so cons come one at a time.
    W.res.metal.cur = (frame % 3000 < 300) and 400 or 50
    if frame == 6000 then W.res.metal.income = 60 end
    S.Frame(frame)
    if #W.errors > 0 then break end
end

for _, e in ipairs(W.errors) do print("LUA ERROR: " .. e) end
check(#W.errors == 0, "no Lua errors in the smoke run")

local function any(p) return #S.Log(p) > 0 end
local function countDef(team, name)
    local n = 0
    for _, u in pairs(W.units) do
        if u.team == team and UnitDefs[u.defID].name == name then n = n + 1 end
    end
    return n
end
check(any("%[MC%] tile block at"), "tile block laid out")
-- (The spine's T1 lab makes con bots of its own; only the opening lab's count here.)
check(#S.Log("%[MC%] con #%d+ out at") == 4, "exactly 4 opening con bots")
check(any("%[SPINE%] start"), "spine started at the hand-off")
check(any("%[MC%] spine based on block cell"), "spine placed outside the tile block")
check(#S.Log("con #%d queued") == 3, "cons 2-4 queued one at a time by trigger")
check(#S.Log("%[TC%] con %d+ takes row") == 4, "each con took a row")
local firstCon = (S.Log("con #1 out at frame %d+ %((%d+)%)")[1] or ""):match("%((%d+)%)")
check(firstCon and #S.Log("%[TC%] con " .. firstCon .. " takes row 1 ") == 1,
      "con #1 gets row 1, beside the commander's tile")
check(any("%[TC%] tile .* done"), "tiles get finished")
check(any("finished row"), "a con finished its row")
check(any("HAND%-OFF"), "air lab queued on income")
check(countDef(0, "corap") >= 1, "air lab built")
check(any("grid expansion started around the tile block"), "grid expansion from the block")
check(countDef(0, "corrad") >= 1, "commander built the radar")
check(any("reclaiming bot lab"), "bot lab reclaimed once the air lab is up")
check(#S.Log("reclaiming con %d+") == 4, "each con reclaimed after its row")
check(countDef(0, "corlab") <= 1, "opening bot lab gone (only the spine's corlab may remain)")

if W.verbose then
    for _, l in ipairs(S.Log("%[MC%]")) do print(l) end
    for _, l in ipairs(S.Log("%[TC%]")) do print(l) end
end
print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
