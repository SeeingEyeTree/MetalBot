# 2026-10-12: strategy framework, slot spine, STANCE_BOT

Goal (user): a framework strategies are built on, like blueprint_placer is for buildings: stances (unit comp), plug-and-play
behaviours shared between units, and run-time decisions (how much to spend, which unit, how to control it) from the real game
state. Scaling is good enough; fewer loose ends so new ideas are cheap to test.

## What was built (all uncommitted on `bot-testing-v2`)

| Piece | Files | What it does |
|---|---|---|
| Behaviour host | `bar_framework/behavior_host.lua`, `behavior_ctx.lua`, `behaviors/` (+ README) | A behaviour is a table (`cfg`, `Init`, `Update`). Assign by name per unit, stackable (first to claim wins), per-unit tunables (units with equal overrides move as one cohort), one de-duplicated order path, `Hold`/`IsHeld` so other controllers keep off a unit it moves. |
| kite | `behaviors/kite.lua` | Back off from ANY approaching enemy (time-to-contact under 4 s, threat value >= 10% of the group), step grows with the threat. Replaces slow_front's fast-chargers-only rule (slow_front keeps `CHARGE_SPEED=1e9` and `SetHold`). |
| stun_target | `behaviors/stun_target.lua` | Shuriken/Wasp target spreading extracted from unit_controller. Not wired into STANCE_BOT yet. |
| Strategy | `strategy.lua`, `strategy_hooks.lua`, `game_state.lua` | Stances + hooks `army_share` / `weights` / `switch`; `Pick`/`Note` (value-deficit, with weights); `Assign` attaches stance behaviours; `InstallSlotSpine`. `strategy_hooks.v16_share` reproduces v16's share policy. |
| Enemy facts | `enemy_intel.lua` (`Facts`, `Blobs`, `EcoTargets`, `RadarCovers`), `game_state.lua` | anti-nuke, AA value, radar, eco value/targets, static defence, T2 units, blobs. Tests: `test_intel_facts.lua`. |
| Stances | `stance_loader.lua`, `stance_editor.html`, `stances/line_ground.lua` | Per-unit `behaviors`/`cfg` (editor boxes), weights in `Pick`, `Value` exported. |
| Slot spine | `slot_spine.lua`, `blueprints/general/NanoBlock.lua` | 16-nano blocks with 2 lab slots in front. Planner (`Cover`/`Counts`/`Enablers`) picks labs from the stance's units, T2/T3 gated by army value, enabler labs placed first, wide labs (gantry) take both slots, swap by reclaim after RECLAIM_DELAY, nanos built ahead of income and re-guard the new lab, labs keep ground cons coming. Adopts the line's own vehicle plant (`AdoptLab`, `Expect`). |
| STANCE_BOT | `candidates/STANCE_BOT/` (copy of v16 + changes) | macro: slot_spine + strategy; lab: stance picks (queue depth 3), T2/T3 via ServiceSpineLab; unit: behaviour host + kite for Lashers/Sheldons. The line's first vehicle plant follows the stance. |
| Tooling | `tests/run_lua.py`, `runs_stance/batch.py`, `deploy.ps1` (recursive copy), `bot_testing.py` (recursive bar_framework copy) | `python tests/run_lua.py tests/test_slot_spine.lua`; batch: `python runs_stance/batch.py TAG BOT_A BOT_B PAIRS END_MIN [PARALLEL]`. |

Tests (all pass): test_behavior_host, test_strategy, test_slot_spine (fake placer), test_intel_facts, test_stance_export.py, plus the
existing slow_front / click_army / scout_lanes / line_bomb suites.

## Results: STANCE_BOT vs LINE_CLICK_v16 (single mode, 30 min, both slot orders)
- Round 1 (bugs: share pinned at 100% by a unit-cap bug; T1 labs one order per 4 s; no T3): lost both, floated 50k+ metal.
- Fixes: unit-cap read, queue depth 3 on army orders, Demon + wide gantry slots, T2 labs wait for their enabler, host plant not duplicated, cons kept coming, next block opens at 75% built.
- Round 3: won both (slot 0 end score 1.89x; slot 1 killed v16's commander at ~27 min). Round 4: lost both (0.25x, 0.57x).
- In all four games the bots were even until ~12 min, then one economy snowballed (income ratios 4x or 0.2x by 20 min). 2-2 is NOT a demonstrated result; per-game noise is large. An 8-game 18-minute batch was cut short (user went to sleep).
- Not tested: vs BARb (user said skip). Deployed to the BAR widget folder for a manual game vs the in-game AI.

## Still to do / ideas
1. More games (18-min batches show the divergence by minute 18): `batch.py b2 candidates/STANCE_BOT candidates/LINE_CLICK_v16 6 18 4`.
2. Understand the 10-16 min exchange: bistable raid war. Look at what v16's wins/losses share (eco destroyed first?). Candidates: stance shares early, fighters/AA, commander safety (STANCE_BOT's commander died at 16:08 to a corhurc in one game).
3. Slot geometry unverified in the real game: slots 144 apart, wide lab at x=72, nano reach ~280. Check lab footprints and that labs exit cleanly.
4. Energy storage: v16's spine cells build `corestor` buffers (ThrottleStorage); the slot spine has none (energy floated late, but may matter).
5. Move the rest of the micro onto the host: Shuriken stun (`stun_target`), commander evade, rez crew, Pounder screen, scouts, bomb_run/air_wing. Air guards (Shuriken, Wasp, fighters) still use the old lab-controller rules, not the stance.
6. Frontier crew for LRPC/defence creep: `knowledge/plans/frontier_crew_todo.md`.
7. experiment_ideas.md mapping: bombing runs (switch hook + AA facts + port bomb_run) are closest; T3 mix is a stance edit; skuttles/spies need a radar-avoiding approach behaviour; nukes need a target picker on `state.facts`/`ei`; energy grid needs an `energy_pressure` fact; LRPC/creep need the frontier crew.
8. Thin bot folders: a bot as config (stance + hooks + overrides) over shared widgets, so an experiment is not a 2000-line copy. Slot spine/strategy are ready for it; the three widgets are not yet shared.
9. `.gitattributes` for line endings was skipped (would renormalise every file with this much uncommitted work).
10. Nothing here is committed. v16/v17 are untouched except shared framework files (slow_front `SetHold`, enemy_intel facts, stance_loader), which are backward compatible.

## Slot spine slack (2026-10-12, later)
`slot_spine.lua` now keeps `CFG.SLACK_BLOCKS = 2` spare blocks (every nano of them built, both slots free) once income >= `SLACK_INCOME` (500 m/s)
and the mex grids are ready, so a comp change puts new labs straight into free slots with their BP already standing. Slack nanos are built via
`S.nanoBuildNeed` but stay parked (`S.nanoNeed`, the spend need, still drives guarding). `[SLOT]` log rows show `spare` and `build`.
Set `SS.CFG.SLACK_BLOCKS = 0` to disable. Tested in `tests/test_slot_spine.lua`; NOT yet A/B'd in game (cost: ~32 nanos of idle metal at 500+ m/s).
