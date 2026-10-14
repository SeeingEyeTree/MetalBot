# WG channels (how widgets and modules talk to each other)

Widgets in one Spring/BAR game share the global table `WG`. A few of the framework modules and all three controllers
communicate through it. This lists every channel, who writes it, who reads it, and what is in it. It was written from the code
on 2026-10-14; when you add a field, add it here. (In `--server single` mode each team gets its own `WG`, and framework modules
do not see the widgets' `WG` automatically: `game_state.Collect{ MB = WG.MetalBot }` passes it in explicitly.)

| Channel | Written by | Read by | What it is |
|---|---|---|---|
| `WG.MetalBot` | `unit_controller` (`PublishState`, once a second), `raid_response.Publish` | `lab_controller`, `macro_controller`, `line_transition`, `defense_crew`, `enemy_intel`, `game_state`, `unit_controller` | the unit controller's read-out of the game for everyone else (below) |
| `WG.Strategy` | `macro_controller` | `lab_controller`, `macro_controller`, `unit_controller`, `raid_response` | the `strategy.lua` object: current stance, `Pick` / `Note` / `Plan()`, `Assign(host, uid, defID)` |
| `WG.Spine` | `line_transition` (when the spine is built) | `lab_controller`, `line_transition`, `spine` | the vehicle-lab spine: `IsLab`, `IsT1Lab`, `IsLeaving`, `NextOrder`, `Share`, `Held`, `CFG.QUEUE_DEPTH` |
| `WG.TileLabHold` | `macro_controller` | `lab_controller`, `macro_controller` | `function(labID) -> true` while the macro still owes that air lab constructors (the lab controller then adds nothing ahead of them) |
| `WG.BombPlan` | `phase_plan` view | `bomb_run`, `lab_recycler`, `phase_plan` | the bomber game plan (`plan.recycle` ...) |
| `WG.AntiNuke` | `defense_crew` | `lab_controller` | `saviorWant`: how many mobile anti-nukes the cover plan wants |
| `WG.StatsTracker` | `metalbot_stats_tracker` | the tracker itself, bots (`DecodeSpeed`) | tracker API |

## `WG.MetalBot` fields

Published by `unit_controller.PublishState` unless noted. All are plain values or small tables; a reader must tolerate `nil`
(the first ticks, or a module that failed to load).

| Field | Meaning | Main readers |
|---|---|---|
| `frame` | frame of the last publish | |
| `urgency`, `urgencyDeficit`, `urgencyChannel` | `threat_map.ProductionUrgency`: `"none"` / `"build"` / `"rush"`, how short we are, `"air"` / `"ground"` | `lab_controller` (defence), `strategy_hooks` |
| `homeX/Z`, `foeX/Z`, `axisX/Z`, `foeDist` | map model: our base, the enemy's, the axis between them | |
| `threats` | the intruder groups now: `{ x, z, channel }` | `game_state` |
| `raid` | the labs' raid record, held ~10 s: `{ frame, value, ground, air, speed, moving, channel, n }` (`raid_response.Publish`) | `lab_controller` |
| `airLosses` | own air units shot down by enemy fighters in the last 30 s (`raid_response.Publish`) | `lab_controller` |
| `intel` | `enemy_intel.Summary`: what we know of the enemy (`airValue`, `groundValue`, `airLabs`, `t2AirLabs`, `silos`, ...) | `lab_controller`, `strategy_hooks`, `game_state` |
| `scoutWant` | scouts the labs should keep | `lab_controller` |
| `ringRadarWant` | ring radar units the T2 labs should trickle | `lab_controller` |
| `callScouts` | Hawks the attack groups have called | `lab_controller` |
| `armyCount`, `armyValue`, `armyGround`, `armyAir` | our combat units, their metal value, split ground / air (ground AA counts) | `lab_controller`, `strategy_hooks`, `game_state` |
| `trade` | click_army's raid trade summary | `strategy_hooks` (game plan) |
| `airKills`, `airLost` | air value killed / lost over the last 2 min | `lab_controller` (air superiority) |
| `hunt` | the game is won, bombers hunt the last commander | `lab_controller` |
| `airAlarm` | bombers heading for the base: `{ frame, n }` | `lab_controller` |
