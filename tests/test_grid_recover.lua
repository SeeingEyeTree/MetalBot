-- tests/test_grid_recover.lua     python tests/run_lua.py tests/test_grid_recover.lua
-- line_transition GRID_RECOVER and SECOND_AIR_LAB's site pick (RAID_BOT, user 2026-10-13):
--   * a finished grid's mex spots are remembered (merged over re-runs);
--   * a spot empty on two looks in a row queues the grid first in pendingGrids (recover = true); one look is not enough;
--   * not while a raid cluster is near the grid; not while the grid is being built / retrofitted;
--   * a retrofitted grid is opened for retrofit again instead of re-run;
--   * the second air lab takes a 3x2 block of line slots (fewest mexes first) and nano slots beside it.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local LT = VFS.Include("LuaUI/Widgets/bar_framework/line_transition.lua")
local X = LT._test
check(X.RememberGridMexes and X.UpdateRecovery and X.PickLab2Site, "test hooks exported")

local function NewT()
    W.units, W.orders, W.log = {}, {}, {}
    WG = { MetalBot = { threats = {} } }
    local cfg = {}
    for k, v in pairs(LT.CFG) do cfg[k] = v end
    cfg.GRID_RECOVER = true
    return { CFG = cfg, teamID = 0, WG = WG, gridStates = {}, upgradeStates = {}, pendingGrids = {}, gridRotation = {},
             upgradedKeys = {}, siloPending = {}, freeT2Cons = {}, completed = {}, gridFinished = {} }
end

local ax, az = 4000, 4000
local spots = { { 3900, 3900 }, { 4100, 3900 }, { 4000, 4150 } }
local function Grid(statusOf)
    local q = {}
    for i, p in ipairs(spots) do
        q[#q + 1] = { cls = "metal", act = "build", status = statusOf and statusOf(i) or "built", wx = p[1], wz = p[2] }
    end
    q[#q + 1] = { cls = "energy", act = "build", status = "built", wx = 4200, wz = 4200 }
    return { anchorX = ax, anchorZ = az, queue = q }
end

-- plain grid
local T = NewT()
local mex = {}
for i, p in ipairs(spots) do mex[i] = S.Spawn("cormex", 0, p[1], p[2], { silent = true }) end
X.RememberGridMexes(T, Grid())
check(T.gridMexes and #T.gridMexes[ax .. "," .. az].spots == 3, "three mex spots remembered (wind ignored)")
X.UpdateRecovery(T, 300)
check(#T.pendingGrids == 0, "all mexes standing: nothing queued")
S.Kill(mex[2])
X.UpdateRecovery(T, 600)
check(#T.pendingGrids == 0, "one look at an empty spot is not enough")
X.UpdateRecovery(T, 700)
check(#T.pendingGrids == 0, "looks are RECOVER_EVERY apart")
WG.MetalBot.threats = { { x = 4300, z = 4000 } }
X.UpdateRecovery(T, 900)
check(#T.pendingGrids == 0, "a raid cluster near the grid: wait")
WG.MetalBot.threats = {}
X.UpdateRecovery(T, 1200)
check(#T.pendingGrids == 1 and T.pendingGrids[1].recover == true and T.pendingGrids[1].anchorX == ax,
    "the empty spot confirmed and the raid gone: the grid is queued first for a re-run")
check(#S.Log("%[LT%] .*RECOVER grid %(4000, 4000%): 1 of 3 mex spots empty %-> grid re%-run") == 1, "the recovery is logged")
X.UpdateRecovery(T, 1500)
X.UpdateRecovery(T, 1800)
check(#T.pendingGrids == 1, "a queued grid is not queued twice")

-- the re-run skipped the standing mexes: the spots are kept, not lost
X.RememberGridMexes(T, Grid(function(i) return i == 2 and "built" or "skipped" end))
check(#T.gridMexes[ax .. "," .. az].spots == 3, "a re-run's skipped (standing) mexes stay on the list")

-- busy grid: not judged
T = NewT()
for i, p in ipairs(spots) do if i ~= 1 then S.Spawn("cormex", 0, p[1], p[2], { silent = true }) end end
X.RememberGridMexes(T, Grid())
T.upgradeStates = { { anchorX = ax, anchorZ = az } }
X.UpdateRecovery(T, 300); X.UpdateRecovery(T, 600); X.UpdateRecovery(T, 900)
check(#T.pendingGrids == 0, "a grid being retrofitted is not judged (its T1 mexes are reclaimed on purpose)")

-- a moho on the spot counts as a mex
T = NewT()
S.Spawn("cormoho", 0, spots[1][1], spots[1][2], { silent = true })
for i, p in ipairs(spots) do if i ~= 1 then S.Spawn("cormex", 0, p[1], p[2], { silent = true }) end end
X.RememberGridMexes(T, Grid())
X.UpdateRecovery(T, 300); X.UpdateRecovery(T, 600)
check(#T.pendingGrids == 0, "a T2 mex on the spot counts")

-- retrofitted grid: retrofit re-opened
T = NewT()
for i, p in ipairs(spots) do if i ~= 3 then S.Spawn("cormoho", 0, p[1], p[2], { silent = true }) end end
X.RememberGridMexes(T, Grid())
T.upgradedKeys[ax .. "," .. az] = true
T.upgradeBP = { layout = { { n = "cormoho" } } }
X.UpdateRecovery(T, 300); X.UpdateRecovery(T, 600)
check(T.upgradedKeys[ax .. "," .. az] == nil and #T.pendingGrids == 0, "a retrofitted grid is opened for retrofit again")
check(#S.Log("retrofit re%-opened") == 1, "...and logged")

-- off: nothing
T = NewT()
T.CFG.GRID_RECOVER = false
X.RememberGridMexes(T, Grid())
X.UpdateRecovery(T, 300); X.UpdateRecovery(T, 600)
check(#T.pendingGrids == 0, "GRID_RECOVER off: nothing")

-- ── second air lab site ───────────────────────────────────────────────────────
local LC = VFS.Include("LuaUI/Widgets/bar_framework/line_crew.lua")
local L = LC.Layout(3000, 3000, 12288, 12288, nil)
T = NewT()
T.LC, T.L, T.CFG.LAB2_NANOS = LC, L, 4
local lane = L.lanes[3]
for _, s in ipairs(L.slots) do s.state = "mex" end
-- one 3x2 block of winds in lane 3 (k = 5..7, rows 1-2) and winds beside it (k = 4 and 8)
for _, s in ipairs(lane.slots) do
    if s.row <= 2 and s.k >= 4 and s.k <= 8 then s.state = "wind" end
end
local site = X.PickLab2Site(T)
check(site ~= nil, "a 3x2 block of winds is found")
if site then
    local ok = true
    for _, s in ipairs(site.slots) do if s.state ~= "wind" or s.k < 4 or s.k > 8 then ok = false end end
    check(#site.slots == 6 and ok, "the block is six wind slots")
    local nOk = #site.nanos >= 2
    for _, s in ipairs(site.nanos) do if s.state ~= "wind" then nOk = false end end
    check(nOk, "nano slots are wind slots beside it (" .. #site.nanos .. ")")
end
check(site and site.mexes == 0, "the all-wind block is preferred over blocks with mexes")
-- no wind block left: the block with the fewest mexes (real lines are about half mexes)
for _, s in ipairs(lane.slots) do if s.k == 6 and s.row == 1 then s.state = "mex" end end
local s2 = X.PickLab2Site(T)
check(s2 and s2.mexes == 1, "with no all-wind block, a block with one mex is taken (" .. tostring(s2 and s2.mexes) .. ")")
for _, s in ipairs(L.slots) do s.state = "reserved" end
check(X.PickLab2Site(T) == nil, "no built slots (reserved / starter): no site")

print(string.format("grid_recover: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
