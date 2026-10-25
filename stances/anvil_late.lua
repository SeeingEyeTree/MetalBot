-- HAMMER_ANVIL's late game (2026-10-25): raid_late's comp with the anvil plan (defend / push when ahead, bomb_run waves).
-- From raid_late.lua -- RAID_BOT's late game: Late_game.lua's comp (taken when the unit cap is 75% full) with the Demons kiting at the edge of
-- their range and the raid plan kept.  Late_game.lua itself is the stance editor's file (STANCE_BOT uses it) and is left alone.
local M = {}
M.name = "anvil_late"
M.intent = [=[Final comp once eco outruns the unit cap: Demons, Juggernauts, Dragons.]=]
M.control = [=[click_army groups; Demons kite at the edge of their range in the open field.]=]
M.suggestedShare = [=[~100]=]
M.plan = { army = "defend", bombers = 0.3, bomb_run = "launch", push = { ratio = 1.2 } }
M.units = {
  { n = "cordemon", share = 0.10, behaviors = { "range_kite" } },
  { n = "corjugg",  share = 0.20 },
  { n = "corsent",  share = 0.05 },
  { n = "coraak",   share = 0.04 },
  { n = "corcrwh",  share = 0.70 },
}
return M
