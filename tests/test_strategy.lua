-- tests/test_strategy.lua
-- bar_framework/strategy.lua + stance_loader (weights, behaviours) + game_state + behaviors/stun_target.lua against
-- tests/spring_stub.lua.  Run from the repo root: python tests/run_lua.py tests/test_strategy.lua
--   * the mix follows the stance shares; a `weights` hook tilts it at run time; `switch` changes stance with a fresh,
--     seeded ledger; `army_share` is clamped and falls back to the stance's suggestion; a failing hook is contained;
--   * Assign hands a unit's stance behaviours (and overrides) to the host; InstallSpine adds one policy;
--   * game_state.Collect works on the stub and reads enemy intel from WG.MetalBot;
--   * stun_target: pack spread over targets, a stunned target keeps one keeper, sticky, falls through when empty.

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

local ST = VFS.Include("LuaUI/Widgets/bar_framework/strategy.lua")
local SL = VFS.Include("LuaUI/Widgets/bar_framework/stance_loader.lua")
local GS = VFS.Include("LuaUI/Widgets/bar_framework/game_state.lua")
local BH = VFS.Include("LuaUI/Widgets/bar_framework/behavior_host.lua")

local function Id(name) return UnitDefNames[name].id end

local raidStance = { name = "raid", suggestedShare = "30", units = {
    { n = "corgator", share = 0.5 },
    { n = "corak",    share = 0.3, behaviors = { "kite" }, cfg = { kite = { step = 250 } } },
    { n = "corvamp",  share = 0.2 },
} }
local lateStance = { name = "late", units = { { n = "corsumo", share = 1.0 } } }

-- Simulate a lab: take picks, note each one, return the built value per unit name.
local function Build(strat, n)
    local built = {}
    for _ = 1, n do
        local d = strat:Pick(function() return true end)
        strat:Note(d)
        local name = UnitDefs[d].name
        built[name] = (built[name] or 0) + SL.Value(d)
    end
    return built
end
local function Frac(built, name)
    local t = 0
    for _, v in pairs(built) do t = t + v end
    return (built[name] or 0) / t
end

-- ── mix follows the shares ────────────────────────────────────────────────────
local strat = ST.New{ stances = { raid = raidStance, late = lateStance }, initial = "raid", log = false }
check(strat:Name() == "raid", "initial stance is set")
local b = Build(strat, 200)
check(math.abs(Frac(b, "corgator") - 0.5) < 0.06 and math.abs(Frac(b, "corvamp") - 0.2) < 0.06,
      string.format("value mix follows the shares (gator %.2f, vamp %.2f)", Frac(b, "corgator"), Frac(b, "corvamp")))

-- ── weights tilt it ───────────────────────────────────────────────────────────
local tilt = ST.New{ stances = { raid = raidStance }, initial = "raid", log = false,
    hooks = { weights = function(state) if (state.enemyAirShare or 0) > 0.3 then return { corvamp = 4 } end end } }
tilt:Tick(30, { enemyAirShare = 0 })
local b0 = Build(tilt, 150)
local tilt2 = ST.New{ stances = { raid = raidStance }, initial = "raid", log = false, hooks = tilt.hooks }
tilt2:Tick(30, { enemyAirShare = 0.8 })
local b1 = Build(tilt2, 150)
check(Frac(b1, "corvamp") > Frac(b0, "corvamp") + 0.2,
      string.format("a weights hook shifts the mix toward AA (%.2f -> %.2f)", Frac(b0, "corvamp"), Frac(b1, "corvamp")))

-- ── share hook, fallback, clamp, failing hook ─────────────────────────────────
local sh = ST.New{ stances = { raid = raidStance }, initial = "raid", log = false }
sh:Tick(30, {})
check(math.abs(sh:Share() - 0.30) < 1e-9, "no hook: the stance's suggested share (" .. sh:Share() .. ")")
local sh2 = ST.New{ stances = { late = lateStance }, initial = "late", log = false }
sh2:Tick(30, {})
check(math.abs(sh2:Share() - ST.DEFAULT_SHARE) < 1e-9, "no hook, no suggestion: the default share")
local sh3 = ST.New{ stances = { raid = raidStance }, initial = "raid", log = false,
    hooks = { army_share = function(state) return state.floating and 3 or -1 end } }
sh3:Tick(30, { floating = true }); check(sh3:Share() == 1, "share is clamped to 1")
sh3:Tick(60, {}); check(sh3:Share() == 0, "share is clamped to 0")
local bad = ST.New{ stances = { raid = raidStance }, initial = "raid", log = false,
    hooks = { army_share = function() error("x") end, switch = function() error("y") end, weights = function() error("z") end } }
bad:Tick(30, {})
check((bad.errors or 0) == 3 and bad:Share() == 0.30 and bad:Name() == "raid", "failing hooks are contained")

-- ── switch ────────────────────────────────────────────────────────────────────
local sw = ST.New{ stances = { raid = raidStance, late = lateStance }, initial = "raid", log = false,
    hooks = { switch = function(state) if state.minute >= 16 then return "late" end end } }
sw:Tick(30, { minute = 5 })
check(sw:Name() == "raid", "no switch before the condition")
sw:Tick(60, { minute = 17, armyByDef = { [Id("corsumo")] = 3, [Id("corak")] = 9 } })
check(sw:Name() == "late", "the switch hook changes stance")
check(sw.ledger.total == 3 * SL.Value(Id("corsumo")), "the new ledger is seeded with existing units of that stance only")
check(sw:Pick(function() return true end) == Id("corsumo"), "picks come from the new stance")

-- ── behaviours ────────────────────────────────────────────────────────────────
local host = BH.New{ give = function() end }
local akUnit = S.Spawn("corak", 0, 1000, 1000, { silent = true })
local gtUnit = S.Spawn("corgator", 0, 1100, 1000, { silent = true })
check(strat:Assign(host, akUnit, Id("corak")) and host:Has(akUnit), "Assign attaches the stance's behaviours")
check(host.units[akUnit].cfg.kite.step == 250, "the stance's per-unit override reaches the behaviour")
check(not strat:Assign(host, gtUnit, Id("corgator")) and not host:Has(gtUnit), "a unit with no behaviours gets none")

local added = {}
local fakeSpine = { AddPolicy = function(n, f, i) added[#added + 1] = { n = n, f = f, i = i } end, RemovePolicy = function() end }
sh3:InstallSpine(fakeSpine)
check(#added == 1 and added[1].n == "strategy" and added[1].f(0.9, {}) == sh3:Share(), "InstallSpine adds a policy returning the share")

-- ── slot spine hand-off ───────────────────────────────────────────────────────
local got = {}
local fakeSS = { SetUnits = function(l) got.units = l end, SetShare = function(s) got.share = s end }
local ss = ST.New{ stances = { raid = raidStance, late = lateStance }, initial = "raid", log = false,
    hooks = { army_share = function() return 0.4 end, switch = function(state) if state.minute >= 16 then return "late" end end } }
ss:InstallSlotSpine(fakeSS)
ss:Tick(30, { minute = 1 })
local tot = 0
for _, u in ipairs(got.units) do tot = tot + u.share end
check(#got.units == 3 and math.abs(tot - 1) < 1e-9 and got.share == 0.4, "slot spine gets the comp and the share each Tick")
ss:Tick(60, { minute = 20 })
check(#got.units == 1 and got.units[1].defID == Id("corsumo"), "a stance switch changes the comp the spine plans labs from")

-- ── game_state ────────────────────────────────────────────────────────────────
WG = { MetalBot = { intel = { airValue = 300, groundValue = 700 }, armyCount = 12, threats = { { x = 1, z = 1 } } } }
local gs = GS.Collect(1800, { team = 0 })
check(gs.minute == 1 and gs.armyCount == 12 and #gs.threats == 1, "game_state reads WG.MetalBot")
check(math.abs(gs.enemyAirShare - 0.3) < 1e-9, "enemy air share from intel")
check(gs.metal and gs.energy and gs.metal.fill >= 0, "resources are collected")
WG = {}
check(GS.Collect(0, { team = 0 }).enemyAirShare == nil, "no intel: air share unknown")

-- ── stun_target ───────────────────────────────────────────────────────────────
local given = {}
local sh4 = BH.New{ give = function(uid, cmd, p) given[#given + 1] = { uid = uid, cmd = cmd, tid = p[1] } end }
local packs = {}
for i = 1, 6 do packs[i] = S.Spawn("corbw", 0, 3000 + i * 20, 3000, { silent = true }) end
for _, id in ipairs(packs) do sh4:Assign(id, "stun_target", { need_min = 2, need_max = 2, hp_per = 700 }) end
local targets = {
    { id = 501, x = 3200, z = 3000, hp = 900, mhp = 900, para = 0, value = 300 },
    { id = 502, x = 3300, z = 3000, hp = 900, mhp = 900, para = 5000, value = 500 },   -- already stunned
    { id = 503, x = 3400, z = 3000, hp = 900, mhp = 900, para = 0, value = 200 },
}
local ctx = { TargetsNear = function() return targets end }
local acted = sh4:Update(30, ctx)
local per = {}
for _, g in ipairs(given) do per[g.tid] = (per[g.tid] or 0) + 1 end
check(#given == 6 and per[502] == 1, "a stunned target keeps exactly one keeper (" .. tostring(per[502]) .. ")")
check((per[501] or 0) >= 2 and (per[503] or 0) >= 2, "unstunned targets get their crew")
local t0 = {}
for _, g in ipairs(given) do t0[g.uid] = g.tid end
given = {}
sh4:Update(60, ctx)
local same = true
for _, g in ipairs(given) do if t0[g.uid] ~= g.tid then same = false end end
check(same and #given <= 6, "assignments stick")
targets = {}
acted = sh4:Update(90, ctx)
check(next(acted) == nil, "no targets: the units fall through (nobody claimed)")

-- strategy_hooks.match_enemy
local SH = VFS.Include("LuaUI/Widgets/bar_framework/strategy_hooks.lua")
local function MS(o, st)
    st.metal = st.metal or { fill = 0.1 }
    st.energy = st.energy or { fill = 0.1 }
    return SH.match_enemy(o)(st)
end
local F6 = 6 * 1800
check(MS({ log = false }, { frame = 3000, armyValue = 0, enemyGround = 5000 }) == 0, "match: nothing before the 3:00 start")
check(MS({ log = false }, { frame = F6, armyValue = 0, enemyGround = 4000 }) > 0.99, "match: no army vs a known enemy -> 1")
check(math.abs(MS({ log = false }, { frame = F6, armyValue = 4400, enemyGround = 4000 }) - 0.20) < 1e-6, "match: matched -> floor")
check(math.abs(MS({ log = false }, { frame = F6, armyValue = 9000, enemyGround = 4000 }) - 0.05) < 1e-6, "match: well ahead -> ahead floor")
check(MS({ log = false }, { frame = F6, armyValue = 0 }) > 0.5, "match: unscouted enemy uses the time curve")
check(MS({ log = false }, { frame = F6, armyValue = 9e9, enemyGround = 100,
    metal = { fill = 0.95 }, energy = { fill = 0.95 } }) == 1, "match: floating -> 1")
check(math.abs(MS({ log = false }, { frame = F6, armyValue = 4400, enemyGround = 4000, urgency = "rush",
    threats = { {}, {} } }) - 0.20) < 1e-6, "match: threats do not lift the share while we only match")
local sEarly = MS({ log = false }, { frame = 5400, armyValue = 0, metal = { fill = 0.1, income = 40 } })
check(sEarly > 0.2 and sEarly < 0.4, "match: a small early gap is a few seconds of income, not share 1 (" .. sEarly .. ")")
local h = SH.match_enemy({ log = false })
h({ frame = F6, armyValue = 0, enemyGround = 4000, metal = { fill = 0 }, energy = { fill = 0 } })
local s1 = h({ frame = F6 + 30, armyValue = 9e9, enemyGround = 4000, metal = { fill = 0 }, energy = { fill = 0 } })
check(s1 > 0.9 and s1 < 1, "match: share falls gradually, not at once")

-- income_switch (DRAGON_ECO): one-way, after the smoothed income holds the threshold for hold_s
do
    local sw = SH.income_switch{ to = "mammoth_hold", income = 1100, hold_s = 20 }
    local function At(f, inc) return sw({ frame = f, minute = f / 1800, metal = { income = inc } }) end
    check(At(0, 1500) == nil, "income_switch: not on the first tick above the threshold")
    check(At(300, 1500) == nil, "income_switch: not before hold_s")
    local dip = true
    for f0 = 330, 480, 30 do if At(f0, 200) ~= nil then dip = false end end   -- a 6-tick dip takes the smoothed income under
    check(dip, "income_switch: no switch during a dip")
    local f, got = 510, nil
    while not got and f < 6000 do got = At(f, 1500); f = f + 30 end
    check(got == "mammoth_hold" and f > 510 + 600, "income_switch: a dip restarts the hold; switches once held for 20 s (frame " .. f .. ")")
    check(At(f + 30, 0) == "mammoth_hold", "income_switch: one-way (stays after income falls)")
    local spike = SH.income_switch{ to = "x", income = 1100, hold_s = 20 }
    local fired = false
    for i = 0, 40 do
        if spike({ frame = i * 30, metal = { income = (i % 10 == 0) and 5000 or 300 } }) then fired = true end
    end
    check(not fired, "income_switch: short spikes do not switch (the income is smoothed)")

    -- burst_switch: nothing before income holds, `to` until `spend` went into the army (or burst_s), then `back` for good
    local burst = SH.burst_switch{ to = "burst", back = "hold", income = 250, hold_s = 20, spend = 5000, burst_s = 240 }
    local function B(frame, inc, av) return burst({ frame = frame, metal = { income = inc }, armyValue = av or 1000 }) end
    check(B(0, 100) == nil and B(30, 100) == nil, "burst_switch: no stance before income holds")
    local bf, bgot = 60, nil
    while not bgot and bf < 6000 do bgot = B(bf, 400); bf = bf + 30 end
    local startF = bf - 30
    check(bgot == "burst" and startF >= 60 + 600, "burst_switch: the burst starts once income held 20 s (frame " .. startF .. ")")
    check(B(startF + 30 * 30, 0, 4000) == "burst", "burst_switch: still on below the spend, even if income drops")
    check(B(startF + 40 * 30, 0, 2000) == "burst", "burst_switch: losses do not undo the spend so far")
    check(B(startF + 50 * 30, 0, 6100) == "hold", "burst_switch: ends once the army value rose by `spend`")
    check(B(startF + 300 * 30, 900, 1000) == "hold", "burst_switch: then `back` for good")
    local timed = SH.burst_switch{ to = "burst", back = "hold", income = 0, hold_s = 0, spend = 5000, burst_s = 240 }
    check(timed({ frame = 0, metal = { income = 1 }, armyValue = 0 }) == "burst", "burst_switch: starts")
    check(timed({ frame = 239 * 30, metal = { income = 1 }, armyValue = 0 }) == "burst" and
          timed({ frame = 240 * 30, metal = { income = 1 }, armyValue = 0 }) == "hold", "burst_switch: burst_s caps it without the spend")
    local alive = 0
    local counted = SH.burst_switch{ to = "burst", back = "hold", income = 0, hold_s = 0, unit = "corshad", count = 30, burst_s = 300,
                                     spend = 10, count_fn = function() return alive end }
    check(counted({ frame = 0, metal = { income = 1 }, armyValue = 0 }) == "burst", "burst_switch (count): starts")
    alive = 29
    check(counted({ frame = 30 * 30, metal = { income = 1 }, armyValue = 99999 }) == "burst",
          "burst_switch (count): army value does not end it while under the count")
    alive = 30
    check(counted({ frame = 31 * 30, metal = { income = 1 }, armyValue = 0 }) == "hold", "burst_switch (count): ends at `count` alive")

    -- safe_ratio / abort_ratio: no burst while outmatched on the ground (the defensive `back` meanwhile); a running burst aborts
    local gated = SH.burst_switch{ to = "burst", back = "hold", income = 0, hold_s = 0, burst_s = 300, safe_ratio = 0.8, abort_ratio = 0.5 }
    local function GS(frame, ratio) return gated({ frame = frame, metal = { income = 1 }, armyValue = 0, armyRatio = ratio }) end
    check(GS(0, 0.38) == "hold", "burst_switch (gated): ratio 0.38 < 0.8 -> held, the defensive stance")
    check(GS(30, 0.6) == "hold", "burst_switch (gated): still under safe_ratio -> held")
    check(GS(60, 0.9) == "burst", "burst_switch (gated): safe -> the burst")
    check(GS(90, 0.6) == "burst", "burst_switch (gated): 0.6 is above abort_ratio -> the burst goes on")
    check(GS(120, 0.4) == "hold" and GS(150, 2.0) == "hold", "burst_switch (gated): under abort_ratio -> aborted to `back`, for good")
    local unknown = SH.burst_switch{ to = "burst", back = "hold", income = 0, hold_s = 0, burst_s = 300, safe_ratio = 0.8 }
    check(unknown({ frame = 0, metal = { income = 1 }, armyValue = 0 }) == "burst", "burst_switch (gated): no enemy ground known -> not held")
end

-- unit-cap filter: from capFilter the stances' T1 combat units leave the comp and the picks (off again 0.05 below)
do
    UnitDefNames.corak.customParams = { techlevel = "1" }
    local mix = { name = "mix", units = { { n = "corak", share = 0.7 }, { n = "correap", share = 0.3 } } }
    local cf = ST.New{ stances = { mix = mix }, initial = "mix", capFilter = 0.6 }
    local function Has(list, name) for _, u in ipairs(list) do if u.defID == Id(name) then return true end end return false end
    cf:Tick(30, { capFrac = 0.5 })
    check(Has(cf:UnitList(), "corak"), "cap filter: below the fill the T1 unit stays in the comp")
    cf:Tick(60, { capFrac = 0.65 })
    local ul = cf:UnitList()
    check(not Has(ul, "corak") and Has(ul, "correap") and math.abs(ul[1].share - 1) < 1e-9, "cap filter: the T1 combat unit is dropped, the rest renormalised")
    local got = {}
    for _ = 1, 20 do local d = cf:Pick(function() return true end); if d then got[d] = true; cf:Note(d, 1) end end
    check(not got[Id("corak")] and got[Id("correap")], "cap filter: picks skip the T1 combat unit")
    cf:Tick(90, { capFrac = 0.57 })
    check(not Has(cf:UnitList(), "corak"), "cap filter: hysteresis (still on 0.03 under)")
    cf:Tick(120, { capFrac = 0.54 })
    check(Has(cf:UnitList(), "corak"), "cap filter: off again 0.05 under")
    local onlyT1 = ST.New{ stances = { t1 = { name = "t1", units = { { n = "corak", share = 1 } } } }, initial = "t1", capFilter = 0.6 }
    onlyT1:Tick(30, { capFrac = 0.9 })
    check(Has(onlyT1:UnitList(), "corak"), "cap filter: a stance of only T1 units keeps its comp")
    UnitDefNames.corak.customParams = {}
end

-- behaviours: a stance unit without behaviours falls through to the stance's extras (the sink's Dragons in raid_late)
do
    local late = { name = "late", units = { { n = "corsumo", share = 1 } },
                   extras = { { n = "corsumo", behaviors = { "kite" } } } }
    local bs = ST.New{ stances = { late = late }, initial = "late" }
    local names = bs:BehaviorsFor(Id("corsumo"))
    check(names and names[1] == "kite", "BehaviorsFor: the extras' behaviours when the comp entry has none")
end

-- plan.share: a floor under the hook's share while the stance is current
do
    local lo = { name = "lo", units = { { n = "corak", share = 1 } } }
    local burstSt = { name = "burstSt", plan = { army = "hold", share = 0.65 }, units = { { n = "corshad", share = 1 } } }
    local ps = ST.New{ stances = { lo = lo, burstSt = burstSt }, initial = "lo",
                       hooks = { army_share = function() return 0.10 end } }
    ps:Tick(30, {})
    check(math.abs(ps:Share() - 0.10) < 1e-9, "plan.share: no floor without the field")
    ps:Set("burstSt"); ps:Tick(60, {})
    check(math.abs(ps:Share() - 0.65) < 1e-9, "plan.share lifts the share (" .. ps:Share() .. ")")
end


-- user 2026-10-26: match_enemy `unscouted` share and game_plan `scout` (start on hold, decide raid / hold from the located enemy's army)
do
    local SHm = VFS.Include("LuaUI/Widgets/bar_framework/strategy_hooks.lua")
    local h2 = SHm.match_enemy({ unscouted = 0.35, log = false })
    check(math.abs(h2({ frame = 600, located = false, metal = { income = 20, fill = 0.1 }, energy = { fill = 0.1 }, urgency = "none", threats = {} }) - 0.35) < 1e-9,
          "unscouted: share 0.35 before the enemy is located")
    local sh = h2({ frame = 600, located = true, armyValue = 500, enemyGround = 100, enemyAir = 0, metal = { income = 20, fill = 0.1 }, energy = { fill = 0.1 }, urgency = "none", threats = {} })
    check(sh < 0.35, "unscouted: the old curve applies once located (" .. sh .. ")")
    local gp = SHm.game_plan{ raid = "raid_open", hold = "hold", start_hold = true, scout = { min_stay = 900 } }
    check(gp({ frame = 100, located = false }) == "hold", "game_plan: starts on hold")
    check(gp({ frame = 200, located = true, armyValue = 0, enemyGround = 0, enemyAir = 0 }) == "hold", "game_plan: no decision while nothing is known")
    check(gp({ frame = 300, located = true, armyValue = 800, enemyGround = 100, enemyAir = 0 }) == "raid_open", "game_plan: weak enemy -> raid")
    check(gp({ frame = 500, located = true, armyValue = 800, enemyGround = 3000, enemyAir = 0 }) == "raid_open", "game_plan: no flip inside min_stay")
    check(gp({ frame = 1300, located = true, armyValue = 800, enemyGround = 3000, enemyAir = 0 }) == "hold", "game_plan: strong enemy -> hold")
    local gp2 = SHm.game_plan{ raid = "raid_open", hold = "hold", start_hold = true, scout = {} }
    check(gp2({ frame = 300, located = true, armyValue = 800, enemyGround = 4500, enemyAir = 0 }) == "hold", "game_plan: strong enemy at first sight -> hold")
end

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
