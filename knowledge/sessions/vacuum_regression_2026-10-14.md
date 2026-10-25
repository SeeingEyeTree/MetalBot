# Vacuum eco regression after the 2026-10-14 framework refactor

Vacuum test = `bot_testing.py --bot1 <bot+runs_stance/vac_snippet.lua> --bot2 INACTIVE_BOT --server single --end-minutes 20`.
Metric: `metal_inc_avg` at 20:00 (script: read `eco` rows, team 0). Historical STANCE_BOT (4fa8a2d, before the refactor): ab1 "full" 3.2-4.5k (mean 3.96k), "nofullcrew" 3.9-6.1k.

| bot / variant | 20:00 metal income (k), one per game | 14:00 |
|---|---|---|
| STANCE_BOT at 4fa8a2d (re-run today, same harness) | 3.6, 4.7 | 1.5-1.7k |
| RAID_BOT as it was | 2.1, 3.4 | 1.2-1.3k |
| STANCE_BOT as it was (HEAD) | 2.7 | 1.1k |
| RAID_BOT + T2_UP_FRONT | 3.6, 1.7, 2.3, 2.4 | |
| RAID_BOT + T2_UP_FRONT, no AIR_CON_AT_BACK | 2.4, 2.4 | |
| RAID_BOT, no SECOND_AIR_LAB | 2.1, 2.8 | |
| **RAID_BOT + T2_UP_FRONT, no SECOND_AIR_LAB** | **3.7, 4.6, 4.0, 3.4** | 1.0-1.6k |
| RAID_BOT + T2_UP_FRONT, second lab at 12:00 | 2.9, 3.7 | |
| STANCE_BOT + T2_UP_FRONT | 2.7, 2.9 | |
| STANCE_BOT with the old flag set (no AT_BACK, no T2_UP_FRONT) | 2.4, 2.7 | |
| STANCE_BOT + T2_UP_FRONT, no AT_BACK | 2.8, 2.0 | |
| STANCE_BOT + T2_UP_FRONT, NANO_CREW off | 1.5, 2.6 | |
| STANCE_BOT + T2_UP_FRONT, no FUSION_HELPERS / ENERGY_PRIORITY | 2.8, 2.8 | |

Run-to-run sd is ~25%, so n=2 only separates big effects.

Findings
- The refactor (d6ba532, con broker) stopped ordering T2 air cons when an advanced air lab finishes (old: UPGRADE_CONS_PER_LAB = 4 each); they
  are built on demand by the jobs' `produce` hooks. Cons built by 14:00 fell (RAID_BOT 116 vs 183-207 old; 135 vs 286-326 at 20:00).
  `T2_CONS_UP_FRONT` (preset `T2_UP_FRONT`) restores the old rule. On RAID_BOT it only pays together with dropping SECOND_AIR_LAB
  (the second lab at 8:00 costs ~1.4k of 20:00 income in a vacuum; against people it is what the game review asked for).
- STANCE_BOT is slower than before in a way no flag restores: same cons / army / factory counts at 12-14:00 but ~30% fewer mexes
  (237-284 vs 367-393 at 12:00) and fewer energy buildings (300-350 vs 405), nanos 98-141 vs 180. Still to find inside the
  line_transition / con_broker rewrite (suspects: job priorities -- nanocrew 72 above grid 70 --, hold / reserve of cons, grid opening).
  Bisect idea: worktree at d6ba532 and 15b21fc, 2 vacuum games each.
- Replays (vacuum, saved 2026-10-14): `data\demos\2026-10-14_16-57-24-601_Full Metal Plate 1.7_2026.07.04.sdfz` (RAID_BOT, 3.4k),
  `...16-57-35-109...` (STANCE_BOT, 2.7k). Results: `runs_stance/vacR_*.json`.
