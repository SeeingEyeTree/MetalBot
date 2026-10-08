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

## E1: click_army FORWARD_CORE -> `candidates/LINE_CLICK_v2` -- ADOPT

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
series and with the mechanism (the front no longer walks home).
