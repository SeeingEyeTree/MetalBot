-- raid_start_wall (2026-11-08, CORE_v4 with AREA_DEFENCE; machines/v4_defence.lua): raid_start plus Pounders for area_defence's wall.  User 2026-11-08: "I am a bit
-- worried about how many pounders would get made.  I think for now just change the stance so the unit % is 12 gators to 1 pounder and 10 brutes to one
-- pounder."  Shares are of army SPEND (value), so the count ratio 12 Incisors (135.7 metal-eq each) : 1 Pounder (257.1) is share 0.8637 / 0.1363.  Every finished Pounder goes to the
-- wall (defence/wall.lua); Pounders over the walls' want are reclaimed.  raid_start.lua (the committed CORE_v4's) is unchanged.
-- Opening raid stance (user 2026-10-27): the army is made from 4:00 and goes out to find and raid the enemy at once, survival first.
-- Incisors only (Brutes are slower: gators get around; raid_brutes takes over at 250 m/s); the first six units from the vehicle plant are ground scouts, which the lab rules make (not this comp).
-- Named behaviours (user 2026-10-28): corgator = gator_raid (name only; click_army owns the orders), Lashers that happen to exist kite at range.
local M = {}
M.name = "raid_start_wall"
M.intent = [=[Opening raid: Incisors leave as soon as they are made, scout toward unseen ground, hit enemy build power / eco and pull enemy units to their own side.]=]
M.control = [=[click_army raid groups (2) with SURVIVE: steer away from enemy force, dive only into a big hole, otherwise skirmish and step back; low-hp units retreat. Reinforcements defend the base (raid_response, the held-home production).]=]
M.suggestedShare = [=[60]=]
-- batch: once both groups are out, new Incisors gather at the stage and join the weakest group together (click_army LAUNCH_MIN_AV = 15 gators),
-- not one at a time -- the 2026-10-28 test game had 160 Incisors strung out as single-file reinforcements behind two groups of 3
M.plan = { army = "raid", survive = true, support = "unless_raided", raid_groups = 2, batch = true, prod_s = 10 }
M.units = {
  { n = "corgator", share = 0.8637, note = [=[Incisor: fast cheap raider]=], behaviors = { "gator_raid" } },
  { n = "corlevlr", share = 0.1363, note = [=[Pounder: area_defence's wall, 1 per 12 Incisors]=] },
}
M.extras = {
  { n = "cormist", behaviors = { "range_kite" }, note = [=[Lasher: AA post, steps back from ground enemies inside its range]=] },
}
return M
