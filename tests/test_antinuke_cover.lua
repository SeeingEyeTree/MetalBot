-- tests/test_antinuke_cover.lua: defense_crew.CoverPoints (the anti-nuke cover planner).
-- Run from the repo root: python tests/run_lua.py tests/test_antinuke_cover.lua
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
WG = {}
local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local DC = VFS.Include("LuaUI/Widgets/bar_framework/defense_crew.lua")

local function cluster(cx, cz, n, w)
    local t = {}
    for i = 1, n do t[#t + 1] = { x = cx + (i % 5) * 60, z = cz + math.floor(i / 5) * 60, w = w or 100 } end
    return t
end
local items = {}
for _, c in ipairs({ cluster(1000, 1000, 20), cluster(5000, 1000, 20), cluster(1000, 5000, 20), cluster(5000, 5000, 20, 300) }) do
    for _, it in ipairs(c) do items[#items + 1] = it end
end
local pts = DC.CoverPoints(items, 1000, 8)
check(#pts == 4, "four separate clusters need four cover points (" .. #pts .. ")")
check(pts[1].x > 4800 and pts[1].z > 4800, "the heaviest cluster is covered first")
local one = DC.CoverPoints(cluster(2000, 2000, 30), 1000, 8)
check(#one == 1, "one tight cluster needs one point (" .. #one .. ")")
local capped = DC.CoverPoints(items, 300, 2)
check(#capped == 2, "the count is capped (" .. #capped .. ")")
-- every item is within R of some point when the cap allows
local R, all = 1000, true
for _, it in ipairs(items) do
    local ok = false
    for _, p in ipairs(pts) do if (p.x - it.x) ^ 2 + (p.z - it.z) ^ 2 <= R * R then ok = true end end
    all = all and ok
end
check(all, "every structure is inside some point's radius")
check(#DC.CoverPoints({}, 1000, 8) == 0, "no structures, no points")

-- COVER_REPLACE_MEX (DRAGON_ECO): the corfmd goes on the nearest mex, which is reclaimed first; a factory in the way rules a mex out
S.W.units, S.W.orders, S.W.log, S.W.errors = {}, {}, {}, {}
DC.Init{ teamID = 0, WG = WG }
local fmd = UnitDefNames.corfmd.id
local mexNear = S.Spawn("cormex", 0, 3200, 3000, { silent = true })
local mexFar  = S.Spawn("cormex", 0, 3350, 3000, { silent = true })
local x, _, z, blockers = DC._CoverSite(fmd, 3000, 3000)
DC.COVER_REPLACE_MEX = true
local mx, _, mz, mblock = DC._CoverSite(fmd, 3000, 3000)
check(mx == 3200 and mz == 3000, "replace-mex: the corfmd is centred on the nearest mex (" .. tostring(mx) .. ", " .. tostring(mz) .. ")")
local hasMex = false
for _, b in ipairs(mblock or {}) do if b == mexNear then hasMex = true end end
check(hasMex, "replace-mex: that mex is reclaimed first")
S.Spawn("corlab", 0, 3200, 3040, { silent = true })
mx, _, mz = DC._CoverSite(fmd, 3000, 3000)
check(not (mx == 3200 and mz == 3000), "replace-mex: a mex next to a factory is not used")
local far = DC._CoverSite(fmd, 9000, 9000)
DC.COVER_REPLACE_MEX = false
check(far ~= 3200 and far ~= 3350, "replace-mex: a mex out of reach is never used")
check(#S.W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
