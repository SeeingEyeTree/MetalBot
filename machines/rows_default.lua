-- CORE's default state machines (CFG.MACHINE = "core_default"); edit in machine_editor.html (open this file, change, save).
-- File format: machines/README.md.  Signals: bar_framework/signals.lua.
-- v3 (user 2026-10-29, the BM_akumar6 game): a LINEAR stance machine.  Raid is the default at every tier; hold is the last resort.
--
-- STANCE MACHINE
--   T1  start (raid_start, Incisors) -> start_brutes (raid_brutes, income >= 250)        t1_hold  last resort
--   T2  t2_raid (T2 raid groups)                                                            t2_hold  last resort
--   T3  late (t3_late), permanent: the unit cap fills (12:00+) or income >= 2500 (20:00+)
--   raid -> hold only when REALLY behind with no way to threaten the enemy: (the raids trade badly AND both the projected and the current
--   ground ratio are low) or the enemy has 3x our army and the projection is no better.  Being attacked does NOT pull a raid stance home
--   (raid_response answers raids; RAID_CARRY keeps raids out).  hold -> raid once that is over (ratios back up), or after 150 s in hold unless
--   still far behind.  Tier steps: T1 -> T2 at 8:00+ and income >= 500 (raid -> t2_raid, hold -> t2_hold).  t1_push is gone.
--   An unknown signal (nothing scouted yet) compares false, so an unscouted enemy never sends the bot to hold.
-- SHARE MACHINE (army share, reads the stance through `stance` / `stance_army`; capped at ARMY_SHARE_MAX in macro_runtime)
--   start     big share so ~4k of army stands at 6:00 (nanos guard the lab at share >= 0.8: slot_spine RUSH_SHARE)
--   push_high relatively high share while raiding             hold_low  lower share while holding and not about to be attacked
--   catch_up  match_enemy: a good scout shows the enemy army is as big as ours, so the share follows it
--   attack    share 1.0 while a real attack is on, or many enemy units are inside our territory (near the spine's build power)
return {
  name = "rows_default", version = 3,

  stance_machine = {
    initial = "start",
    nodes = {
      start        = { stance = "raid_start",  x = 60,   y = 260 },   -- T1 raid: 2 raid groups of Incisors
      start_brutes = { stance = "raid_brutes", x = 310,  y = 260 },   -- T1 raid: 3 groups of Brutes, from 250 m/s of metal income
      t1_hold      = { stance = "t1_hold",     x = 310,  y = 60 },    -- T1 last resort: ring + quiet blobs go out as raid groups (plan.raid_sections)
      t2_raid      = { stance = "t2_raid",     x = 810,  y = 260 },   -- T2 raid groups (Tigers + Brutes)
      t2_hold      = { stance = "t2_hold",     x = 810,  y = 60 },    -- T2 last resort
      late         = { stance = "t3_late",     x = 1310, y = 260 },   -- T3 / late: Demons + Juggernauts, permanent
    },
    edges = {
      -- T1 raid chain
      { from = "start", to = "start_brutes", prio = 10, hold_s = 5, note = "income >= 250 m/s: Brutes instead of Incisors, three raid groups",
        when = { sig = "metal_income", op = ">=", val = 250 } },
      -- T1 raid -> hold: last resort
      { from = "start", to = "t1_hold", prio = 20, hold_s = 30, min_stay_s = 90, note = "really behind: the raids trade badly and we are well behind, now and projected",
        when = { all = { { sig = "bad_trade" }, { sig = "proj_ratio", op = "<", val = 0.6 }, { sig = "army_ratio", op = "<", val = 0.6 } } } },
      { from = "start", to = "t1_hold", prio = 19, hold_s = 30, min_stay_s = 90, note = "overwhelmed: the enemy army is 3x ours and the projection is no better",
        when = { all = { { sig = "enemy_located" }, { sig = "enemy_vs_army", op = ">=", val = 3.0 }, { sig = "proj_ratio", op = "<", val = 0.5 } } } },
      { from = "start_brutes", to = "t1_hold", prio = 20, hold_s = 30, min_stay_s = 90, note = "really behind: the raids trade badly and we are well behind, now and projected",
        when = { all = { { sig = "bad_trade" }, { sig = "proj_ratio", op = "<", val = 0.6 }, { sig = "army_ratio", op = "<", val = 0.6 } } } },
      { from = "start_brutes", to = "t1_hold", prio = 19, hold_s = 30, min_stay_s = 90, note = "overwhelmed: the enemy army is 3x ours and the projection is no better",
        when = { all = { { sig = "enemy_located" }, { sig = "enemy_vs_army", op = ">=", val = 3.0 }, { sig = "proj_ratio", op = "<", val = 0.5 } } } },
      -- T1 hold -> raid: back out as soon as it is not hopeless
      { from = "t1_hold", to = "start_brutes", prio = 20, hold_s = 20, min_stay_s = 60, note = "no longer far behind: raid again",
        when = { any = { { sig = "proj_ratio", op = ">=", val = 0.8 }, { sig = "army_ratio", op = ">=", val = 0.8 } } } },
      { from = "t1_hold", to = "start_brutes", prio = 15, note = "150 s in hold and not hopelessly behind: try raiding again",
        when = { all = { { sig = "stance_age_s", op = ">=", val = 150 }, { ["not"] = { sig = "proj_ratio", op = "<", val = 0.4 } } } } },
      -- T1 -> T2
      { from = "start", to = "t2_raid", prio = 5, hold_s = 20, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
      { from = "start_brutes", to = "t2_raid", prio = 5, hold_s = 20, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
      { from = "t1_hold", to = "t2_hold", prio = 5, hold_s = 20, note = "T2 income",
        when = { all = { { sig = "minute", op = ">=", val = 8 }, { sig = "metal_income", op = ">=", val = 500 } } } },
      -- T2 raid <-> hold (same rules as T1)
      { from = "t2_raid", to = "t2_hold", prio = 20, hold_s = 30, min_stay_s = 90, note = "really behind: the raids trade badly and we are well behind, now and projected",
        when = { all = { { sig = "bad_trade" }, { sig = "proj_ratio", op = "<", val = 0.6 }, { sig = "army_ratio", op = "<", val = 0.6 } } } },
      { from = "t2_raid", to = "t2_hold", prio = 19, hold_s = 30, min_stay_s = 90, note = "overwhelmed: the enemy army is 3x ours and the projection is no better",
        when = { all = { { sig = "enemy_located" }, { sig = "enemy_vs_army", op = ">=", val = 3.0 }, { sig = "proj_ratio", op = "<", val = 0.5 } } } },
      { from = "t2_hold", to = "t2_raid", prio = 20, hold_s = 20, min_stay_s = 60, note = "no longer far behind: raid again",
        when = { any = { { sig = "proj_ratio", op = ">=", val = 0.8 }, { sig = "army_ratio", op = ">=", val = 0.8 } } } },
      { from = "t2_hold", to = "t2_raid", prio = 15, note = "150 s in hold and not hopelessly behind: try raiding again",
        when = { all = { { sig = "stance_age_s", op = ">=", val = 150 }, { ["not"] = { sig = "proj_ratio", op = "<", val = 0.4 } } } } },
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
      { from = "start", to = "push_high", prio = 20, note = "the stance machine chose a push stance",
        when = { all = { { sig = "stance", op = "!=", val = "raid_start" }, { sig = "stance", op = "!=", val = "raid_brutes" }, { sig = "stance_army", op = "==", val = "raid" } } } },
      { from = "start", to = "hold_low", prio = 10, note = "the stance machine chose a hold stance",
        when = { all = { { sig = "stance", op = "!=", val = "raid_start" }, { sig = "stance", op = "!=", val = "raid_brutes" } } } },
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
