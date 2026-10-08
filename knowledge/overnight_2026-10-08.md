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

## Harness additions

- **`--bot2 AI:BARb[:profile]`** (bot_testing.py): BAR's native BARb AI plays team 1 (default profile `hard`). Player 1
  joins as a spectator and hosts the AI; its stats widgets get `GetMyTeamID = 1` patched in (a spectator reads 0), so
  END_SCORE and the tracker rows work as for a bot. The AI's commander is never self-destructed at end-minutes, so only
  the END_SCORE comparison is meaningful at the deadline (an earlier commander kill is still a real `game_over`).

## Baseline

- LINE_CLICK vs pool/bots/champion_v1, army value at frame 14400, one match per slot: **1.25x and 1.31x, gm 1.28,
  "A is better"** (main PC). TreeServer, same A/B: 1.40x in the first match.
