-- IRON_TIDE stage 2 (T2, metal income ~600 m/s): Tigers and Mammoths hold the line, Banishers and Sheldons kite out the damage.
-- No raids yet: the army is being built to be big enough for stage 3 to push without trading badly.
local M = {}
M.name = "tide_hold"
M.intent = [=[Cost-effective T2 defence while the economy keeps growing toward the gantry.]=]
M.control = [=[Hold at the line front; Banishers range_kite, Sheldons kite; the rest hold in front.]=]
M.suggestedShare = [=[30]=]
M.plan = { army = "hold" }
M.units = {
  { n = "correap", share = 0.35, note = [=[Tiger: the front]=] },
  { n = "corsumo", share = 0.15, note = [=[Mammoth: T2 bot lab, heavy anchor]=] },
  { n = "corban",  share = 0.25, note = [=[Banisher: kites at range edge]=], behaviors = { "range_kite" } },
  { n = "cormort", share = 0.15, note = [=[Sheldon: long range, kites]=],
    behaviors = { "kite" }, cfg = { kite = { step = 300 } } },
  { n = "corsent", share = 0.05, note = [=[flak: base screen + escort]=] },
  { n = "coraak",  share = 0.05, note = [=[T2 bot AA]=] },
}
return M
