-- tests/test_slow_front.lua
-- bar_framework/slow_front.lua against tests/spring_stub.lua with hand-placed units.  Run from the repo root through
-- lupa's Lua 5.1 (see tests/LUA_TESTING.md).  The stub teleports units on MOVE/FIGHT only inside S.Frame, which this
-- test never calls: positions stay where the test puts them, so each pass is judged on the orders it gives.
--   * AGGRESSIVE: with an enemy in sight, in range or not, the Lashers get FIGHT orders toward it - never MOVE, never
--     a "stand" on their own spot - unless it is charging them;
--   * a slow or stationary enemy, however close, does not make them back off;
--   * a fast CHARGE (closing >= CHARGE_SPEED, hit within CHARGE_TTC s, worth >= CHARGE_MIN_FRAC of the group) is
--     answered with a MOVE away (no FIGHT), the Pounders meet it, and the next order after the step is FIGHT again;
--   * one lone raider charging 8 Lashers is not a charge worth running from;
--   * the group's core is the FORWARD cluster: new units at home do not pull it back;
--   * Pounders hold ~200 in front of the Lasher core, meet a diver, reach a spot behind them by MOVE;
--   * rez bots reclaim only BEHIND the Lashers and repair hurt units.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}

local MM   = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
local UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local EI   = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
local SF   = VFS.Include("LuaUI/Widgets/bar_framework/slow_front.lua")
MM.Init(0, 0)
MM.SetHome(W.start[0][1], W.start[0][2])
EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
SF.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY }
local CFG = SF.CFG

local ax, az = MM.Axis()                 -- unit vector home -> foe
local px, pz = -az, ax
local stx, stz = MM.PointAt(CFG.STAGE_FRAC * MM.Dist(), 0)
local function At(fwd, side) return stx + ax * fwd + px * (side or 0), stz + az * fwd + pz * (side or 0) end
local function Dist(a, b, c, d) return math.sqrt((a - c) ^ 2 + (b - d) ^ 2) end

local lashers, pounders, bots = {}, {}, {}
for i = 1, 8 do
    local x, z = At(0, (i - 4.5) * 60)
    local id = S.Spawn("cormist", 0, x, z, { silent = true }); lashers[#lashers + 1] = id; SF.Add(id, "back")
end
for i = 1, 4 do
    local x, z = At(150, (i - 2.5) * 80)
    local id = S.Spawn("corlevlr", 0, x, z, { silent = true }); pounders[#pounders + 1] = id; SF.Add(id, "front")
end
for i = 1, 2 do
    local x, z = At(-350, (i - 1.5) * 100)
    local id = S.Spawn("cornecro", 0, x, z, { silent = true }); bots[#bots + 1] = id; SF.Add(id, "rez")
end

local frame = 0
local function Pass(n)
    for _ = 1, n or 1 do frame = frame + 30; W.frame = frame; SF.Update(frame) end
end
local function Orders(ids, cmd)
    local set, out = {}, {}
    for _, id in ipairs(ids) do set[id] = true end
    for _, o in ipairs(W.orders) do
        if set[o.id] and (cmd == nil or o.cmd == cmd) then out[#out + 1] = o end
    end
    return out
end
local function Clear() W.orders = {} end
local function Enemy(name, fwd, side)
    local x, z = At(fwd, side or 0)
    return S.Spawn(name, 1, x, z, { silent = true })
end
local function Kill(ids) for _, id in ipairs(ids) do W.units[id] = nil end end
local function LashCentroid()
    local sx, sz = 0, 0
    for _, id in ipairs(lashers) do sx, sz = sx + W.units[id].x, sz + W.units[id].z end
    return sx / #lashers, sz / #lashers
end
-- make an enemy walk straight at the Lasher core at `speed` elmos/s (the stub reports elmos per frame)
local function Charge(id, speed)
    local cx, cz = LashCentroid()
    local u = W.units[id]
    local dx, dz = cx - u.x, cz - u.z
    local d = math.sqrt(dx * dx + dz * dz)
    u.vx, u.vz = dx / d * speed / 30, dz / d * speed / 30
end
local function MeanTarget(os)
    local sx, sz = 0, 0
    for _, o in ipairs(os) do sx, sz = sx + o.params[1], sz + o.params[3] end
    return sx / #os, sz / #os
end

-- launch
Pass(2)
check(SF.Launched(), "the group launches at the stage")
Clear()

-- ── 1. an enemy in sight, out of range: FIGHT toward it ───────────────────────
local e1 = Enemy("corak", 1500, 300)          -- ~1500 away, well out of range
Pass(1)
local f1 = Orders(lashers, 16)
check(#f1 >= 6 and #Orders(lashers, 10) == 0, "out of range: FIGHT toward the enemy, no MOVE (" .. #f1 .. ")")
do
    local tx, tz = MeanTarget(f1)
    local cx, cz = LashCentroid()
    local ex, ez = W.units[e1].x, W.units[e1].z
    check(Dist(tx, tz, ex, ez) < Dist(cx, cz, ex, ez) - 300, "out of range: the FIGHT target is nearer the enemy")
end

-- ── 2. the enemy in RANGE and standing: still a FIGHT toward it, never a stand or a back-off ──
Kill({ e1 }); Clear()
local e2 = Enemy("corak", 420)               -- 420 from the core: inside our 700 and inside its 300+ range
Pass(1)
check(#Orders(lashers, 10) == 0, "a close, stationary enemy does not make the Lashers back off")
local f2 = Orders(lashers, 16)
check(#f2 >= 1, "in range: they keep a FIGHT order toward it (" .. #f2 .. ")")
local standing = 0
for _, o in ipairs(f2) do
    local u = W.units[o.id]
    if Dist(o.params[1], o.params[3], u.x, u.z) < 5 then standing = standing + 1 end
end
check(standing == 0, "they are not given a stand-still order on their own spot (" .. standing .. ")")

-- ── 3. a slow enemy walking at them: no back-off ──────────────────────────────
Kill({ e2 }); Clear()
local e3 = Enemy("corak", 500)
Charge(e3, 30)                                -- under CHARGE_SPEED
Pass(1)
check(#Orders(lashers, 10) == 0, "an enemy closing at 30/s is not a charge")

-- ── 4. a fast charge: MOVE away, Pounders meet it, then FIGHT again ───────────
Kill({ e3 }); Clear()
local raiders = {}
for i = 1, 8 do raiders[#raiders + 1] = Enemy("corraid", 560, (i - 4.5) * 40); Charge(raiders[#raiders], 80) end
Pass(1)
local mv = Orders(lashers, 10)
check(#mv >= 6, "a charge: the Lashers are given MOVE orders (" .. #mv .. ")")
check(#Orders(lashers, 16) == 0, "a charge: no FIGHT to the Lashers while backing off")
do
    local cx, cz = LashCentroid()
    local ex, ez = W.units[raiders[1]].x, W.units[raiders[1]].z
    local tx, tz = MeanTarget(mv)
    check(Dist(tx, tz, ex, ez) > Dist(cx, cz, ex, ez) + 250, "a charge: the step is away from the chargers (about " .. CFG.BACK_STEP .. ")")
end
local pm = Orders(pounders, 16)
check(#pm >= 3, "a charge: the Pounders FIGHT toward it (" .. #pm .. ")")
do
    local cx, cz = LashCentroid()
    local far = 0
    for _, o in ipairs(pm) do if Dist(o.params[1], o.params[3], cx, cz) > CFG.INTERCEPT_MAX + 120 then far = far + 1 end end
    check(far == 0, "a charge: the Pounders meet it near the Lashers, no further than INTERCEPT_MAX")
end
-- the chargers are gone: after the step the Lashers FIGHT forward again
Kill(raiders); Clear()
Pass(12)                                      -- the step takes 400/52 s; 12 passes = 12 s
local e4 = Enemy("corak", 1200, 200)
Clear()
Pass(1)
check(#Orders(lashers, 16) >= 6 and #Orders(lashers, 10) == 0, "after the back step: FIGHT toward the enemy again")
Kill({ e4 })

-- ── 5. one raider charging 8 Lashers is not worth running from ────────────────
Clear(); Pass(8); Clear()
local lone = Enemy("corak", 450); Charge(lone, 90)
Pass(1)
check(#Orders(lashers, 10) == 0, "a lone raider (under CHARGE_MIN_FRAC of the group) does not send the Lashers back")
Kill({ lone })

-- ── 6. the core is the forward cluster ────────────────────────────────────────
Clear(); Pass(4); Clear()
local homeBunch = {}
for i = 1, 24 do
    local hx, hz = W.start[0][1] + i * 6, W.start[0][2] + 200
    local id = S.Spawn("cormist", 0, hx, hz, { silent = true }); homeBunch[#homeBunch + 1] = id; SF.Add(id, "back")
end
local e6 = Enemy("corak", 1500, 300)
Pass(1)
local fwd = Orders(lashers, 16)                -- the original (forward) Lashers
local cx6, cz6 = LashCentroid()
local ex6, ez6 = W.units[e6].x, W.units[e6].z
check(#fwd >= 6, "reinforcements at home: the forward Lashers still get orders (" .. #fwd .. ")")
do
    local tx, tz = MeanTarget(fwd)
    check(Dist(tx, tz, ex6, ez6) < Dist(cx6, cz6, ex6, ez6), "reinforcements at home do not pull the forward Lashers back")
end
local toCore = Orders(homeBunch, 16)
check(#toCore >= 12, "the new units at home FIGHT toward the core (" .. #toCore .. ")")
do
    local tx, tz = MeanTarget(toCore)
    check(Dist(tx, tz, cx6, cz6) < 400, "...and their target is the forward core")
end
Kill({ e6 })
for _, id in ipairs(homeBunch) do SF.Remove(id); W.units[id] = nil end

-- ── 7. Pounders: ~200 in front of the Lashers; a spot behind them is reached by MOVE ──
Clear(); Pass(4); Clear()
local lcx, lcz = LashCentroid()
for i, id in ipairs(pounders) do
    local u = W.units[id]; u.x, u.z = lcx - ax * 700 + px * (i - 2.5) * 80, lcz - az * 700 + pz * (i - 2.5) * 80
end
local e7 = Enemy("corak", 1100)
Pass(16)           -- the stub does not walk them: let the 450-frame heartbeat re-state the order
local pf = Orders(pounders)
check(#pf >= 3, "pounders: ordered toward their guard spot")
local fwdOK = true
for _, o in ipairs(pf) do
    local ahead = (o.params[1] - lcx) * ax + (o.params[3] - lcz) * az
    if math.abs(ahead - CFG.PAD) > 160 then fwdOK = false end
end
check(fwdOK, "pounders: the guard spot is ~" .. CFG.PAD .. " in front of the Lasher core")
check(#Orders(pounders, 10) == 0, "pounders: moving forward is FIGHT, not MOVE")
Kill({ e7 }); Clear()
for i, id in ipairs(pounders) do
    local u = W.units[id]; u.x, u.z = lcx + ax * 900 + px * (i - 2.5) * 80, lcz + az * 900 + pz * (i - 2.5) * 80
end
local e7b = Enemy("corak", 1500)
Pass(1)
check(#Orders(pounders, 10) >= 3, "pounders: a guard spot BEHIND them is reached by MOVE (" .. #Orders(pounders, 10) .. ")")
Kill({ e7b }); Clear()
for i, id in ipairs(pounders) do
    local u = W.units[id]; u.x, u.z = lcx + ax * 200 + px * (i - 2.5) * 80, lcz + az * 200 + pz * (i - 2.5) * 80
end
local dive = Enemy("corak", 300, 0)
W.units[dive].x, W.units[dive].z = W.units[lashers[8]].x + 150, W.units[lashers[8]].z      -- 150 from a Lasher
local dx0, dz0 = W.units[dive].x, W.units[dive].z
Pass(1)
local toDiver = 0
for _, o in ipairs(Orders(pounders, 16)) do
    if Dist(o.params[1], o.params[3], dx0, dz0) < 400 then toDiver = toDiver + 1 end
end
check(toDiver >= 3, "pounders: a diver within " .. CFG.DIVE_R .. " of a Lasher is met by the Pounders (" .. toDiver .. ")")
Kill({ dive })

-- ── 8. rez bots: behind the Lashers only; repair the hurt ─────────────────────
Clear(); Pass(10)
lcx, lcz = LashCentroid()
S.AddFeature(lcx + ax * 900, lcz + az * 900, 200, "")           -- ahead of the line
local behindF = S.AddFeature(lcx - ax * 300, lcz - az * 300, 200, "")    -- behind it
Clear()
Pass(6)
local rb = Orders(bots, 90)
local aheadHit, behindHit = false, false
for _, o in ipairs(rb) do
    local fid = o.params[1] - 32000
    if W.features[fid] and (W.features[fid].x - lcx) * ax + (W.features[fid].z - lcz) * az > 100 then aheadHit = true end
    if fid == behindF then behindHit = true end
end
check(not aheadHit, "rez bots never reclaim a wreck AHEAD of the Lashers")
check(behindHit, "rez bots reclaim the wreck behind the Lashers")
W.units[lashers[1]].hp = W.units[lashers[1]].maxhp * 0.4
Clear(); Pass(2)
check(#Orders(bots, 40) >= 1, "rez bots repair a hurt Lasher")
check(#W.errors == 0, "no Lua errors")

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
