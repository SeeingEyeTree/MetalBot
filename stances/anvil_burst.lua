-- HAMMER_ANVIL stage 2 (2026-10-25): the bomber burst.  T1_bombing_run's comp (user: "rush out as many bombers in a short period
-- of time ... spend a lot quickly and then go back into eco.  15-30 bombers"), taken for a fixed window by
-- strategy_hooks.burst_switch until 30 Shadows stand.  plan.share lifts the army share for the window; plan.bomb_run = "rally":
-- bomb_run.lua holds the bombers at the station (anvil_hold's "launch" sends them the moment the burst ends).
local M = {}
M.name = "anvil_burst"
M.intent = [=[Spend hard on T1 bombers for a short window, hit enemy eco and build power, then back to eco.]=]
M.control = [=[bomb_run: fighters FIGHT ahead, ~4 bombers per eco point, home when spent. Ground defends / pushes.]=]
M.suggestedShare = [=[65]=]
M.plan = { army = "defend", share = 0.65, bomb_run = "rally" }
M.units = {
  { n = "corshad", share = 0.85, note = [=[Shadow: T1 bomber]=] },
  { n = "corveng", share = 0.15, note = [=[Avenger: fighter cover for the bombers (anvil_open made the first ones)]=] },
}
return M
