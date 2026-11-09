-- TEST stance (user 2026-11-04): the T2 raid node with 100% Skuttles (corsktl, 27000 E / 755 metal = 35.8 E per metal, about 2-3x a normal unit), to see
-- whether the nano-column plan (nano_cols/plan.lua) adapts its energy target to the spine's comp.  Used by machines/v4_skuttle_test.lua only.
local M = {}
M.name = "t2_skuttle"
M.intent = [=[TEST: Skuttles only (a spine unit with a very high energy cost).]=]
M.control = [=[click_army groups.]=]
M.suggestedShare = [=[55]=]
M.plan = { army = "raid", support = "unless_raided" }
M.units = {
  { n = "corsktl", share = 1.0, ratio = 1.0, perK = 0.877, cost = 1140.7, note = [=[Skuttle]=] },
}
return M
