-- tests/test_raid_plan.lua
-- RAID_BOT's game-plan pieces (game review 2026-10-13):
--   * stances raid_open / hold / raid_late load, carry `plan`, and the hold units their `tag`;
--   * strategy_hooks.game_plan: raid -> hold when behind AND trading badly (not on one alone), min stay, hold -> raid after
--     being ahead for resume_for; chain_switch lets cap_switch win;
--   * strategy_hooks.income_mix: mass units carry the share at low income, quality units at high income;
--   * behaviors/range_kite: backs off to the edge of our range, not from an enemy that outranges us, not while defending,
--     holds the unit for the step, one unit's threat does not move another unit far away;
--   * game_state: armyRatio / airSuperior from the published WG.MetalBot fields.
-- Run: python tests/run_lua.py tests/test_raid_plan.lua

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local SL = VFS.Include("LuaUI/Widgets/bar_framework/stance_loader.lua")
local ST = VFS.Include("LuaUI/Widgets/bar_framework/strategy.lua")
local H  = VFS.Include("LuaUI/Widgets/bar_framework/strategy_hooks.lua")
local GS = VFS.Include("LuaUI/Widgets/bar_framework/game_state.lua")

-- ── stances ───────────────────────────────────────────────────────────────────
local ro, ho, rl = SL.Load("raid_open"), SL.Load("hold"), SL.Load("raid_late")
check(ro and ho and rl, "raid_open, hold and raid_late load")
check(ro and ro.plan and ro.plan.army == "raid", "raid_open plan: army raid")
check(ho and ho.plan and ho.plan.army == "hold" and ho.plan.bombers == 0.5, "hold plan: army hold, bombers 0.5")
check(rl and rl.plan and rl.plan.army == "raid", "raid_late plan: army raid")
check(ho and #ho.units == 8, "hold has the user's six units + the two ground AA")
local names = {}
for _, u in ipairs(ho and ho.units or {}) do names[u.n] = u end
for _, n in ipairs({ "corak", "corlevlr", "cormort", "corsumo", "corshiva", "corban", "coraak", "corsent" }) do
    check(names[n] ~= nil, "hold includes " .. n)
end
check(names.corak and names.corak.tag == "mass" and names.corsumo and names.corsumo.tag == "quality", "hold units carry tags")
check(names.corban and names.corban.behaviors and names.corban.behaviors[1] == "range_kite", "Banishers range-kite")
local ron = {}
for _, u in ipairs(ro and ro.units or {}) do ron[u.n] = u end
check(not ron.cormist and not ron.corlevlr and not ron.cormort and not ron.corsumo, "raid_open has no slow units")
check(ron.cordemon and ron.cordemon.behaviors[1] == "range_kite", "raid_open Demons range-kite")
check(ron.coraak and ron.corsent, "raid_open has a few ground AA (coraak, corsent)")
check(SL.Load("line_ground").plan == nil, "a stance without plan has none (line_ground unchanged)")

local strat = ST.New{ stances = { "raid_open", "hold" }, initial = "raid_open" }
check(strat:Plan() and strat:Plan().army == "raid", "Strategy:Plan() returns the current stance's plan")
strat:Set("hold")
check(strat:Plan().army == "hold", "Strategy:Plan() follows the stance")

-- ── game_plan ─────────────────────────────────────────────────────────────────
local gp = H.game_plan{}
local function St(f, ratio, trade, extra)
    local s = { frame = f, armyRatio = ratio, trade = trade, armyGround = 1000, enemyGround = 1000 }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end
local good  = { killed = 2000, lost = 1500, ratio = 1.33, badEnds = 0 }
local bad   = { killed = 0, lost = 1484, ratio = 0, badEnds = 1 }
local ends2 = { killed = 300, lost = 800, ratio = 0.375, badEnds = 2 }
check(gp(St(9000, 0.6, good)) == "raid_open", "game_plan: behind but trading well -> stay raid")
check(gp(St(9030, 1.2, bad)) == "raid_open", "game_plan: trading badly but ahead -> stay raid")
check(gp(St(9060, 0.81, bad)) == "hold", "game_plan: behind (0.81) and 0 kills / 1484 lost -> hold (the 9:30 case)")
check(#S.Log("%[PLAN%] .*raid_open %-> hold") == 1, "game_plan: the switch is logged")
check(gp(St(9090, 2.0, good)) == "hold", "game_plan: ahead at once does not flip back (min stay / resume_for)")
-- ahead for 60 s, but still inside min stay (2700 from 9060) -> hold until 11760
check(gp(St(9060 + 1800, 2.0, good)) == "hold", "game_plan: still inside min stay")
check(gp(St(11760, 2.0, good)) == "raid_open", "game_plan: ahead >= 1.4 for 60 s and min stay over -> raid")
local gp2 = H.game_plan{}
check(gp2(St(9000, 0.8, ends2)) == "hold", "game_plan: two bad group ends in a row while behind -> hold")
local gp3 = H.game_plan{}
check(gp3(St(9000, nil, bad)) == "raid_open", "game_plan: no enemy ground known (ratio nil) -> no switch")
check(gp3(St(9030, 0.5, nil)) == "raid_open", "game_plan: no trade data -> no switch")
local gp4 = H.game_plan{}
gp4(St(9000, 0.5, bad))                              -- hold
check(gp4(St(12000, 2.0, good)) == "hold", "game_plan: resume needs the ratio held, one sample is not enough")
check(gp4(St(12030, 1.0, good)) == "hold", "game_plan: the ahead timer resets when the ratio drops")
check(gp4(St(13830, 2.0, good)) == "hold" and gp4(St(15630, 2.0, good)) == "raid_open",
    "game_plan: resumes only after 60 s ahead counted from the last drop")

local capOn = false
local chain = H.chain_switch{ function() if capOn then return "raid_late" end end, H.game_plan{} }
check(chain(St(9000, 0.5, bad)) == "hold", "chain: game_plan decides while the cap switch is off")
capOn = true
check(chain(St(9030, 2.0, good)) == "raid_late", "chain: the cap switch wins once on")

-- ── income_mix ────────────────────────────────────────────────────────────────
local mix = H.income_mix{}
local hs = ST.New{ stances = { "hold" }, initial = "hold" }
local wLo = mix({ metal = { income = 100 } }, hs)
local wHi = mix({ metal = { income = 1500 } }, hs)
check(wLo and wLo.corak == 2.0 and wLo.corsumo == 0.5, "income_mix: low income -> mass x2, quality x0.5")
check(wHi and math.abs(wHi.corak - 0.3) < 1e-9 and wHi.corsumo == 2.0, "income_mix: high income -> mass x0.3, quality x2")
local wMid = mix({ metal = { income = 575 } }, hs)
check(wMid and math.abs(wMid.corak - 1.15) < 1e-9, "income_mix: linear in between (575 m/s -> mass 1.15)")
local rs = ST.New{ stances = { "raid_open" }, initial = "raid_open" }
check(mix({ metal = { income = 100 } }, rs) == nil, "income_mix: no tags in the stance -> no weights")
-- the weights reach the pick: at low income the first pick of hold is a mass unit
hs.weights = wLo
local canAll = function() return true end
local first = hs:Pick(canAll)
check(first == UnitDefNames.corak.id or first == UnitDefNames.corlevlr.id, "income_mix: low income picks a mass unit first")
hs.weights = wHi
local firstHi = hs:Pick(canAll)
check(firstHi ~= UnitDefNames.corak.id and firstHi ~= UnitDefNames.corlevlr.id, "income_mix: high income picks a quality unit first")

-- ── range_kite ────────────────────────────────────────────────────────────────
local BH = VFS.Include("LuaUI/Widgets/bar_framework/behavior_host.lua")
local given = {}
local host = BH.New{ give = function(uid, cmd, p) given[#given + 1] = { uid = uid, cmd = cmd, x = p[1], z = p[3] } end }
local enemies = {}
local defending = {}
local ctx = {
    EnemiesNear = function(x, z, r)
        local out = {}
        for _, e in ipairs(enemies) do
            if math.sqrt((e.x - x) ^ 2 + (e.z - z) ^ 2) <= r then out[#out + 1] = e end
        end
        return out
    end,
    Range = function() return 600 end,
    Speed = function() return 60 end,
    Defending = function(uid) return defending[uid] == true end,
}
local d1 = S.Spawn("corsumo", 0, 1000, 1000, { silent = true })
local d2 = S.Spawn("corsumo", 0, 8000, 8000, { silent = true })
host:Assign(d1, "range_kite")
host:Assign(d2, "range_kite")
-- an enemy (range 300) at 400 from d1: inside 0.85 x 600 = 510 -> back to 570
enemies = { { uid = 9001, x = 1400, z = 1000, range = 300, value = 200, mobile = true } }
local acted = host:Update(30, ctx)
local o1
for _, o in ipairs(given) do if o.uid == d1 then o1 = o end end
check(acted[d1] == "range_kite" and o1 and o1.cmd == 10, "range_kite: an enemy inside 85% of our range -> MOVE")
check(o1 and math.abs(o1.x - (1000 - 170)) < 1 and math.abs(o1.z - 1000) < 1,
    "range_kite: straight away from it, back to 95% of our range (step 170)")
check(acted[d2] == nil, "range_kite: the other Demon, far away, is not moved")
check(host:IsHeld(d1, 31), "range_kite: the unit is held for the step")
check(host:IsHeld(d1, 30 + 80) and not host:IsHeld(d1, 30 + 90), "range_kite: held about step / speed seconds (170/60 s = ~85 frames)")
-- enemy at the edge (560 > 510): no kite
given = {}
local hostB = BH.New{ give = function(uid, cmd, p) given[#given + 1] = { uid = uid, cmd = cmd } end }
hostB:Assign(d1, "range_kite")
enemies = { { uid = 9001, x = 1560, z = 1000, range = 300, value = 200, mobile = true } }
acted = hostB:Update(30, ctx)
check(acted[d1] == nil and #given == 0, "range_kite: enemy at 93% of our range -> no step, keep firing")
-- an enemy that outranges us: close in, no kite
enemies = { { uid = 9002, x = 1300, z = 1000, range = 700, value = 200, mobile = true } }
acted = hostB:Update(60, ctx)
check(acted[d1] == nil, "range_kite: an enemy that outranges us is not kited")
-- static defences are not kited
enemies = { { uid = 9003, x = 1300, z = 1000, range = 300, value = 200, mobile = false } }
acted = hostB:Update(90, ctx)
check(acted[d1] == nil, "range_kite: static defences are ignored")
-- defending: no kite
enemies = { { uid = 9001, x = 1400, z = 1000, range = 300, value = 200, mobile = true } }
defending[d1] = true
acted = hostB:Update(120, ctx)
check(acted[d1] == nil, "range_kite: no kiting while the unit defends (raid response / home guard)")
defending[d1] = nil
acted = hostB:Update(150, ctx)
check(acted[d1] == "range_kite", "range_kite: kites again once it no longer defends")

-- ── game_state fields ─────────────────────────────────────────────────────────
local mb = { armyGround = 4000, armyAir = 3000, airKills = 500, airLost = 100,
             intel = { airValue = 1000, groundValue = 5000 }, trade = bad }
local s = GS.Collect(9000, { MB = mb })
check(math.abs(s.armyRatio - 0.8) < 1e-9, "game_state: armyRatio = own ground / enemy ground")
check(s.airSuperior == true, "game_state: 3x their air and killing more than we lose -> air superior")
check(s.trade == bad, "game_state: trade passed through")
mb.airLost = 900
check(GS.Collect(9000, { MB = mb }).airSuperior == false, "game_state: losing the air trade -> not air superior")
mb.airLost, mb.armyAir = 100, 1200
check(GS.Collect(9000, { MB = mb }).airSuperior == false, "game_state: under 1.5x their air -> not air superior")
check(GS.Collect(9000, { MB = {} }).airSuperior == nil and GS.Collect(9000, { MB = {} }).armyRatio == nil,
    "game_state: other bots (no fields) get nil, not errors")

print(string.format("%d checks, %d failed", checks, failures))
