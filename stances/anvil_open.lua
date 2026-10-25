-- HAMMER_ANVIL stage 1 (2026-10-25): boom behind a cheap T1 screen (the 2026-10-25 CORE_HUMAN game: 10% army share, 9.4k m/s at
-- 22:30).  plan.army = "defend" (unit_runtime): the blobs (maneuver_defence) stop raids, and click_army pushes while our ground
-- army clearly outweighs the enemy's.  The Shuriken floor (lab rules) is the mobile home defence.  The hammer comes later, from the air.
local M = {}
M.name = "anvil_open"
M.intent = [=[Boom: a cheap T1 screen holds our line; spend as little on the army as the threat allows.]=]
M.control = [=[Blobs on the perimeter intercept raids; push with raid groups when clearly ahead; Sheldons kite.]=]
M.suggestedShare = [=[10]=]
M.plan = { army = "defend" }
M.units = {
  { n = "corak",    share = 0.25, tag = "mass",    note = [=[Grunt: spam screen]=] },
  { n = "corlevlr", share = 0.25, tag = "mass",    note = [=[Pounder: the tank]=] },
  { n = "cormort",  share = 0.25, tag = "quality", note = [=[Sheldon: long-range support, kites]=],
    behaviors = { "kite" }, cfg = { kite = { step = 300 } } },
  { n = "corcrash", share = 0.10, note = [=[Trasher: T1 bot AA with the screen]=] },
  { n = "corveng",  share = 0.15, note = [=[Avenger: air cover now, the bombers' escort later; puts an air lab in the spine before the burst]=] },
}
return M
