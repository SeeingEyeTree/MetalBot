-- tests/test_bomb_run_group.lua: bomb_run's grouping options (AIR_TIMING v3): "launch now" needs LAUNCH_NOW_MIN bombers, only bombers
-- gathered at the station (GATHER_R) launch, and a wave keeps its members (FIXED_WAVE: a bomber built during it waits for the next).
-- Run: python tests/run_lua.py tests/test_bomb_run_group.lua
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
local SHAD = UnitDefNames.corshad.id
local MM = { Ready = function() return true end, Home = function() return 1000, 1000 end, Dist = function() return 8000 end,
             PointAt = function() return 1800, 1000 end, Clamp = function(x, z) return x, z end, Foe = function() return 9000, 9000 end }
local UQ = { is_air = function(d) return d == SHAD end, is_dedicated_aa = function() return false end,
             is_bomber = function(d) return d == SHAD end }
local targets = { { x = 8000, z = 8000, bp = 0, eco = true, value = 200, mobile = false }, { x = 8100, z = 8000, eco = true, value = 200 } }
local EI = { RaidTargets = function() return targets end, ThreatAt = function() return 0 end, Class = function() return nil end }

local BR = dofile("bar_framework/bomb_run.lua")
local bombers = {}
BR.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, bombers = bombers, combat = {}, guards = {},
         cfg = { LAUNCH_NOW_MIN = 20, GATHER_R = 600, FIXED_WAVE = true, MIN_LAUNCH_DAMAGE = 0, COOLDOWN = 0, RELAUNCH_MIN = 20 } }
local function Add(n, x, z)
    local ids = {}
    for i = 1, n do
        local id = S.Spawn("corshad", 0, x + i, z, { silent = true })
        bombers[id] = true; ids[#ids + 1] = id
    end
    return ids
end
local frame = 0
local function Step(plan) frame = frame + 30; W.frame = frame; ARMY.Sweep(frame); BR.Update(frame, plan) end
local plan = { bomb = true, launch = true }

local first = Add(5, 1800, 1000)                -- 5 at the station
Step(plan)
check(BR.Mode() == "rally", "launch now with 5 bombers (< LAUNCH_NOW_MIN 20): no launch")
local far = Add(20, 400, 400)                   -- 20 more, still far from the station (not gathered)
Step(plan)
check(BR.Mode() == "rally", "25 bombers but only 5 gathered at the station: no launch")
for _, id in ipairs(far) do W.units[id].x, W.units[id].z = 1850, 1000 end   -- they arrive
Step(plan)
check(BR.Mode() == "strike", "25 gathered: the wave launches")
local late = Add(3, 1800, 1000)                 -- built during the wave
Step(plan)
local lateRole = {}
for _, id in ipairs(late) do lateRole[ARMY.RoleOf(id) or "none"] = true end
local lateOrder
for i = #W.orders, 1, -1 do if W.orders[i].id == late[1] then lateOrder = W.orders[i]; break end end
check(lateOrder and lateOrder.cmd == 10, "a bomber built during the wave is told to MOVE to the station, not to attack (FIXED_WAVE)")
check(BR.Status().wave and BR.Status().wave.members[first[1]] and not BR.Status().wave.members[late[1]], "the wave's members are the launch's")

-- ── ALL_FIGHTERS: a launch takes every fighter, home guards and air-raid responders too; the wave's end releases them ──
do
    local VENG = UnitDefNames.corveng.id
    local UQ2 = { is_air = function(d) return d == SHAD or d == VENG end, is_dedicated_aa = function(d) return d == VENG end,
                  is_bomber = function(d) return d == SHAD end }
    local BR2 = dofile("bar_framework/bomb_run.lua")
    local bombers2, combat2, guards2 = {}, {}, {}
    BR2.Init{ MM = MM, UQ = UQ2, EI = EI, ARMY = ARMY, bombers = bombers2, combat = combat2, guards = guards2,
              cfg = { ALL_FIGHTERS = true, RALLY_FIGHTERS = false, LAUNCH_MIN = 5, MIN_LAUNCH_DAMAGE = 0, COOLDOWN = 0, RUN_FRAMES = 300,
                      RETURN_FRAMES = 60 } }
    for i = 1, 5 do local id = S.Spawn("corshad", 0, 1800 + i, 1000, { silent = true }); bombers2[id] = true end
    local free = S.Spawn("corveng", 0, 1500, 1000, { silent = true }); combat2[free] = VENG
    local guard = S.Spawn("corveng", 0, 1000, 1000, { silent = true }); combat2[guard] = VENG; guards2[guard] = true
    local rush = S.Spawn("corveng", 0, 1100, 1000, { silent = true }); combat2[rush] = VENG
    frame = frame + 30; W.frame = frame; ARMY.Sweep(frame)
    ARMY.Claim(ARMY.PRIO.HOME_GUARD, guard, { role = "HOME_GUARD", cmd = 10, x = 1000, z = 1000 }, frame)
    ARMY.Claim(ARMY.PRIO.RAID, rush, { role = "AIR_DEF", cmd = 16, x = 1200, z = 1000 }, frame)
    frame = frame + 30; W.frame = frame; ARMY.Sweep(frame); BR2.Update(frame, { bomb = true })
    check(BR2.Mode() == "strike", "the wave launches")
    check(ARMY.RoleOf(free) == "BOMBRUN" and ARMY.RoleOf(guard) == "BOMBRUN" and ARMY.RoleOf(rush) == "BOMBRUN",
          "every fighter escorts it: free " .. tostring(ARMY.RoleOf(free)) .. ", home guard " .. tostring(ARMY.RoleOf(guard)) ..
          ", air-raid responder " .. tostring(ARMY.RoleOf(rush)))
    for id in pairs(bombers2) do W.units[id] = nil end        -- the bombers die: the wave ends, the escort comes home
    for _ = 1, 6 do frame = frame + 30; W.frame = frame; ARMY.Sweep(frame); BR2.Update(frame, { bomb = true }) end
    check(ARMY.RoleOf(guard) ~= "BOMBRUN" and ARMY.RoleOf(free) ~= "BOMBRUN", "after the wave the fighters are released (home guard " ..
          tostring(ARMY.RoleOf(guard)) .. ")")
end

-- ── WAVE_SCOUTS: a launch takes 2..5 air scouts over the points; the wave's end releases them; the labs are told how many are missing ──
do
    local FINK = UnitDefNames.corfink and UnitDefNames.corfink.id
    check(FINK ~= nil, "the stub has the Finch (corfink)")
    local UQ3 = { is_air = function(d) return d == SHAD or d == FINK end, is_dedicated_aa = function() return false end,
                  is_bomber = function(d) return d == SHAD end }
    local BR3 = dofile("bar_framework/bomb_run.lua")
    local bombers3, scouts3 = {}, {}
    BR3.Init{ MM = MM, UQ = UQ3, EI = EI, ARMY = ARMY, bombers = bombers3, combat = {}, guards = {}, scouts = scouts3,
              cfg = { WAVE_SCOUTS_MIN = 2, WAVE_SCOUTS_MAX = 5, LAUNCH_MIN = 5, MIN_LAUNCH_DAMAGE = 0, COOLDOWN = 0, RALLY_FIGHTERS = false,
                      RETURN_FRAMES = 60 } }
    for i = 1, 5 do local id = S.Spawn("corshad", 0, 1800 + i, 1000, { silent = true }); bombers3[id] = true end
    local sc = {}
    for i = 1, 3 do local id = S.Spawn("corfink", 0, 1200 + i, 1000, { silent = true }); scouts3[id] = FINK; sc[#sc + 1] = id end
    frame = frame + 30; W.frame = frame; ARMY.Sweep(frame); BR3.Update(frame, { bomb = true })
    check(BR3.Mode() == "strike", "the wave launches")
    local eyes = 0
    for _, id in ipairs(sc) do if ARMY.RoleOf(id) == "BOMBRUN_EYES" then eyes = eyes + 1 end end
    check(eyes == 3, "the 3 air scouts fly with the wave (" .. eyes .. ")")
    check(BR3.ScoutRoom() == 0 or BR3.ScoutRoom() == 2, "scout room reported")
    for id in pairs(bombers3) do W.units[id] = nil end
    for _ = 1, 6 do frame = frame + 30; W.frame = frame; ARMY.Sweep(frame); BR3.Update(frame, { bomb = true }) end
    local still = 0
    for _, id in ipairs(sc) do if ARMY.RoleOf(id) == "BOMBRUN_EYES" then still = still + 1 end end
    check(still == 0, "after the wave the scouts are released (" .. still .. ")")
    check(BR3.ScoutRoom() == 2, "back at the rally with 3 of 5 scouts: the labs are asked for 2 more (" .. BR3.ScoutRoom() .. ")")
end

check(#W.errors == 0, "no Lua errors")
print(string.format("test_bomb_run_group: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
