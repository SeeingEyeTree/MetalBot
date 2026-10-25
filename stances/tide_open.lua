-- IRON_TIDE stage 1 (T1): a cheap screen that lets the economy boom.  Spam and Pounders soak damage and give vision, Sheldons
-- kite behind them, a little flak covers the line.  Nothing here goes looking for a fight (plan.army = "hold": click_army stages
-- at our line and raid response answers intruders).
local M = {}
M.name = "tide_open"
M.intent = [=[Boom: a cheap T1 screen at the line; spend as little on the army as the threat allows.]=]
M.control = [=[Hold at the line front; Sheldons kite behind the spam; raid response answers intruders.]=]
M.suggestedShare = [=[15]=]
M.plan = { army = "hold" }
M.units = {
  { n = "corak",    share = 0.25, tag = "mass",    note = [=[Grunt: spam screen]=] },
  { n = "corlevlr", share = 0.20, tag = "mass",    note = [=[Pounder: the tank]=] },
  { n = "corraid",  share = 0.20, tag = "mass",    note = [=[Raider: mobile reserve]=] },
  { n = "cormort",  share = 0.25, tag = "quality", note = [=[Sheldon: long-range support, kites]=],
    behaviors = { "kite" }, cfg = { kite = { step = 300 } } },
  { n = "corsent",  share = 0.05, note = [=[flak: base screen]=] },
  { n = "coraak",   share = 0.05, note = [=[T2 bot AA]=] },
}
return M
