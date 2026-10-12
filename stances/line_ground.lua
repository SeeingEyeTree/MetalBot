-- The ground army the LINE spine builds (LINE_CLICK_v16's vehicle plant + T2 labs) as one stance, for STANCE_BOT.
-- Air guards (Shuriken, Wasp, fighters) stay with the lab controller's roles; this is the spine's share.
-- behaviors / cfg: bar_framework/behavior_host (kite = back off from ANY approaching enemy, threat-weighted).
local M = {}
M.name = "line_ground"
M.intent = [=[Raid-and-trade ground army: fast Gators/Raiders for the attack groups, a slow Lasher/Pounder group that holds ground, T2 Mammoths/Sheldons/Tigers once the army can feed a T2 lab.]=]
M.control = [=[Lashers and Sheldons back away from anything closing on them (kite); Pounders screen in front (slow_front.lua); Gators, Raiders and Tigers go with click_army's attack groups.]=]
M.suggestedShare = [=[20]=]
M.units = {
  { n = "corgator", share = 0.04, note = [=[Incisor: cheap fast vehicle]=] },
  { n = "corraid",  share = 0.06, note = [=[Raider: fast vehicle]=] },
  { n = "cormist",  share = 0.08, note = [=[Lasher: long-range support, kites]=], behaviors = { "kite" }, cfg = { kite = { step = 400 } } },
  { n = "corlevlr", share = 0.04, note = [=[Pounder: the screen]=] },
  { n = "corsumo",  share = 0.10, note = [=[Mammoth: T2 bot lab]=] },
  { n = "cormort",  share = 0.06, note = [=[Sheldon: T2 support, kites]=], behaviors = { "kite" }, cfg = { kite = { step = 300 } } },
  { n = "correap",  share = 0.12, note = [=[Tiger: T2 vehicle plant]=] },
  { n = "cordemon", share = 0.50, note = [=[Demon: T3 gantry (v16's late army)]=] },
}
return M
