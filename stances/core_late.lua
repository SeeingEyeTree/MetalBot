-- CORE late game (user 2026-10-26): Demons and Tigers; the Dragons come from the metal sink (SINK / metal_sink.lua), not from here.
local M = {}
M.name = "core_late"
M.intent = [=[Final comp once the unit cap is filling: Demons and Tigers, the Dragon sink on top.]=]
M.control = [=[click_army groups; Demons kite at the edge of their range.]=]
M.suggestedShare = [=[~100]=]
M.plan = { army = "raid" }
M.units = {
  { n = "cordemon", share = 0.50, note = [=[Demon: T3 gantry]=], behaviors = { "range_kite" } },
  { n = "correap",  share = 0.44, note = [=[Tiger]=] },
  { n = "corsent",  share = 0.03, max = 40, note = [=[Fury: flak escort]=] },
  { n = "coraak",   share = 0.03, note = [=[Manticore: AA escort]=] },
}
return M
