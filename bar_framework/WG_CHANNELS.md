# WG channels (how widgets and modules talk to each other)

Widgets in one Spring/BAR game share the global table `WG`. A few of the framework modules and all three controllers
communicate through it. This lists every channel, who writes it, who reads it, and what is in it. It was written from the code
on 2026-10-14; when you add a field, add it here. (In `--server single` mode each team gets its own `WG`, and framework modules
do not see the widgets' `WG` automatically: `game_state.Collect{ MB = WG.MetalBot }` passes it in explicitly.)

| Channel | Written by | Read by | What it is |
|---|---|---|---|
| `WG.MetalBot` | `unit_controller` (`PublishState`, once a second), `raid_response.Publish` | `lab_controller`, `macro_controller`, `line_transition`, `defense_crew`, `enemy_intel`, `game_state`, `unit_controller` | the unit controller's read-out of the game for everyone else (below) |
| `WG.Strategy` | `macro_controller` | `lab_controller`, `macro_controller`, `unit_controller`, `raid_response` | the `strategy.lua` object: current stance, `Pick` / `Note` / `Plan()`, `Assign(host, uid, defID)` |
| `WG.StanceChoices` / `WG.StanceRequest` / `WG.ArmyShareRequest` | `macro_controller` (`MANUAL_STANCES` -> `StanceChoices`); `stance_panel.lua` (the other two) | the macro's switch / `army_share` hooks, `stance_panel.lua` | CORE_HUMAN (2026-10-25): the stances a person may pick, the one picked, and a manual army share 0..1 (nil = the bot's own rule). Only present when `MANUAL_STANCES` is set |
| `WG.Spine` | `line_transition` (when the spine is built) | `lab_controller`, `line_transition`, `spine` | the vehicle-lab spine: `IsLab`, `IsT1Lab`, `IsLeaving`, `NextOrder`, `Share`, `Held`, `CFG.QUEUE_DEPTH` |
| `WG.TileLabHold` | `macro_controller` | `lab_controller`, `macro_controller` | `function(labID) -> true` while the macro still owes that air lab constructors (the lab controller then adds nothing ahead of them) |
| `WG.BombPlan` | `phase_plan` view | `bomb_run`, `lab_recycler`, `phase_plan` | the bomber game plan (`plan.recycle` ...) |
| `WG.AntiNuke` | `defense_crew` | `lab_controller` | `saviorWant`: how many mobile anti-nukes the cover plan wants |
| `WG.DefenceReclaim` | `defence/wall.lua` (unit_runtime `AREA_DEFENCE`) | `home_defence.lua` (macro side) | `{ [uid] = { x, z, frame, nano } }`: our own surplus wall Pounders walking to a nano; the nanos in reach reclaim them (nano_broker `PRIO.DECOM`) |
| `WG.ProxyBase` | `proxy_base.lua` (macro side, `PROXY`) | `area_defence.lua` (declares the "proxy" area), unit_runtime `PROXY_ARMY` (retasks raid groups), `lab_rules.lua` ("proxy-lab" want), `lab_orders.lua` (proxy labs take no requests) | `{ x, z, key (the try), labID, frameID, state = "beachhead" | "con" | "hold", con, go, labs = { [labID] = "t1" | "t2" }, want = { [labID] = unit name }, static (T2 defences standing), lrpc (Basilisks standing) }` while a proxy base is wanted or stands; nil otherwise |
| `WG.ProxyConvoy` | `sink_lift.lua` (macro side, a convoy site) | `air_wing.lua` (ESCORT) | `{ state = "loading" | "rally" | "flying", x, z (the transports' centre), tx, tz (the site), n, key, frame, tids }` while the proxy's nano convoy is out; nil otherwise |
| `WG.DragonLab` | DRAGON_ECO `macro_controller` (`dragon_lab.lua`) | DRAGON_ECO `lab_controller`, `unit_controller` (the Dragons' gather point) | the T2 air lab in front of the spine that makes Dragons: `id`, `x`, `z`, `ready`, `decoys` (`[uid] = true`, the decoy commanders assisting it) |
| `WG.UQSnap` | `unit_query.lua` | everything that counts or scans own units | `{ [teamID] = { frame, count, ids, defOf, byDef, ... } }`: the once-per-frame walk of `GetTeamUnits` (and `["enemies<team>"]`), shared by all `VFS.Include` instances of unit_query |
| `WG.EcoLedger` | `eco_ledger.lua` (consumers register: `slot_spine` via `line_transition`, `metal_sink`) | `metal_sink`, `line_decoy`, `energy.lua` | `{ consumers = { [name] = { capacity = fn() -> m/s, energyPerMetal = fn() } } }`: who can spend how much and what energy per metal they want; read through `Ledger.Capacity / EnergyTarget` |
| `WG.SinkLabs` | `metal_sink.lua` | DRAGON_ECO `lab_controller` (via `CH.SinkLabs`) | `{ [labID] = {id, x, z, ready, decoys, decoyMax, unit, spot} }`, every finished sink lab (decoys = the decoy commanders assisting it, at most `decoyMax` = 32).  `WG.DragonLabs` (same records) and `WG.DragonLab` (the first) are kept as aliases |
| `WG.DecoyLabs` | `line_transition` (`line_decoy.lua`) | `lab_controller` (via `CH.DecoyLabs`) | `{ [labID] = {id, x, z, ready, decoys, decoyMax, line = true} }`: the T2 bot labs the line was turned into; decoy commanders assist these first (up to `decoyMax` = 8 each), then the sink labs |
| `WG.DecoyLabs` (sink) | `metal_sink.lua` (`SINK_DECOY_LABS`) | `lab_controller` (via `CH.DecoyLabs`) | the sink's own decoy T2 bot labs go in the same table with `sink = true` and `decoyMax = SINK_DECOY_OWN` (11); lab_rules' `decoy-lab` want owns their queues |
| `WG.SinkPlan` | `metal_sink.lua` | `lab_controller` (via `CH.SinkPlan`) | `{ rate, perLab, jobs, decoyLabs, capReserve }`: one decoy's metal/s on the sink unit, decoys per sink lab, sink labs in flight (their decoy room counts), the sink owns the decoy labs, unit-cap slots kept for the sink unit (no decoys ordered below it) |
| `WG.SinkLiftTids` | `sink_lift.lua` | `air_lift.lua` | `{ transportID, ... }`: the metal sink's light transports (they fly nanos to the sink sites); air_lift leaves them alone |
| `WG.LabBroker` | `lab_controller` (RAID_BOT, DRAGON_ECO, STANCE_*) | `con_broker` (`OrderCon`), `line_transition` | `{ LB = lab_broker module, lb = the instance }`: the macro's constructor orders to labs go through the same queue owner |
| `WG.ConBroker` | `line_transition` | tests, other widgets | the `con_broker` instance: who owns which constructor |
| `WG.ScoutNet` | CORE `unit_controller` (`scout_net.lua`) | anything that wants a look at the map | the scouting API: `RequestScout(x, z, opts)` / `RequestSector(key, opts)` (answered by the nearest free scout; `opts.kind` = `"scout"`, `"hawk"` or `"any"`, `untilMode` = `"seen"` / `"arrive"` / `"expire"`, `ttl`, `key` to refresh one request), `SacrificeScout(x, z)` (a scout runs straight at the spot and is expected to die), `Repeat(target, every)`, `CancelRequest(id)`, `Picture(frame)` (the enemy groups with value and last sighting, total value, commander, when the base was last seen), `LastSeenNear(x, z, r)`, `Want()`, `Stats()` |
| `WG.LabOrders` | `lab_controller` (`lab_orders.lua`, lab_rules `SUPPORT_ORDERS`) | `army_groups` (support elements), `air_lift` (transports), `lab_rules` -> `slot_spine.SetRequired` | the request layer between the stance loop and the air rush: `Request(key, { picks, n, tier = "high" \| "normal", where, held_ok, budget })` every tick it is still wanted, `Drop(key)`, `Status(key)`, `Wanted()` (first picks only a spine lab could make: the spine plans that lab) |
| `WG.AirLift` | `unit_controller` (`air_lift.lua`, unit_runtime `AIR_LIFT`) | `support/arty.lua`, `support/aa.lua`, `sink_lift.lua` (the convoy's route) | slow units by air transport: `Request(uid, x, z, prio, key)`, `Busy(uid)` (being picked up / carried: no orders), `Waiting(uid)`, `Cancel(uid)`, `RouteClear(ax, az, x, z)` (no remembered enemy AA / fighters on the way) |
| `WG.NcFerryTids` | `line_transition` (`nano_cols/ferry.lua`) | `air_lift` | the ferry's transports (the lift leaves them alone); nil once the ferry is done |
| `WG.ArmyGroups` | `unit_controller` (`army_groups.lua`, unit_runtime `SUPPORT`) | `line_transition` (`spam_lab.lua`), `defense_crew` | the army-group API: `Groups()` (the records: `{ id, kind, cx, cz, value, n, target, dx, dz, want }`, the stage last), `Owns(uid)` (a support element holds the unit: defense_crew does not move such a Savior), `Wants()`, `SpamWanted()` (a record opts into spam: the spam lab is built), `RecordOf(uid)` |
| `WG.ScoutLabs` | `line_transition` (`scout_lab.lua`, a dead lab's id is dropped) | `lab_controller` (`lab_rules`: `scout-lab` owns their queues), `unit_controller` (`scout_wing`: their units are the wing's) | `{ air = id, ground = id }`: the scout labs. Only the `scout-lab` want orders them (`lab.only`), while `WG.MetalBot.scoutWing` is short |
| `WG.SpamLab` | `line_transition` (`spam_lab.lua`, cleared when the lab dies) | `lab_controller` (`lab_rules`), `unit_controller` (`army_groups`: its units are spam) | `{ id }`: the T1 bot lab for the spam element. Only the `spam-lab` want orders it (`lab.only`), and only while the element is short |
| `WG.RezLab` | `line_transition` (`rez_lab.lua`, cleared when the lab dies) | `lab_controller` (`lab_rules`) | `{ id }`: the line's T1 bot lab for rez bots. While it stands, the `rez-lab` want is the only thing that orders it (`lab.only`); other T1 bot labs make rez bots only when the room is more than its queue + `REZ_OVERFLOW` (`rez-overflow`) |
| `WG.StarterLab` | `macro_controller` (`macro_runtime`) | `lab_controller` (`lab_rules`) | `function() -> labID or nil, conOpen`: the starter bot lab (held for the macro's cons) and whether a con order is waiting in it; `rez-starter` puts a rez bot into its empty queue between cons (2026-10-31) |
| `WG.StatsTracker` | `metalbot_stats_tracker` | the tracker itself, bots (`DecodeSpeed`) | tracker API |

## Typed access (2026-10-16)

`bar_framework/wg_channels.lua` is the schema for every channel above (`SCHEMA`), plus nil-safe getters (`CH.MetalBot(WG)`,
`CH.TileLabHeld(WG, labID)`, `CH.SaviorWant(WG)`, `CH.Plan(WG)`, `CH.DragonLabs(WG)` ...) and `CH.Publish(WG, name, value)`. Read and
publish through it instead of `WG and WG.X and ...` chains. Under the test stub (`WG_CHANNELS_STRICT`) a malformed publish is an error and
`CH.Validate(WG)` (used at the end of `test_raid_bot` / `test_dragon_eco_bot`) fails on a field that is not in the schema, so a new
channel or field goes into `SCHEMA` and into this file together. Every function takes `WG` explicitly (a `VFS.Include`d module does not
see the widget's per-team `WG` in `--server single`). `tests/test_wg_schema.lua`.

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
| `cover` | `cover_defence.lua` (raid_response `COVER`) or `area_defence.lua` (unit_runtime `AREA_DEFENCE`, same fields): `{ frame, threats, uncovered, uncoveredValue, covered }` -- enemy ground groups on our side and how many lack defenders worth 1.2x them | unit_runtime `holdHome` (no raid launch while `uncovered > 0`) |
| `defence` | `area_defence.lua` (unit_runtime `AREA_DEFENCE`): `{ frame, margin, needUnits, covered, coverS, threats, borrowed, handedBack, raided, walls = { walls, pounders, tzars, want, wantT, reclaiming, sent, reclaimed, onThreat }, air, checklist = { { key, level, want, have, short, answer, note, since } }, homeAAWant, score = { wall/air/army = { k, l } } }` -- margin = the worst threat's built cover / need (no new production counted) | signals `def_threats`, `def_margin`, `def_need_units`, `def_covered`, `def_cover_s` (machines/v4_defence.lua's defended bursts) |
| `enemyBP` | unit_runtime PublishState (every 150 frames) | `proxy_base.lua` (the spot) | `{ x, z, n, frame }`: the weighted centre of the enemy's known labs (x3) and static builders |
| `scoutWing` | `scout_wing.lua` (unit_runtime `SCOUT_WING`): `{ air, ground, airHave, groundHave, airBuilding, groundBuilding, airShort, groundShort }` -- the wing's want, alive, in production and short per kind (its scouts are NOT in `scoutWant`'s count) | `lab_rules` (`scout-lab`) |
| `ringRadarWant` | ring radar units the T2 labs should trickle | `lab_controller` |
| `callScouts` | Hawks the attack groups have called | `lab_controller` |
| `armyCount`, `armyValue`, `armyGround`, `armyAir` | our combat units, their metal value, split ground / air (ground AA counts) | `lab_controller`, `strategy_hooks`, `game_state` |
| `avOwnRate`, `avEnemyRate`, `avProjRatio` | army-value derivatives (m/s, m/s, ratio 60 s ahead); nil until ~25 s of samples (`av_rates.lua`) | `unit_runtime` -> `game_state` / fsm signals |
| `blobs` | the maneuver plan's blob posts `{ {x, z, n}, ... }` (nil under other plans) | `line_transition` (radar posts) |
| `trade` | click_army's raid trade summary | `strategy_hooks` (game plan) |
| `airKills`, `airLost` | air value killed / lost over the last 2 min | `lab_controller` (air superiority) |
| `hunt` | the game is won, bombers hunt the last commander | `lab_controller` |
| `airAlarm` | bombers heading for the base: `{ frame, n }` | `lab_controller` |
| `pushMode` | the defend plan's army mode `defend` / `push` / `raid` (unit_runtime `push.mode`) | `signals.lua` (`push_mode`) |
| `rez` | `rez_broker.lua` (`Demand()`): `{ want, reclaim, repair, bots, frame }` -- rez bots the work wants (wreck metal in the work zone / `RECLAIM_PER_BOT` + missing army hp in metal / `REPAIR_PER_BOT`, at most 100) | `lab_rules` (the rez floor: `SQUAD.RezRoom`) |
| `support` | `army_groups.lua` (unit_runtime `SUPPORT`): per support element `{ want, have, made, picks }` -- want = n x group slots of each kind that opts in, have = units the element holds, made = ever taken, picks = unit names the labs build for it (best first) | `lab_rules` (`group-support`, `spam-lab`, the rez floor) |
| `artyOn` | `support/arty.lua`: true once the arty element latched on (income >= `from_income`) | `support/aa.lua` (n_arty sizes), `air_lift` (`MIN` transports) |
| `raidAir` | enemy air-to-ground units near one of our raid groups (click_army `AIR_PRESSURE`; nil when off): `{ active, near, lastF, checkF }`, active held 240 s after the last sighting | `support/aa.lua` (element on, n by tier), unit_runtime launch gate, `lab_rules` (`AIR_PRESSURE_FIGHTERS`), `nano_cols/fronts.lua` (`NC_T2_LAB_AIR_EXTRA`), signal `raid_air` |
| `airRaid` | enemy bombers in our half (unit_runtime AIRDEF): `{ frame, n, value, x, z, tx, tz, seenMax, rush, since, defenders }`; `rush` = a large raid | `lab_rules` (AA floor, air-rush flush), `macro_runtime` (AIR_RUSH_SHARE) |
