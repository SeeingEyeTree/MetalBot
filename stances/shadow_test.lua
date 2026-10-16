-- Test stance for the `shadow` behaviour (bar_framework/behaviors/shadow.lua).  In a game with a stance bot (RAID_BOT:
-- set STANCE = "shadow_test" in its macro_controller CFG), `/give corgator 20`: ONE Incisor (max = 1) tails the enemy at the
-- edge of its vision, the other 19 are the army it rides ahead of.  The real unit is a Rascal (corfav).
local M = {}
M.name = "shadow_test"
M.intent = [=[Test: one Incisor shadows the enemy at the edge of its sight; the rest fight normally.]=]
M.control = [=[click_army for the army, shadow for one unit.]=]
M.suggestedShare = [=[20]=]
M.plan = { army = "raid" }
M.units = {
  { n = "corgator", share = 1.0, note = [=[Incisor: one of them shadows]=],
    behaviors = { "shadow" }, cfg = { shadow = { max = 1 } } },
}
return M
