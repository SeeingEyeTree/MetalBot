# bar_framework

Shared modules the bot controllers load with `VFS.Include("LuaUI/Widgets/bar_framework/<name>.lua")`
(`deploy.ps1` copies them into BAR's widget folder). Module defaults are LINE_CLICK_v16's settings; a bot overrides a
default only when it wants to differ (pass `cfg = {...}` to `Init`/`LT.New`; the "pre-v16 ... pinned" overrides in
`candidates/LINE_CLICK` etc. show how). Modules with no user left were moved to `archive/framework/`.

**Used by LINE_CLICK_v16** (and so by v17 / LINE_BOMB):

| Group | Module | Job |
|---|---|---|
| Economy | `line_crew` | the line: slots of mex/wind/nano from the commander outward |
| | `con_broker` | every air con (T1 and T2) has one owner; jobs (grid, retrofit, silo, energy cell, consolidation, second lab, line nano rebuild, nano crew, helpers) register `AddJob{prio, tier, want, start, sessions, produce}` and the broker hands out cons by priority / nearest, keeps the reserve + T2 hold, preempts helper jobs, runs the placer sessions and frees the builder when one ends; `defense_crew` seizes cons through `pool`. Con orders to labs go through `lab_broker` (`WG.LabBroker`). Header of the file shows how to add a job. Test: `tests/test_con_broker.lua` |
| | `line_transition` (+ `line_transition/*.lua`) | the sequencer (air lab, vehicle lab, spine host) over one module per job: `grid_core` / `grid_interrupts` / `grid_helpers` / `grid_retrofit` / `grid_recovery`, `energy` (push, consolidation, fusion helpers), `nano_crew`, `silo`, `line_recovery`, `second_lab`, `t2bot_lab`, `rez_lab` (a reserved T1 bot lab on the line for the rez floor, `REZ_LAB`, 2026-10-25), `spam_lab` (a T1 bot lab + 4 nanos for the army groups' spam element, `SPAM_LAB`, 2026-10-30), `line_decoy`, `radar_posts`, `spine_cons`, `con_orders`; each registers its con_broker job under a section |
| | `eco_planner`, `spend_governor` | look-ahead for what a grid builds next; army-share governor (used by `line_transition`, `spine`) |
| | `defense_crew` | flak / anti-nuke / silos the grids do not build themselves |
| Army | `spine` | stack of unit-producing grid cells seeded by the vehicle lab |
| | `click_army` | human-style attack groups going for enemy build power / eco / commander |
| | `slow_front` | Lashers / Pounders / rez bots (the slow group) |
| | `army_groups` + `support/` | (2026-10-30) the army as **group records** (one per click_army attack group, kind `raid` / `slow`, plus the `stage`) and the **support elements** each kind opts into, each a fixed size ("enough", not a stance share): `aa` (flak truck / Lasher behind the group), `spam` (Grunts from the spam lab ahead of it), `rez` (adopted rez bots: repair / reclaim for that group, a rez_broker job), `antinuke` (a Savior with it once an enemy silo is seen), `jammer` (coreter over it), `scout` (a scout_net run over its target every N s). unit_runtime option `SUPPORT = { raid = {...}, slow = {...}, stage = {...} }`, a stance's `plan.group_support` replaces it; units are owned with army_broker roles `SUP_*`; the labs build to `WG.MetalBot.support` (lab_rules `group-support`, `spam-lab`; `SUPPORT_FROM_BUDGET` charges them to the army share); `[SUP]` rows. A new element = one file in `support/` + its name in `army_groups.ELEMENTS`. Notes: `knowledge/bots/support_elements_2026-10-30.md` |
| | `line_fight`, `army_broker` | spine push/retreat logic; single owner of orders to combat units |
| | `perimeter_guard` | DRAGON_ECO: defenders hold a ring round our furthest buildings and answer intruders inside it (`pg.clusters`); selected by the stance plan `army = "perimeter"`. Test: `tests/test_perimeter_guard.lua` |
| | `maneuver_defence` | CORE (stance plan `army = "maneuver"`): the army stands in blobs on the perimeter 10 s of move speed apart, sends ~2x an incoming group's value to meet it (behaviors/intercept.lua's meeting point; the `shadow` behaviour keeps groups in view), and walks every unit back to its post afterwards; slow units are the backstop. Options: the stance's `plan.maneuver = {...}` over `MD.CFG`. Test: `tests/test_maneuver_defence.lua` |
| | `metal_sink` | the metal sink (was dragon_lab): sink spots in front of the spine, the lab for the sink unit, decoy room, energy ratio; DRAGON_ECO: T2 air labs that make Dragons (site, con-broker job, helpers, `WG.DragonLab(s)`). Tests: `tests/test_dragon_lab.lua` |
| | `unit_clock` | per-unit command frequency: tiers 0.5 / 1 / 2 Hz (scouts and quiet guards / normal / raiding or enemy near) and a per-unit phase, so orders spread over the second; used by `army_broker` (`SetClock`, `Flush`, `UpdateClock`); RAID_BOT only |
| | `idle_value` | (2026-10-29) is the army doing anything: a unit not within 15 s of a comparable amount of enemy value is idle and its worth decays (80 s); unit_runtime publishes it (signals `army_idle_frac` / `army_value_eff` / `army_wasted`, `[IDLE]` rows), ledger_logger logs it (`[LED] spend` `army_idle=` `wasted=`) |
| | `air_transport` | (2026-10-29) move one unit with an air transport: `AT.Move` (LOAD_UNITS + queued UNLOAD_UNIT), `AT.Update` follows it to done / failed, `AT.CanCarry` from mass / size; not used by a bot yet; engine test `tests/engine/transport_test.py` |
| | `lab_broker` | single owner of factory queue orders: a bot registers WANTS (priority, mode empty / ahead / topup / tail, `pick(lab)`), the broker does the queue read, tail order, insert-ahead with its pending gate, grace and depth fill, and logs `[LB]` orders per want; used by RAID_BOT's `lab_controller` (test `tests/test_lab_broker.lua`) |
| | `raid_response` | what the army does when enemies are behind the line: intruder groups, who answers (up to NEED_MULT x their value), intercept / stun / Wasp split, release as raiders die (cfg `KEEP_MULT`), publishes `mb.raid` / `mb.airLosses`; RAID_BOT and STANCE_BOT (`tests/test_raid_response.lua`) |
| | `bot_config` + `presets/` | `BC.Preset("<module>", "GROUP", ...)` merges named option groups (`presets/<module>.lua`); `BC.Apply` merges a bot's overrides into a module's defaults, logs `[CFG] <module> (<bot>): N changed -- ...` and warns about options that are not in the defaults (`tests/test_bot_config.lua`) |
| | `air_wing` | standing air wing (fighters, bombers) |
| | `rez_crew`, `raid_group`, `endgame`, `commander_guard` | rez/reclaim bots, raiders, "find and kill the last commander", commander evasion |
| Intel | `enemy_intel`, `recon_plan`, `scout_plan`, `scout_lanes`, `scout_rings`, `scout_net` | remembered enemy info (`EI.Groups` = the enemy's unit groups with value, range and last sighting); scouting before and after contact; `scout_rings` = vision rings round our buildings, pushed out while scouts survive (STANCE_BOT); `scout_net` = CORE's scouting after the `scout_lanes` FIND phase: requests (the `WG.ScoutNet` API), sacrifice runs at stale enemy groups, scout/radar watch posts just outside a group's guns, one perimeter ring, a sweep; tests `test_scout_net.lua`, `test_scout_net_bot.lua` |
| | `threat_map`, `threat_log` | where we are threatened (and a log for `threat_map_viz`) |
| | `map_model`, `unit_query` | map geometry relative to our base; unit classification. `unit_query` also holds the **per-frame snapshot** (C5): `snapshot(team)` walks `GetTeamUnits` once per game frame and everyone shares it (`ids`, `defOf`, `byDef`; `units_of`, `count_of`, `structures`, `enemies`, `get_by_role`); kept on `WG.UQSnap`, and ended early when the unit count changes. Add a new "count / find my units" need here, not another `GetTeamUnits` loop |
| | `value_weights` | what a unit is WORTH when it dies (2026-10-25), for the fight ledger: army = cost, eco = cost + 60 s of income, build power = 3 x cost + 60 s of throughput, commander 25k; every number in `M.CFG`. `Value(defID, progress)` -> value, category. Test: `tests/test_value_weights.lua` |
| | `build_tree` | **who can build what** (C1), cached per defID: `Options` / `CanBuild`, the one definition of `IsGroundCon` / `IsAirCon` / `IsNano` / `Tier`, `LabsFor` / `CheapestLab`, `Placers` / `NeedsAir`, `ConsMadeBy` / `ConMadeBy`, `EnablerLab` / `Prereq`. `blueprint_placer.CanBuild`, `slot_spine`, `metal_sink`, `line_transition` and both lab controllers use it. Test: `tests/test_build_tree.lua` |
| | `roles` | **unit roles per faction** (C4): `Roles.Get("decoy")` -> `cordecom`, ... Cortex filled, Armada an empty table (missing entries fall back to the Cortex name with a log row). `tests/check_role_names.py` fails on a new unit-name literal in `bar_framework/` (baseline `tests/role_name_baseline.json`; `--save` after a deliberate blueprint literal). Test: `tests/test_roles.lua` |
| | `eco_ledger` | **spend / energy / unit cap** (C3): `Saturated` / `Surplus` (spine saturation, one threshold table), `EnergyTarget` (EP_RATIO override, else the registered consumers' blend), `CapLeft` / `CapSlack`, `DecoyDemand`. Consumers register on `WG.EcoLedger` (`slot_spine` capacity, the sink's energy per metal). Test: `tests/test_eco_ledger.lua` |
| | `con_broker` pools | **ground cons through the broker** (C2): `CB.AddPool` / `CB.TakeAny` / `CB.GiveBack` / `CB.RemoveJob`. `slot_spine` registers its ground cons as pool `spine-ground` (`PoolTake` / `PoolGive` / `PoolCount`); the sink and the line decoy labs borrow through `TakeAny`, only the borrower can give a con back, a resident comes back as a resident, and `CB.Status` lists who holds what |

**Used by shared files rather than a bot:** `escape_guard`, `nano_broker` (by `blueprint_placer.lua`), `resource_utils`
(documented in `agent_harness.py`).

**Strategy framework (2026-10-12, not wired into a bot yet):** `behavior_host` + `behaviors/` (plug-and-play unit control, see
`behaviors/README.md`), `slot_spine` (nano blocks + lab slots, labs chosen from the comp; replaces `spine` for new bots), `strategy` (stances + run-time hooks for share, stance switch and unit weights), `game_state` (the one state
table the hooks read), `stance_loader` (stance files, value-deficit pick with weights). Tests: `test_behavior_host`, `test_strategy`.

**Config-driven controllers (2026-10-16):** `macro_runtime.lua` and `lab_rules.lua` are RAID_BOT's macro and lab controllers moved into the
framework, unchanged except that the numbers and tables are overridable. A bot's controller is the widget's `GetInfo` plus
`MACRO.Install(widget, WG, { ...overrides... })` / `LAB.Install(widget, WG, { ... })` (`WG` is passed in because an included file does not see
the widget's own `WG`; `false` switches a stance off, `nil` means "absent"; an unknown key logs `[CFG] ... (typo?)`). The keys are `M.DEFAULTS` in
`macro_runtime.lua` and `M.TUNABLES` / `M.TABLE_OPTIONS` in `lab_rules.lua`. `candidates/CORE` is the first such bot; `python order_check.py check
--only CORE` proves it plays exactly like RAID_BOT (93,168 orders identical, eco_sim seed 2). Still inline and not configurable: Cortex unit names in
the lab rules (knowledge/plans/tasks_2026-10-16.md C4) and the strategy wiring's RAID_BOT shape (cap_switch -> game_plan chain, income_mix weights).
DRAGON_ECO's extras (income_switch, metal sink, line-con hand-over) and STANCE_ECO2's older lab controller are not covered yet.

**Metal sink in CORE (opt-in):** `SINK = true` in both `MACRO.Install` and `LAB.Install` (see `candidates/CORE_SINK`) adds `metal_sink.lua` (sink labs, decoy commanders, Dragons via `SINK_EXTRAS` injected into every stance). Default is off and CORE stays order-identical to RAID_BOT (`order_check.py check --only CORE`). Limits: decoys come only from the spine's T2 bot labs; CORE has no perimeter guard, so `dragon_defend` gets no intruders; RAID's `EP_RATIO=15` overrides the sink's energy ratio.

**DRAGON_ECO (2026-10-14):** options that default off, so other bots are unchanged:
- **`strategy_hooks.income_switch`:** take a stance once smoothed metal income holds a threshold for `hold_s` (one-way).
- **`slot_spine`:** `RECLAIM_UNNEEDED` clears a lab the plan dropped (slot or adopted) once a lab for the new comp stands; `Front()` gives the spine's facing and block anchors.
- **`defense_crew`:** `COVER_FIXED_ONLY` (every cover point gets a static corfmd, no Saviors), `COVER_REPLACE_MEX` (the corfmd replaces the nearest grid mex).
- **`line_transition`:** `T.noConLabs[labID]` keeps a lab out of the T2 con orders (the Dragon lab); `LT.OnUnitDestroyed(T, id, attackerID)` passes the killer on to the spine.
- **`slot_spine`:** `REBUILD_NANOS` (+ `REBUILD_DELAY`, `REBUILD_SAFE_R`, `env.Safe(x, z, r)`): a nano an enemy destroyed is queued again at its spot once nothing threatens it. Labs were always rebuilt (the planner refills a freed slot); nanos and storages of a finished block were not.
- **Stances:** `plan = { army = "perimeter" }` (unit controller: the perimeter planner instead of click_army / slow_front) and `extras = { {n, behaviors, cfg} }` (units the stance does not build through the spine but whose behaviours it assigns: the Dragons). `strategy:BehaviorsFor` reads them.
- **Behaviours:** `dragon_raid` (waves of `wave`; target the commander, else build power, else anti-air, else the closest eco) and `dragon_defend` (waiting Dragons fight intruders inside the perimeter, else gather at the Dragon lab). Test: `tests/test_dragon_behaviors.lua`.

**RAID_BOT (2026-10-13, game review):** options that default off, so other bots are unchanged:
- **`click_army`:**
  - `EARLY_LAUNCH` / `LAUNCH_RATIO_EARLY` / `BLIND_LAUNCH` / `MIN_GROUP_UNITS`: small groups leave early, and a group needs at least 3 units.
  - `LAB_EXIT_R/W`: fresh units at an enemy lab do not steer the legs.
  - `ENGAGE`: COMMIT to build power next to a group, or ESCAPE to the line front, when surrounded or losing.
  - `HOLE_FIND`: approach from the least defended point on a ring round the target, and scout the unseen points.
  - `SetMode("hold")`, `TradeSummary`.
  - `FIGHTER_POST`: fighters wait behind the front, out of enemy AA (`M.FighterPost`, also air_wing's `station` hook).
  - `SCOUT_ROUTE`: scout requests follow the route and look at the target.
- **`strategy_hooks`:**
  - `game_plan`: raid → hold when behind and the raids trade badly.
  - `chain_switch`.
  - `income_mix`: tilts units tagged `mass` / `quality` by income.
- **Stances:** `plan` (`Strategy:Plan()`) and per-unit `tag`.
- **`game_state`:** `armyRatio`, `trade`, `airSuperior`.
- **`line_transition`:**
  - `CON_HOLD` stops air/T2 con orders during a ground raid.
  - `GRID_RECOVER` rebuilds grids whose mex spots stay empty.
  - `SECOND_AIR_LAB` builds a second T1 air lab on the finished line.
- **`behaviors/range_kite`** (see `behaviors/README.md`).
- Tests: `test_raid_army`, `test_raid_plan`, `test_con_hold`, `test_grid_recover`, `test_raid_bot`.

**LINE_BOMB only:** `phase_plan`, `bomb_run`, `lab_recycler` (LINE_BOMB's lab controller also uses `stance_loader`).

Deploy list: `deploy.ps1`. Tests: `tests/` (see `tests/LUA_TESTING.md`).

Cross-widget state (`WG.*`): see `WG_CHANNELS.md`.

**Maneuver defence on CORE (2026-10-16):** the stance's `plan.army` picks the army module in CORE's unit controller: `raid` / `hold` = click_army (unchanged), `maneuver` = `maneuver_defence.lua` (units that carry the `shadow` behaviour stay with the behaviour host). `macro_runtime` takes `INCOME_SWITCH = {to =, income =, hold_s =}` (a T1 stance to a T2 one) and `HOLD_STANCE` / `LATE_STANCE = false` to switch those off. `candidates/DEFENCE_BOT` is CORE plus that config: stances `standard_t1_defence` (Brutes, Pounder backstop, Rascal shadows) and `standard_t2_defence` (Tigers + Tzars). Tests: `test_maneuver_defence.lua`, `test_defence_bot.lua`, `test_shadow.lua`. A stance change that involves the maneuver plan (into it, out of it, or T1 -> T2 defence) RELEASES the ground army: CORE's `StanceHandover` forgets every ground combat unit, blob unit and shadow in every controller and registers it again like a new unit, so the new stance's plan and behaviours take it (`[UnitCtrl] ... units released to the ... plan` row; a Rascal that stops shadowing becomes a scout). Other stance changes (raid_open -> hold ...) are unchanged. The T2 stance builds no Rascals, so shadows are replaced only while T1 plants make them.

**Radar for the maneuver plan (2026-10-16):** `line_transition/radar_posts.lua` (con_broker job `radar`, option `RADAR_POSTS`, on by default but inert without blobs) has a free air con build a `corrad` 200 elmos behind each blob post that has no radar within 900 (the unit controller publishes the posts as `WG.MetalBot.blobs`). Radar dots (contacts with no unit type) count 60 each in `maneuver_defence` (`BLIP_VALUE`; two dots make a group worth meeting, one does not; flying dots are skipped), and a `shadow` with nothing in sight goes to look at the nearest ground dot (`ctx.BlipsNear`, mode `investigate`). Shadows now keep the enemy at 85% of their sight (`edge`).

**CORE_HUMAN / manual control (2026-10-25):** `macro_runtime` option `MANUAL_STANCES = { names }` loads those stances, replaces the automatic switch chain with one that applies `WG.StanceRequest`, wraps `army_share` so `WG.ArmyShareRequest` overrides it, and publishes `WG.StanceChoices`; `stance_panel.lua` (repo root, a general widget) draws the buttons. `lab_rules` option `SHURI_LIFT_ALWAYS` keeps the Shuriken floor ahead of the air lab's owed cons all game (no unit controller means no raid signal to lift the hold). `build_tree.ConsMadeBy` and `macro_runtime.FindConBotDefID` only count a ground builder that can place a factory or a mex (`BT.PlacesEconomy`): the Trapper (`cormlv`, mines only) was picked as the vehicle plant's con. Notes: `knowledge/bots/core_human_2026-10-25.md`.

**Ledgers (2026-10-25):** `ledger_logger.lua` (repo root, a general widget like the stats tracker) logs `[LED]` spend / fight / value / scout rows; `ledger_report.py` reads them. `knowledge/ledgers.md`.
