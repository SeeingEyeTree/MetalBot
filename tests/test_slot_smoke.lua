-- tests/test_slot_smoke.lua
-- Run from the repo root:  lua5.1 tests/test_slot_smoke.lua [-v]   (or through lupa)
--
-- candidates/TILE_V2's three widgets with CFG.TILE_STYLE = "slots" against tests/spring_stub.lua.
-- The stub builds instantly, so this checks that the code paths run -- strips taken, slots filled
-- with mex / wind / nano, hand-off fires, the air lab goes beside the block -- not that it plays well.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
local lines = false      -- "lines" as an argument: LINES_FOREVER (extending lines, no mex grids)
local early = false      -- "early": income reaches 60 at once, so the hand-off comes while slots are still free
for _, a in ipairs(arg or {}) do
    if a == "-v" then W.verbose = true end
    if a == "lines" then lines = true end
    if a == "early" then early = true end
end

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what)
    end
end

-- A temporary copy of the macro with the slot style switched on.
local src = assert(io.open("candidates/TILE_V2/macro_controller.lua", "r")):read("*a")
local patched, n = src:gsub('TILE_STYLE%s*=%s*"blueprint"', 'TILE_STYLE          = "slots"')
check(n == 1, "found the TILE_STYLE config line")
if lines then
    local n2
    patched, n2 = patched:gsub('LINES_FOREVER%s*=%s*false', 'LINES_FOREVER       = true')
    check(n2 == 1, "found the LINES_FOREVER config line")
end
os.execute("mkdir tests\\_tmp_slots 2>nul")
local f = assert(io.open("tests/_tmp_slots/macro_controller.lua", "w"))
f:write(patched)
f:close()

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
W.res.metal.cur = 0
S.LoadWidget("tests/_tmp_slots/macro_controller.lua")
S.LoadWidget("candidates/TILE_V2/lab_controller.lua")
S.LoadWidget("candidates/TILE_V2/unit_controller.lua")
S.Callin("Initialize")
S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])
S.Spawn("corcom", 1, W.start[1][1], W.start[1][2])

local END = 10 * 60 * 30
for frame = 0, END, 10 do
    W.res.metal.cur = (frame % 3000 < 300) and 400 or 50
    -- Flows swing between "energy is tight" (pick wind) and "metal is tight" (pick mex), so both
    -- branches of the pressure rule run; the stub models no economy of its own.
    if math.floor(frame / 40) % 2 == 0 then
        W.res.metal.pull, W.res.metal.income = 20, 30
        W.res.energy.pull, W.res.energy.income = 300, 100
    else
        W.res.metal.pull, W.res.metal.income = 60, 20
        W.res.energy.pull, W.res.energy.income = 50, 400
    end
    -- (Lines mode: the stub fills slots within seconds, so the hand-off must come while some are still free.)
    if frame >= ((lines or early) and 100 or 6000) then W.res.metal.income = 60 end
    S.Frame(frame)
    if #W.errors > 0 then break end
end

for _, e in ipairs(W.errors) do print("LUA ERROR: " .. e) end
check(#W.errors == 0, "no Lua errors in the smoke run")

local function any(p) return #S.Log(p) > 0 end
local function countDef(team, name)
    local c = 0
    for _, u in pairs(W.units) do
        if u.team == team and UnitDefs[u.defID].name == name then c = c + 1 end
    end
    return c
end

check(any("%[MC%] tile style: slots"), "slot style loaded")
check(any("%[SC%] slot block: 4 strips, 64 slots, 16 nano spots"), "block laid out (2 x 2 strips)")
check(any("%[SC%] con %d+ takes lane"), "con bots took strips")
check(any("%[SC%] commander %d+ takes lane"), "commander became a stand-in builder")
check(countDef(0, "cormex") >= 20, "mexes built in slots (" .. countDef(0, "cormex") .. ")")
-- (Winds are counted from the crew's own summary: by the end of the run the macro's wind
-- consolidation may already have reclaimed some of the live ones.)
check(any("%[SC%] %d+:%d+ slots: mex %d+ wind [1-9]"), "winds built in slots when energy is the tighter resource")
check(countDef(0, "cornanotc") >= 1, "nanos built on the nano line (" .. countDef(0, "cornanotc") .. ")")
check(any("%[SC%] %d+:%d+ slots: mex"), "periodic slot summary logged")
check(any("HAND%-OFF"), "air lab queued on income")
check(countDef(0, "corap") >= 1, "air lab built")
check(any("%[SPINE%] start"), "spine started")
check(any("%[MC%] spine based on block cell"), "spine placed outside the block")
if lines then
    check(any("%[MC%] lines mode"), "lines mode: no hand-over to mex grids")
    check(#S.Log("%[MC%] grid cell") == 0, "lines mode: no mex grid cell was opened")
    check(any("%[SC%] %d+:%d+ strip row %d+ added"), "the lines extended (a strip row was added)")
    check(any("%[MC%] air lab spot: in the slot lines"), "air lab placed inside a line")
    check(any("%[SC%] air lab reserved on 6 slots") or any("%[SC%] air lab goes in the reserved bay"),
          "air lab reserved 6 slots")
    check(#S.Log("%[SC%] commander %d+ takes lane") >= 2, "commander went back to the lines after the lab")
    check(#S.Log("%[SC%] con %d+ takes lane") >= 1, "con bots on the lines")
else
    check(any("grid expansion started around the tile block"), "grid expansion from the block")
    -- The seeded first grid: helper air cons guard the grid's con until it has 2 nanos, then are released.
    check(any("%[MC%] seeded first grid: helper air cons"), "helper seed mode on")
    check(not any("%[LIFT%]"), "no nano lift in helper mode")
    check(any("%[MC%] air con %d+ helps con %d+ build a nano"), "an air con helped the grid's con")
    check(any("%[MC%] helper air con %d+ released"), "helpers were released once the grid had 2 nanos")
    -- The lines reserve 4 more strip rows from the start and add them as slots run low, then stop.
    local rows = #S.Log("%[SC%] %d+:%d+ strip row %d+ added")
    check(rows <= 4, "at most 4 extra strip rows (" .. rows .. ")")
    check(not any("strip row [6-9] added"), "no row past the 6th")
    local airCons = 0
    for _, l in ipairs(S.Log("%[MC%] air con")) do airCons = airCons + 1 end
    -- one grid at a time while income is under GRID_NORMAL_INCOME (60 here): nothing opens beyond the pace rule
    check(not any("%(bank:"), "no grid opened from the bank below 100 m/s")
    if early then
        check(any("%[SC%] air lab bay kept free"), "the lab bay was kept free from the commander's first lane")
        check(any("%[SC%] air lab goes in the reserved bay") or any("%[SC%] air lab reserved on 6 slots"),
              "air lab reserved inside the rows")
        check(any("%[MC%] air lab spot: in the slot lines"), "air lab placed in the rows")
        check(#S.Log("%[SC%] commander %d+ takes lane") >= 2, "commander went back to its lane after the lab")
    end
end

if W.verbose then
    for _, l in ipairs(S.Log("%[SC%]")) do print(l) end
    for _, l in ipairs(S.Log("%[MC%]")) do print(l) end
end

os.remove("tests/_tmp_slots/macro_controller.lua")
os.execute("rmdir tests\\_tmp_slots 2>nul")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then error("test_slot_smoke: " .. failures .. " failure(s)") end
