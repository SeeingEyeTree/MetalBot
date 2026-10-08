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

Also open from the 30-min game: v12 led at 20:00 (army 82.5k vs 63.6k) but LINE_CLICK led at 30:00 (292k vs 211k).
