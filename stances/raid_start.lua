-- Opening raid stance (user 2026-10-27): the army is made from 4:00 and goes out to find and raid the enemy at once, survival first.
-- Incisors only (Brutes are slower: gators get around); the first six units from the vehicle plant are ground scouts, which the lab rules make (not this comp).
local M = {}
M.name = "raid_start"
M.intent = [=[Opening raid: Incisors leave as soon as they are made, scout toward unseen ground, hit enemy build power / eco and pull enemy units to their own side.]=]
M.control = [=[click_army raid groups with SURVIVE: steer away from enemy force, dive only into a big hole, otherwise skirmish and step back; low-hp units retreat.]=]
M.suggestedShare = [=[60]=]
M.plan = { army = "raid", survive = true, support = "unless_raided" }
M.units = {
  { n = "corgator", share = 1.0, note = [=[Incisor: fast cheap raider]=] },
}
return M
