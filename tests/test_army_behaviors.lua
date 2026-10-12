-- tests/test_army_behaviors.lua
-- The army behaviours in bar_framework/behaviors/ (pick_target, commander_strike, attack_target, steer, squad_retreat,
-- bomber_run) run on behavior_host with a FAKE ctx, so no click_army / enemy intel is needed.
--   python tests/run_lua.py tests/test_army_behaviors.lua
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

local BH = VFS.Include("LuaUI/Widgets/bar_framework/behavior_host.lua")

local given
local function NewHost()
    given = {}
    return BH.New{ cfg = { HEARTBEAT = 1, REISSUE_EPS = 0, REISSUE_GAP = 0 },
                   give = function(uid, cmd, p) given[#given + 1] = { uid = uid, cmd = cmd, p = p } end }
end
local function Count(cmd) local n = 0; for _, g in ipairs(given) do if g.cmd == cmd then n = n + 1 end end; return n end

local function Ctx(o)
    local ctx
    ctx = { shared = {}, labels = {}, retreats = {}, ended = {}, released = {}, squad = {},
        Foe = function() return 9000, 6000 end,
        Clamp = function(x, z) return x, z end,
        Alive = function(uid) return Spring.GetUnitDefID(uid) ~= nil end,
        Log = function(frame, f, ...) ctx.labels[#ctx.labels + 1] = string.format(f, ...) end,
        Rank = function(frame, cx, cz, k) local out = {}; for i = 1, math.min(k, #(o.targets or {})) do out[i] = o.targets[i] end; return out end,
        TopTargets = function(frame, cx, cz, k) return {} end,
        Commander = function() return o.commander end,
        ThreatAt = function() return o.threat or 0 end,
        AirThreatAt = function() return o.airThreat or 0 end,
        ArmedValueNear = function(frame, x, z, r) return o.armedNear and o.armedNear(x, z) or 0 end,
        Cluster = function() if o.cluster then return o.cluster[1], o.cluster[2], o.cluster[3] end end,
        Retreat = function(frame, uid) ctx.retreats[#ctx.retreats + 1] = uid end,
        EndRetreat = function(uid) ctx.ended[#ctx.ended + 1] = uid end,
        Release = function(uid) ctx.released[#ctx.released + 1] = uid end,
        Home = function() return 1000, 6000 end,
        Hunting = function() return false end,
    }
    return ctx
end

local function Army(n, x, z, def)
    local ids = {}
    for i = 1, n do ids[i] = S.Spawn(def or "corak", 0, x + i, z, { silent = true }) end
    return ids
end
local function Assign(h, ids, stack, over) for _, id in ipairs(ids) do h:Assign(id, stack, over) end end

-- ── pick_target: count by army size, lab build power first, commander ────────
local labBP = { x = 8800, z = 6000, uid = nil, labBP = true, bp = 200, name = "nano" }
local eco   = { x = 8000, z = 7000, uid = nil, eco = true }
local eco2  = { x = 7000, z = 3000, uid = nil, eco = true }
local h = NewHost()
local ids = Army(10, 2000, 6000)
Assign(h, ids, { "pick_target", "attack_target" })
local ctx = Ctx{ targets = { labBP, eco, eco2 } }
h:Update(0, ctx)
check(#ctx.shared.targets == 1, "10 units: 1 target (got " .. #ctx.shared.targets .. ")")
check(ctx.shared.labBP == true and ctx.shared.tx == 8800, "target 1 is the lab build power")
check(Count(16) == 10, "all 10 units FIGHT")

h = NewHost(); ids = Army(60, 2000, 6000)
Assign(h, ids, { "pick_target", "attack_target" })
ctx = Ctx{ targets = { labBP, eco, eco2 } }
h:Update(0, ctx)
check(#ctx.shared.targets == 3, "60 units: 3 targets")
local toLab = 0
for _, g in ipairs(given) do if g.p[1] == 8800 then toLab = toLab + 1 end end
check(toLab >= 0.65 * 60, "70% of the army goes to the lab build power (" .. toLab .. "/60)")
local others = 0
for _, g in ipairs(given) do if g.p[1] == 8000 or g.p[1] == 7000 then others = others + 1 end end
check(others > 0 and toLab + others == 60, "the rest is split over the other targets")

-- a count override: ask for 2
h = NewHost(); ids = Army(60, 2000, 6000)
Assign(h, ids, { "pick_target", "attack_target" }, { pick_target = { count = 2 } })
ctx = Ctx{ targets = { labBP, eco, eco2 } }
h:Update(0, ctx)
check(#ctx.shared.targets == 2, "cfg count = 2 returns 2 targets")

-- commander: wins over ordinary targets, but not over lab build power
local cmdr = { x = 9100, z = 6100, commander = true, guard = 0 }
h = NewHost(); ids = Army(30, 2000, 6000)
Assign(h, ids, { "pick_target", "commander_strike", "attack_target" })
ctx = Ctx{ targets = { eco, eco2 }, commander = cmdr }
h:Update(0, ctx)
local atCmdr = 0
for _, g in ipairs(given) do if g.p[1] == 9100 then atCmdr = atCmdr + 1 end end
check(atCmdr == 30, "commander in the open: every unit goes for it")
h = NewHost(); ids = Army(30, 2000, 6000)
Assign(h, ids, { "pick_target", "commander_strike", "attack_target" })
ctx = Ctx{ targets = { labBP, eco }, commander = cmdr }
h:Update(0, ctx)
atCmdr = 0
for _, g in ipairs(given) do if g.p[1] == 9100 then atCmdr = atCmdr + 1 end end
check(atCmdr == 0 and ctx.shared.labBP, "lab build power outranks the commander")

-- ── steer ────────────────────────────────────────────────────────────────────
h = NewHost(); ids = Army(10, 2000, 6000)
Assign(h, ids, { "pick_target", "steer", "attack_target" })
ctx = Ctx{ targets = { eco } }
h:Update(0, ctx)
check(Count(10) == 0 and Count(16) == 10, "steer: nothing in the way -> straight FIGHT")
h = NewHost(); ids = Army(10, 2000, 6000)
Assign(h, ids, { "pick_target", "steer", "attack_target" })
ctx = Ctx{ targets = { { x = 9000, z = 6000 } }, cluster = { 5500, 6000, 5000 } }
h:Update(0, ctx)
check(Count(10) == 10, "steer: an army on the path -> everyone MOVEs to a leg point")
local g1 = given[1]
check(g1 and math.abs(g1.p[3] - 6000) > 200, "steer: the leg point is off the straight line (z=" .. tostring(g1 and g1.p[3]) .. ")")
-- no steering inside the attack range
h = NewHost(); ids = Army(10, 8500, 6000)
Assign(h, ids, { "pick_target", "steer", "attack_target" })
ctx = Ctx{ targets = { { x = 9000, z = 6000 } }, cluster = { 8700, 6000, 5000 } }
h:Update(0, ctx)
check(Count(10) == 0, "steer: close to the target -> FIGHT, no detour")

-- ── squad_retreat ────────────────────────────────────────────────────────────
h = NewHost(); ids = Army(4, 3000, 6000)
for _, id in ipairs(ids) do W.units[id].hp = 300 end
Assign(h, ids, { "squad_retreat", "pick_target", "attack_target" })
ctx = Ctx{ targets = { eco }, armedNear = function() return 5000 end }
h:Update(0, ctx)
check(#ctx.retreats == 4 and Count(16) == 0, "squad_retreat: 4 hurt units with enemies near retreat and are not ordered to attack")
check(next(ctx.squad) ~= nil, "squad_retreat: they are in the shared squad table")
for _, id in ipairs(ids) do W.units[id].hp = 900 end        -- healed
ctx.retreats, given = {}, {}
local ctx2 = ctx
ctx2.ArmedValueNear = function() return 0 end
h:Update(100, ctx2)
check(#ctx2.ended == 4 and next(ctx2.squad) == nil, "squad_retreat: healed units are released")
-- healthy units never retreat
h = NewHost(); ids = Army(4, 3000, 6000)
Assign(h, ids, { "squad_retreat", "pick_target", "attack_target" })
ctx = Ctx{ targets = { eco }, armedNear = function() return 5000 end }
h:Update(0, ctx)
check(#ctx.retreats == 0 and Count(16) == 4, "squad_retreat: healthy units keep attacking")

-- ── bomber_run ───────────────────────────────────────────────────────────────
h = NewHost(); ids = Army(8, 1000, 6000, "corhurc")
Assign(h, ids, { "bomber_run" })
ctx = Ctx{ targets = { labBP, eco } }
h:Update(0, ctx)
check(Count(20) == 8, "bomber_run: 8 bombers ATTACK together")
check(given[1] and given[1].p[1] == 8800, "bomber_run: the lab build power is the target")
given = {}
h:Update(60, ctx)
check(#given == 0 and #ctx.released == 0, "bomber_run: the run is left alone until release_after")
h:Update(160, ctx)
check(#ctx.released == 8, "bomber_run: bombers are released after the run")
given = {}
h:Update(500, ctx)
check(#given == 0, "bomber_run: cooldown holds the next run")
h:Update(3000, ctx)
check(Count(20) == 8, "bomber_run: the next run after the cooldown")
h = NewHost(); ids = Army(5, 1000, 6000, "corhurc")
Assign(h, ids, { "bomber_run" })
ctx = Ctx{ targets = { eco } }
h:Update(0, ctx)
check(#given == 0, "bomber_run: fewer than min bombers wait")
h = NewHost(); ids = Army(8, 1000, 6000, "corhurc")
Assign(h, ids, { "bomber_run" })
ctx = Ctx{ targets = { eco }, airThreat = 1e9 }
h:Update(0, ctx)
check(#given == 0, "bomber_run: a target defended by too much anti-air is skipped")

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
