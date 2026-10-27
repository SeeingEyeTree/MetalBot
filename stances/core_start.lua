-- CORE's opening army (user 2026-10-26): 6 Incisors to 1 Pounder by count (76 / 24 by value), built fast on the line's vehicle lab with
-- nanos on it; the share machine gives it a big army share so ~4k of army value stands by 6:00.  After 6:00 the stance machine moves to
-- t1_hold or t1_push.
local M = {}
M.name = "core_start"
M.intent = [=[Opening: Incisors (fast, cheap) with a Pounder screen, ~4k army value by 6:00, then hold or push by what the scouts found.]=]
M.control = [=[maneuver blobs hold a ring a little out from the base (plan army "hold"); nothing leaves.]=]
M.suggestedShare = [=[60]=]
M.plan = { army = "hold", maneuver = { R_MIN = 1100 } }
M.units = {
  { n = "corgator", share = 0.76, note = [=[Incisor: 6 of every 7 units]=] },
  { n = "corlevlr", share = 0.24, note = [=[Pounder: the slow screen, 1 of every 7]=] },
}
return M
