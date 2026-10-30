-- RAID_BOT's hold game plan (game review 2026-10-13; comp by the user): after the raids trade badly and the enemy army is
-- bigger, defend cost-effectively at our line and let bombers bring the game back when we hold the air.
-- Shares depend on what we can make: "mass" units (Grunts are just spam, Pounders) carry the share at low income so the
-- army can spread; "quality" units (the most effective ones) take over as income grows (strategy_hooks.income_mix).
-- plan.army = "hold": click_army launches nothing and stages near our line; plan.bombers: air labs build bombers while
-- we are air-superior.
local M = {}
M.name = "hold"
M.intent = [=[Defend cost-effectively near our line after a bad trade; bombers hit enemy build power while we have air superiority.]=]
M.control = [=[Army stages at our line front and answers raids. Sheldons kite, Banishers kite at the edge of their range; the rest hold in front.]=]
M.suggestedShare = [=[30]=]
M.plan = { army = "hold", bombers = 0.5 }
M.units = {
  { n = "corak",    share = 0.15, tag = "mass",    note = [=[Grunt: spam]=] },
  { n = "corlevlr", share = 0.15, tag = "mass",    note = [=[Pounder: the screen]=] },
  { n = "cormort",  share = 0.15, tag = "quality", note = [=[Sheldon: long-range support, kites]=],
    behaviors = { "kite" }, cfg = { kite = { step = 300 } } },
  { n = "corsumo",  share = 0.20, tag = "quality", note = [=[Mammoth: T2 bot lab]=] },
  { n = "corshiva", share = 0.15, tag = "quality", note = [=[Shiva: gantry]=] },
  { n = "corsent",  share = 0.06, note = [=[flak (T2 vehicle plant): base screen + army escort]=] },
  { n = "coraak",   share = 0.05, note = [=[T2 bot AA, longer range: base screen + army escort]=] },
  { n = "corban",   share = 0.20, tag = "quality", note = [=[Banisher: T2 vehicle plant, kites at range edge]=],
    behaviors = { "range_kite" } },
}
return M
