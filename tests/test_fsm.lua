-- tests/test_fsm.lua
-- bar_framework/fsm.lua + signals.lua + machines/*.lua against tests/spring_stub.lua.  python tests/run_lua.py tests/test_fsm.lua
--   * condition trees (all / any / not, nil signal = false), edge hold_s / min_stay_s / prio / any_edges;
--   * the two machines see each other (stance -> share node); share ramp_s; hook nodes;
--   * machines/core_default.lua and air_timing.lua validate; core_default follows game_plan's cases.

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

local FSM = VFS.Include("LuaUI/Widgets/bar_framework/fsm.lua")
local SG  = VFS.Include("LuaUI/Widgets/bar_framework/signals.lua")

-- conditions
local vals = { a = 5, b = true, c = false, s = "x" }
local function get(n) return vals[n] end
check(FSM.Eval({ sig = "a", op = ">", val = 3 }, get), "a > 3")
check(not FSM.Eval({ sig = "a", op = "<", val = 3 }, get), "a < 3 false")
check(not FSM.Eval({ sig = "zz", op = ">", val = 3 }, get), "unknown signal compares false")
check(FSM.Eval({ ["not"] = { sig = "zz", op = ">", val = 3 } }, get), "not(unknown test) is true")
check(FSM.Eval({ sig = "b" }, get) and not FSM.Eval({ sig = "c" }, get) and not FSM.Eval({ sig = "zz" }, get), "bare boolean signals")
check(FSM.Eval({ all = { { sig = "b" }, { any = { { sig = "c" }, { sig = "s", op = "==", val = "x" } } } } }, get), "all/any nesting")
check(not FSM.Eval({ all = { { sig = "b" }, { sig = "c" } } }, get), "all with a false member")
check(FSM.Explain({ all = { { sig = "a", op = ">", val = 3 }, { ["not"] = { sig = "c" } } } }, get) == "(a=5 > 3 AND NOT c)", "explain text")

-- a machine: hold_s, min_stay_s, prio, any_edges
local spec = {
    initial = "A",
    nodes = { A = { stance = "a" }, B = { stance = "b" }, C = { stance = "c" } },
    edges = {
        { from = "A", to = "B", when = { sig = "go" }, hold_s = 10 },
        { from = "A", to = "C", when = { sig = "go2" }, prio = 5, min_stay_s = 30 },
    },
    any_edges = { { to = "C", when = { sig = "panic" }, prio = 9 } },
}
check(#FSM.ValidateMachine(spec, "stance_machine", { known = function() return true end }) == 0, "spec validates")
local m = FSM.NewMachine(spec, { label = "t", log = function() end })
local env = { go = true, go2 = false, panic = false }
local function G(n) return env[n] end
check(m:Tick(0, G) == "A", "hold_s not yet elapsed")
check(m:Tick(299, G) == "A", "9.97 s still held")
check(m:Tick(300, G) == "B", "held 10 s -> B")
local m2 = FSM.NewMachine(spec, { label = "t", log = function() end })
env.go = false; m2:Tick(0, G); env.go = true
check(m2:Tick(10, G) == "A", "go restarts hold_s")
env.panic = true
check(m2:Tick(20, G) == "C", "any_edge fires from any node")
check(m2:Tick(30, G) == "C", "any_edge does not loop on its own target")
local bad = { initial = "X", nodes = { A = { stance = "a" } }, edges = { { from = "A", to = "Q", when = { sig = "nope" } } } }
local probs = FSM.ValidateMachine(bad, "stance_machine", { known = function(n) return n ~= "nope" end })
check(#probs >= 3, "validation finds bad initial, bad target, unknown signal (" .. #probs .. ")")

-- signals
local st = { minute = 5, metal = { income = 300, fill = 0.4 }, armyValue = 1000, located = true, enemyGround = 300, enemyAir = 100,
             trade = { killed = 100, lost = 2000, ratio = 0.05, badEnds = 0 }, airRaid = { n = 9, rush = true }, capFrac = 0.5 }
check(SG.Get("metal_income", st) == 300, "metal_income")
check(SG.Get("enemy_vs_army", st) == 0.4, "enemy_vs_army")
check(SG.Get("bad_trade", st) == true, "bad_trade")
check(SG.Get("air_raid_rush", st) == true and SG.Get("air_raid", st) == true, "air raid signals")
check(SG.Get("army_ratio", st) == nil, "army_ratio nil when unknown")

-- bundle: share machine reads the stance
local bspec = {
    stance_machine = { initial = "open", nodes = { open = { stance = "s_open" }, burst = { stance = "s_burst" } },
        edges = { { from = "open", to = "burst", when = { sig = "metal_income", op = ">=", val = 250 } } } },
    share_machine = { initial = "low", nodes = { low = { share = 0.2 }, high = { share = 0.8, ramp_s = 10 }, hk = { hook = "h" } },
        edges = { { from = "low", to = "high", when = { sig = "stance", op = "==", val = "s_burst" } } } },
}
local B = FSM.Bundle(bspec, { hookFactories = { h = function() return function() return 0.5 end end }, log = function() end })
local cur = "s_open"
local strat = { Name = function() return cur end, Plan = function() return { army = "raid", share = 0.1 } end }
local lowSt = { frame = 0, minute = 0, metal = { income = 100 } }
check(B.switch(lowSt, strat) == "s_open", "bundle stays open at low income")
check(math.abs(B.army_share(lowSt, strat) - 0.2) < 1e-9, "low share node")
local hiSt = { frame = 30, minute = 0, metal = { income = 400 } }
check(B.switch(hiSt, strat) == "s_burst", "bundle switches stance")
cur = "s_burst"
local sh1 = B.army_share(hiSt, strat)
check(sh1 >= 0.2 and sh1 < 0.8, "share starts from the old value, then ramps (" .. tostring(sh1) .. ")")
local sh2 = B.army_share({ frame = 30 + 30 * 2, minute = 0, metal = { income = 400 } }, strat)
check(sh2 > 0.2 and sh2 < 0.8, "ramp_s eases the share (" .. tostring(sh2) .. ")")
local sh3 = B.army_share({ frame = 30 + 30 * 100, minute = 0, metal = { income = 400 } }, strat)
check(math.abs(sh3 - 0.8) < 1e-9, "ramp ends at the node share (" .. tostring(sh3) .. ")")
check(B.StanceNames()[1] == "s_open" and #B.StanceNames() == 2, "stance names, initial first")

-- the shipped machines
local H = { match_enemy = true, v16_share = true }
for _, name in ipairs({ "core_default", "air_timing" }) do
    local spec2, err = FSM.Load(name)
    check(spec2 ~= nil, name .. " loads " .. tostring(err))
    if spec2 then
        local pr = FSM.Validate(spec2, { hookFactories = H })
        for _, p in ipairs(pr) do print("  " .. name .. ": " .. p) end
        check(#pr == 0, name .. " validates")
    end
end

-- core_default: hold -> raid when the enemy is weak; raid -> hold when behind + bad trades; late at the cap
local cd = FSM.Load("core_default")
local CB = FSM.Bundle(cd, { hookFactories = { match_enemy = function() return function() return 0.4 end end }, log = function() end })
local cs = "hold"
local cstrat = { Name = function() return cs end, Plan = function() return {} end }
local function S0(extra)
    local t = { frame = 0, minute = 0, metal = { income = 100 }, capFrac = 0.1, located = false, enemyGround = 0, enemyAir = 0 }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
check(CB.switch(S0(), cstrat) == "hold", "core_default starts in hold")
local f = 1800 * 3
check(CB.switch(S0{ frame = f, minute = 3, located = true, armyValue = 3000, enemyGround = 500 }, cstrat) == "raid_open", "weak enemy located -> raid_open")
cs = "raid_open"
f = f + 30 * 100
check(CB.switch(S0{ frame = f, minute = 4, located = true, armyValue = 3000, enemyGround = 500, armyRatio = 0.7,
    trade = { killed = 0, lost = 1500, ratio = 0, badEnds = 0 } }, cstrat) == "hold", "behind + bad trade -> hold")
cs = "hold"
check(CB.switch(S0{ frame = f + 30, minute = 13, capFrac = 0.8 }, cstrat) == "raid_late", "cap filling -> raid_late (any_edge)")
cs = "raid_late"
check(CB.switch(S0{ frame = f + 60, minute = 14, capFrac = 0.8, located = true, armyValue = 3000, enemyGround = 100 }, cstrat) == "raid_late", "late is permanent")
check(math.abs(CB.army_share(S0(), cstrat) - 0.4) < 1e-9, "core_default share node runs match_enemy")

print(string.format("test_fsm: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
