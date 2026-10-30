-- CORE_v4's state machines (CFG.MACHINE = "v4_raid", user 2026-10-30): raid only, to get the bot off the ground; edit in machine_editor.html.
-- File format: machines/README.md.  Signals: bar_framework/signals.lua.
--
-- STANCE MACHINE (linear, no hold stances): it always raids.  Raids on our base are still answered by the background systems
-- (raid_response, home defence, the Shuriken floor, AA) -- no stance change needed.
--   t1 (T1_raid, Incisors) -> t1_5 (T1_5_raid, Brutes + Pounders) at 250 m/s -> t2 (t2_raid, Tigers + Brutes) at 8:00 and 500 m/s
--   -> late (t3_late, Demons + Juggernauts), permanent, once the unit cap fills (12:00+) or at 2500 m/s (20:00+).
-- SHARE MACHINE (army share; capped at ARMY_SHARE_MAX in macro_runtime)
--   open 0 until 4:00, start 0.6, spam 0.75 while the opening lab and its nanos can spend it (126 m/s, until 9:00), then raid 0.55;
--   attack 1.0 while a real attack is on / many enemies are near the base.
return {
  name = "v4_raid", version = 1,

  stance_machine = {
    initial = "t1",
    nodes = {
      t1   = { stance = "T1_raid",   x = 60,   y = 260 },   -- T1 raid: Incisors
      t1_5 = { stance = "T1_5_raid", x = 360,  y = 260 },   -- T1.5 raid: Brutes + Pounders
      t2   = { stance = "t2_raid",   x = 660,  y = 260 },   -- T2 raid: Tigers + Brutes
      late = { stance = "t3_late",   x = 960,  y = 260 },   -- T3 / late: Demons + Juggernauts, permanent
    },
    edges = {
      { from = "t1", to = "t1_5", prio = 10, hold_s = 5, note = "income >= 250 m/s: Brutes and Pounders",
        when = { sig = "metal_income", op = ">=", val = 250 } },
      { from = "t1", to = "t2", prio = 20, hold_s = 20, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
      { from = "t1_5", to = "t2", prio = 20, hold_s = 20, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
    },
    any_edges = {
      { to = "late", prio = 100, note = "unit cap filling",
        when = { all = { { sig = "minute", op = ">=", val = 12 }, { sig = "cap_frac", op = ">=", val = 0.75 } } } },
      { to = "late", prio = 90, hold_s = 30, note = "T3 income",
        when = { all = { { sig = "minute", op = ">=", val = 20 }, { sig = "metal_income", op = ">=", val = 2500 } } } },
    },
  },

  share_machine = {
    initial = "open",
    nodes = {
      open   = { share = 0.0,  ramp_s = 1,  x = 60,  y = 100 },   -- no army until 4:00: the eco and the labs' build power come first
      start  = { share = 0.6,  ramp_s = 5,  x = 60,  y = 260 },
      spam   = { share = 0.75, ramp_s = 5,  x = 300, y = 260 },   -- the opening lab + 8 nanos spend ~97 m/s nonstop: 126 m/s of income carries it
      raid   = { share = 0.55, ramp_s = 10, x = 560, y = 260 },   -- the steady raiding share
      attack = { share = 1.0,  ramp_s = 3,  x = 820, y = 100 },
    },
    edges = {
      { from = "open", to = "start", prio = 30, note = "4:00: the army starts spending",
        when = { sig = "minute", op = ">=", val = 4 } },
      { from = "start", to = "spam", prio = 15, hold_s = 10, note = "income >= 1.3x what a lab with 8 nanos spends nonstop (126 m/s)",
        when = { all = { { sig = "metal_income", op = ">=", val = 126 }, { sig = "minute", op = "<", val = 9 } } } },
      { from = "start", to = "raid", prio = 10, note = "9:00 without the spam: the raid share",
        when = { sig = "minute", op = ">=", val = 9 } },
      { from = "spam", to = "raid", prio = 10, hold_s = 5, note = "9:00: only the opening spams; from here the raid share (the eco must grow)",
        when = { sig = "minute", op = ">=", val = 9 } },
      { from = "spam", to = "raid", prio = 8, hold_s = 20, note = "income fell under 1.15x what 8 nanos spend (111 m/s)",
        when = { sig = "metal_income", op = "<", val = 111 } },
      { from = "attack", to = "raid", prio = 20, hold_s = 20, note = "the attack is over",
        when = { all = { { ["not"] = { sig = "under_attack" } }, { sig = "enemy_near_base", op = "<", val = 300 } } } },
    },
    any_edges = {
      { to = "attack", prio = 50, note = "a real attack, or a lot of enemy near the base / spine build power",
        when = { any = { { sig = "under_attack" }, { sig = "enemy_near_base", op = ">=", val = 600 } } } },
    },
  },
}
