-- tests/test_value_weights.lua
-- bar_framework/value_weights.lua: the category and the value of a unit.  Real numbers from ecosim/unitdefs.lua (BAR's Cortex defs).
--   * a T1 mex is worth its cost + 60 s x 2.37 m/s, a T2 mex cost + 60 s x 9.48 m/s (knowledge/economy_numbers.md)
--   * an energy plant is worth its cost + 60 s of its energy in metal-equivalent (/70); wind uses 60% of its rating
--   * build power is worth BP_MULT x cost + the throughput term, and is the biggest multiplier of cost of any category
--   * army = cost, the commander = COMMANDER, a unit half built is worth half
-- Run from the repo root:  python tests/run_tests.py -k value_weights

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 0.5) end

UnitDefs = {
    [1] = { name = "cormex",   metalCost = 50,   energyCost = 500,   extractsMetal = 0.001, speed = 0 },
    [2] = { name = "cormoho",  metalCost = 640,  energyCost = 8100,  extractsMetal = 0.004, speed = 0 },
    [3] = { name = "corfus",   metalCost = 3600, energyCost = 22000, energyMake = 850, speed = 0 },
    [4] = { name = "corwin",   metalCost = 43,   energyCost = 175,   windGenerator = 25, speed = 0 },
    [5] = { name = "cornanotc", metalCost = 230, energyCost = 3200,  isBuilder = true, buildSpeed = 200, speed = 0 },
    [6] = { name = "corcrwh",  metalCost = 5100, energyCost = 72000, speed = 114.9, canFly = true, weapons = { {} } },
    [7] = { name = "corcom",   metalCost = 2700, energyCost = 26000, isBuilder = true, buildSpeed = 300, speed = 37.5, customParams = { iscommander = "1" } },
    [8] = { name = "cordecom", metalCost = 750,  energyCost = 13000, isBuilder = true, buildSpeed = 300, speed = 37.5, weapons = { {} }, customParams = { isdecoycommander = "1" } },
    [9] = { name = "corllt",   metalCost = 90,   energyCost = 700,   speed = 0, weapons = { {} } },
    [10] = { name = "corrad",  metalCost = 55,   energyCost = 500,   speed = 0, radarRadius = 2100 },
    [11] = { name = "corlab",  metalCost = 470,  energyCost = 1050,  isBuilder = true, isFactory = true, buildSpeed = 150, speed = 0 },
    [12] = { name = "corestor", metalCost = 175, energyCost = 1800,  speed = 0, energyStorage = 6000 },
    [13] = { name = "corfav",  metalCost = 26,   energyCost = 270,   speed = 153, weapons = {} },
}
local VW = dofile("bar_framework/value_weights.lua")

local function V(id) return VW.Value(id) end

local v, c = V(1); check(c == "eco" and near(v, 50 + 500 / 70 + 60 * 2.37), "T1 mex = cost + 60 s x 2.37 (" .. tostring(v) .. ")")
v, c = V(2); check(c == "eco" and near(v, 640 + 8100 / 70 + 60 * 9.48), "T2 mex = cost + 60 s x 9.48 (" .. tostring(v) .. ")")
v, c = V(3); check(c == "eco" and near(v, 3600 + 22000 / 70 + 60 * 850 / 70), "fusion = cost + 60 s of 850 E/s in metal-equivalent (" .. tostring(v) .. ")")
v, c = V(4); check(c == "eco" and near(v, 43 + 175 / 70 + 60 * (25 * 0.6) / 70), "wind = cost + 60 s of 60% of its rating (" .. tostring(v) .. ")")
v, c = V(12); check(c == "eco" and near(v, 175 + 1800 / 70), "a storage is eco, worth its cost (" .. tostring(v) .. ")")
v, c = V(5); check(c == "bp" and near(v, 3 * (230 + 3200 / 70) + 60 * 200 * 0.05), "nano = 3 x cost + 60 s x 200 BP x 0.05 (" .. tostring(v) .. ")")
v, c = V(11); check(c == "bp", "a factory is build power")
v, c = V(8); check(c == "bp", "a decoy commander is build power (not a commander)")
v, c = V(7); check(c == "commander" and v == 25000, "the commander is worth COMMANDER")
v, c = V(6); check(c == "army" and near(v, 5100 + 72000 / 70), "a Dragon is army, worth its cost (" .. tostring(v) .. ")")
v, c = V(9); check(c == "defence" and near(v, 90 + 700 / 70), "an armed structure is defence")
v, c = V(10); check(c == "other", "a radar is other")
v, c = V(13); check(c == "other", "an unarmed fast scout is other")
-- the ordering the user asked for: per metal of cost, build power > eco > army
local function mult(id) local vv = V(id); return vv / VW.Cost(id) end
check(mult(5) > mult(2) and mult(2) > mult(6) and mult(5) > mult(3), "per metal of cost: nano (bp) > T2 mex (eco) > Dragon (army); nano > fusion")
check(mult(6) == 1, "army is worth exactly its cost")
-- progress
local vfull = V(2)
check(near(VW.Value(2, 0.5), vfull / 2), "half built = half the value")
check(VW.Value(2, 0) == 0 and near(VW.Value(2, 3), vfull), "progress is clamped to 0..1")
-- tuning
local VW2 = VW.New({ SECONDS = 120 })
check(VW2.Value(1) > VW.Value(1), "SECONDS is tunable (more income counted, more value)")
check(select(2, VW.Value(9999)) == "other" and VW.Value(9999) == 0, "an unknown def is worth 0, other")

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
