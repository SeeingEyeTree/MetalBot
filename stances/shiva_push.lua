-- Shiva push (user, 2026-10-16): the third stance of the standard family.  Nothing but Shivas (corshiva, T3 gantry, amphibious siege
-- mech, 9400 hp, speed 48, hits ground and air) -- the labs build only them, so the economy comes first and the gantry later.
-- plan.army = "raid": click_army's groups advance across the map at the enemy's build power / eco / commander.  Every Shiva carries
-- the `kite` behaviour: when enemies close on the group it steps back (the group's whole step, held until it is done), then goes on.
local M = {}
M.name = "shiva_push"
M.intent = [=[Mass Shivas from the gantry and advance them across the map, backing off from anything that closes on them.]=]
M.control = [=[click_army groups advance on the enemy; kite steps the group back from approaching enemies (bar_framework/behaviors/kite.lua).]=]
M.suggestedShare = [=[~100]=]
M.plan = { army = "raid" }
M.units = {
  { n = "corshiva", share = 1.0, note = [=[Shiva: gantry, advances and kites]=],
    behaviors = { "kite" }, cfg = { kite = { step = 350, step_min = 150, trigger_ttc = 5.0 } } },
}
return M
