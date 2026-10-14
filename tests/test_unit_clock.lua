-- tests/test_unit_clock.lua     python tests/run_lua.py tests/test_unit_clock.lua
-- bar_framework/unit_clock.lua + army_broker's use of it:
--   * Due: each unit is due once per its tier's period (0.5 / 1 / 2 Hz), and units are spread over many frames;
--   * Classify: raiding / urgent / enemy near -> HIGH (held after the trigger), scout or quiet -> LOW, else NORMAL;
--   * EnemyNear sees contacts in range only, ignoring stale ones;
--   * broker: a non-urgent order is held until the unit's frame (Flush), an urgent one goes at once, every unit's order
--     goes out within one period, and without a clock nothing is held.
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

local CLK = VFS.Include("LuaUI/Widgets/bar_framework/unit_clock.lua")

-- Due counts over 120 frames
local function DueCount(uid) local n = 0; for f = 1, 120 do if CLK.Due(uid, f) then n = n + 1 end end; return n end
CLK.Reset()
check(DueCount(10) == 4, "NORMAL: 4 sends in 120 frames (30-frame period)")
CLK.SetTier(10, CLK.LOW);  check(DueCount(10) == 2, "LOW: 2 sends in 120 frames (0.5 Hz)")
CLK.SetTier(10, CLK.HIGH); check(DueCount(10) == 8, "HIGH: 8 sends in 120 frames (2 Hz)")
CLK.Reset()

-- spread: 60 consecutive ids do not all fall on one frame
local perFrame = {}
for uid = 1, 60 do for f = 0, 29 do if CLK.Due(uid, f) then perFrame[f] = (perFrame[f] or 0) + 1 end end end
local worst = 0
for _, n in pairs(perFrame) do worst = math.max(worst, n) end
check(worst <= 4, "60 NORMAL units spread over the second (worst frame has " .. worst .. ")")

-- Classify
check(CLK.Classify(1, { scout = true }, 100) == CLK.LOW, "a scout with no enemy near is LOW")
check(CLK.Classify(1, { scout = true, enemyNear = true }, 110) == CLK.HIGH, "the same scout with an enemy near is HIGH")
check(CLK.Classify(1, { scout = true }, 150) == CLK.HIGH, "...and stays HIGH inside the hold")
check(CLK.Classify(1, { scout = true }, 110 + CLK.HIGH_HOLD + 1) == CLK.LOW, "...then drops back to LOW")
check(CLK.Classify(2, { raiding = true }, 100) == CLK.HIGH, "a raiding unit is HIGH")
check(CLK.Classify(3, { urgent = true }, 100) == CLK.HIGH, "an urgent duty is HIGH")
check(CLK.Classify(4, { quiet = true }, 100) == CLK.LOW, "a quiet guard is LOW")
check(CLK.Classify(5, {}, 100) == CLK.NORMAL, "anything else is NORMAL")
check(CLK.AnyHigh() and CLK.CountHigh() == 2, "HIGH count tracks units (" .. CLK.CountHigh() .. ")")
CLK.Forget(2); CLK.Forget(3); CLK.Forget(1)
check(not CLK.AnyHigh(), "Forget removes HIGH units")

-- EnemyNear
CLK.BuildEnemyIndex({ a = { x = 1000, z = 1000, frame = 100 }, b = { x = 5000, z = 5000, frame = 0 } }, 200)
check(CLK.EnemyNear(1500, 1000), "an enemy 500 away is near")
check(not CLK.EnemyNear(3500, 1000), "an enemy 2500 away is not")
CLK.BuildEnemyIndex({ b = { x = 5000, z = 5000, frame = 0 } }, 400)
check(not CLK.EnemyNear(5000, 5000), "a contact older than CONTACT_MAX_AGE is ignored")

-- broker
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
for id = 100, 159 do W.units[id] = { defID = 1, x = 100, y = 0, z = 100, team = 0 } end
local function Orders() local n = 0; for _ in ipairs(W.orders) do n = n + 1 end; return n end

-- no clock: issued at once
W.orders = {}
ARMY.Claim(ARMY.PRIO.LINE, 100, { role = "LINE", cmd = ARMY.CMD_FIGHT, x = 500, z = 500 }, 1000)
check(Orders() == 1, "without a clock the order goes out at once")
ARMY.Release(100)

ARMY.SetClock(CLK)
CLK.Reset()
-- a LINE order is held until the unit's frame
W.orders = {}
local uid = 101
local f0 = 2000
while CLK.Due(uid, f0) do f0 = f0 + 1 end
ARMY.Claim(ARMY.PRIO.LINE, uid, { role = "LINE", cmd = ARMY.CMD_FIGHT, x = 500, z = 500 }, f0)
check(Orders() == 0, "a LINE order is held when it is not the unit's frame")
local sent
for f = f0 + 1, f0 + 30 do
    ARMY.Flush(f)
    if Orders() > 0 and not sent then sent = f end
end
check(sent and CLK.Due(uid, sent) and sent - f0 <= 30, "...and goes out on the unit's own frame within a period (" .. tostring(sent) .. ")")
check(Orders() == 1, "...exactly once")

-- a LOW unit re-claimed every 30 frames still gets its order inside one period (the wait is not restarted)
CLK.SetTier(105, CLK.LOW)
W.orders = {}
local g0 = 6000
for f = g0, g0 + 90 do
    if (f - g0) % 30 == 0 then ARMY.Claim(ARMY.PRIO.LINE, 105, { role = "LINE", cmd = ARMY.CMD_FIGHT, x = 600, z = 600 }, f) end
    ARMY.Flush(f)
end
check(Orders() == 1, "a LOW unit re-claimed every 30 frames is sent once within a period (" .. Orders() .. ")")

CLK.SetTier(105, CLK.NORMAL); ARMY.Release(105)

-- an urgent order goes at once
W.orders = {}
ARMY.Claim(ARMY.PRIO.RETREAT, 102, { role = "RETREAT", cmd = ARMY.CMD_MOVE, x = 50, z = 50 }, 3001)
check(Orders() == 1, "a RETREAT order is not held")

-- 60 units claimed on the same frame go out over many frames
W.orders = {}
for id = 100, 159 do if id ~= 100 then ARMY.Release(id) end end
local perF = {}
for id = 103, 159 do ARMY.Claim(ARMY.PRIO.LINE, id, { role = "LINE", cmd = ARMY.CMD_FIGHT, x = 700, z = 700 }, 4000) end
local before = Orders()
for f = 4001, 4030 do
    local b = Orders(); ARMY.Flush(f); perF[f] = Orders() - b
end
local mx, tot = 0, before
for _, n in pairs(perF) do mx = math.max(mx, n); tot = tot + n end
check(tot == 57, "all 57 held orders went out within a second (" .. tot .. ")")
check(mx <= 4, "no frame carries more than 4 of them (" .. mx .. ")")

-- UpdateClock tiers by role / enemy
ARMY.Release(103)
ARMY.Claim(ARMY.PRIO.SCOUT, 104, { role = "SCOUT", cmd = ARMY.CMD_MOVE, x = 900, z = 900 }, 5000)
ARMY.UpdateClock(5000, {})
check(CLK.Tier(104) == CLK.LOW, "UpdateClock: a scout is LOW")
ARMY.UpdateClock(5030, { e = { x = 150, z = 150, frame = 5030 } })
check(CLK.Tier(104) == CLK.HIGH, "UpdateClock: the scout is HIGH with an enemy near")

check(#W.errors == 0, "no Lua errors")
print(string.format("unit_clock: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
