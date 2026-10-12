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
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
