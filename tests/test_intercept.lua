-- tests/test_intercept.lua
-- bar_framework/behaviors/intercept.lua against behavior_host.lua and tests/spring_stub.lua.  The raid cluster and the
-- assets are fake ctx functions, so no enemy units are spawned.  Run: python tests/run_lua.py tests/test_intercept.lua
--   * a moving raid: responders MOVE (never FIGHT) to a point ahead of the raiders on the path to the asset
--   * a responder that cannot reach the path in time holds a station between the raiders and the asset
--   * units spread across the path
--   * a raid that has stopped: FIGHT on the raiders
--   * the asset the raiders head for is the one picked, not the nearest

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local BH = VFS.Include("LuaUI/Widgets/bar_framework/behavior_host.lua")
local I  = VFS.Include("LuaUI/Widgets/bar_framework/behaviors/intercept.lua")

local given = {}
local function NewHost()
    given = {}
    return BH.New{ give = function(uid, cmd, p) given[uid] = { cmd = cmd, x = p[1], z = p[3] } end }
end

-- raiders at (4000, 4000) running at 85 elmos/s toward -x (toward the asset at (1000, 4000)); a decoy asset off to the side
local function Cluster(over)
    local c = { x = 4000, z = 4000, vx = -85, vz = 0, speed = 85, stillS = 0, n = 5, cost = 600, channel = "ground" }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end
local ASSETS = { { x = 1000, z = 4000, w = 900 }, { x = 4200, z = 1000, w = 300 }, { x = 3800, z = 4300, w = 40 } }

-- picks the asset ahead of the raiders, not the nearer one behind / beside them
local a = I.PickAsset(Cluster(), ASSETS)
check(a and a.x == 1000, "the asset on the raiders' path is the target (got " .. tostring(a and a.x) .. ")")

local function Run(cluster, positions, cfgOver)
    local h = NewHost()
    local ids = {}
    for i, p in ipairs(positions) do
        local id = S.Spawn("corgator", 0, p[1], p[2], { silent = true })
        ids[#ids + 1] = id
        h:Assign(id, "intercept", cfgOver)
    end
    local ctx = {
        ClusterOf = function() return cluster end,
        Assets = function() return ASSETS end,
        Speed = function() return 85 end,
    }
    h:Update(300, ctx)
    return ids
end

-- 1. moving raid, responders close to the path: MOVE ahead of the raiders (x less than the raiders' x, toward the asset)
local ids = Run(Cluster(), { { 2600, 4300 }, { 2600, 4350 }, { 2600, 4400 } })
local moves, ahead = 0, 0
for _, id in ipairs(ids) do
    local g = given[id]
    if g and g.cmd == 10 then moves = moves + 1 end
    if g and g.x < 4000 and g.x > 1000 then ahead = ahead + 1 end
end
check(moves == 3, "all three responders MOVE (not FIGHT) against a moving raid (" .. moves .. ")")
check(ahead == 3, "every meeting point is on the raiders' path between them and the asset")

-- 2. spread across the path: z offsets differ
local zs = {}
for _, id in ipairs(ids) do zs[#zs + 1] = given[id].z end
table.sort(zs)
check(zs[3] - zs[1] >= 150, "the block spreads across the path (" .. (zs[3] - zs[1]) .. " elmos wide)")

-- 3. far responders cannot reach the path in time: they hold a station short of the asset, between it and the raiders
local ids2 = Run(Cluster({ vx = -300, speed = 300 }), { { 9000, 9000 }, { 9000, 9100 } })
local station = 0
for _, id in ipairs(ids2) do
    local g = given[id]
    if g and g.cmd == 10 and g.x > 1000 and g.x < 2500 then station = station + 1 end
end
check(station == 2, "responders that cannot catch the raiders block between them and the asset (" .. station .. ")")

-- 4. a stopped raid is fought where it stands
local ids3 = Run(Cluster({ vx = 0, speed = 0, stillS = 5 }), { { 3000, 4000 }, { 3000, 4100 } })
local fights = 0
for _, id in ipairs(ids3) do
    local g = given[id]
    if g and g.cmd == 16 and g.x == 4000 and g.z == 4000 then fights = fights + 1 end
end
check(fights == 2, "units FIGHT the raiders once they have stopped (" .. fights .. ")")

-- 5. no cluster for the unit: nothing claimed, no error
local h = NewHost()
local id = S.Spawn("corgator", 0, 100, 100, { silent = true })
h:Assign(id, "intercept")
h:Update(300, { ClusterOf = function() return nil end, Assets = function() return ASSETS end })
check(given[id] == nil and (h.stats.errors or 0) == 0, "a unit with no raid to answer is left alone")

print(string.format("test_intercept: %d checks, %d failures", checks, failures))
if failures > 0 then error("test_intercept failed") end
