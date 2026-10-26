# AIR_TIMING (2026-10-25): CORE with an anvil-and-hammer strategy

`candidates/AIR_TIMING` is CORE with a new strategy. The ground army only holds our line (the anvil), and the economy booms
behind a 10% army share. Air is the hammer that kills enemy build power. The idea comes from the 2026-10-25 CORE_HUMAN game
(`core_human_2026-10-25.md`): the person ran 10% share from the start, kept Shurikens as a mobile home defence, and had an air group
that sniped nano turrets and winds.

## Strategy (config only: `candidates/AIR_TIMING/macro_controller.lua`)
| stance | taken | comp | share |
|---|---|---|---|
| `anvil_open` | start | Grunts, Pounders, Sheldons (kite), Trashers | `v16_share` floor 0.10 (`MATCH = false`) |
| `anvil_burst` | income >= 250 for 20 s (`BURST_SWITCH`) | T1_bombing_run's comp: Shadows 78%, Avengers 22% | `plan.share = 0.65` until army value +5k (at most 240 s) |
| `anvil_hold` | burst over | `hold`'s comp plus more AA; `plan.bombers = 0.5` | 0.10 floor |
| `raid_late` | unit cap 75% full | CORE's | |

All four plans except `raid_late` are `army = "hold"`. Bomber runs (`click_army` UpdateBombers: 8+ bombers, a 90 s cooldown) do not
depend on the plan. The sink's Dragons get `SINK_EXTRAS` `dragon_raid` waves of 30 (CORE uses 50), ordered build power, then
commander, then AA, then eco.

## Framework additions (all opt-in, default off)
- `strategy_hooks.burst_switch{ to, back, income, hold_s, spend, burst_s, minute }`. `macro_runtime` key `BURST_SWITCH`: chained after the
  income switches and before the game plan. It ends on **spend**, not on time, because in eco_sim the burst's air labs stood 60-75 s into a
  fixed 90 s window and the fighter floor took the first queues, so only 1 Shadow was built. With `spend = 5000` the burst ran 128 s and
  25 Shadows stood. Tests are in `tests/test_strategy.lua`.
- Stance `plan.share` (`strategy.lua`): a floor under the hook's army share while that stance is current.
- **`bar_framework/unit_runtime.lua`**: CORE's unit controller moved into the framework unchanged (`UNIT.Install(widget, WG, { MECH = {...} })`).
  `candidates/CORE/unit_controller.lua` and AIR_TIMING's are now stubs, so a new CORE variant is three short config files and no
  1.9k-line copy. IRON_TIDE, CORE_STD, CORE_SINK, DEFENCE_BOT and SHIVA_BOT still carry their own drifted copies. Moving them needs an
  order check each. The original file is in git history: `candidates/CORE/unit_controller.lua` at aec9251.

## Round 2 (after the first game, user review)
The user's review: the bombers never attacked, and the ground army "danced in a ball doing nothing". They wanted bombers sent
the moment the burst stops, about 30 of them, and the ground pushing when winning or stopping raids, never parked.
- **Why the bombers never flew.** `endgame.Strike` claims every bomber at HOME_GUARD priority (`BOMBER_WAIT`, parked behind the
  base) until the enemy commander is freshly seen. click_army's bomber runs claim at LINE priority, so the broker rejected them, yet
  `[CK] bomber run: 29 bombers` was still logged. The air wing skips `BOMBER_WAIT`, which is why it had 0 bombers all game.
  **This hits CORE too** (its click_army bomber runs never fly). It is not fixed for CORE yet.
- **The ball** was click_army's `hold` mode: the whole army in a golden-angle ring at the stage point, launching nothing. It is
  removed: `unit_runtime` treats plan army `"hold"` as `"defend"`.
- **New plan army `"defend"`** (unit_runtime): maneuver_defence blobs intercept raids. Click_army raid groups push (at enemy build
  power / eco) while our ground army outweighs the scouted enemy ground army: `plan.push = { ratio 1.3, back 1.0, hold_s 20,
  min_value 3000 }`, with hysteresis. With the enemy army unknown it pushes only with 4 x min_value. A flip hands the army over
  like a stance change.
- **`plan.bomb_run = "rally" | "launch"`** (unit_runtime + bomb_run.lua, from LINE_BOMB). It flies the T1_bombing_run control: on
  launch every free fighter FIGHTs ahead as the escort, about 4 bombers per eco point (CLUSTER_R 200 suits the bomb AOE), points
  re-picked as they die, home when spent. `bomb_run` now takes `BOMBER_WAIT` bombers (RAID priority). `plan.launch` sends the first
  wave at once with whatever stands. `RALLY_FIGHTERS = false` leaves the fighters with the air wing between waves.
  AIR_TIMING: `BOMB_RUN = { LAUNCH_MIN = 30, LAUNCH_FLOOR = 30, RELAUNCH_MIN = 12, RALLY_FIGHTERS = false }`.
- **Burst end:** `burst_switch{ unit = "corshad", count = 30 }` ends at 30 Shadows alive (by army value the ground army's growth
  ended it after 48 s). `anvil_open` builds 15% Avengers so the spine has an air lab before the burst. In eco_sim: 30 Shadows in
  188 s (9:53 -> 13:01).
- `anvil_late` = raid_late's comp with the defend / push plan and bomber waves (LATE_STANCE).
- **CORE is affected** by the unit_runtime change: its `hold` stance (after bad trades) now defends / pushes instead of parking.

## Round 3: CORE's air defence and air-con recovery (user review of the AIR_TIMING vs CORE game)
The game: AIR_TIMING won by game over at 14:22, when its Shadows killed CORE's commander. CORE saw a bomber at ~11:30 and the 26-41
bomber wave from ~13:25, and built no AA. CORE's `AIR ALARM` counts only bombers within 2.8k of the base centre (or within 6.5k and
closing). The wave went for the outer grids. CORE also lost many T1 air cons to fighters and did not replace them.
- **`mb.airRaid`** (unit_runtime `AIRDEF`): fresh typed bomber contacts in our part of the map (forward fraction <= 0.65).
  `seenMax` = the most seen at once. `rush` = at least 8 bombers or 1200 value, held 40 s after the last sighting. `tx, tz` = their
  position projected 12 s ahead.
- **AA floor** (lab_rules want `aa-floor`, prio 97, ahead): once any bomber is seen, keep `AA_FLOOR_BASE 4 + 0.15 x seenMax` (max 12)
  ground AA, alive or ordered, from whichever lab can make one: flak truck (corsent), then coraak, cormist, corcrash (roles
  `aa_flak_truck` ...).
- **Air rush** (want `air-rush`, prio 150, lab_broker mode `flush`): every lab that can make AA clears its queue, the unit in progress
  included, once per raid (`flushKey` = `mb.airRaid.since`), then keeps `AIR_RUSH_DEPTH 4` AA queued. Flak first; air labs make
  fighters. Existing labs only. Labs owing air cons (TileLabHeld) are left alone.
- **Army share** goes to `AIR_RUSH_SHARE` (1.0, macro_runtime) during the rush.
- **AA units in a rush**: every ground AA unit (RESPOND priority) and every free fighter (RAID priority, but not a bomb_run escort or a
  commander strike) FIGHT at the projected raid position. They are released when it ends. Ground AA is now routed before the maneuver
  blobs and the slow group (before this, the blobs took the AA trucks). The T1 AA units (corcrash, cormist) count as ground AA.
- **`AIR_CON_LABS`** (line_transition, default on): while jobs + reserve want at least 2 more T1 air cons than stand ready, for 60 s,
  an open grid's unstarted capstone becomes a T1 air lab, built next (at most 2). `QueueAirCon` orders from the T1 air lab with the
  shortest queue: the line's lab or a capstone lab. Before this, only `T.airLabID` was used, and nothing at all once it died.

## Round 4 (user review of the air-defence game: a draw at 25:00)
- **The AA rush overbuilt.** It stayed on 40 s past the last big sighting and kept 4 AA per lab queued; 158, then 282, then 670 AA
  units and fighters were sent. Now it ends once fewer than 3 bombers have been seen for 10 s (`AIRDEF.END_MIN` / `END_HOLD`). The
  labs order AA only until ground AA + fighters (alive or ordered) are worth `AIR_RUSH_MULT` 2 x the raid still in sight. When it
  ends, `LB.EndFlush` takes the rush's AA off every queue it flushed.
- **Dragons never moved out.** `Strategy:BehaviorsFor` returned nil for a stance unit without behaviours (raid_late's corcrwh, 64%)
  and never looked at the stance extras. So no Dragon finished in raid_late got `dragon_raid` / `dragon_defend`, and nothing
  else commands a sink Dragon: they sat at their labs (no `[DW]` row in any game). Fixed: fall through to the extras. The
  default `SINK_EXTRAS` wave is 50 (AIR_TIMING overrides it to 30).
- **Unit cap: `CAP_T1_FRAC` 0.6** (macro_runtime -> `strategy.capFilter`). From 60% cap fill, off again at 55%, the stances' T1 combat
  units (techlevel 1, armed, mobile, not builders) leave the comp (`UnitList`, which the slot spine plans labs from) and the picks.
  A stance of only T1 units keeps its comp. Scouts and the lab rules' floors are not stance picks.
- **Air-con capstones fired in the opening** (4:30 / 5:30), when the jobs always want more cons. Now not before 8:00 and the first grid's
  cap lift (`AIR_CON_START_FRAME`); at most 3 labs.
- **Spending** (user: AIR_TIMING spent everything, CORE floated). Measured: at 24:00 both pulled about the same (AIR_TIMING
  4.4k/s, CORE 4.2k/s), but CORE earned 8.5k/s against 4.8k, and neither was capped (CORE 2,395 of 3,000 units). The float is spending
  capacity, not a AIR_TIMING config: both bots' sink labs sat "waiting for a con" (the sinklab job needs an air con, and the air
  cons come from one busy T1 air lab). In eco_sim all three configs float the same at 25:00. The mid-game air-con capstones should
  help; the sink's con supply is the next thing to fix.
- Rez bots: control changed somewhere along the way (user: fine, just noted).

## Round 5: CORE's scaling (real game: CORE's income flat at 3.2k from 21:00); fixed in eco_sim
eco_sim, 6 seeds, against `aec9251` (CORE before this session and the earlier uncommitted work): 20:00 income 7366 there, 6632 now (-10%).
The sim is not deterministic: two runs of the same seeds differ by up to ~15%, so use 6 seeds.
1. **Grid recovery loop** (bug, older than this session). The T1 grid has 22 mexes; the retrofit (`upgrade.lua`) has 18 T2 mexes and 4
   fusions on the corner spots. Recovery judged retrofitted grids against the T1 spots, saw "4 of 22 empty", and re-opened the
   retrofit every RECOVER_EVERY, forever. That was 500+ recoveries per sim game, ~180 on one grid in the real game, each holding a
   T2 con, so the fusion push and the other retrofits starved. Fixed: the retrofit job's `onDone` records the T2 mexes it built
   (`RememberRetrofitMexes`); recovery judges a retrofitted grid against those, and gives up on spots that stay empty after
   `RECOVER_SAME_MAX` (2) re-runs. Recoveries in the sim: 0.
2. **Rez floor** (from the earlier session): rez lab at 40 m/s and 8 rez bots from 3:00 cost 13% income at 10:00. Now the rez lab
   comes at 250 m/s income and the bots from 8:00 with a floor of 4 (CORE and AIR_TIMING configs). 10:00 income 283 -> 319.
3. **Sink started too early** (`SINK` was off in aec9251). The first lab went up at ~12:20, when income reached 85% of "what the spine
   can spend" (a number that leaves out the economy's own spending), with 1.5k banked. It took cons and metal from the retrofits.
   Now the first lab needs the bank at max(15k, 25% of storage) for 30 s (`SINK_START_*`). It then goes up at 15-18 min. Labs are
   sized from unspent income (income - smoothed pull; `SINK_SURPLUS_PULL`).
   Also fixed: `metal_sink.Init` turned an explicit `false` option back into the default (`cfg[k] ~= nil and cfg[k] or v`).
- Neutral (inside the noise): AIR_CON_LABS, SINK_PARALLEL 3 vs 5, SINK_MAX 10 vs 40.
- Result: 20:00 income 6794 -> 7281 (aec9251: 7366); T2 mexes at 18:00 307 -> 376; fusions at 20:00 140 -> 155.
- Cost: in the vacuum sim the bank floats more after 18:00 (326k at 20:00 against 67k), because nothing else can spend 8k m/s at the cap.
  Real games still need checking.

## Checks done
- eco_sim, seed 1, 15 min: same income as with the fixed window (10:00 448, 14:00 ~1.7k m/s), 0 Lua errors, stances switch as
  designed.
- `tests/run_tests.py --touched`: all pass. `check_role_names` baseline re-saved for the moved literals. `check_lua_unbound`: 0.
- One 25-min single-mode game vs LINE_CLICK_v16 with a replay (result below). No A/B was run.
