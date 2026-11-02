-- v4_rows_raid (user 2026-11-01): rows_eco_legacy with RAID stances only -- "only raid for right now".  The hold stances (t1_hold / t2_hold) are gone:
-- they handed the army to the maneuver blobs, which stops click_army's raid groups and with them the army groups' support (the arty element's
-- Quakers, the AA).  Raid stays the stance at every tier; being behind is answered by raid_response / cover_defence at home, not by a stance switch.
-- The share machine is rows_eco_legacy's (its hold_low / push_high are army-share values, not stances; with raid stances only it settles on push_high), plus
-- ECO BURSTS (user 2026-11-01): push_high -> eco_burst (share 0.25) for 90 s while nothing of the enemy has been on our side for 45 s (signal home_quiet_s).
-- File format: machines/README.md.  Signals: bar_framework/signals.lua.  Edit in machine_editor.html (python fsm_index.py first).
--
-- STANCE MACHINE
--   T1  start (raid_start, Incisors) -> start_brutes (raid_brutes, income >= 250)
--   T2  t2_raid (Tigers + Brutes) at 8:00+ and income >= 500
--   T3  late (t3_late), permanent: the unit cap fills (12:00+) or income >= 2500 (20:00+)
return {
  name = "v4_rows_raid", version = 1,

  stance_machine = {
    initial = "start",
    nodes = {
      start        = { stance = "legacy/raid_start",  x = 60,   y = 260 },   -- T1 raid: 2 raid groups of Incisors
      start_brutes = { stance = "legacy/raid_brutes", x = 310,  y = 260 },   -- T1 raid: 3 groups of Brutes, from 250 m/s of metal income
      t2_raid      = { stance = "legacy/t2_raid",     x = 810,  y = 260 },   -- T2 raid groups (Tigers + Brutes)
      late         = { stance = "legacy/t3_late",     x = 1310, y = 260 },   -- T3 / late: Demons + Juggernauts, permanent
    },
    edges = {
      { from = "start", to = "start_brutes", prio = 10, hold_s = 5, note = "income >= 250 m/s: Brutes instead of Incisors, three raid groups",
        when = { sig = "metal_income", op = ">=", val = 250 } },
      { from = "start", to = "t2_raid", prio = 5, hold_s = 20, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
      { from = "start_brutes", to = "t2_raid", prio = 5, hold_s = 20, note = "T2 income",
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
      -- user 2026-10-27: no army until 4:40 (the eco and the labs' build power come first; the starter lab's few Grunts are the lab rules'), then 35% of actual spending
      open      = { share = 0.0,  ramp_s = 1, x = 60,   y = 100 },
      start     = { share = 0.6,  ramp_s = 5, x = 60,   y = 260 },   -- 0.6 (was 0.35, user 2026-10-27): the army-only nanos can absorb ~99 m/s on two plants, the queue must not throttle them
      -- one lab + 8 nanos = 150 + 8 x 200 = 1750 build power; making the opening comp (6 Incisors : 1 Pounder, 0.0556 metal per build-power-second) nonstop that
      -- spends ~97 m/s.  Once metal income is 1.3x that (126 m/s) the eco can carry it: the share jumps to 75% so all 8 nanos assist the lab (slot_spine sizes its active nanos
      -- from share x income / 11 m/s per nano)
      spam      = { share = 0.75, ramp_s = 5, x = 300,  y = 260 },
      hold_low  = { share = 0.22, ramp_s = 20, x = 560, y = 100 },
      push_high = { share = 0.55, ramp_s = 10, x = 560, y = 420 },
      catch_up  = { hook = "match_enemy", cfg = { floor = 0.25, unscouted = 0.35 }, x = 1060, y = 100 },
      attack    = { share = 1.0,  ramp_s = 3, x = 1060, y = 420 },
      -- user 2026-11-01: the fighting is all on the far side (nothing of the enemy on our side for 45 s): a burst of eco, then back to the raid share
      eco_burst = { share = 0.25, ramp_s = 10, x = 810, y = 560 },
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
      -- (raid_start and raid_brutes are the opening raids: they keep the high start share)
      { from = "start", to = "push_high", prio = 20, note = "the stance machine chose a later raid stance",
        when = { all = { { sig = "stance", op = "!=", val = "legacy/raid_start" }, { sig = "stance", op = "!=", val = "legacy/raid_brutes" }, { sig = "stance_army", op = "==", val = "raid" } } } },
      { from = "start", to = "hold_low", prio = 10, note = "the stance machine chose a non-raid stance",
        when = { all = { { sig = "stance", op = "!=", val = "legacy/raid_start" }, { sig = "stance", op = "!=", val = "legacy/raid_brutes" } } } },
      { from = "hold_low", to = "push_high", prio = 10, note = "raiding: keep the share relatively high",
        when = { sig = "stance_army", op = "==", val = "raid" } },
      { from = "push_high", to = "hold_low", prio = 10, note = "not raiding: lower the share",
        when = { sig = "stance_army", op = "!=", val = "raid" } },
      { from = "hold_low", to = "catch_up", prio = 10, hold_s = 10, note = "good scout: the enemy army is about as big as ours",
        when = { all = { { sig = "enemy_scouted" }, { sig = "enemy_vs_army", op = ">", val = 0.9 } } } },
      { from = "catch_up", to = "hold_low", prio = 10, hold_s = 30, note = "the enemy army is small again",
        when = { sig = "enemy_vs_army", op = "<", val = 0.7 } },
      { from = "catch_up", to = "push_high", prio = 20, note = "raiding: keep the share relatively high",
        when = { sig = "stance_army", op = "==", val = "raid" } },
      -- ECO BURSTS (user 2026-11-01, vs DEFENCE_BOT: it never threatens our side, so there is room to eco): raiding, 10:00+, nothing of the enemy on our
      -- side for 45 s and the raids not trading badly -> 0.25 for 90 s; back early when an enemy shows up on our side; at least 90 s at push_high between bursts
      { from = "push_high", to = "eco_burst", prio = 15, hold_s = 5, note = "the fighting is all on the far side: a burst of eco",
        when = { all = { { sig = "minute", op = ">=", val = 10 }, { sig = "stance_army", op = "==", val = "raid" }, { sig = "home_quiet_s", op = ">=", val = 45 },
                         { sig = "share_age_s", op = ">=", val = 90 }, { ["not"] = { sig = "bad_trade" } } } } },
      { from = "eco_burst", to = "push_high", prio = 20, note = "an enemy on our side: back to the raid share",
        when = { sig = "home_quiet_s", op = "<", val = 5 } },
      { from = "eco_burst", to = "push_high", prio = 10, note = "the burst is over",
        when = { sig = "share_age_s", op = ">=", val = 90 } },
      { from = "attack", to = "push_high", prio = 20, hold_s = 20, note = "the attack is over; raiding",
        when = { all = { { ["not"] = { sig = "under_attack" } }, { sig = "enemy_near_base", op = "<", val = 300 }, { sig = "stance_army", op = "==", val = "raid" } } } },
      { from = "attack", to = "hold_low", prio = 10, hold_s = 20, note = "the attack is over; not raiding",
        when = { all = { { ["not"] = { sig = "under_attack" } }, { sig = "enemy_near_base", op = "<", val = 300 } } } },
    },
    any_edges = {
      { to = "attack", prio = 50, note = "a real attack, or a lot of enemy near the base / spine build power",
        when = { any = { { sig = "under_attack" }, { sig = "enemy_near_base", op = ">=", val = 600 } } } },
    },
  },
}
