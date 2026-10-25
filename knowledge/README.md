# knowledge

Game facts and how the bots are built. Dated session logs live in `sessions/`, not here.

## Reference (top level)
| File | What |
|---|---|
| `game_mechanics.md` | BAR / Spring mechanics the bots rely on (read this first) |
| `economy_numbers.md` | measured mex / fusion / Dragon numbers |
| `unit_catalog.json` | every unit's stats (built by `extract_unit_catalog.py`) |
| `framework_api.md` | `bar_framework/` module API |
| `ledgers.md` | the spend / fight / scouting-lead ledgers (`ledger_logger.lua`, `ledger_report.py`) and what each kind of unit is worth (`value_weights.lua`) |
| `scoring.md` | the phi state-value score: why it is built this way, weights, validation log |
| `eco_sim.md` | the fast economy simulator (`eco_sim.py`): how it works, calibration, tuning log |
| `eco_scaling_2026-10-09.md` | the economy scaling bench (`eco_scaling.py`, ECO_BENCH) |
| `lessons_learned.md` | curated insights from agent runs (older entries predate the current harness; see its top) |

## Data
`replay_history.jsonl` (written by `replay_analysis.py`), `strategy_log.jsonl`, `raid_runs/`, `threat_logs/`.

## `bots/` -- how a bot is put together
Design notes for the bots and framework pieces: `v16_2026-10-09.md` (the main bot), `dragon_eco_2026-10-14.md`,
`scout_rings_2026-10-12.md`, `session_2026-10-12_stance_framework.md` (stances, behaviours, slot spine),
`session_2026-10-13_raid_bot.md` (RAID_BOT), `core_human_2026-10-25.md` (CORE_HUMAN: a person on the army, the logger fix, a read of a game, the Dragon / sink math, the rez lab).

## `plans/` -- open work
`tasks_2026-10-16.md`, `plan_mediator_obs_stances_scenarios_2026-10-16.md`, `frontier_crew_todo.md`.

## `sessions/` -- dated logs (history, not reference)
Overnight runs, eco sessions, regression and variance notes, the CLAUDE.md history, the paintkid replay review.
Useful for "what was tried and why", but check the code before trusting a number.
