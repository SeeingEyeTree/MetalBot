-- HAMMER_ANVIL stage 3 (2026-10-25): the anvil.  plan.bomb_run = "launch": the burst's bombers go the moment it ends, later waves
-- (the labs' plan.bombers) at bomb_run's RELAUNCH_MIN.  plan.army = "defend": blobs stop raids, click_army pushes when ahead.
--  RAID_BOT's hold comp (stances/hold.lua, comp by the user) with more AA, so the
-- line stands while the economy grows; bombers keep hitting build power while we hold the air (plan.bombers), and the sink's
-- Dragons (SINK_EXTRAS in the macro config: dragon_raid waves, build power first) are the hammer.
local M = {}
M.name = "anvil_hold"
M.intent = [=[Hold our line cost-effectively; bombers and Dragon waves kill enemy build power.]=]
M.control = [=[Blobs intercept raids; push with raid groups when clearly ahead. Sheldons kite, Banishers kite at range edge.]=]
M.suggestedShare = [=[20]=]
M.plan = { army = "defend", bombers = 0.5, bomb_run = "launch" }
M.units = {
  { n = "corak",    share = 0.12, tag = "mass",    note = [=[Grunt: spam]=] },
  { n = "corlevlr", share = 0.13, tag = "mass",    note = [=[Pounder: the screen]=] },
  { n = "cormort",  share = 0.15, tag = "quality", note = [=[Sheldon: long-range support, kites]=],
    behaviors = { "kite" }, cfg = { kite = { step = 300 } } },
  { n = "corsumo",  share = 0.18, tag = "quality", note = [=[Mammoth: T2 bot lab]=] },
  { n = "corshiva", share = 0.12, tag = "quality", note = [=[Shiva: gantry]=] },
  { n = "corban",   share = 0.15, tag = "quality", note = [=[Banisher: kites at range edge]=],
    behaviors = { "range_kite" } },
  { n = "corsent",  share = 0.08, note = [=[flak: base screen + line]=] },
  { n = "coraak",   share = 0.07, note = [=[T2 bot AA]=] },
}
return M
