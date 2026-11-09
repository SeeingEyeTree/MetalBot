-- raid_brutes_wall (2026-11-08, CORE_v4 with AREA_DEFENCE; machines/v4_defence.lua): raid_brutes plus Pounders for area_defence's wall.  User 2026-11-08: "I am a bit
-- worried about how many pounders would get made.  I think for now just change the stance so the unit % is 12 gators to 1 pounder and 10 brutes to one
-- pounder."  Shares are of army SPEND (value), so the count ratio 10 Brutes (269.3 metal-eq each) : 1 Pounder (257.1) is share 0.9129 / 0.0871.  Every finished Pounder goes to the
-- wall (defence/wall.lua); Pounders over the walls' want are reclaimed.  raid_brutes.lua (the committed CORE_v4's) is unchanged.
-- raid_start with Brutes (corraid) instead of Incisors, three raid groups (user 2026-10-28: "the same as the starting one, it just builds
-- brutes instead of gators at a 250 m/s signal.  Brutes are better but you need mass and speed at the very start, so you make gators").
-- The machine moves start -> start_brutes once metal income >= 250.  Batch reinforcements: new units gather at the stage and join in batches.
local M = {}
M.name = "raid_brutes_wall"
M.intent = [=[Opening raid, Brutes: tougher raiders in three groups, new units join in batches. Same survive-first raid as raid_start.]=]
M.control = [=[click_army raid groups (3) with SURVIVE: steer away from enemy force, dive only into a big hole, otherwise skirmish and step back; reinforcements gather at the stage and join the weakest group together. Raid groups do not come home: reinforcements defend.]=]
M.suggestedShare = [=[60]=]
M.plan = { army = "raid", survive = true, support = "unless_raided", raid_groups = 3, batch = true, prod_s = 8 }
M.units = {
  { n = "corraid", share = 0.9129, note = [=[Brute: tougher fast vehicle]=], behaviors = { "brute_raid" } },
  { n = "corlevlr", share = 0.0871, note = [=[Pounder: area_defence's wall, 1 per 10 Brutes]=] },
}
M.extras = {
  { n = "corgator", behaviors = { "gator_raid" }, note = [=[Incisors left over from raid_start]=] },
  { n = "cormist", behaviors = { "range_kite" }, note = [=[Lasher: AA post, steps back from ground enemies inside its range]=] },
}
return M
