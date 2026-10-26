-- AIR_TIMING's late game (2026-10-25): taken when the unit cap is 75% full.  plan.army = "defend": blobs hold the base, the army pushes
-- when clearly ahead and raids the far side (low-risk targets, a garrison stays) when nobody has raided us for a while.  Bomber waves go on.
-- The push (user 2026-10-25): a MAIN PUSH of the slow, cost-effective units (Mammoths screen, Sheldons / Banishers behind them: click_army's
-- slow group, speed < plan.push.slow) draws the enemy army, while TWO fast raid groups (Tigers, Demons) go for the sides (SIDE_R).
-- Flak trucks (10%) escort every attack group.  The Dragons come from the metal sink, more ground AA from the AA floor and the rush.
local M = {}
M.name = "anvil_late"
M.intent = [=[Main push of Mammoths + artillery draws the enemy army; Tiger / Demon raid groups hit the sides.  Dragons from the sink.]=]
M.control = [=[Defend with the blobs; push (main push + 2 side raids) when ahead; low-risk raids when quiet.  Demons / Banishers kite at range.]=]
M.suggestedShare = [=[~100]=]
M.plan = { army = "defend", bombers = 0.3, bomb_run = "launch", push = { ratio = 1.2, slow = 60, raid_groups = 2, side_r = 2500, prod_s = 20, crit_s = 20 } }
M.units = {
  { n = "correap",  share = 0.25, note = [=[Tiger: fast T2 tank, the side raids]=] },
  { n = "cordemon", share = 0.15, behaviors = { "range_kite" }, note = [=[Demon: heavy flamer, raids, kites at range edge]=] },
  { n = "corsumo",  share = 0.20, note = [=[Mammoth: the main push's screen]=] },
  { n = "cormort",  share = 0.15, note = [=[Sheldon: the main push's artillery]=] },
  { n = "corban",   share = 0.15, behaviors = { "range_kite" }, note = [=[Banisher: the main push's long-range support]=] },
  { n = "corsent",  share = 0.10, note = [=[Fury flak truck: ground AA escort, shared over the main push and the raid groups (user 2026-10-25: the Tigers had no AA)]=] },
}
return M
