-- tests/test_con_hold.lua     python tests/run_lua.py tests/test_con_hold.lua
-- line_transition's CON_HOLD (RAID_BOT, game review 2026-10-13): while it returns true, no new air con (T1 air lab) and no
-- energy / retrofit T2 con (advanced air lab) is ordered; without it (every other bot) the orders go out as before; an
-- erroring hook does not hold anything.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local LT = VFS.Include("LuaUI/Widgets/bar_framework/line_transition.lua")
check(LT._test and LT._test.QueueAirCon and LT._test.MakeEnergyT2Con, "test hooks exported")

local function Orders(defID)
    local n = 0
    for _, o in ipairs(W.orders) do
        local d = o.cmd < 0 and -o.cmd or nil
        if o.cmd == CMD.INSERT and o.params and o.params[2] and o.params[2] < 0 then d = -o.params[2] end
        if d == defID then n = n + 1 end
    end
    return n
end

local function NewT(hold)
    W.units, W.orders, W.log = {}, {}, {}
    local ap  = S.Spawn("corap", 0, 1000, 1000, { silent = true })
    local aap = S.Spawn("coraap", 0, 1400, 1000, { silent = true })
    local cfg = {}
    for k, v in pairs(LT.CFG) do cfg[k] = v end
    cfg.CON_HOLD, cfg.EP_CON_FORCE, cfg.EP_CON_BATCH, cfg.EP_CON_EVERY = hold, true, 2, 450
    local T = { CFG = cfg, airLabID = ap, airConDefID = UnitDefNames.corca.id, airConsOrdered = 0, airConsAlive = {},
                orders = {}, firstGridOK = true, teamID = 0, freeT2Cons = {},
                upgradeBP = { layout = { { n = "cormoho" } } },
                BP = { CanBuild = function(builder, target) return builder == UnitDefNames.coraca.id end } }
    return T, ap, aap
end

-- no hook: orders go out (every other bot)
local T = NewT(nil)
LT._test.QueueAirCon(T, 900)
check(Orders(UnitDefNames.corca.id) == 1 and T.airConsOrdered == 1, "no CON_HOLD: the air con is ordered")
LT._test.MakeEnergyT2Con(T, 900, "ENERGY CELL")
check(Orders(UnitDefNames.coraca.id) == 2, "no CON_HOLD: the advanced air lab makes 2 T2 cons")

-- hold on: nothing
local held = true
T = NewT(function() return held end)
LT._test.QueueAirCon(T, 900)
check(Orders(UnitDefNames.corca.id) == 0 and T.airConsOrdered == 0, "CON_HOLD: no air con, and none counted as ordered")
LT._test.MakeEnergyT2Con(T, 900, "ENERGY CELL")
check(Orders(UnitDefNames.coraca.id) == 0, "CON_HOLD: no T2 con")
check(#S.Log("%[LT%] .*CON HOLD: air con skipped") == 1, "CON_HOLD: the hold is logged")
check(T.epConFrame == nil, "CON_HOLD: the T2-con timer is not used up by a held order")
-- released: orders resume at once
held = false
LT._test.QueueAirCon(T, 960)
LT._test.MakeEnergyT2Con(T, 960, "ENERGY CELL")
check(Orders(UnitDefNames.corca.id) == 1 and Orders(UnitDefNames.coraca.id) == 2, "hold over: both orders go out")

-- a broken hook holds nothing
T = NewT(function() error("boom") end)
LT._test.QueueAirCon(T, 900)
check(Orders(UnitDefNames.corca.id) == 1, "an erroring CON_HOLD does not stop the economy")

-- with a lab controller's broker published, the con orders go through it (LB.Order), not straight to the lab
do
    local LBm = VFS.Include("LuaUI/Widgets/bar_framework/lab_broker.lua")
    local lb = LBm.New{}
    T = NewT(nil)
    T.WG = { LabBroker = { LB = LBm, lb = lb } }
    LT._test.QueueAirCon(T, 900)
    LT._test.MakeEnergyT2Con(T, 900, "ENERGY CELL")
    check(lb.orders == 3 and Orders(UnitDefNames.corca.id) == 1 and Orders(UnitDefNames.coraca.id) == 2,
        "with WG.LabBroker the air con and T2 con orders are the lab broker's (" .. lb.orders .. " recorded)")
    check(lb.stats.external == 3, "...recorded as external orders")
end

print(string.format("con_hold: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
