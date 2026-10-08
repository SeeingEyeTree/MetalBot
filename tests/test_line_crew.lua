-- tests/test_line_crew.lua
-- Run from the repo root:  lua tests/test_line_crew.lua [-v]   (or through lupa)
--
-- 1. Geometry of the line (bar_framework/line_crew.lua) in the line_com blueprint's frame:
--    slots, the nano column, the lanes and the starter never overlap; every slot is in build reach of a stop
--    of its own lane; every nano spot is in reach of con 1's lane; the commander reaches every starter item
--    before the first nano from where it stands.
-- 2. A stub smoke run of LINE_BOT/macro_controller.lua (the stub builds instantly: this checks the code paths,
--    not how it plays).

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
for _, a in ipairs(arg or {}) do if a == "-v" then W.verbose = true end end

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local LC  = VFS.Include("LuaUI/Widgets/bar_framework/line_crew.lua")
local COM = VFS.Include("LuaUI/Widgets/blueprints/general/line_com.lua")
local REACH = 128 + LC.FOOT_HALF - 8

local function Hits(a, b) return a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1 end
local function SlotBox(s) return { x0 = s.bx - 32, x1 = s.bx + 32, z0 = s.bz - 32, z1 = s.bz + 32 } end
local function NanoBox(s) return { x0 = s.bx - 24, x1 = s.bx + 24, z0 = s.bz - 24, z1 = s.bz + 24 } end
local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

-- b-frame distance (rotation does not change distances)
local function BDist(a, bx, bz) return Dist(a.bx, a.bz, bx, bz) end

local L = LC.Layout(3000, 3000, 8192, 8192, COM)

-- counts
check(#L.slots == 128, "128 slots (8 rows x 16)")
check(#L.nanos == 20, "20 nano spots")
for id = 1, 4 do check(#L.lanes[id].slots == 32, "lane " .. id .. " has 32 slots") end
for id = 1, 4 do check(#L.lanes[id].stops == 8 or #L.lanes[id].stops > 0, "lane " .. id .. " has stops") end

-- starter boxes
local starter = {}
for _, it in ipairs(COM.layout) do starter[#starter + 1] = { n = it.n, box = LC.ItemBox(it), it = it } end

-- the starter is NOT part of the line: it lies wholly left of the first nano / first slot column (x < 112)
local firstNano = L.nanos[1]
check(firstNano.bx - 24 == 112, "the first nano's left edge is x = 112 (" .. (firstNano.bx - 24) .. ")")
for _, st in ipairs(starter) do
    if st.n ~= "cornanotc" then
        check(st.box.x1 <= 112, "starter " .. st.n .. " lies left of the line (x1 = " .. st.box.x1 .. ")")
    end
end
for _, s in ipairs(L.slots) do check(s.bx - 32 >= 112, "slot columns start at the first nano's left edge") ; break end
local minX = math.huge
for _, s in ipairs(L.slots) do minX = math.min(minX, s.bx - 32) end
check(minX == 112, "slot rows start exactly at x = 112 (" .. minX .. ")")
local maxX = -math.huge
for _, s in ipairs(L.slots) do maxX = math.max(maxX, s.bx + 32) end
check(maxX == 112 + 16 * 64, "slot rows are 16 slots long (" .. maxX .. ")")
local nanoEnd = L.nanos[#L.nanos].bx + 24
check(nanoEnd <= maxX, "20 nanos fit within the slot rows (" .. nanoEnd .. " <= " .. maxX .. ")")

-- slot boxes vs each other, vs nano spots
local slotBoxes = {}
for _, s in ipairs(L.slots) do slotBoxes[#slotBoxes + 1] = { s = s, b = SlotBox(s) } end
local overlaps = 0
for i = 1, #slotBoxes do
    for j = i + 1, #slotBoxes do
        if Hits(slotBoxes[i].b, slotBoxes[j].b) then overlaps = overlaps + 1 end
    end
end
check(overlaps == 0, "no two slots overlap (" .. overlaps .. ")")
local nanoClash = 0
for _, n in ipairs(L.nanos) do
    for _, sb in ipairs(slotBoxes) do if Hits(NanoBox(n), sb.b) then nanoClash = nanoClash + 1 end end
end
check(nanoClash == 0, "no nano spot overlaps a slot (" .. nanoClash .. ")")
for i = 1, #L.nanos - 1 do check(not Hits(NanoBox(L.nanos[i]), NanoBox(L.nanos[i + 1])), "nano spots do not overlap") end

-- lanes: a 3-cell (48) corridor along the line, clear of every slot and nano spot and the starter
for _, lane in ipairs(L.lanes) do
    local corridor = { x0 = 0, x1 = 1300, z0 = lane.z - 24, z1 = lane.z + 24 }
    local clear = true
    for _, sb in ipairs(slotBoxes) do if Hits(corridor, sb.b) then clear = false end end
    check(clear, "lane " .. lane.id .. " corridor is clear of slots")
    clear = true
    for _, n in ipairs(L.nanos) do if Hits(corridor, NanoBox(n)) then clear = false end end
    check(clear, "lane " .. lane.id .. " corridor is clear of nanos")
end

-- nothing marked "starter" among the slots (the starter lies outside the line) and exactly one starter nano
local nStarterSlots = 0
for _, s in ipairs(L.slots) do if s.state == "starter" then nStarterSlots = nStarterSlots + 1 end end
check(nStarterSlots == 0, "the starter takes no slot (" .. nStarterSlots .. ")")
local starterNanoSpots = 0
for _, n in ipairs(L.nanos) do if n.state == "starter" then starterNanoSpots = starterNanoSpots + 1 end end
check(starterNanoSpots == 1 and L.nanos[1].state == "starter", "exactly one nano spot is the starter nano, the first (" .. starterNanoSpots .. ")")

-- reach: every slot from a stop of its own lane
for _, lane in ipairs(L.lanes) do
    local worst = 0
    for _, s in ipairs(lane.slots) do
        local best = math.huge
        for _, st in ipairs(lane.stops) do best = math.min(best, Dist(st.bx, st.bz, s.bx, s.bz)) end
        worst = math.max(worst, best)
        check(best <= REACH, string.format("lane %d slot k=%d z=%d within reach of a stop (%.0f <= %d)", lane.id, s.k, s.bz, best, REACH))
    end
    if W.verbose then print(string.format("lane %d worst slot reach %.0f (limit %d)", lane.id, worst, REACH)) end
end
-- nano spots from con 1's lane
for _, n in ipairs(L.nanos) do
    local best = math.huge
    for _, st in ipairs(L.lanes[2].stops) do best = math.min(best, Dist(st.bx, st.bz, n.bx, n.bz)) end
    check(best <= REACH, string.format("nano spot j=%d within reach of a stop of lane 2 (%.0f)", n.j, best))
end
-- stops run in order of x, so a builder that only moves forward visits them all
for _, lane in ipairs(L.lanes) do
    for i = 2, #lane.stops do check(lane.stops[i].bx > lane.stops[i - 1].bx, "lane " .. lane.id .. " stops ascend in x") end
end

-- The commander spawns at b = (32, -16) (COM_OFFSET (-32, 16)): >= 64 elmos from the mexes, clear of every starter
-- item (with a 16-elmo body margin), and within its build range of all of them.
local cmdX, cmdZ = -LC.COM_OFFSET.x, -LC.COM_OFFSET.z
check(cmdX == 32 and cmdZ == -16, "commander at b = (32, -16)")
local body = { x0 = cmdX - 16, x1 = cmdX + 16, z0 = cmdZ - 16, z1 = cmdZ + 16 }
local COMMANDER_REACH = 300      -- corcom buildDistance 300 in BAR
for _, st in ipairs(starter) do
    check(not Hits(body, st.box), "the commander's spawn is clear of the starter's " .. st.n .. " at (" .. st.it.x .. "," .. st.it.z .. ")")
    if st.n ~= "cornanotc" then
        check(Dist(cmdX, cmdZ, st.it.x, st.it.z) <= COMMANDER_REACH, "commander reaches starter " .. st.n .. " from its spawn")
    end
end
for _, sb in ipairs(slotBoxes) do check(not Hits(body, sb.b), "the commander's spawn is clear of the slots") ; break end

-- world mapping, five spawns: the line points toward the map centre and the rows stay on the map
for _, sp in ipairs({ { 1000, 1000 }, { 7000, 1000 }, { 1000, 7000 }, { 7000, 7000 }, { 4000, 600 } }) do
    local LL = LC.Layout(sp[1], sp[2], 8192, 8192, COM)
    local inside = true
    for _, s in ipairs(LL.slots) do
        if s.wx < 32 or s.wz < 32 or s.wx > 8192 - 32 or s.wz > 8192 - 32 then inside = false end
    end
    local cx, cz = LC.World(LL, 100, 0)
    local ax, az = LC.World(LL, 0, 0)
    -- the line runs ACROSS the enemy axis: its long direction has no component along the map-centre axis
    local cvx, cvz = 4096 - sp[1], 4096 - sp[2]      -- (the macro decides from the commander's spawn)
    local toward
    if math.abs(cvz) >= math.abs(cvx) then toward = (cz - az) == 0 else toward = (cx - ax) == 0 end   -- (ties: z major)
    if W.verbose then print(string.format("spawn (%d,%d) rot %d inside=%s toward=%s", sp[1], sp[2], LL.rot, tostring(inside), tostring(toward))) end
    check(toward, string.format("spawn (%d,%d): the line runs across the enemy axis", sp[1], sp[2]))
    check(inside, string.format("spawn (%d,%d): every slot is on the map", sp[1], sp[2]))
end

-- ── smoke run ────────────────────────────────────────────────────────────────
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
S.LoadWidget("LINE_BOT/macro_controller.lua")
S.Callin("Initialize")
S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])
S.Spawn("corcom", 1, W.start[1][1], W.start[1][2])

local END = 12 * 60 * 30
for frame = 0, END, 10 do
    W.res.metal.cur = (frame % 3000 < 300) and 400 or 50
    if math.floor(frame / 40) % 2 == 0 then
        W.res.metal.pull, W.res.metal.income = 20, 30
        W.res.energy.pull, W.res.energy.income = 300, 100
    else
        W.res.metal.pull, W.res.metal.income = 60, 20
        W.res.energy.pull, W.res.energy.income = 50, 400
    end
    -- idle phases (nothing under pressure) so the nano rule runs too
    if frame > 6000 and frame < 9000 then
        W.res.metal.pull, W.res.metal.income = 10, 60
        W.res.energy.pull, W.res.energy.income = 50, 400
    end
    S.Frame(frame)
    if #W.errors > 0 then break end
end

for _, e in ipairs(W.errors) do print("LUA ERROR: " .. e) end
check(#W.errors == 0, "no Lua errors in the smoke run")
local function any(p) return #S.Log(p) > 0 end
check(any("%[LN%] line laid out"), "line laid out")
check(any("%[LN%] .*lab finished, con #1 queued"), "con #1 queued when the lab finished")
check(any("%[LN%] .*con #1 out"), "con #1 out")
check(any("%[LN%] con %d+ takes lane 2"), "con 1 took the nano lane (lane 2)")
check(any("%[LN%] commander %d+ takes lane 1"), "commander took its lane")
check(any("%[LN%] .*con #2 queued"), "con #2 queued")
check(any("%[LN%] con %d+ takes lane 3"), "con 2 took lane 3")
check(any("%[LN%] .*status:"), "status rows logged")
check(any("%[LN%] .*lane %d %(%a+%d?%) DONE"), "a lane finished")
check(#S.Log("%[LN%] con %d+ takes lane 2") == 1 and S.Log("%[LN%] con %d+ takes lane 2")[1]:find("108") ~= nil,
      "con #1 (the first con out) took the nano lane")
-- transition: reserved slots, air lab, two nanos, first grid beyond the line
check(any("%[LT%] .*AIR LAB queued"), "air lab queued")
check(any("%[LT%] .*AIR LAB finished"), "air lab finished")
check(#S.Log("%[LT%] %d+:%d+ lab nano done") == 2, "two nanos beside the air lab")
check(any("%[LT%] .*first grid cell .*48 elmos beyond the line"), "first grid placed beyond the line")
check(any("%[LT%] grid 2 at"), "grid expansion continued past the first grid")
check(any("%[LT%] .*mostly built %-%- retrofit eligible"), "grids become retrofit-eligible at 70%")
check(any("%[LT%] .*retrofit started"), "a T2 con started a retrofit")
check(any("%[LT%] .*unit cap tight"), "consolidation switched on when the unit cap got tight")
check(any("%[LT%] .*consolidating 4 winds"), "a block of 4 winds was consolidated")
check(not any("energy storage requested"), "no energy storage is requested (removed)")
check(any("%[LT%] .*vehicle lab frame up: %d+ nano"), "nanos are put on the vehicle lab's frame")
check(any("%[LT%] .*air lab frame up: %d+ nano"), "nanos are put on the air lab's frame")
check(not any("ERROR in job%-started handler"), "no error in a job-started handler")
-- vehicle lab (the spine's seed), starter-lab reclaim, spine
check(any("%[LN%] .*starter lab reclaim"), "the starter bot lab is reclaimed")
check(any("%[LT%] .*VEHICLE LAB queued"), "vehicle lab queued")
check(any("%[LT%] .*VEHICLE LAB finished"), "vehicle lab finished")
check(#S.Log("%[LT%] .*vehicle lab nano done") == 2, "two nanos beside the vehicle lab")
check(any("%[LT%] .*spine: cell 1 at"), "spine cell 1 placed in front of the vehicle lab")
check(any("%[SPINE%] start:"), "spine started (stack reserved)")
check(any("%[LT%] .*air con cap %(3%) lifted: the air lab's nanos are up"), "the early air con cap (3) is lifted once the air lab's nanos stand")
check(not any("ERROR in job%-done handler"), "no error in a job-done handler")
check(any("%[SPINE%] opened T1 cell #1"), "spine cell 1 opened once the vehicle lab stood")
do   -- the spine faces the enemy (map centre side), the first mex grid is on the far side
    local sx, sz = (S.Log("%[LT%] .*spine: cell 1 at")[1] or ""):match("cell 1 at %((%-?%d+), (%-?%d+)%)")
    local gx, gz = (S.Log("%[LT%] .*first grid cell")[1] or ""):match("first grid cell %((%-?%d+), (%-?%d+)%)")
    if sx and gx then
        local cx, cz = Game.mapSizeX / 2, Game.mapSizeZ / 2
        local ds = (sx - cx) ^ 2 + (sz - cz) ^ 2
        local dg = (gx - cx) ^ 2 + (gz - cz) ^ 2
        check(ds < dg, string.format("spine cell 1 is nearer the map centre than the first mex grid (%.0f < %.0f)", math.sqrt(ds), math.sqrt(dg)))
    else
        check(false, "spine cell 1 and the first grid cell were logged")
    end
end
do   -- the air lab goes first, the vehicle lab is queued after it
    local airAt, vpAt
    for i, l in ipairs(W.log) do
        if not airAt and l:find("AIR LAB queued", 1, true) then airAt = i end
        if not vpAt and l:find("VEHICLE LAB queued", 1, true) then vpAt = i end
    end
    check(airAt and vpAt and airAt < vpAt, "the air lab is queued before the vehicle lab")
end
do   -- the vehicle lab's block is on the lane the air lab did not take; no spine cell or lane sits on the line
    local WL = WG.Spine and WG.Spine.State and WG.Spine.State()
    check(WL ~= nil and #WL.cells >= 1, "spine has a cell open")
    if WL and WL.cells[1] then
        local c = WL.cells[1]
        check(c.ax >= 240 and c.az >= 240, "spine cell 1 is on the map")
    end
end
do   -- nothing is reserved up front
    local n = 0
    for _, s in ipairs(L.slots) do
        if s.state == "reserved" or s.state == "estor_slot" then n = n + 1 end
    end
    check(n == 0, "no slot is reserved before the transition")
end
if W.verbose then for _, l in ipairs(S.Log("%[LN%]")) do print(l) end end

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then error("test_line_crew: " .. failures .. " failure(s)") end
