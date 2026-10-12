# LINE_BOMB

LINE_CLICK_v16 + the stance system + a T1 bomber rush. Plan: **T1 defense -> T1 bombing run -> T2 defense -> late game.**
The bet: bots have weak AA, so ~30 Whirlwinds (`corshad`) hitting their mex/wind at ~9:00 do game-winning damage.

## The plan (bar_framework/phase_plan.lua, tunables in `CFG.PLAN` of the macro controller)
| Phase | Stance (stances/*.lua) | What happens |
|---|---|---|
| DEF1 | `T1_defense` | v16 opening. From 5:15 the spine opens the **bomber lab cell** (pre-built build power). |
| BOMB | `T1_bombing_run` on the bomber labs, `T1_defense` on every other lab | From 7:30 (3+ bomber labs standing) the labs queue bombers + fighters 3 deep, capped at 30 alive / 50 ever. `bomb_run.lua` flies the waves. Ground share is NOT raised ("if the ground can hold, more units don't help"). |
| DEF2 | `T2_defense` | From 11:30 or when the raid is spent: `lab_recycler.lua` reclaims the T1 air labs and puts two T2 air labs in the same slots. |
| LATE | `Late_game` | From 16:00 or 700 m/s income: spine share 1.0, Dragons from the T2 air labs, T3 from the spine. |

If the bomber labs are not up by 10:00 the raid is dropped (straight to DEF2). `WG.BombPlan` is the published plan.

## New pieces
- `bar_framework/stance_loader.lua`: loads `stances/<name>.lua`, value-deficit pick (`Pick`, `positiveOnly`), per-stance ledger.
- `bar_framework/phase_plan.lua`: the state machine (no Spring calls).
- `bar_framework/bomb_run.lua`: RALLY -> STRIKE -> RETURN. Bombing points = clusters of static enemy eco (mex, wind, nanos, labs),
  4 bombers per point (`PER_TARGET`), at most 8 points, points only where enemy AA (`EI.ThreatAt air`) is under 0.6x the wave's value;
  fighters FIGHT at the best point ahead of the bombers; two fighters scout the enemy eco before launch. Launch at 20 bombers (12 after
  90 s of BOMB), relaunch at 10. Log rows `[BR]`.
- `bar_framework/lab_recycler.lua`: clear queues -> nanos reclaim the T1 air labs -> `spine.OpenSwapCell` places the T2 air labs
  (blueprint `T1Air.lua` `M.swap`) once income >= 120 m/s. Log rows `[LR]`.
- `blueprints/general/T1Air.lua`: 3 `corap` + 10 `cornanotc` (~4.2k metal, 2450 BP).
- `spine.lua` (additive, inert unless asked): `OpenAirCell`, `OpenSwapCell`, `AirUnits`, `IsAirLab`, `SetNanoFloor`; air cells are not
  held, throttled or parked, and their labs run through the normal lab picks (`IsT1Lab` is true for them).
- `lab_controller.lua`: stance picks for the T1 spine labs (the T1 bot lab now makes army too), T2 spine labs, and `ServiceAirLab`
  for the air cell. Without a plan or a stance file it is v16.
- `unit_controller.lua`: `bomb_run` owns the bombers and the wave's fighters; click_army and air_wing get no bombers; air_wing's hunt
  stops while the bomb plan is on. Publishes `WG.BombRun`.

## Pre-built build power
The air cell is built ahead of the BOMB phase (5:15-7:30), so the bomber labs and 10 nanos are standing when the stance switches.
`spine.SetNanoFloor(f)` pre-releases T2/T3 nanos for `f` x income in DEF2 (0.5) and LATE (1.0).

## Not done / risks
- Only the logic is stub-tested (`tests/test_line_bomb.lua`; the stub's cons never build spine cells, so the test builds the air cell itself).
- The T1 bot lab now builds army (corthud, corak) from `T1_defense`; v16's only made cons. May cost eco in DEF1: watch the first A/B.
- Bombers rearm by reload alone (`corbomb` reload 6 s, no pads); a wave's ATTACK orders are re-stated by army_broker every heartbeat.
- Energy: a Whirlwind costs 4600 energy; 30 bombers = 138k energy. Energy income at 7:30 decides how fast the wave builds.
- Control notes of the DEF stances (Pounders pull back, hold 20% toward the enemy; Mammoths behind spam) are not implemented in slow_front.
- `corshad` AA-avoidance reads `enemy_intel` only: AA the scouts never saw is not avoided.
- `air_wing.lua` and `spend_governor.lua` were missing from `deploy.ps1` (the harness copies all of `bar_framework/`); added.
