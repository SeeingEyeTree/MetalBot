-- tests/test_army_mode.lua: unit_runtime.ArmyMode, the plan army "defend"'s mode (defend / push / raid; home only on a bad trade or lost mass).
-- Run: python tests/run_lua.py tests/test_army_mode.lua
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
local UR = VFS.Include("LuaUI/Widgets/bar_framework/unit_runtime.lua")
local A = UR.ArmyMode
local o = { ratio = 1.3, back = 1.0, min_value = 3000, quiet_s = 90, back_value = 600 }
local good = { killed = 5000, lost = 4000, ratio = 1.25, badEnds = 0 }

-- going out
check(A("defend", { own = 2000, enemy = 1000, quietS = 500 }, o) == "defend", "under min_value: defend however quiet")
check(A("defend", { own = 5000, enemy = 3000, quietS = 10 }, o) == "push", "1.67x the scouted enemy: push")
check(A("defend", { own = 5000, enemy = 4500, quietS = 10 }, o) == "defend", "1.1x and not quiet: defend")
check(A("defend", { own = 5000, enemy = 9000, quietS = 120 }, o) == "raid", "behind but quiet for 120 s: low-risk raids")
check(A("defend", { own = 5000, enemy = 9000, quietS = 120, raidV = 800 }, o) == "defend", "raided right now: no new raid mode")
check(A("defend", { own = 13000, enemy = 0, quietS = 0 }, o) == "push", "no enemy known and 4x min_value: push")
check(A("defend", { own = 5000, enemy = 9000, quietS = 120 }, { quiet = false }) == "defend", "quiet = false: no raid mode")
check(A("defend", { own = 50000, enemy = 1000, coolS = 20 }, o) == "defend", "20 s after a pull-back: cooling down")
check(A("defend", { own = 50000, enemy = 1000, coolS = 70 }, o) == "push", "after the cooldown: push again")

-- out: a raid on us does NOT recall the army (raid_response answers with reinforcements / home guards)
check(A("push", { own = 87000, enemy = 50000, raidV = 4245, trade = good, peak = 87000 }, o) == "push",
      "pushing at 1.74x with a 4.2k raid on us: stays out (the 19:51 recall)")
check(A("push", { own = 5000, enemy = 9000, trade = good, peak = 6000 }, o) == "push", "behind but trading fine and still massed: stays out")
check(A("raid", { own = 6000, enemy = 9000, raidV = 3000, trade = good, peak = 6000 }, o) == "raid", "raiding with a raid on us: stays out")
check(A("raid", { own = 20000, enemy = 9000, trade = good, peak = 20000 }, o) == "push", "raiding and now clearly ahead: push")

-- out -> home only on a bad trade or lost critical mass
local m, _, why = A("push", { own = 20000, enemy = 9000, trade = { killed = 1000, lost = 5000, ratio = 0.2, badEnds = 0 }, peak = 25000 }, o)
check(m == "defend" and why == "trading badly", "lost 5k for 1k: trading badly -> home (" .. tostring(why) .. ")")
check(A("push", { own = 20000, enemy = 9000, trade = { killed = 0, lost = 900, ratio = 0, badEnds = 2 }, peak = 20000 }, o) == "defend",
      "two groups spent for nothing: home")
check(A("push", { own = 20000, enemy = 9000, trade = { killed = 100, lost = 1000, ratio = 0.1 }, peak = 20000 }, o) == "push",
      "a bad ratio on a small loss (< bad_lost) is not a bad trade yet")
m, _, why = A("raid", { own = 9000, enemy = 9000, trade = good, peak = 20000 }, o)
check(m == "defend" and why == "lost critical mass", "under half of the peak: lost critical mass -> home")
check(A("push", { own = 2500, enemy = 1000, trade = good, peak = 3000 }, o) == "defend", "under min_value: home")
-- critical mass from production: under crit_s (20) seconds of army production -> home; the peak rule only without a rate
m, _, why = A("push", { own = 30000, enemy = 9000, trade = good, peak = 100000, prod = 1000 }, o)
check(m == "push", "30k out, 20 s of 1000/s production = 20k: still massed (the peak 100k no longer counts)")
m, _, why = A("push", { own = 15000, enemy = 9000, trade = good, peak = 15000, prod = 1000 }, o)
check(m == "defend" and why == "lost critical mass", "15k out < 20 s x 1000/s: lost critical mass")
local _, r = A("defend", { own = 3000, enemy = 1500 }, o)
check(math.abs(r - 2) < 1e-9, "the ratio is returned")

check(#W.errors == 0, "no Lua errors")
print(string.format("test_army_mode: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
