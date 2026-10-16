-- tests/test_line_transition_modules.lua     python tests/run_lua.py tests/test_line_transition_modules.lua
-- The modules under bar_framework/line_transition/ are testable on their own: LT._X is the shared internals table they install
-- into, so a test builds a small T by hand and calls one module's function.  Checks:
--   * every module installed and exported what the others need (the X guard errors on a read of a name nobody exported);
--   * each con_broker job registers under its section (grid / energy / crew / line / spine), in JOB_ORDER's order, and the spine
--     section holds the cons the spine takes;
--   * grid_interrupts: a grid whose mexes are all up (or that has enough nanos) becomes retrofit-eligible, once.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame = 0

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local LT = VFS.Include("LuaUI/Widgets/bar_framework/line_transition.lua")
local CB = VFS.Include("LuaUI/Widgets/bar_framework/con_broker.lua")
local X = LT._X
check(X ~= nil, "LT._X is exported for tests")

-- exports other modules rely on
for _, name in ipairs({ "AssignCons", "QueueAirCon", "AddCompleted", "ReleaseCandidates", "UpdateEligibility", "RememberGridMexes",
                        "UpdateRetrofitCons", "CheckCapPressure", "UpdateNanoCrew", "SpineTakeCon", "SpineReturnCon", "StartSpine" }) do
    check(rawget(X, name) ~= nil, "X." .. name .. " is exported")
end
local ok = pcall(function() return X.NoSuchExport end)
check(not ok, "reading an export nobody made is an error (install-order guard)")

-- jobs and sections
local T = { CFG = LT.CFG, teamID = 0, ecoPaused = false, siloJobs = {}, consolidateJobs = {}, upgradeStates = {}, lab2Sessions = {},
            gridStates = {}, pendingGrids = {}, nanoCrew = {}, helpers = {}, fusHelpers = {}, windBlocks = {}, siloPending = {},
            gridFinished = {}, completed = {}, completedKeys = {}, assigned = {}, upgradedKeys = {}, orders = {}, airConsAlive = {},
            BP = { CanBuild = function() return true end } }
T.CB = CB.New{ isT2 = function() return false end, updateSession = function() end, echo = function() end }
for _, name in ipairs({ "silo", "consolidate", "retrofit", "lab2", "linenano", "nanocrew", "grid", "fusionhelp", "gridhelp", "radar", "spine" }) do
    check(type(X.jobs[name]) == "function", "job '" .. name .. "' has a registration function")
    X.jobs[name](T, T.CB)
end
local sec = CB.Sections(T.CB)
local function Has(section, job)
    for _, n in ipairs(sec[section] or {}) do if n == job then return true end end
    return false
end
check(Has("grid", "grid") and Has("grid", "retrofit") and Has("grid", "gridhelp") and Has("grid", "silo"), "grid section: grid, retrofit, gridhelp, silo")
check(Has("energy", "consolidate") and Has("energy", "fusionhelp"), "energy section: consolidate, fusionhelp")
check(Has("crew", "nanocrew") and Has("crew", "radar"), "crew section: nanocrew, radar")
check(Has("line", "lab2") and Has("line", "linenano"), "line section: lab2, linenano")
check(Has("spine", "spine"), "spine section: the spine owner is a registered job")
check(sec.other == nil, "no job without a section")

-- the spine takes a con under its own section
local con = S.Spawn("corca", 0, 1000, 1000, { silent = true })
CB.Add(T.CB, con)
local got = X.SpineTakeCon(T, nil, false)
check(got == con, "SpineTakeCon takes the free con (" .. tostring(got) .. ")")
local t1 = CB.SectionHeld(T.CB, "spine")
check(t1 == 1, "the spine section holds it (" .. tostring(t1) .. ")")

-- grid_interrupts
local function Grid(items)
    return { anchorX = 100, anchorZ = 200, queue = items, done = false }
end
local function Mex(built) return { cls = "metal", act = "build", built = built, status = built and "built" or "queued" } end
local function Nano(built) return { cls = "nano", act = "build", built = built, status = built and "built" or "queued" } end
do
    local t = { CFG = setmetatable({ RETROFIT_MEX_DONE = true, RETROFIT_MIN_NANOS = false }, { __index = LT.CFG }), gridStates = {},
                gridFinished = {}, completed = {}, completedKeys = {}, assigned = {}, pendingGrids = {}, frame = 120, teamID = 0,
                CB = T.CB, orders = {}, airConsAlive = {} }
    t.gridStates[1] = Grid({ Mex(true), Mex(false), Nano(true) })
    X.UpdateEligibility(t, 120)
    check(not t.gridFinished["100,200"], "a grid with a mex still to build is not eligible")
    t.gridStates[1].queue[2].built = true
    X.UpdateEligibility(t, 121)       -- not a multiple of 60: nothing happens
    check(not t.gridFinished["100,200"], "the check runs once a second (frame % 60)")
    X.UpdateEligibility(t, 180)
    check(t.gridFinished["100,200"] == true, "all mexes up -> retrofit eligible")
    check(#t.completed == 1, "...and listed as completed once")
    X.UpdateEligibility(t, 240)
    check(#t.completed == 1, "...not again on the next look")
end
do
    local t = { CFG = setmetatable({ RETROFIT_MEX_DONE = true, RETROFIT_MIN_NANOS = 2 }, { __index = LT.CFG }), gridStates = {},
                gridFinished = {}, completed = {}, completedKeys = {}, assigned = {}, pendingGrids = {}, frame = 60, teamID = 0,
                CB = T.CB, orders = {}, airConsAlive = {} }
    t.gridStates[1] = Grid({ Mex(true), Nano(true), Nano(false) })
    X.UpdateEligibility(t, 60)
    check(not t.gridFinished["100,200"], "RETROFIT_MIN_NANOS: one nano is not enough")
    t.gridStates[1].queue[3].built = true
    X.UpdateEligibility(t, 120)
    check(t.gridFinished["100,200"] == true, "RETROFIT_MIN_NANOS: two nanos standing -> eligible")
end

-- radar_posts: a radar tower beside each blob of the maneuver plan, none without blobs
do
    local started = {}
    local t = { CFG = LT.CFG, teamID = 0, frame = 9000, ecoPaused = false, CB = T.CB,
                WG = { MetalBot = { homeX = 2400, homeZ = 1900, blobs = { { x = 3400, z = 1900, n = 6 }, { x = 4800, z = 1900, n = 6 }, { x = 6500, z = 1900, n = 6 } } } },
                BP = { CanBuild = function() return true end,
                       New = function(layout, con, x, z) started[#started + 1] = { n = layout.layout[1].n, x = x, z = z, con = con }; return { done = false } end } }
    local before = #X.RadarUnmet(t, 9000)
    check(before == 3, "radar_posts: three blobs and no radar -> three sites (" .. before .. ")")
    local sites = X.RadarUnmet(t, 9000)
    check(math.abs(sites[1].x - 3200) < 5 and math.abs(sites[1].z - 1900) < 5, "radar_posts: the site is 200 behind the blob toward the base (" .. math.floor(sites[1].x) .. ")")
    S.Spawn("corrad", 0, 3300, 1900, { silent = true })
    t.radarListF = nil
    local after = #X.RadarUnmet(t, 9100)
    check(after == 2, "radar_posts: a radar within 900 of a blob covers it (" .. after .. " left)")
    -- the job: one con, at the first blob without a radar
    local t2 = t
    local cb = CB.New{ isT2 = function() return false end, updateSession = function() end, echo = function() end }
    t2.CB = cb
    X.jobs.radar(t2, cb)
    local con2 = S.Spawn("corca", 0, 3000, 1500, { silent = true })
    CB.Add(cb, con2)
    CB.Update(cb, 9100, { metal = { 1000, 2000, 0, 300 } }, true)
    check(#started == 1 and started[1].n == "corrad", "radar_posts: the free air con is sent to build a corrad (" .. #started .. " started)")
    check(started[1] and started[1].x > 4000, "...at the first blob that has none (x=" .. tostring(started[1] and math.floor(started[1].x)) .. ")")
    -- no blobs published (any other plan): nothing wanted
    t.WG.MetalBot.blobs = nil
    check(#X.RadarUnmet(t, 9200) == 0, "radar_posts: no blobs (another stance plan) -> no radar job")
end

print(string.format("line_transition modules: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
