# Overnight run 2026-10-08 (LINE_CLICK)

Running log of what was tried overnight, newest at the bottom. Base bot: `candidates/LINE_CLICK`.

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