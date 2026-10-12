-- tests/test_scout_rings.lua      python tests/run_lua.py tests/test_scout_rings.lua
-- bar_framework/scout_rings.lua: rings of scout posts around our structures, pushed outward while quiet,
-- pulled in where scouts die or enemies stand, radar units on the second ring.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

W.units, W.errors, W.log, W.orders = {}, {}, {}, {}
local homeX, homeZ = 1200, 6000
W.start = { [0] = { homeX, homeZ }, [1] = { 11000, 6100 } }
local MM = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local RS = VFS.Include("LuaUI/Widgets/bar_framework/scout_rings.lua")
MM.Init(0, 0)
MM.SetHome(homeX, homeZ)
MM.SetFoe(11000, 6100, "test")
RS.Init{ MM = MM, UQ = UQ }

-- a base: a blob around home, with a mex line running east (like the screenshot)
local pts = {}
for i = 0, 40 do
    pts[#pts + 1] = homeX + (i % 8) * 120 - 400; pts[#pts + 1] = homeZ + math.floor(i / 8) * 150 - 300
end
for i = 1, 12 do pts[#pts + 1] = homeX + 800 + i * 220; pts[#pts + 1] = homeZ + 40 end
RS.SetStructures(pts)
local cx, cz = RS.Centre()
check(cx and cx > homeX, "centre sits inside the footprint, east of home because of the line")

-- every structure is inside the bin's hull
for i = 1, #pts / 2 do
    local a = math.atan2(pts[2 * i] - cz, pts[2 * i - 1] - cx)
    local b = math.floor((a + math.pi) / (2 * math.pi) * 36) + 1
    if b > 36 then b = 36 end
    local proj = (pts[2 * i - 1] - cx) * math.cos(-math.pi + (b - 0.5) / 36 * 2 * math.pi)
               + (pts[2 * i] - cz) * math.sin(-math.pi + (b - 0.5) / 36 * 2 * math.pi)
    check(RS.Hull(b) + 1 >= proj, "hull covers structure " .. i)
end

-- push creeps while quiet
local frame = 0
local function Run(frames) for _ = 1, frames, 30 do frame = frame + 30; RS.Step(frame) end end
local b0 = 1; for b = 1, 36 do if RS.OuterRadius(b) > RS.OuterRadius(b0) then b0 = b end end
local before = RS.OuterRadius(18)
Run(240 * 6)
local after = RS.OuterRadius(18)
check(after > before + 600, string.format("push grows while quiet (%.0f -> %.0f)", before, after))

-- posts: inside the map, not inside the footprint margin, outside the enemy keep-out
local scoutPosts = RS.BuildPosts(450)
check(#scoutPosts > 8, "has posts: " .. #scoutPosts)
local mx, mz = MM.MapSize()
for _, p in ipairs(scoutPosts) do
    check(p.x >= 0 and p.x <= mx and p.z >= 0 and p.z <= mz, "post inside the map")
    check(Dist(p.x, p.z, 11000, 6100) >= 2500, "post outside the enemy keep-out")
end
check(RS.RingCount() >= 2, "several rings once pushed: " .. RS.RingCount())
-- no two posts on top of each other
local minD = math.huge
for i = 1, #scoutPosts do for j = i + 1, #scoutPosts do
    minD = math.min(minD, Dist(scoutPosts[i].x, scoutPosts[i].z, scoutPosts[j].x, scoutPosts[j].z))
end end
check(minD >= 300, "posts are spread (min gap " .. math.floor(minD) .. ")")
-- the first few fill posts are spread: not all on one side
local firstN, minAng, maxAng = 6, math.huge, -math.huge
for i = 1, firstN do minAng = math.min(minAng, scoutPosts[i].ang); maxAng = math.max(maxAng, scoutPosts[i].ang) end
check(maxAng - minAng > 2.0, "first posts cover a wide arc")
-- west edge: base at the map's west side -> rings are half circles (posts clamped, deduped), none behind the edge
for _, p in ipairs(scoutPosts) do check(p.x >= 100, "clamped to the map margin") end

-- a scout dies at bearing east, 3000 out: that bin is capped just inside, the ring there falls back
local eastBin = 18 + 1
local rEast = RS.OuterRadius(eastBin)
RS.OnLost(cx + rEast - 100, cz, frame)
local capped = RS.OuterRadius(eastBin)
check(capped < rEast - 400, string.format("ring pulls in where a scout died (%.0f -> %.0f)", rEast, capped))
-- and does not push straight back into it
Run(240 * 3)
check(RS.OuterRadius(eastBin) <= capped + 200, "no immediate re-push into the loss")
-- a long time later the cap has crept back out
Run(30 * 600)
check(RS.OuterRadius(eastBin) > capped + 800, "cap recovers over time")

-- an armed enemy seen north of the base: ring there stands off
local northBin = 27
local rN = RS.OuterRadius(northBin)
RS.ObserveEnemies(frame, { { x = cx, z = cz + rN - 200 } })
check(RS.OuterRadius(northBin) < rN - 600, "ring stands off from an armed enemy")
RS.ObserveEnemies(frame + 60, {})
check(RS.OuterRadius(northBin) >= rN - 1, "...and is back out as soon as the enemy is gone")

-- assignment: scouts and radars
local scouts, radars = {}, {}
for i = 1, 10 do scouts[#scouts + 1] = { id = i, x = homeX, z = homeZ } end
for i = 1, 3 do radars[#radars + 1] = { id = 100 + i, x = homeX, z = homeZ } end
local plan = RS.Plan(frame, scouts, radars, 450, 1800)
local n = 0; for _ in pairs(plan) do n = n + 1 end
check(n == 13, "every unit gets a post: " .. n)
local seen = {}
for uid, t in pairs(plan) do
    local k = math.floor(t.x) .. "," .. math.floor(t.z)
    check(not seen[k], "no two units share a post")
    seen[k] = true
end
for i = 1, 3 do check(plan[100 + i] and plan[100 + i].kind == "radar", "radar unit planned as radar") end
-- stable: same inputs, same posts
local plan2 = RS.Plan(frame + 30, scouts, radars, 450, 1800)
local same = true
for uid, t in pairs(plan) do if not plan2[uid] or plan2[uid].x ~= t.x or plan2[uid].z ~= t.z then same = false end end
check(same, "plan is stable between calls")
-- fewer scouts than posts: all still on distinct posts and spread out in angle
local few = {}
for i = 1, 4 do few[#few + 1] = { id = 200 + i, x = homeX, z = homeZ } end
local p3 = RS.Plan(frame + 60, few, {}, 450, 0)
local angs = {}
for _, t in pairs(p3) do angs[#angs + 1] = math.atan2(t.z - cz, t.x - cx) end
table.sort(angs)
print("angs", table.concat(angs, " "), #RS.Posts(), RS.RingCount()); check(#angs == 4 and (angs[#angs] - angs[1]) > 1.5, "four scouts are spread around the base")

-- few scouts go to the OUTER ring, not spread over every ring
local six = {}
for i = 1, 6 do six[#six + 1] = { id = 300 + i, x = homeX, z = homeZ } end
local p6 = RS.Plan(frame + 90, six, {}, 450, 0)
for _, t in pairs(p6) do check(t.ring == 1, "six scouts all on the outer ring (got ring " .. tostring(t.ring) .. ")") end

print(string.format("scout_rings: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
