-- DRAGON_ECO's opening army (user 2026-10-14): Pounders and a few Lashers from the spine's T1 vehicle plants until metal income
-- reaches 1.1k m/s (strategy_hooks.income_switch -> mammoth_hold).  They only defend (plan army = "perimeter"): perimeter_guard holds them on a ring
-- ~2800 elmos out from our furthest buildings and sends them at intruders; they never attack.
local M = {}
M.name = "pounder_hold"
M.intent = [=[Cheap defensive screen while the economy grows; nothing attacks until the Dragons.]=]
M.control = [=[perimeter_guard: squads at posts on the 2800-elmo ring, FIGHT to intruders inside it, back to the post after.]=]
M.suggestedShare = [=[10]=]
-- army = "perimeter": the armed ground units only defend (perimeter_guard).  extras: the Dragons come from their own lab (not the
-- spine), carry these behaviours (dragon_defend while they wait for the wave, dragon_raid once 50 stand) and are never part of the comp.
M.plan = { army = "perimeter" }
M.extras = {
  { n = "corcrwh", behaviors = { "dragon_raid", "dragon_defend" }, cfg = { dragon_raid = { wave = 50 } },
    note = [=[Dragon: helps defend while it waits for the wave; the wave hits commander, then build power, then AA, then the closest eco]=] },
}
M.units = {
  { n = "corlevlr", share = 0.85, note = [=[Pounder: the screen]=] },
  { n = "cormist",  share = 0.15, note = [=[Lasher: token AA]=] },
}
return M
