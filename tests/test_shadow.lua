-- tests/test_shadow.lua: bar_framework/behaviors/shadow.lua against behavior_host.lua.  Fake ctx, no real enemies.
-- Run: python tests/run_lua.py tests/test_shadow.lua
--   * enemy inside the edge -> MOVE away; outside it -> close in; in the dead zone -> stand
--   * enemy gone -> chase the last seen spot, then ride ahead of the army (the other shadows are not "the army")
--   * hurt -> back to the army;  max = 1 -> only one unit of the cohort shadows
--   * chase sim: a 20-gator army marching on a base with a defender army -- the shadow ends alive, enemy always in sight

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
local SH = VFS.Include("LuaUI/Widgets/bar_framework/behaviors/shadow.lua")

local SIGHT = 500
local function Ctx(enemies, friends)
    return {
        Sight = function() return SIGHT end,
        EnemiesNear = function(x, z, r)
            local out = {}
            for _, e in ipairs(enemies) do
                if (e.x - x) ^ 2 + (e.z - z) ^ 2 <= r * r then out[#out + 1] = e end
            end
            return out
        end,
        Friends = function() return friends or {} end,
        Axis = function() return 1, 0 end,
    }
end

local given
local function Host() given = {}; return BH.New{ give = function(uid, cmd, p) given[uid] = { cmd = cmd, x = p[1], z = p[3] } end } end
local function One(x, z, hp, over)
    local h = Host()
    local id = S.Spawn("corfav", 0, x, z, { silent = true })
    if hp then W.units[id].hp = hp * W.units[id].maxhp end
    h:Assign(id, "shadow", over)
    return h, id
end
local function D(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

-- 1. too close: back off to ~85% of sight, directly away
local h, id = One(1000, 1000)
h:Update(100, Ctx({ { uid = 900, x = 1200, z = 1000, range = 300 } }))
local g = given[id]
check(g and g.cmd == 10 and g.x < 1000, "enemy 200m east of a 500m-sight unit: it moves west")
check(g and math.abs((1200 - g.x) - 425) < 5, "...to 85% of sight from the enemy (" .. tostring(g and 1200 - g.x) .. ")")
check(h:IsHeld(id, 105), "...and other controllers are told to keep off")

-- 2. too far: close in
h, id = One(1000, 1000)
h:Update(100, Ctx({ { uid = 900, x = 1425, z = 1000, range = 300 } }))   -- 495m away: still seen but at the edge of the scan
g = given[id]
check(g == nil or g.x == 1000, "enemy 425m away (inside the dead zone): stand")
h, id = One(1000, 1000)
SIGHT = 800
h:Update(100, Ctx({ { uid = 900, x = 1790, z = 1000, range = 300 } }))  -- 790m of 800 sight: at the far edge
g = given[id]
check(g and g.x > 1000 and math.abs(1790 - g.x - 680) < 5, "enemy at 790m of 800 sight: close in to 85% (" .. tostring(g and 1790 - g.x) .. ")")
SIGHT = 500

-- 3. dead zone: stands (a MOVE onto itself)
h, id = One(1000, 1000)
h:Update(100, Ctx({ { uid = 900, x = 1425, z = 1000, range = 300 } }))
g = given[id]
check(g and g.x == 1000 and g.z == 1000, "enemy at 85%: it stands where it is")

-- 4. away from two enemies, not into the second
h, id = One(1000, 1000)
h:Update(100, Ctx({ { uid = 900, x = 1200, z = 1000, range = 300 }, { uid = 901, x = 1000, z = 1250, range = 300 } }))
g = given[id]
check(g and g.x < 1000 and g.z < 1000, "enemies east and south: it goes north-west")

-- 5. enemy gone: chase the last seen spot (stops at 85% of sight from it), then forget it
h, id = One(1000, 1000, nil, { patrol = false })
h:Update(100, Ctx({ { uid = 900, x = 1460, z = 1000, range = 300 } }))
W.units[id].x = 400
h:Update(200, Ctx({}, { { uid = 1, x = 0, z = 0, value = 100 } }))
g = given[id]
check(g and g.x > 400 and g.x < 1460, "enemy out of view: it heads for where it was last seen")
h:Update(2000, Ctx({}, { { uid = 1, x = 0, z = 0, value = 100 } }))
g = given[id]
check(g and g.x == 700, "long lost: it rides 700m ahead of the army toward the enemy (x=" .. tostring(g and g.x) .. ")")

-- 6. nothing known and no army: not claimed
h, id = One(1000, 1000)
local acted = h:Update(100, Ctx({}))
check(not acted[id] and given[id] == nil, "no enemy, no army: the unit is left to its controller")

-- 7. hurt: back to the army
h, id = One(1000, 1000, 0.2)
h:Update(100, Ctx({ { uid = 900, x = 1460, z = 1000, range = 300 } }, { { uid = 1, x = 100, z = 100, value = 500 } }))
g = given[id]
check(g and g.x == 100 and g.z == 100, "20% health: it goes back to the army")

-- 8. max = 1: only one of three shadows
h = Host()
local ids = {}
for i = 1, 3 do ids[i] = S.Spawn("corfav", 0, 1000 + i * 10, 1000, { silent = true }); h:Assign(ids[i], "shadow", { max = 1 }) end
local acted3 = h:Update(100, Ctx({ { uid = 900, x = 1200, z = 1000, range = 300 } }))
local n = 0
for _, i in ipairs(ids) do if acted3[i] then n = n + 1 end end
check(n == 1, "max = 1: one unit shadows, the others are left alone (" .. n .. ")")

-- 9. the other shadows are not the army: anchor is the non-shadow friends only
h, id = One(1000, 1000, nil, { patrol = false })
local friends = { { uid = id, x = 1000, z = 1000, value = 26 }, { uid = 2, x = 200, z = 200, value = 120 } }
h:Update(100, Ctx({}, friends))
g = given[id]
check(g and g.x == 900 and g.z == 200, "anchor ignores the shadow itself (x=" .. tostring(g and g.x) .. ", z=" .. tostring(g and g.z) .. ")")

-- 9b. patrol (the default): nothing known -> each shadow sweeps its own lane out and back toward the enemy base
do
    local hp = Host()
    local ids = {}
    for i = 1, 3 do ids[i] = S.Spawn("corfav", 0, 1000, 1000, { silent = true }); hp:Assign(ids[i], "shadow") end
    local ctx = Ctx({}, { { uid = 1, x = 1000, z = 1000, value = 500 } })
    ctx.EnemyBase = function() return 9000, 1000 end             -- due east
    local minR, maxR, lanes = 1e9, 0, {}
    for t = 0, 70 do
        hp:Update(100 + t * 30, ctx)
        for i, id in ipairs(ids) do
            local g = given[id]
            local r = D(g, { x = 1000, z = 1000 })
            minR, maxR = math.min(minR, r), math.max(maxR, r)
            if t == 10 then lanes[i] = math.atan2(g.z - 1000, g.x - 1000) end
        end
    end
    check(minR >= 1190 and maxR <= 3410, "patrol: the lanes run between 1200 and 3400 from the army (" .. math.floor(minR) .. ".." .. math.floor(maxR) .. ")")
    check(maxR > 2800 and minR < 1800, "patrol: it goes out and comes back (" .. math.floor(minR) .. ".." .. math.floor(maxR) .. ")")
    check(lanes[1] < lanes[2] and lanes[2] < lanes[3] and lanes[3] - lanes[1] > 0.8, "patrol: the three shadows take different bearings round east")
    check(math.abs(lanes[2]) < 0.4, "patrol: the middle shadow's lane points at the enemy base")
    local capped = One(1000, 1000)
    local ctx2 = Ctx({}, { { uid = 1, x = 1000, z = 1000, value = 500 } })
    ctx2.EnemyBase = function() return 3000, 1000 end              -- the enemy is only 2000 away: 45% = 900 < patrol_min
    local hc, idc = capped, nil
    for id2 in pairs(hc.units) do idc = id2 end
    for t = 0, 40 do
        hc:Update(100 + t * 30, ctx2)
        local g = given[idc]
        check(D(g, { x = 1000, z = 1000 }) <= 905, "patrol: never past 45% of the way to the enemy base")
        if failures > 0 then break end
    end
end

-- 10. chase sim: a defending enemy army (range 300, speed 85, sight irrelevant) chases whatever is nearest it, the
-- shadow (speed 153) is meant to be outside range the whole time and always keep the enemy in view.
do
    h, id = One(0, 0)
    local sh = W.units[id]
    local foes = {}
    for i = 1, 8 do foes[i] = { uid = 900 + i, x = 3000 + i * 20, z = 0, range = 300 } end
    local army = { { uid = 1, x = 0, z = 0, value = 120 } }
    local closest, outOfView, minD = 1e9, 0, 1e9
    local frame = 0
    for step = 1, 300 do                                          -- 1 s ticks
        frame = frame + 30
        for _, e in ipairs(foes) do                               -- the enemy marches at the shadow (a harsh test)
            local dx, dz = sh.x - e.x, sh.z - e.z
            local d = math.sqrt(dx * dx + dz * dz)
            if d > 1 then e.x, e.z = e.x + dx / d * 85, e.z + dz / d * 85 end
        end
        army[1].x = army[1].x + 85
        h:Update(frame, Ctx(foes, army))
        local o = given[id]
        if o then
            local dx, dz = o.x - sh.x, o.z - sh.z
            local d = math.sqrt(dx * dx + dz * dz)
            local mv = math.min(d, 153)
            if d > 1 then sh.x, sh.z = sh.x + dx / d * mv, sh.z + dz / d * mv end
        end
        local nd = 1e9
        for _, e in ipairs(foes) do nd = math.min(nd, math.sqrt((e.x - sh.x) ^ 2 + (e.z - sh.z) ^ 2)) end
        if step > 40 then
            minD = math.min(minD, nd)
            if nd > SIGHT then outOfView = outOfView + 1 end
        end
    end
    check(minD > 300, "chase sim: the shadow was never inside the enemy's range 300 (closest " .. math.floor(minD) .. ")")
    check(outOfView < 10, "chase sim: the enemy was in view nearly all the time (lost " .. outOfView .. "/260 ticks)")
end

-- 11. a radar dot, nothing in sight: go and look at it, stopping at 85% of sight from it
do
    local hb, idb = One(1000, 1000)
    local ctx = Ctx({}, { { uid = 1, x = 1000, z = 1000, value = 500 } })
    ctx.BlipsNear = function() return { { uid = 777, x = 3500, z = 1000 } } end
    hb:Update(100, ctx)
    local gb = given[idb]
    check(gb and gb.cmd == 10 and math.abs((3500 - gb.x) - 425) < 5 and gb.x > 1000, "radar dot 2500 away: it goes to 85% of sight from it (" .. tostring(gb and 3500 - gb.x) .. ")")
    ctx.BlipsNear = function() return {} end
end

print(string.format("test_shadow: %d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
