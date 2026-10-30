-- RAID_BOT's opening game plan (game review 2026-10-13): fast raiders that are active early, hit build power, and either
-- commit or escape (click_army ENGAGE).  No slow units here: Lashers/Pounders/Sheldons/Mammoths belong to the hold plan.
-- plan.army = "raid": click_army launches groups; the strategy's game_plan hook switches to "hold" after bad trades.
local M = {}
M.name = "raid_open"
M.intent = [=[Raid: Gators and Raiders out early in small groups, Tigers once T2 vehicles stand, Demons for the late raid groups. Win by killing enemy build power / eco / commander.]=]
M.control = [=[click_army groups (early launch, commit to build power or escape, find the hole in the base). Demons kite at the edge of their range in the open field.]=]
M.suggestedShare = [=[20]=]
M.plan = { army = "raid" }
M.units = {
  { n = "corgator", share = 0.20, note = [=[Incisor: cheap fast raider]=] },
  { n = "corraid",  share = 0.25, note = [=[Raider: fast vehicle]=] },
  { n = "correap",  share = 0.25, note = [=[Tiger: T2 vehicle plant]=] },
  { n = "corsent",  share = 0.05, note = [=[T2 vehicle flak: very effective vs air, short range; base screen + army escort]=] },
  { n = "coraak",   share = 0.03, note = [=[T2 bot AA: longer range, a bit less effective; base screen + army escort]=] },
  { n = "cordemon", share = 0.30, note = [=[Demon: T3 gantry, kites at range edge]=], behaviors = { "range_kite" } },
}
return M
