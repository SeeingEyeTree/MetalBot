-- CORE's default state machines (CFG.MACHINE = "core_default"); edit in machine_editor.html (open this file, change, save).
-- File format: machines/README.md.  Signals: bar_framework/signals.lua.  v2 (user 2026-10-26): T1 / T2 hold and push stances, a 4k opening.
--
-- STANCE MACHINE
--   start     core_start  6 Incisors : 1 Pounder, held just out from the base, for the first 6:00
--   t1_hold   T1 defend, ring ~1100 out          t1_push   T1 raid groups (Incisor / Brute)
--   t2_hold   T2 defend, ~18% T1 filler          t2_push   T2 raid groups (Tiger), ~23% T1
--   late      Demons + Tigers (the Dragon sink is separate); permanent once the unit cap fills
--   at 6:00: enemy well scouted and little army value seen -> push, otherwise hold.  hold <-> push follows the scouted enemy's value
--   against ours and bad trades; a real attack on us pulls a push stance back to hold.  T2 stances once income >= 500.
-- SHARE MACHINE (army share, reads the stance through `stance` / `stance_army`)
--   start     big share so ~4k of army stands at 6:00 (nanos guard the lab at share >= 0.8: slot_spine RUSH_SHARE)
--   push_high relatively high share while raiding             hold_low  lower share while holding and not about to be attacked
--   catch_up  match_enemy: a good scout shows the enemy army is as big as ours, so the share follows it
--   attack    share 1.0 while a real attack is on, or many enemy units are inside our territory (near the spine's build power)
return {
  name = "rows_default", version = 2,

  stance_machine = {
    initial = "start",
    nodes = {
      start   = { stance = "core_start", x = 60,   y = 260 },
      t1_hold = { stance = "t1_hold",    x = 560,  y = 100 },
      t1_push = { stance = "t1_push",    x = 560,  y = 420 },
      t2_hold = { stance = "t2_hold",    x = 1060, y = 100 },
      t2_push = { stance = "t2_push",    x = 1060, y = 420 },
      late    = { stance = "core_late",  x = 1560, y = 260 },
    },
    edges = {
      -- 6:00: well scouted and the enemy army is small next to ours -> push; otherwise hold (also when nothing was scouted)
      { from = "start", to = "t1_push", prio = 20, note = "6:00: enemy scouted, little army value seen -> raid",
        when = { all = { { sig = "minute", op = ">=", val = 6 }, { sig = "enemy_scouted" }, { sig = "enemy_vs_army", op = "<", val = 0.6 }, { ["not"] = { sig = "under_attack" } } } } },
      { from = "start", to = "t1_hold", prio = 10, note = "6:00: otherwise hold",
        when = { sig = "minute", op = ">=", val = 6 } },
      -- T1: hold <-> push
      { from = "t1_hold", to = "t1_push", prio = 10, hold_s = 30, min_stay_s = 60, note = "enemy army small next to ours",
        when = { all = { { sig = "enemy_scouted" }, { sig = "enemy_vs_army", op = "<", val = 0.5 }, { ["not"] = { sig = "under_attack" } } } } },
      { from = "t1_push", to = "t1_hold", prio = 30, min_stay_s = 45, note = "real attack on us: come home",
        when = { sig = "under_attack" } },
      { from = "t1_push", to = "t1_hold", prio = 20, min_stay_s = 90, note = "raids trade badly",
        when = { all = { { sig = "bad_trade" }, { sig = "army_ratio", op = "<", val = 0.85 } } } },
      { from = "t1_push", to = "t1_hold", prio = 10, hold_s = 20, min_stay_s = 60, note = "the enemy army is as big as ours",
        when = { all = { { sig = "enemy_located" }, { sig = "enemy_vs_army", op = ">", val = 0.9 } } } },
      -- T1 -> T2 on income (keeps the hold / push mode)
      { from = "t1_hold", to = "t2_hold", prio = 5, hold_s = 20, min_stay_s = 60, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
      { from = "t1_push", to = "t2_push", prio = 5, hold_s = 20, min_stay_s = 60, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
      -- T2: hold <-> push
      { from = "t2_hold", to = "t2_push", prio = 10, hold_s = 30, min_stay_s = 60, note = "enemy army small next to ours",
        when = { all = { { sig = "enemy_scouted" }, { sig = "enemy_vs_army", op = "<", val = 0.5 }, { ["not"] = { sig = "under_attack" } } } } },
      { from = "t2_push", to = "t2_hold", prio = 30, min_stay_s = 45, note = "real attack on us: come home",
        when = { sig = "under_attack" } },
      { from = "t2_push", to = "t2_hold", prio = 20, min_stay_s = 90, note = "raids trade badly",
        when = { all = { { sig = "bad_trade" }, { sig = "army_ratio", op = "<", val = 0.85 } } } },
      { from = "t2_push", to = "t2_hold", prio = 10, hold_s = 20, min_stay_s = 60, note = "the enemy army is as big as ours",
        when = { all = { { sig = "enemy_located" }, { sig = "enemy_vs_army", op = ">", val = 0.9 } } } },
    },
    any_edges = {
      -- cap_switch: the unit cap is filling -> the late stance for the rest of the game (no edge leaves it)
      { to = "late", prio = 100, note = "unit cap filling",
        when = { all = { { sig = "minute", op = ">=", val = 12 }, { sig = "cap_frac", op = ">=", val = 0.75 } } } },
    },
  },

  share_machine = {
    initial = "open",
    nodes = {
      -- user 2026-10-27: no army until 4:00 (the eco and the labs' build power come first; the starter lab's few Grunts are the lab rules'), then 35% of actual spending
      open      = { share = 0.0,  ramp_s = 1, x = 60,   y = 100 },
      start     = { share = 0.35, ramp_s = 5, x = 60,   y = 260 },
      -- one lab + 8 nanos = 150 + 8 x 200 = 1750 build power; making the opening comp (6 Incisors : 1 Pounder, 0.0556 metal per build-power-second) nonstop that
      -- spends ~97 m/s.  Once metal income is 1.3x that (126 m/s) the eco can carry it: the share jumps to 75% so all 8 nanos assist the lab (slot_spine sizes its active nanos
      -- from share x income / 11 m/s per nano)
      spam      = { share = 0.75, ramp_s = 5, x = 300,  y = 260 },
      hold_low  = { share = 0.22, ramp_s = 20, x = 560, y = 100 },
      push_high = { share = 0.55, ramp_s = 10, x = 560, y = 420 },
      catch_up  = { hook = "match_enemy", cfg = { floor = 0.25, unscouted = 0.35 }, x = 1060, y = 100 },
      attack    = { share = 1.0,  ramp_s = 3, x = 1060, y = 420 },
    },
    edges = {
      { from = "open", to = "start", prio = 30, note = "4:00: the army starts spending",
        when = { sig = "minute", op = ">=", val = 4 } },
      { from = "start", to = "spam", prio = 15, hold_s = 10, note = "income >= 1.3x what a lab with 8 nanos spends nonstop (126 m/s): all 8 nanos on",
        when = { sig = "metal_income", op = ">=", val = 126 } },
      { from = "hold_low", to = "spam", prio = 12, hold_s = 10, note = "income >= 1.3x what a lab with 8 nanos spends nonstop (126 m/s): all 8 nanos on",
        when = { all = { { sig = "metal_income", op = ">=", val = 126 }, { sig = "minute", op = "<", val = 9 } } } },
      { from = "push_high", to = "spam", prio = 12, hold_s = 10, note = "income >= 1.3x what a lab with 8 nanos spends nonstop (126 m/s): all 8 nanos on",
        when = { all = { { sig = "metal_income", op = ">=", val = 126 }, { sig = "minute", op = "<", val = 9 } } } },
      { from = "spam", to = "hold_low", prio = 9, hold_s = 5, note = "9:00: only the opening spams; from here the hold share (the eco must grow again)",
        when = { sig = "minute", op = ">=", val = 9 } },
      { from = "spam", to = "hold_low", prio = 8, hold_s = 20, note = "income fell under 1.15x what 8 nanos spend (111 m/s): back to the hold share",
        when = { sig = "metal_income", op = "<", val = 111 } },
      { from = "start", to = "push_high", prio = 20, note = "the stance machine chose a push stance",
        when = { all = { { sig = "stance", op = "!=", val = "core_start" }, { sig = "stance_army", op = "==", val = "raid" } } } },
      { from = "start", to = "hold_low", prio = 10, note = "the stance machine chose a hold stance",
        when = { sig = "stance", op = "!=", val = "core_start" } },
      { from = "hold_low", to = "push_high", prio = 10, note = "raiding: keep the share relatively high",
        when = { sig = "stance_army", op = "==", val = "raid" } },
      { from = "push_high", to = "hold_low", prio = 10, note = "holding: lower the share",
        when = { sig = "stance_army", op = "!=", val = "raid" } },
      { from = "hold_low", to = "catch_up", prio = 10, hold_s = 10, note = "good scout: the enemy army is about as big as ours",
        when = { all = { { sig = "enemy_scouted" }, { sig = "enemy_vs_army", op = ">", val = 0.9 } } } },
      { from = "catch_up", to = "hold_low", prio = 10, hold_s = 30, note = "the enemy army is small again",
        when = { sig = "enemy_vs_army", op = "<", val = 0.7 } },
      { from = "catch_up", to = "push_high", prio = 20, note = "raiding: keep the share relatively high",
        when = { sig = "stance_army", op = "==", val = "raid" } },
      { from = "attack", to = "push_high", prio = 20, hold_s = 20, note = "the attack is over; raiding",
        when = { all = { { ["not"] = { sig = "under_attack" } }, { sig = "enemy_near_base", op = "<", val = 300 }, { sig = "stance_army", op = "==", val = "raid" } } } },
      { from = "attack", to = "hold_low", prio = 10, hold_s = 20, note = "the attack is over; holding",
        when = { all = { { ["not"] = { sig = "under_attack" } }, { sig = "enemy_near_base", op = "<", val = 300 } } } },
    },
    any_edges = {
      { to = "attack", prio = 50, note = "a real attack, or a lot of enemy near the base / spine build power",
        when = { any = { { sig = "under_attack" }, { sig = "enemy_near_base", op = ">=", val = 600 } } } },
    },
  },
}
