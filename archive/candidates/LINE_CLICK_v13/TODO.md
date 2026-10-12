# LINE_CLICK_v13 -- user's notes after watching v12 (2026-10-08)

Base: `candidates/LINE_CLICK_v12`. Status per item: TODO / DONE-untested / VERIFIED.

1. **Grids stall while floating metal and energy -- DONE-untested.** Seen in the 30-min replay game (v12 = team 1):
   grids stuck at 2 from 4:00 to 7:40 with 2 idle air cons and 0 waiting; 7-8 grids from 9:30 to 15:00, 3-4 idle air
   cons the whole time. Every grid sat on one row (z = 12112, the map edge). Throttles found in line_transition:
   - new cells were only searched for while the bank held GRID_BANK metal (the army spends the bank) -> `COLLECT_ALWAYS`;
   - no cells past the line's enemy-facing edge, i.e. toward the map interior -> `GRID_ENEMY_SIDE = 1500`;
   - only 2 grids opening while the line is unbuilt, and the idle-con rule needed 550 M/s -> `GRIDS_OPENING = 3`,
     `GRID_FAST_INCOME = 250`.
2. **Spawn / base near the map edge -- partly.** The bot cannot choose its start (the map/lobby does). What it now
   does is let grids grow toward the interior (item 1). A harness option for an inset start is not done.
3. **Lean harder into exponential income -- via 1 and 4.** Target 2-4k M/s by 19:00 (v12: ~660 at 20:00). Check with
   v13 vs INACTIVE_BOT (queued) and the 30-min game.
4. **Army floor 10%, more responsive production -- DONE-untested.** `SPINE_CFG = { FLOOR = 0.10, MOVES_MAX = 12,
   NANO_BATCH = 8, NANO_INFLIGHT_MAX = 10 }` (was 0.20 / 6 / 4 / 6).
5. **Mammoths and Sheldons in the slow group -- DONE-untested.** unit_controller `SLOW_KIND` adds corsumo (front) and
   cormort (back); lab builds Sheldons again (`T2_SLOW_SHARE = 0.35`).
6. **Rez bots >= 30, scaled with reclaim; do their job -- DONE-untested.** lab: floor ramps 2 -> 30 from 5:00 to 8:00,
   + one per 300 metal of wrecks on the map, cap 80. slow_front `REZ_BRAVE`: repair any damaged unit in reach even with
   enemies near (retreat only below 20% hp or with no job), riskier wrecks (SAFE_FRAC 1.5), wider search (2000).
   Rez bots come from the spine's T1 bot lab -- watch that it keeps up (one lab, also making cons).
7. **Shuriken micro -- DONE-untested.** Responding Shurikens get individual ATTACK targets: an unstunned unit gets 2-6
   (by hp), a stunned one keeps ONE keeper, the rest go to units that are still moving. Log: `[UC/stun]`.

## Results so far

- v13 (everything) vs v12, 30 min, main PC, v13 in slot 1: **lost badly**, 137k vs 307k at 26:00 (cut by wall clock);
  v13 income 596 vs 925 at 20:00, 7.3k eco lost vs 3.8k. Rez crew in-engine: 30 rez bots, 1600+ repairs, 1100+ rezzes.
- Split to find out why (20 min):
  - v13a = v12 + grid/eco switches + LINE_GATE off: slot 0 1.14x at 16:00 (wall-clock cut), income 573 vs 429.
  - v13b = v12 + army changes (floor 10%, slow group, rez, Shurikens): slot 0 tie 1.03x but **11.0k eco lost vs 1.1k**;
    slot 1 (TreeServer) 0.69x, **10.6k eco lost vs 0.8k**. The army changes leave the eco open to raids.
  - Stun allocation works in-engine (`[UC/stun] 17 stunners on 4 targets (0 stunned, 4 still moving)`).
  - v13c = v13 with the 20% floor back, vs v12: TreeServer 1.21x (s0), 1.07x (s1); main PC **0.86x (s0), 0.81x (s1)**.
  - **v13d** = v13a + Mammoths/Sheldons in the slow group + Shuriken stuns + brave rez crew, with v12's rez count
    and spine settings, **vs v13a**: tie 0.99x (s0), **win 1.38x (s1)** -> geometric mean 1.17x.
  - Conclusion: **v13d is the current best.** What hurt: the 10% army floor (v13b: ~11k eco lost to raids) and the
    30-rez-bot floor by 8:00 / faster nano switching (v13c lost both main-PC games). The user's "30+ rez bots" needs a
    later ramp (e.g. reach 30 by ~15:00, scaled by wreck metal) -- next to try, on top of v13d.
  - v13e = v13d + rez floor 2 -> 30 from 8:00 to 15:00 (+ wreck metal): vs v13d 0.71x (s0), 1.34x (s1) -> 0.98x,
    no measurable difference (2 games).
  - 30-min game, v12 vs v13d (v13d in slot 1, main PC): **v13d killed v12's commander at 24.9 min**; income 805 vs
    585 M/s at 20:00, eco lost 1.6k vs 6.6k. Replay: demos/2026-10-08_16-16-40-669_Full Metal Plate 1.7_2026.07.04.sdfz.
  - Still far from the 2-4k M/s target: best seen 1,256 M/s at 20:00 (v13a).
  - **v14** = v13d + GRID_BALANCE (grids build the pressed resource; nano only when neither is used),
    GRID_INTR_MIN_NANOS 0, placer SINGLE_ORDER_GRACE 60 (user saw an air con ordered to a mex and redirected):
    **lost 0.29x to v13d** -- grids stalled (168 M/s from 10:00; nothing placed 9:00-10:00 with 4k banked). Cause: the
    interrupt path retried an unbuildable item forever; fixed in blueprint_placer (0be5f6d), not yet re-tested.

**Next session:** one v14 vs v13d game with the fix; if it scales, A/B it properly (both slot orders, TreeServer).
Best bot right now: **v13d**.

Also open from the 30-min game: v12 led at 20:00 (army 82.5k vs 63.6k) but LINE_CLICK led at 30:00 (292k vs 211k).
