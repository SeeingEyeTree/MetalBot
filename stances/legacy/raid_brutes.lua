-- raid_start with Brutes (corraid) instead of Incisors, three raid groups (user 2026-10-28: "the same as the starting one, it just builds
-- brutes instead of gators at a 250 m/s signal.  Brutes are better but you need mass and speed at the very start, so you make gators").
-- The machine moves start -> start_brutes once metal income >= 250.  Batch reinforcements: new units gather at the stage and join in batches.
local M = {}
M.name = "raid_brutes"
M.intent = [=[Opening raid, Brutes: tougher raiders in three groups, new units join in batches. Same survive-first raid as raid_start.]=]
M.control = [=[click_army raid groups (3) with SURVIVE: steer away from enemy force, dive only into a big hole, otherwise skirmish and step back; reinforcements gather at the stage and join the weakest group together. Raid groups do not come home: reinforcements defend.]=]
M.suggestedShare = [=[60]=]
M.plan = { army = "raid", survive = true, support = "unless_raided", raid_groups = 3, batch = true, prod_s = 8 }
M.units = {
  { n = "corraid", share = 1.0, note = [=[Brute: tougher fast vehicle]=], behaviors = { "brute_raid" } },
}
M.extras = {
  { n = "corgator", behaviors = { "gator_raid" }, note = [=[Incisors left over from raid_start]=] },
  { n = "cormist", behaviors = { "range_kite" }, note = [=[Lasher: AA post, steps back from ground enemies inside its range]=] },
}
return M
