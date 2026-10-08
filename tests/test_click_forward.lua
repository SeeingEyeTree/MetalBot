-- tests/test_click_forward.lua
-- Run from the repo root through lupa's Lua 5.1 (see tests/LUA_TESTING.md).
--
-- click_army's FORWARD_CORE (2026-10-08).  One attack group has reached the enemy base (its units ~1800 from
-- the target), and 40 reinforcements have just joined it from the factory at home.
--   * old rule (FORWARD_CORE off): the core is "the units near the centroid of everyone", which the 40 at home
--     drag back, so the units at the front are ordered BACK toward home -- the bug seen vs BARb (a 112k army at
--     mid-map with the enemy commander in sight);
--   * FORWARD_CORE: the core is the forward cluster, it keeps going toward its target, and the reinforcements
--     walk to it;
--   * CORE_WAIT_FRAC: a small front waits for units close behind it, but not for units fresh from the factory.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

-- Returns, for the units that were at the front, how many were ordered toward / away from their target.
local function Scenario(cfg, nearReinforce)
    W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
    W.frame, WG = 0, {}
    local MM   = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
    local UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
    local EI   = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
    local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
    local CA   = VFS.Include("LuaUI/Widgets/bar_framework/click_army.lua")
    MM.Init(0, 0)
    MM.SetHome(W.start[0][1], W.start[0][2])
    EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
    local combat = {}
    cfg.MAX_GROUPS = 1
    CA.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, combat = combat, guards = {}, muster = {},
             scouts = {}, responding = {}, bombers = {}, cfg = cfg }

    local hx, hz = W.start[0][1], W.start[0][2]
    local fx, fz = MM.Foe()
    local nano = S.Spawn("cornanotc", 1, fx, fz, { silent = true })
    local frame = 0
    local function Update(collect)
        frame = frame + 30
        EI.Scan(frame); ARMY.Sweep(frame); CA.Update(frame)
        local o = W.orders
        if collect then W.orders = {} else S.Frame(frame) end
        return o
    end
    local function Gators(n, x, z)
        local ids = {}
        for i = 1, n do
            local id = S.Spawn("corgator", 0, x + (i % 5) * 30, z + math.floor(i / 5) * 30, { silent = true })
            combat[id] = UnitDefNames.corgator.id
            ids[#ids + 1] = id
        end
        return ids
    end

    Update(false)
    local sx, sz = CA.StagePoint()
    local front = Gators(20, sx, sz)
    for _ = 1, 4 do Update(false) end
    check(#CA.Groups() == 1, "the 20 gators at the stage launch a group")
    -- the group has walked to the enemy base: 1800 from the nano, toward home
    local ax, az = hx - fx, hz - fz
    local al = math.sqrt(ax * ax + az * az); ax, az = ax / al, az / al
    for i, id in ipairs(front) do
        W.units[id].x = fx + ax * 1800 + (i % 5) * 30
        W.units[id].z = fz + az * 1800 + math.floor(i / 5) * 30
    end
    -- reinforcements: fresh from the factory at home, or (nearReinforce) a little way behind the front
    local rx, rz = hx, hz
    if nearReinforce then rx, rz = fx + ax * 4500, fz + az * 4500 end
    Gators(40, rx, rz)
    -- they join the group, and then count toward its centre; army_broker sends at most one order per unit per
    -- 90 frames, so look at every order over the next 150 frames (positions stay put: no S.Frame)
    local last = {}
    for _ = 1, 5 do
        for _, o in ipairs(Update(true)) do last[o.id] = o end
    end
    local toward, away, hold = 0, 0, 0
    for _, id in ipairs(front) do
        local o, u = last[id], W.units[id]
        if o and (o.cmd == 10 or o.cmd == 16) and o.params and o.params[1] then
            local now = Dist(u.x, u.z, fx, fz)
            local after = Dist(o.params[1], o.params[3], fx, fz)
            if after < now - 50 then toward = toward + 1
            elseif after > now + 50 then away = away + 1
            else hold = hold + 1 end
        elseif o and o.cmd == 20 then
            toward = toward + 1
        end
    end
    return toward, away, hold, CA
end

-- the old rule: the front is called back toward home
local t0, a0 = Scenario({ FORWARD_CORE = false }, false)
print(string.format("old rule: %d front units ordered toward the target, %d ordered away", t0, a0))
check(a0 >= 15, "old rule (documents the bug): the front is ordered back toward the reinforcements")

-- FORWARD_CORE: the front keeps going
local t1, a1 = Scenario({ FORWARD_CORE = true }, false)
print(string.format("FORWARD_CORE: %d toward, %d away", t1, a1))
check(t1 >= 18 and a1 == 0, "FORWARD_CORE: the front keeps moving on its target")

-- CORE_WAIT_FRAC: units fresh from the factory (far behind) do not hold the front back ...
local t2, a2, h2 = Scenario({ FORWARD_CORE = true, CORE_WAIT_FRAC = 0.35 }, false)
check(t2 >= 18 and h2 == 0, "CORE_WAIT_FRAC: reinforcements 10,000 behind do not stop the front")
-- ... but 40 units close behind (2700 back) are waited for
local t3, a3, h3 = Scenario({ FORWARD_CORE = true, CORE_WAIT_FRAC = 0.35 }, true)
print(string.format("CORE_WAIT_FRAC with 40 close behind: %d toward, %d away, %d hold", t3, a3, h3))
-- (holding = FIGHT on the core's own centre, so units at the edge of the blob step a little either way)
check(h3 >= 15 and t3 + a3 <= 5, "CORE_WAIT_FRAC: a small front waits for the 40 just behind it")

-- FLANK: an enemy army sits 3000 ahead on the straight path to the target (out of LegPoint's 900 reach, so the
-- old leg steering does not see it).  Off: the first leg goes (nearly) straight at it; on: the group heads for a
-- waypoint beside it, so its first leg turns well off the line.
local function FlankScenario(flank)
    W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
    W.frame, WG = 0, {}
    local MM   = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
    local UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
    local EI   = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
    local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
    local CA   = VFS.Include("LuaUI/Widgets/bar_framework/click_army.lua")
    MM.Init(0, 0)
    MM.SetHome(W.start[0][1], W.start[0][2])
    EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
    local combat = {}
    CA.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, combat = combat, guards = {}, muster = {},
             scouts = {}, responding = {}, bombers = {}, cfg = { MAX_GROUPS = 1, FORWARD_CORE = true, FLANK = flank } }
    local fx, fz = MM.Foe()
    S.Spawn("cornanotc", 1, fx, fz, { silent = true })
    local frame = 0
    local function Update()
        frame = frame + 30
        EI.Scan(frame); ARMY.Sweep(frame); CA.Update(frame)
        local o = W.orders; W.orders = {}
        return o
    end
    Update()
    local sx, sz = CA.StagePoint()
    local ids = {}
    for i = 1, 20 do
        local id = S.Spawn("corgator", 0, sx + (i % 5) * 30, sz + math.floor(i / 5) * 30, { silent = true })
        combat[id] = UnitDefNames.corgator.id
        ids[#ids + 1] = id
    end
    -- the enemy army, 3000 ahead of the stage on the way to the nano
    local ux, uz = fx - sx, fz - sz
    local L = math.sqrt(ux * ux + uz * uz); ux, uz = ux / L, uz / L
    for i = 1, 30 do
        S.Spawn("corak", 1, sx + ux * 3000 + (i % 6) * 25, sz + uz * 3000 + math.floor(i / 6) * 25, { silent = true })
    end
    local last = {}
    for _ = 1, 6 do for _, o in ipairs(Update()) do last[o.id] = o end end
    local lat, n = 0, 0
    for _, id in ipairs(ids) do
        local o = last[id]
        if o and o.cmd == 10 and o.params and o.params[1] then
            local dx, dz = o.params[1] - sx, o.params[3] - sz
            lat = lat + math.abs(-dx * uz + dz * ux); n = n + 1
        end
    end
    return n > 0 and lat / n or 0, #CA.Groups(), S.Log("%[CK%] .*flanks the enemy army")
end
local latOff, gOff = FlankScenario(false)
local latOn, gOn, logOn = FlankScenario(true)
print(string.format("FLANK off: first legs %.0f off the line; FLANK on: %.0f off the line", latOff, latOn))
check(gOff == 1 and gOn == 1, "the 20 gators launch in both runs")
check(latOff < 250, "FLANK off: the group heads (nearly) straight at the enemy army")
check(latOn > 450, "FLANK on: the group's first leg turns well off the line, toward a waypoint beside the army")
check(#logOn >= 1, "FLANK on: the flank is logged")

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then error(failures .. " check(s) failed") end
