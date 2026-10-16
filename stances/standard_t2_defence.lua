-- Maneuver defence, tier 2 (user, 2026-10-16).  The same plan as standard_t1_defence with T2 vehicles only: no T1 units are
-- built any more (the Rascals and Brutes that exist keep their jobs).  Tigers are the blobs, Tzars the slow backstop (speed 39 is
-- under maneuver_defence's BACKSTOP_SPEED, so they stand in front of the base centre and never intercept).
local M = {}
M.name = "standard_t2_defence"
M.intent = [=[Defend: Tigers in blobs on the perimeter, Tzars as the backstop. T1 units are no longer built.]=]
M.control = [=[maneuver_defence: blobs 10 s apart, intercept ~2x an incoming group's value, return to post.]=]
M.suggestedShare = [=[40]=]
M.plan = { army = "maneuver", maneuver = { SPACING_S = 10, NEED_MULT = 2.0 } }
M.units = {
  { n = "correap", share = 0.6, note = [=[Tiger: the blobs]=] },
  { n = "corgol",  share = 0.4, note = [=[Tzar: slow heavy backstop]=] },
}
return M
