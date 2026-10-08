-- tests/test_scout_lanes.lua
-- Run from the repo root through lupa's Lua 5.1 (see tests/LUA_TESTING.md).
--
-- bar_framework/scout_lanes.lua, FIND mode (LINE_CLICK's scouting), in two start layouts:
--   * "diagonal": home in a corner, enemy across the map (the headless harness);
--   * "west-east": home on the west edge, enemy on the east (a normal Full Metal Plate game), with the
--     engine giving NO enemy start, so the plan only has the mirror guess, like a real game.
-- For each:
--   * two scouts get opposite lanes and their first targets are the two far corners of the ENEMY half;
--   * from there each sweeps inward toward the middle of where the enemy can spawn;
--   * nothing on our half is looked at until the enemy half has been swept;
--   * no sector is looked at twice while the sweep is still on;
--   * no scout sits idle at the start (never-seen sectors count as unseen).
-- The stub teleports a scout to its target, so this checks the plan, not the walking.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

local function Scenario(label, homeX, homeZ, enemyStart)
    W.units, W.errors, W.log, W.orders = {}, {}, {}, {}
    W.start = { [0] = { homeX, homeZ }, [1] = enemyStart }       -- enemyStart nil: the engine gives no spawn
    -- fresh module instances (VFS.Include runs the file again)
    local MM = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
    local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
    local SP = VFS.Include("LuaUI/Widgets/bar_framework/scout_lanes.lua")
    MM.Init(0, 0)
    MM.SetHome(homeX, homeZ)
    SP.Init{ MM = MM, UQ = UQ, TM = nil, allyID = 0 }
    local P = label .. ": "

    local a = S.Spawn("corfav", 0, homeX, homeZ, { silent = true })
    local b = S.Spawn("corfav", 0, homeX + 20, homeZ, { silent = true })
    local ids = { a, b }
    local seq, order = { [a] = {}, [b] = {} }, {}
    local frame = 0
    local firstPlan
    for step = 1, 70 do
        frame = frame + 120
        SP.Observe(frame, ids)
        local plan = SP.Plan(frame, ids, 0)
        if step == 1 then firstPlan = plan end
        for _, uid in ipairs(ids) do
            local t = plan[uid]
            if t then
                seq[uid][#seq[uid] + 1] = { t.x, t.z }
                order[#order + 1] = { uid = uid, x = t.x, z = t.z }
                W.units[uid].x, W.units[uid].z = t.x, t.z      -- it gets there
            end
        end
    end

    -- 0. nobody waits around: both scouts have a target on the very first plan
    check(firstPlan[a] ~= nil and firstPlan[b] ~= nil, P .. "both scouts get a target on the first plan")

    -- 1. lanes and corners
    local la, lb = SP.LaneOf(a), SP.LaneOf(b)
    check(la and lb and la ~= lb, P .. "the two scouts sweep opposite lanes")
    local cornerA, cornerB = SP.Corner(la), SP.Corner(lb)
    check(cornerA and cornerB and not MM.IsOurHalf(cornerA.x, cornerA.z) and not MM.IsOurHalf(cornerB.x, cornerB.z),
          P .. "both corners are on the enemy half of the map")
    check(cornerA and cornerB and (cornerA.lat < 0) ~= (cornerB.lat < 0), P .. "...on opposite sides of the axis")
    local fa, fb = seq[a][1], seq[b][1]
    -- (the sector grid is trimmed at the margin, so the nearest sector centre can be ~1,900 from a corner)
    check(fa and Dist(fa[1], fa[2], cornerA.x, cornerA.z) < 2000, P .. "scout 1's first target is its far corner")
    check(fb and Dist(fb[1], fb[2], cornerB.x, cornerB.z) < 2000, P .. "scout 2's first target is the other far corner")
    check(Dist(fa[1], fa[2], fb[1], fb[2]) > 4000, P .. "...and the two corners are far apart")

    -- 2. sweeping inward: later targets are nearer the middle of the enemy's spawn region (the mirror
    -- estimate) than the corner was.  Only meaningful for a corner that is far from that middle.
    local ex, ez = MM.Foe()
    local function MeanDistToMiddle(list, from, to)
        local s, n = 0, 0
        for i = from, math.min(to, #list) do s = s + Dist(list[i][1], list[i][2], ex, ez); n = n + 1 end
        return n > 0 and s / n or 0
    end
    local checkedInward = 0
    for _, uid in ipairs(ids) do
        local cornerDist = Dist(seq[uid][1][1], seq[uid][1][2], ex, ez)
        if cornerDist > 4000 then
            local later = MeanDistToMiddle(seq[uid], 2, 9)
            checkedInward = checkedInward + 1
            check(later < cornerDist, string.format(P .. "scout %s sweeps inward (%.0f from the middle at the corner, %.0f after)",
                  uid == a and "1" or "2", cornerDist, later))
        end
    end
    check(checkedInward >= 1, P .. "at least one lane starts far from the middle, so the sweep direction was tested")

    -- 3. the enemy half comes first, all of it
    local enemySectors = 0
    local sectors = MM.BuildSectors(nil, 200)
    for _, s in pairs(sectors) do if not MM.IsOurHalf(s.x, s.z) then enemySectors = enemySectors + 1 end end
    local firstOurs
    for i, o in ipairs(order) do
        if MM.IsOurHalf(o.x, o.z) then firstOurs = i; break end
    end
    check(enemySectors > 10, P .. "the enemy half has sectors to sweep (" .. enemySectors .. ")")
    check(firstOurs == nil or firstOurs > enemySectors - 4,
          string.format(P .. "our half is looked at only after the enemy half is swept (first at target #%s of %d enemy sectors)",
                        tostring(firstOurs), enemySectors))

    -- 4. no sector twice while sweeping
    local seen, dup = {}, 0
    for i = 1, math.min(#order, enemySectors - 4) do
        local k = MM.SectorKey(order[i].x, order[i].z, 1448)
        if seen[k] then dup = dup + 1 end
        seen[k] = true
    end
    check(dup == 0, P .. "no sector is visited twice while the sweep is still on")

    -- 5. one scout alone takes a corner too
    SP.Forget(a); SP.Forget(b)
    local solo = S.Spawn("corfav", 0, homeX, homeZ, { silent = true })
    local plan = SP.Plan(frame + 100000, { solo }, 0)
    local t = plan[solo]
    check(t ~= nil and SP.LaneOf(solo) ~= nil, P .. "a lone scout gets a lane and a target")
    check(t and not MM.IsOurHalf(t.x, t.z), P .. "...on the enemy half")
end

Scenario("diagonal", 2400, 848, { 9648, 11408 })
Scenario("west-east", 3062, 6111, nil)

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
