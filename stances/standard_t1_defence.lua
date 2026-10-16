-- Maneuver defence, tier 1 (user, 2026-10-16).  Brutes stand in blobs on a perimeter round the base, 10 s of move speed apart;
-- a few Rascals shadow the enemy at the edge of their sight (behaviors/shadow.lua) so the blobs see raids coming; when a group
-- heads for the base ~2x its value of Brutes goes out to meet it, then walks back to its post (bar_framework/maneuver_defence.lua).
-- The Pounders are the slow backstop in front of the base centre; they do not intercept.
-- plan.army = "maneuver" is what makes CORE run the blobs instead of click_army; plan.maneuver overrides maneuver_defence.lua's CFG.
local M = {}
M.name = "standard_t1_defence"
M.intent = [=[Defend: Brutes in blobs on the perimeter, a few Pounders as a backstop, Rascals shadowing the enemy. Never attacks.]=]
M.control = [=[maneuver_defence: blobs 10 s apart, intercept ~2x an incoming group's value, return to post. shadow: Rascals tail the enemy at the edge of their sight.]=]
M.suggestedShare = [=[40]=]
M.plan = { army = "maneuver", maneuver = { SPACING_S = 10, NEED_MULT = 2.0 } }
M.units = {
  { n = "corraid",  share = 0.835, note = [=[Brute: the blobs]=] },
  { n = "corlevlr", share = 0.14,  note = [=[Pounder: slow backstop in front of the base centre]=] },
  { n = "corfav",   share = 0.025, note = [=[Rascal: shadow, finds the enemy groups and keeps them in sight]=],
    behaviors = { "shadow" }, cfg = { shadow = { max = 3 } } },
}
return M
