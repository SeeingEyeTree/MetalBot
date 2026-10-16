-- DRAGON_ECO's army from 1.1k m/s (user 2026-10-14): the spine's vehicle plants are reclaimed (slot_spine RECLAIM_UNNEEDED) and
-- T2 bot labs make Mammoths and a few Manticores.  Defence only (plan army = perimeter), until the Dragons.  The same labs also make
-- the decoy commanders that assist the Dragon lab (lab_controller's decoy want, outside the stance).
local M = {}
M.name = "mammoth_hold"
M.intent = [=[Heavy defensive screen that keeps us alive while the economy reaches Dragons.]=]
M.control = [=[perimeter_guard: squads at posts on the 2800-elmo ring, FIGHT to intruders inside it, back to the post after.]=]
M.suggestedShare = [=[10]=]
-- army = "perimeter": the armed ground units only defend (perimeter_guard).  extras: the Dragons come from their own lab (not the
-- spine), carry these behaviours (dragon_defend while they wait for the wave, dragon_raid once 50 stand) and are never part of the comp.
M.plan = { army = "perimeter" }
M.extras = {
  { n = "corcrwh", behaviors = { "dragon_raid", "dragon_defend" }, cfg = { dragon_raid = { wave = 50 } },
    note = [=[Dragon: helps defend while it waits for the wave; the wave hits commander, then build power, then AA, then the closest eco]=] },
}
M.units = {
  { n = "corsumo", share = 0.85, note = [=[Mammoth: the screen]=] },
  { n = "coraak",  share = 0.15, note = [=[Manticore: token AA]=] },
}
return M
