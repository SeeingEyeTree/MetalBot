-- tests/test_endgame_strike.lua: endgame.Strike with STRIKE_MIN_VALUE (AIR_TIMING): the commander is struck only by bombers worth a
-- one-pass kill; fewer are not claimed (and not parked with STRIKE_PARK false); the old rule (nil) strikes whenever the commander is in view.
-- Run: python tests/run_lua.py tests/test_endgame_strike.lua
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
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
local MM   = { Ready = function() return true end, PointAt = function() return 500, 500 end, Clamp = function(x, z) return x, z end }
local UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")

local SHAD = UnitDefNames.corshad
check(SHAD ~= nil, "the stub has the Shadow")
local shadV = (SHAD.metalCost or 0) + (SHAD.energyCost or 0) / 70

local cmdr = S.Spawn("corcom", 1, 9000, 9000, { silent = true })
local EI = { Commander = function() return 9000, 9000, W.frame, cmdr end, AntiNukeCovers = function() return false end }
local function NewEG(cfg)
    local EG = dofile("bar_framework/endgame.lua")
    EG.Init{ EI = EI, MM = MM, UQ = UQ, ARMY = ARMY, TM = {}, teamID = 0, cfg = cfg }
    return EG
end
local function Bombers(n)
    local ids = {}
    for i = 1, n do ids[#ids + 1] = S.Spawn("corshad", 0, 1000 + i * 10, 1000, { silent = true }) end
    return ids
end
local function Roles(ids)
    local r = {}
    for _, id in ipairs(ids) do local k = ARMY.RoleOf(id) or "none"; r[k] = (r[k] or 0) + 1 end
    return r
end

-- the old rule: the commander in view -> every bomber strikes, however few
do
    local EG = NewEG(nil)
    local ids = Bombers(5)
    W.frame = 100; ARMY.Sweep(100)
    EG.Strike(100, ids)
    check(Roles(ids).STRIKE == 5, "old rule: 5 bombers strike a commander in view (the stream)")
    for _, id in ipairs(ids) do ARMY.Release(id); W.units[id] = nil end
end

-- STRIKE_MIN_VALUE: under it no strike (and no parking with STRIKE_PARK false); at it, the strike
do
    local EG = NewEG({ STRIKE_MIN_VALUE = 47 * shadV, STRIKE_PARK = false })
    local ids = Bombers(30)
    W.frame = 200; ARMY.Sweep(200)
    EG.Strike(200, ids)
    local r = Roles(ids)
    check((r.STRIKE or 0) == 0 and (r.BOMBER_WAIT or 0) == 0, "30 Shadows: no strike, not parked (bomb_run keeps them)")
    for _, id in ipairs(Bombers(17)) do ids[#ids + 1] = id end
    W.frame = 300; ARMY.Sweep(300)
    EG.Strike(300, ids)
    check(Roles(ids).STRIKE == 47, "47 Shadows: the one-pass strike (" .. tostring(Roles(ids).STRIKE) .. ")")
end

check(#W.errors == 0, "no Lua errors")
print(string.format("test_endgame_strike: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
