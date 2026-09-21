# champion_v1

**Status as of 2026-09-18: byte-identical to `candidates/20260918_024045`.**

This started as a stacked best-of bot: rez-bot `lab_controller.lua` + `unit_controller.lua`
from `20260918_024045`, plus the closed-loop energy controller from `20260918_025426`. The
stacking idea is sound — those runs touch disjoint files, so they combine with no merge.

The energy controller was then re-tested with `ab_test.py` under the fixed harness and turned
out to be a **regression** (baseline_001 leads in both slots, 1.15x in slot 1), so it was
reverted to baseline's `macro_controller.lua`. That leaves this bot equal to `20260918_024045`.

**This is the honest current state: no `macro_controller.lua` change has ever been validated
under a working harness.** Every macro "win" in `strategy_log.jsonl` predates the harness
fixes. Re-validating them with `ab_test.py` is the open work; whichever one genuinely leads in
both slots becomes this bot's macro and makes it a real champion again.

Not yet folded in (all conflict on `unit_controller.lua`, so they need real merges, and all
need re-validating first):
- `20260916_040637` — flank raiders
- `20260918_024155` — node-span scaling + reinforcement muster
- `20260918_064114` — retreat-HP / enemy-radius tuning

Compare with `ab_test.py`, never with a single `bot_testing.py` match. See
`knowledge/lessons_learned.md`.
