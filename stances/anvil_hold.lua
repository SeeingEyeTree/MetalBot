-- AIR_TIMING stage 3 (2026-10-25): the anvil.  plan.bomb_run = "launch": the burst's bombers go the moment it ends, later waves
-- (the labs' plan.bombers) at bomb_run's RELAUNCH_MIN.  plan.army = "defend": blobs stop raids, click_army pushes when ahead.
--
-- v2 (2026-10-25, from the per-type stats of a game vs CORE: 3 Mammoths, 0 Shivas, 0 Banishers built at a 10% share; 16 Sheldons in
-- the blobs were sent in front of raiders): a T2 anvil with roles.  Mammoths are the screen (maneuver_defence backstop; the slow
-- group's screen when pushing), Sheldons and Banishers are support (SUPPORT_ROLE: behind the screen, at range), Tigers intercept,
-- flak / Manticores are ground AA.  plan.share 0.20 lifts the 10% boom share once the burst is over so the T2 labs stand.
local M = {}
M.name = "anvil_hold"
M.intent = [=[Hold our line with a T2 screen + artillery; bombers and Dragon waves kill enemy build power.]=]
M.control = [=[Mammoth screen at the posts, Sheldons / Banishers behind at range, Tigers intercept raids; push (slow group + raid groups) when clearly ahead.]=]
M.suggestedShare = [=[20]=]
-- push: the main push is the slow group (slower than 60: Mammoths, Sheldons, Banishers), 2 fast raid groups go for the sides
M.plan = { army = "defend", bombers = 0.5, bomb_run = "launch", share = 0.20, push = { slow = 60, raid_groups = 2, side_r = 2500, prod_s = 20, crit_s = 20 } }
M.units = {
  { n = "corsumo",  share = 0.30, tag = "quality", note = [=[Mammoth: the screen]=] },
  { n = "cormort",  share = 0.25, tag = "quality", note = [=[Sheldon: long-range support (no kite in the blobs)]=] },
  { n = "corban",   share = 0.15, tag = "quality", note = [=[Banisher: support, kites at range edge when pushing]=],
    behaviors = { "range_kite" } },
  { n = "correap",  share = 0.15, note = [=[Tiger: the fast interceptor]=] },
  { n = "corsent",  share = 0.10, note = [=[flak: ground AA]=] },
  { n = "coraak",   share = 0.05, note = [=[Manticore: ground AA]=] },
}
return M
