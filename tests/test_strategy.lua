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

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
