-- PAINTKID_BOT: Incisors (corgator) and nothing else from the spine -- as many as the economy can pay for.
local M = {}
M.name = "paintkid_gators"
M.intent = [=[Gator spam: every spine lab makes Incisors; no T2, no slow units.]=]
M.control = [=[Every ground unit attacks the enemy base directly (click_army DIRECT).]=]
M.suggestedShare = [=[100]=]
M.units = {
  { n = "corgator", share = 1.0, note = [=[Incisor: cheap fast vehicle]=] },
}
return M
