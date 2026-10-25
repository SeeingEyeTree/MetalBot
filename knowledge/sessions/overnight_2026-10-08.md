# Overnight run 2026-10-08 (LINE_CLICK)

Running log of what was tried overnight, newest at the bottom. Base bot: `candidates/LINE_CLICK`.

## Summary (read this first)

**Result: `candidates/LINE_CLICK_v12` beats LINE_CLICK 5-0-1 over 6 twenty-minute mirror games** (TreeServer, both slot
orders x3, no desyncs), END_SCORE geometric mean over the slot orders **1.36x** (1.36 from slot 0, 1.37 from slot 1),
ahead in every game. v12 = LINE_CLICK + three changes:

1. **FORWARD_CORE** (click_army): an attack group's core is its forward cluster, not the centroid that new units
   dragged home (a bug: groups "attacking" a nano had their centre 11,000 elmos away and called the front back).
2. **FLANK** (click_army): groups go round the biggest recent enemy ground-army cluster on their path. Alone vs v2:
   3-1, the two slot-1 games won 1.59x and 1.50x.
3. **ENERGY_PUSH** (line_transition): from ~16-17 min metal floated to its 30k cap while energy ran at ~100% of
   income; wind blocks become fusions while that holds. Alone vs v2: 8 games, 1.14x, ahead or level in all 7 full games.
4. plus v3b's commander rule: evade only a real dive (armed value >= 1500 near it); never retire, no cloak.

**Not adopted (no measurable difference):** full commander safety v3 (retire + cloak + evade anything), commander
helps lab jobs (v5e, 8-min army 0.94x), air-con cap 5 (v7a, 0.98x), commander evade-only-dives alone (v3b, 1.00x).

**Harness/measurement findings that matter more than any single change:**
- **Our stats tracker desynced nearly every match** at 10-14 game-min (`Spring.RequestPath`); off now. Late-game
  numbers before 2026-10-08 02:43 are suspect. Likely also the human-vs-bot two-PC desync. `result.desync` flags it.
- **Another session's `Stop-Process spring-headless` killed every match** for the first hour.
- **The main PC has a ~1.4-1.5x slot-0 edge in 20-minute mirrors** (TreeServer ~1.0-1.1x): run mirror A/Bs on
  TreeServer; always pair slot orders. ab_test now stops each match at the checkpoint (`--end-minutes`).
- **BARb (`--bot2 AI:BARb`) is a weak opponent for LINE_CLICK** (7x income by 12:00; commander kill 13-16 min in
  every clean game for LINE_CLICK, v2 and v8f alike) - a regression check, not a strength measure.

**Open:** the main-PC slot edge (a no-pin-cores diagnostic was queued but the main PC slept 04:45-09:30); nukes,
T3 mix, defence creep, LRPC were not reached (the measurable window was the bottleneck all night).

## Harness problems found first (they invalidated the first hour of results)

1. **Another session killed every match.** `metalbot-db` ran `Get-Process spring-headless | Stop-Process` between its
   replay checks; all five main-PC matches from 01:15-01:45 died at the second a replay check finished (no shutdown line
   in any infolog; ab_test then reported `n/a` or `unit_count_fallback`). Memory note added. Its CPU load also pinned
   the speed governor at the 2x floor (LINE_CLICK looked "slow"; it is not: 9-13x on a free PC).
2. **ab_test ran every match to the wall-clock backstop.** It never passed `--end-minutes`, so a match that only needs
   frame 14400 played a 60-minute game until `--duration` ran out (and with the old 300 s default it stopped short of
   frame 14400 on a loaded PC). Now: `--end-minutes` defaults to one minute past the checkpoint, `--duration` is
   derived by bot_testing, `--keep DIR` saves each match's result json.

3. **DESYNCS in nearly every match, from our stats tracker (fixed 02:43, confirmation pending).** Every main-PC and
   TreeServer match before the fix logged `Sync error for <player> in frame N` with N = 18170-25066 (10-14 game-min),
   for every bot including the BARb host process -- which runs no bot widgets, only `metalbot_stats_tracker.lua`. The
   spectator host, the one process WITHOUT the tracker, is the one that reports the others as out of sync. The tracker
   calls `Spring.RequestPath` (lab-exit check, every 30 s per ground lab) through the simulation's own path manager.
   After a desync each process plays its own diverged game, and sometimes a client is dropped (autoquit) and its
   tracker rows stop (two 20-minute games here lost team 0's data at ~15 min). So **everything measured after ~10 min
   of game time before this fix is suspect**; the 8-minute ab_test checkpoint (frame 14400) is before it and stands.
   The check is now off (`FAC_EXIT_CHECK = false`; `fac_exit_ok` reads unknown). The first match after the fix passed
   frame 28,000 with no sync error. This is very likely also the cause of the "two-machine games desync at the first
   fight" (the logger/tracker are deployed by every deploy.ps1).

## Harness additions

- **`--bot2 AI:BARb[:profile]`** (bot_testing.py): BAR's native BARb AI plays team 1 (default profile `hard`). Player 1
  joins as a spectator and hosts the AI; its stats widgets get `GetMyTeamID = 1` patched in (a spectator reads 0), so
  END_SCORE and the tracker rows work as for a bot. The AI's commander is never self-destructed at end-minutes, so only
  the END_SCORE comparison is meaningful at the deadline (an earlier commander kill is still a real `game_over`).

- `--end-minutes` matches in `ab_test.py`; `series.py` (a batch of matches, resumable) and `match_summary.py`
  (winner, commander deaths, army / income / losses to the enemy at checkpoints).

## Baseline

- LINE_CLICK vs pool/bots/champion_v1, army value at frame 14400, one match per slot: **1.25x and 1.31x, gm 1.28,
  "A is better"** (main PC). TreeServer, same A/B: **1.40x and 1.35x, gm 1.38**.
- LINE_CLICK vs BARb (hard): LINE_CLICK out-earns it ~7x by 12:00 (375 vs 49 m/s) but **does not always finish it**:
  commander kills at 10.1 and 16.1 min, none in two other 20-minute games (it won those on END_SCORE, 12x).

## E1: click_army FORWARD_CORE -> `candidates/LINE_CLICK_v2` -- real bug fixed; mirror gain NOT demonstrated (E3)

**Problem (seen vs BARb, 20:00):** 112k of army stood at mid-map (dist_base ~5500) with the enemy commander in sight
and 633 value guarding it. With 3 groups out every new unit joins the weakest group from the factory, so a group's
centroid slid toward home ("attacking" a nano with its centre 11,000 elmos away) and the core -- the units around the
centroid -- were sent back to it. `tests/test_click_forward.lua` reproduces it: old rule, 20/20 front units are
ordered away from their target.

**Change:** `CFG.FORWARD_CORE` -- the core is the forward cluster (nearest the target with 2 others within 500, and
everyone within 1500 of it); the core's value decides fights/targets; `CMDR_KEEP_FRAC 0.8` (stay on the commander while
the guard is < 0.8x the core; it flip-flopped at 0.3); `CORE_WAIT_FRAC 0.35` (a small front waits for units within
4000 behind it, not for units fresh from the factory). Off by default; LINE_CLICK_v2 turns it on.

**Results (20-minute games):**

| match | result |
|---|---|
| v2 vs BARb x3 | commander killed at 12.3, 13.1, 12.9 min (3/3) |
| LINE_CLICK vs BARb x4 | killed at 10.1, 16.1 min; no kill in 2 (2/4) |
| v2 (slot 0) vs LINE_CLICK | **v2 killed LINE_CLICK's commander at 9.7 min** (a dive found it in its lane, few guards) |
| LINE_CLICK vs v2 (slot 1) | **v2 won on END_SCORE 102k vs 85k (1.20x) from the weaker slot**; enemy eco destroyed 7.4k vs 1.4k |

v2 won both head-to-heads, including from slot 1. Two matches is not a large sample, but it agrees with the BARb
series and with the mechanism (the front no longer walks home). **Caveat (found later): all of these were played
before the desync fix, and the commander kills at 12-13 min fall inside the 10-14 min desync window.** Clean
re-run: E3 below.

## E3: clean re-run of v2 vs LINE_CLICK (after the desync fix) -- NO DIFFERENCE DEMONSTRATED

| match (20 min, main PC, no desync) | result |
|---|---|
| v2 (s0) vs LINE_CLICK | v2 1.28x |
| v2 (s0) vs LINE_CLICK | v2 1.75x |
| LINE_CLICK (s0) vs v2 | LINE_CLICK 1.57x (v2 0.64x) |
| LINE_CLICK (s0) vs v2 | LINE_CLICK 1.65x (v2 0.61x) |

Geometric mean over the slot orders **0.97x**: the earlier "v2 won both" was in desynced games. **The slot-0 edge in
20-minute mirror games is ~1.5x on END_SCORE** (same-slot spread ~1.35x), far larger than the 8-minute army
metric's. Order latency is symmetric (~22 frames both); slot 0 has the higher income at 15:00 in 12 of 13 mirror games;
the two starts are mirror images ((2400,850) rot 0 vs (9650,11400) rot 2). Cause not found. FORWARD_CORE still fixes
a real bug (the test shows it; vs BARb it is re-measured in E7), but no mirror effect is measurable at this noise.

## E2: commander safety -> `candidates/LINE_CLICK_v3` -- NO DIFFERENCE, not adopted

v2 + commander_guard in the macro: evade any armed enemy near it (crew suspended, `LC.Suspend/Resume`), cloak
when energy covers the MOVING cost (1000 E/s for corcom; cloaking on the standing 100 E/s emptied the opening's
energy in 24 s), retire to a safe spot behind the base (jammer + 2 AA) at 10:00 or when its lane is done.

| match (20 min, no desync) | result |
|---|---|
| v3 (s0) vs LINE_CLICK | tie 1.05x (this one desynced) |
| v3 (s0) vs LINE_CLICK | win 1.58x |
| LINE_CLICK (s0) vs v3 | loss 0.84x; v3 income 378 vs 673 at 20:00, 4.6k eco lost by 10:00 (vs 0.7k) |
| v3 (s0) vs v2 | win 1.19x |
| v2 (s0) vs v3 | loss 0.90x |

Slot 0 won every game: geometric mean over the slot orders 1.04 (vs LINE_CLICK) and 1.03 (vs v2) -- nothing
measurable. Mechanism: the commander retired at ~5:45 (its lane done) and ran from single raiders; it is one of the
best defenders of the early base (3700 hp, a real weapon), so the eco lost a defender. **Lesson: in 20-minute games
the slot-0 advantage is ~1.2-1.3x on END_SCORE -- always pair the slot orders.** Follow-up `LINE_CLICK_v3b`: no
retirement, no cloak, evade only a real dive (armed value >= 1500 near it).

## Which machine for mirror A/Bs: TreeServer

Per-slot ratios of every 20-minute A/B give the slot-0 edge on each machine: **main PC 1.24-1.55x, TreeServer
0.94-1.10x** (and small on both at 8 minutes). The main PC (Ryzen AI 7 350, hybrid Zen5/Zen5c cores; the harness
pins each engine's main thread to one core) favours slot 0 for a reason not found yet (no wall-clock budgets in bot
code; order latency equal). Mirror head-to-heads were moved to TreeServer; the main PC runs single-bot BARb series.

## E4: ENERGY PUSH -> `candidates/LINE_CLICK_v4e` -- promising, more games running

| match (20 min, TreeServer) | result |
|---|---|
| v4e (s0) vs v2 | loss: v4e's commander killed at 18.8 min |
| v4e (s0) vs v2 | tie 1.05x |
| v2 (s0) vs v4e | **v4e 1.31x from slot 1** |
| v2 (s0) vs v4e | v4e 1.09x from slot 1 (tie) |

Geometric mean over slot orders 1.12x (bar ~1.16 for 4 games). The push fired at 17:13-17:45 (metal 6-7k of 16-20k,
energy pull 90-100% of income): metal only starts floating at ~16:00, so most of the effect falls after the
20-minute window. 4 more games queued (e7t).

## E5: commander helps the outer-lane cons' lab jobs -> `candidates/LINE_CLICK_v5e` -- NO GAIN, dropped

Mechanism works (the commander assisted the vehicle lab at 3:24, its nanos at 3:33 and 4:15...), but the 8-minute army
A/B vs v2 gave 0.98, 1.01, 0.92. The order of the two labs varies from game to game (v2 had its air lab first, at
3:16, in the same match), so the 3:30-5:00 idle lanes are not a fixed cost.

## E2b: commander evades only real dives -> `candidates/LINE_CLICK_v3b` -- running (main PC, so slot-biased)

v3b (s0) vs v2: 1.27x; v2 (s0) vs v3b: v3b 0.67x. Slot edge dominates; 2 more games.

## E8: FLANK -> `candidates/LINE_CLICK_v8f` -- queued (TreeServer mirror x4, main PC vs BARb x3)

Groups go round the biggest recently seen enemy ground-army cluster on their path (waypoint 2800 to the side, side
kept per group). Stub: first legs 662 elmos off the line vs 18 without (`tests/test_click_forward.lua`).
### E8 result (TreeServer, 20 min, no desyncs): v8f vs v2 -- 3 wins, 1 loss

| match | result |
|---|---|
| v8f (s0) vs v2 | loss: v8f's commander killed at 12.2 min |
| v8f (s0) vs v2 | win: v8f killed v2's commander at 13.8 min |
| v2 (s0) vs v8f | **v8f 1.59x from slot 1** |
| v2 (s0) vs v8f | **v8f 1.50x from slot 1** |

The flank logs fire as intended (`[CK] group #2 flanks the enemy army (av=6627 vs core 5407): via (4414,8634)`).

### E4 result (TreeServer, 8 games): v4e vs v2 -- 3 wins, 1 loss (commander killed), 4 ties; 1.14x

Slot 0: 1.05, 1.04, 1.03 (+ the loss); slot 1: 1.31, 1.09, 1.49, 1.11. Ahead or level in every full-length game.

### BARb, clean (main PC, 22-min cap): commander killed in every game

LINE_CLICK 13.1 / 15.2 / 14.6 min; v2 13.7 / 13.3; v8f 15.7 / 16.4. No difference in finishing vs BARb (the earlier
"v2 finishes BARb 3/3, LINE_CLICK 2/4" was in desynced games).

## E9: the combination -> `candidates/LINE_CLICK_v12` -- BEATS LINE_CLICK

v12 = v2 (FORWARD_CORE) + FLANK + ENERGY_PUSH + v3b's commander rule (evade only real dives). TreeServer, 20 min:

| match | result |
|---|---|
| v12 (s0) vs LINE_CLICK | win 1.98x |
| v12 (s0) vs LINE_CLICK | tie 1.02x |
| v12 (s0) vs LINE_CLICK | win 1.25x |
| LINE_CLICK (s0) vs v12 | **win 1.54x from slot 1** |
| LINE_CLICK (s0) vs v12 | **win 1.30x from slot 1** |
| LINE_CLICK (s0) vs v12 | **win 1.28x from slot 1** |

**5-0-1, ahead in all 6, geometric mean 1.36x over the slot orders (1.36 / 1.37).** This is the one result tonight
that clears the noise by a wide margin. Recommended next main bot. Not yet measured: v12 vs BARb (queued on the main
PC after the diagnostic), and v12 against a human.

## Ideas from experiment_ideas.md: what happened to each

- **7 Bombing runs** -- not built. The late game is energy-bound; a corhurc costs 18,500 E (the energy of ~17 gators)
  and the mirror opponent has a large air guard. Also found: endgame.lua's `EG.Strike` holds every bomber at home
  (HOME_GUARD priority) whenever the bot is not hunting, so click_army's bomber runs could never fire -- fix that
  first if bombers are tried (unit_controller: call `EG.Strike` only while hunting).
  RAIDER_BOT's targeting: waves of >= 3 corshad on the densest cluster of VISIBLE enemy value (re-aimed after each drop);
  weak points: not eco-specific, needs a spotter to see anything, no AA estimate, small waves.
- **4 Energy grid** -- done as ENERGY_PUSH (wind blocks -> fusions in finished grids) rather than a separate grid:
  the measured problem is metal floating from ~16:00 with energy at ~100% of income. Trigger used: metal bank >= 30%
  of storage and >= 3000, energy bank < 50% and pull >= 85% of income, from 10:00; at most 2 jobs at once.
- **1 Nukes** -- not built. TILE_BOT's grid-4 silo capstone exists but firing was never wired; a silo needs nanos in
  reach (a T2 con cannot place T1 nanos) and a site bigger than a wind block. endgame.lua's FireNukes + enemy_intel's
  AntiNukeCovers are the pieces to reuse for targeting.
- **2 Skuttles/spies, 3 LRPC, 5 T3 mix, 6 defence creep** -- not reached.
## Daytime follow-up (2026-10-08, after the user watched v12)

**30-min check of v12:** LINE_CLICK (s0) vs v12, TreeServer: v12 led at 20:00 (army 82.5k vs 63.6k) but LINE_CLICK led at
30:00 (~343k vs 264k END_SCORE, computed from the 30:00 rows). Replay demos/2026-10-08_13-52-31-583_*.sdfz.

**User's notes (full list and status: `candidates/LINE_CLICK_v13/TODO.md`)** -> v13 = v12 + all of them. Then split:

| variant | what | result (20 min) |
|---|---|---|
| v13 | everything | lost 0.44x vs v12 at 26:00 (s1, main PC); eco raided |
| **v13a** | grid expansion: COLLECT_ALWAYS, GRID_ENEMY_SIDE 1500 (grids toward the map interior), GRIDS_OPENING 3, GRID_FAST_INCOME 250, LINE_GATE off | **3-0 vs v12, 1.19x** (1.14 s0, 1.21 + 1.30 s1); up to 1,256 M/s at 20:00 |
| v13b | army only: floor 10%, faster nanos, Mammoths/Sheldons slow group, 30 rez by 8:00 + brave rez, Shuriken stuns | 0-2-1 vs v12; **~11k eco lost to raids** in 2 games |
| v13c | v13 with the 20% floor | 1-2-1 vs v12 (1.21, 1.07, 0.86, 0.81) |
| **v13d** | v13a + slow group Mammoths/Sheldons + Shuriken stuns + brave rez (v12 rez count & spine) | vs v13a: 0.99 (s0), **1.38 (s1)**; 30-min vs v12: **killed v12's commander at 24.9 min** |
| v13e | v13d + 30 rez bots ramped 8:00-15:00, + wreck metal | vs v13d 0.71 / 1.34 -> 0.98, no difference |
| v14 | v13d + grids choose by resource pressure (GRID_BALANCE, mex without nanos in reach) + placer order grace 60 frames | **0.29x vs v13d (s1)**: grids stalled, income stuck at 168 M/s from 10:00, nothing placed 9:00-10:00 with 4k banked |

**Current best: `candidates/LINE_CLICK_v13d`.** Lessons: the grid throttles were real (cells only searched while the
bank had 500; no cells toward the interior; the line gate) and fixing them is the biggest gain of the day. The 10%
army floor and an early 30-rez floor leave the eco open to raids. The stun allocator works in-engine
(`[UC/stun] 17 stunners on 4 targets`). The rez crew in v13 did 1,600+ repairs / 1,100+ rezzes by 25:00.

**v14's stall, cause found but fix unmeasured:** the placer's interrupt path took the first unbuilt item of a class
without checking it was buildable; the normal order skips a blocked spot after 3 looks, the interrupt path did not.
Harmless while the metal interrupt hardly fired (bank < 150 AND 2 nanos in reach); with the balance interrupts always on
an air con sat on one impossible item. Fixed in blueprint_placer (commit 0be5f6d), stub-tested only; the next step is
one v14 vs v13d game. The user's original observation (grids build nanos first while metal is short; an air con ordered
to a mex then redirected) is still the open problem -- the order grace and GRID_BALANCE are the candidate fixes.

**Still open:** income is ~800-1,250 M/s at 20:00 vs the user's 2-4k target; the bot cannot pick its spawn (grids
toward the interior is the workaround); the main-PC slot-edge diagnostic was inconclusive (no-pin runs hit the wall
clock).

**Repo note:** during the session HEAD moved from `main` to `bot-testing-v2` without a checkout entry (another session?).
Everything after v12 is committed on `bot-testing-v2`; `main` stops at v12 (000b3b1). The user decides how to merge.