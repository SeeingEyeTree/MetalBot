-- tests/test_eco_ledger.lua -- bar_framework/eco_ledger.lua (C3): saturation, energy target, unit cap, decoy demand, the WG registry.
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

local L = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")

-- saturation
local sat, cap = L.Saturated({ metalIncome = 1100 }, 1220)
check(sat and cap == 1220, "1100 of 1220 m/s is saturated (>= 85%)")
check(not (L.Saturated({ metalIncome = 1000 }, 1220)), "1000 of 1220 is not")
check(not (L.Saturated({ metalIncome = 400 }, 100)), "never under MIN_INCOME (500), whatever the capacity")
check(L.Saturated({ metalIncomeS = 900, metalIncome = 100 }, 1000), "the smoothed income is the one read")
check(L.Saturated({ metalIncome = 2100 }, nil) and not (L.Saturated({ metalIncome = 1900 }, nil)), "no capacity figure: the fallback income (2000)")
check(L.Saturated({ metalIncome = 750 }, 1000, { minIncome = 800 }) == false, "a caller can raise the minimum (the line decoy labs use 800)")
check(L.Saturated({ metalIncome = 600 }, 1000, { satFrac = 0.5, minIncome = 100 }), "...and the fraction")
check(L.Surplus({ metalIncome = 1500 }, 1000) == 500 and L.Surplus({ metalIncome = 900 }, 1000) == 0, "Surplus: the income the capacity cannot spend")

-- registry and energy target
check(L.Capacity(WG, "spine") == nil and L.EnergyTarget(WG) == nil, "nothing registered: no capacity, no energy target")
L.Register(WG, "spine", { capacity = function() return 1220 end })
L.Register(WG, "sink", { energyPerMetal = function() return 14.1 end })
check(L.Capacity(WG, "spine") == 1220, "a registered capacity is read")
check(math.abs(L.EnergyTarget(WG) - 14.1) < 1e-9, "one consumer with an energy figure: that figure")
check(L.EnergyTarget(WG, 15) == 15, "an explicit override (EP_RATIO) wins")
L.Register(WG, "grids", { capacity = function() return 1000 end, energyPerMetal = function() return 4 end })
L.Register(WG, "sink", { capacity = function() return 3000 end, energyPerMetal = function() return 14 end })
check(math.abs(L.EnergyTarget(WG) - (4 * 1000 + 14 * 3000) / 4000) < 1e-9, "several consumers: blended by capacity")
L.Unregister(WG, "grids")
check(math.abs(L.EnergyTarget(WG) - 14) < 1e-9, "Unregister drops one")
L.Register(WG, "bad", { capacity = function() error("boom") end, energyPerMetal = function() error("boom") end })
check(L.Capacity(WG, "bad") == nil and L.EnergyTarget(WG) ~= nil, "a consumer that errors is ignored")

-- unit cap
local left, maxU, cnt = L.CapLeft(0)
check(left == nil or left == maxU - cnt, "CapLeft: max minus count (or nil when the engine gives neither)")
Spring.GetTeamMaxUnits = function() return 3000 end
Spring.GetTeamUnitCount = function() return 2900 end
check(L.CapLeft(0) == 100, "CapLeft with a cap of 3000 and 2900 units")
check(L.CapSlack(0, 0.1, 1000) == 300 and L.CapSlack(0, 0.5, 1000) == 1000, "CapSlack: the smaller of the absolute slack and a share of the cap")
Spring.GetTeamMaxUnits = function() return 0 end
check(L.CapSlack(0, 0.1, 1000) == 1000, "CapSlack without a known cap: the absolute figure")

-- decoys
check(L.DecoyDemand(1000, 100) == 70, "1000 m/s x 0.9 / 12.75 = 70 decoys")
check(L.DecoyDemand(10, 100) == 8, "at least DECOY_MIN")
check(L.DecoyDemand(5000, 64) == 64, "at most the room the labs have")
check(L.DecoyDemand(1000, 100, { spend = 0.5, rate = 10, min = 1 }) == 50, "a caller's own constants")

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
