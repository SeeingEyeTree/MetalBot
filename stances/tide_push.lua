-- IRON_TIDE stage 3 (T3, metal income ~1100 m/s): the push.  Shivas are the wave (hit ground and air, 9400 hp, amphibious), Demons
-- kite at the edge of their range, Tigers/Banishers stay as the screen that soaks the first volley, flak + AA bots keep the sky clear.
-- plan.army = "raid": click_army groups advance on enemy build power / eco / commander; Shivas back off (kite) from anything closing in.
local M = {}
M.name = "tide_push"
M.intent = [=[Push with a Shiva wave once the economy can replace losses faster than the enemy can inflict them.]=]
M.control = [=[click_army groups advance; Shivas kite (step back as a group), Demons and Banishers range_kite.]=]
M.suggestedShare = [=[~70]=]
M.plan = { army = "raid" }
M.units = {
  { n = "corshiva", share = 0.55, note = [=[Shiva: the wave]=],
    behaviors = { "kite" }, cfg = { kite = { step = 350, step_min = 150, trigger_ttc = 5.0 } } },
  { n = "cordemon", share = 0.15, note = [=[Demon: kites at range edge]=], behaviors = { "range_kite" } },
  { n = "correap",  share = 0.12, note = [=[Tiger: screen]=] },
  { n = "corban",   share = 0.08, note = [=[Banisher: kites at range edge]=], behaviors = { "range_kite" } },
  { n = "corsent",  share = 0.05, note = [=[flak: escort]=] },
  { n = "coraak",   share = 0.05, note = [=[T2 bot AA: escort]=] },
}
return M
