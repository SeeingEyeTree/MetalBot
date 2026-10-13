-- tests/test_set_target.lua
-- click_army.lua with CFG.SET_TARGET: an attack group keeps MOVEing through the enemy base and each unit gets SET_TARGET
-- (BAR target-on-the-move) on an enemy building inside its weapon range, instead of stopping to ATTACK.
-- Run: python tests/run_lua.py tests/test_set_target.lua   (the stub teleports units on MOVE, so this checks the logic)

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

local MM   = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
local UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local EI   = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
local CA   = VFS.Include("LuaUI/Widgets/bar_framework/click_army.lua")

MM.Init(0, 0)
MM.SetHome(W.start[0][1], W.start[0][2])
EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
local combat = {}
CA.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, combat = combat, guards = {}, muster = {}, scouts = {},
         responding = {}, bombers = {}, cfg = { SET_TARGET = true } }

local seen = {}
local frame = 0
local function Run(n)
    for _ = 1, n do
        frame = frame + 30
        EI.Scan(frame); ARMY.Sweep(frame); CA.Update(frame)
        for _, o in ipairs(W.orders) do seen[#seen + 1] = o end
        S.Frame(frame)
    end
end

local hx, hz = W.start[0][1], W.start[0][2]
local fx, fz = MM.Foe()
local nano = S.Spawn("cornanotc", 1, fx, fz, { silent = true })
local mex  = S.Spawn("cormex",    1, fx + 200, fz, { silent = true })
for i = 1, 26 do
    local id = S.Spawn("corgator", 0, hx + 200 + i * 5, hz + 100, { silent = true })
    combat[id] = UnitDefNames.corgator.id
end
Run(60)

local setT, attack, beyond = 0, 0, 0
for _, o in ipairs(seen) do
    if o.cmd == 34923 then setT = setT + 1 end
    if o.cmd == 20 then attack = attack + 1 end
end
check(#CA.Groups() >= 1, "a group launched")
check(setT > 0, "units were given SET_TARGET while the group attacked (" .. setT .. ")")
check(attack == 0, "no unit was ordered to stop and ATTACK the target (" .. attack .. ")")
local sawBeyond = false
for _, o in ipairs(seen) do
    if o.cmd == 10 and o.params[1] and (o.params[1] - fx) ^ 2 + (o.params[3] - fz) ^ 2 > 200 ^ 2 then sawBeyond = true end
end
check(sawBeyond, "the group keeps moving (MOVE orders on past the target)")

print(string.format("test_set_target: %d checks, %d failures", checks, failures))
if failures > 0 then error("test_set_target failed") end
