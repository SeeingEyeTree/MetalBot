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
      eco    = { share = 0.25, ramp_s = 8,  x = 560, y = 420 },   -- ECO WINDOW (user 2026-10-30): the raids cannot make progress / the fight is far away -> a short stretch of eco and tech
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
      -- ECO WINDOW: safe (nothing near the base) AND we are not behind AND the raids are not getting anywhere (bad trade, or most of the army idle).
      -- It lasts 90 s at most; any enemy near the base, or a projection that turns against us, ends it at once (the attack any_edge also fires from here).
      { from = "raid",  to = "eco", prio = 12, hold_s = 15, note = "raids make no progress and nothing is near: eco window",
        when = { all = { { sig = "minute", op = ">=", val = 5 }, { sig = "share_age_s", op = ">=", val = 60 },
                         { sig = "enemy_near_base", op = "<", val = 200 }, { ["not"] = { sig = "proj_ratio", op = "<", val = 1.0 } },
                         { any = { { sig = "bad_trade" }, { sig = "army_idle_frac", op = ">=", val = 0.5 } } } } } },
      { from = "spam",  to = "eco", prio = 9, hold_s = 15, note = "the opening lab spams but the raids make no progress: eco window",
        when = { all = { { sig = "minute", op = ">=", val = 5 }, { sig = "enemy_near_base", op = "<", val = 200 },
                         { ["not"] = { sig = "proj_ratio", op = "<", val = 1.0 } }, { sig = "bad_trade" } } } },
      { from = "eco",   to = "raid", prio = 20, hold_s = 5, note = "window over (90 s), or a threat is coming",
        when = { any = { { sig = "share_age_s", op = ">=", val = 90 }, { sig = "enemy_near_base", op = ">=", val = 300 },
                         { sig = "proj_ratio", op = "<", val = 0.9 } } } },
      { from = "attack", to = "raid", prio = 20, hold_s = 20, note = "the attack is over",
        when = { all = { { ["not"] = { sig = "under_attack" } }, { sig = "enemy_near_base", op = "<", val = 300 } } } },
    },
    any_edges = {
      { to = "attack", prio = 50, note = "a real attack, or a lot of enemy near the base / spine build power",
        when = { any = { { sig = "under_attack" }, { sig = "enemy_near_base", op = ">=", val = 600 } } } },
    },
  },
}
