# bar_framework

Shared modules the bot controllers load with `VFS.Include("LuaUI/Widgets/bar_framework/<name>.lua")`
(`deploy.ps1` copies them into BAR's widget folder). Module defaults are LINE_CLICK_v16's settings; a bot overrides a
default only when it wants to differ (pass `cfg = {...}` to `Init`/`LT.New`; the "pre-v16 ... pinned" overrides in
`candidates/LINE_CLICK` etc. show how). Modules with no user left were moved to `archive/framework/`.

**Used by LINE_CLICK_v16** (and so by v17 / LINE_BOMB):

| Group | Module | Job |
|---|---|---|
| Economy | `line_crew` | the line: slots of mex/wind/nano from the commander outward |
| | `line_transition` | air lab, then mex/wind/nano grids, retrofits, energy push/cells, silo capstones, unit-cap relief |
| | `eco_planner`, `spend_governor` | look-ahead for what a grid builds next; army-share governor (used by `line_transition`, `spine`) |
| | `defense_crew` | flak / anti-nuke / silos the grids do not build themselves |
| Army | `spine` | stack of unit-producing grid cells seeded by the vehicle lab |
| | `click_army` | human-style attack groups going for enemy build power / eco / commander |
| | `slow_front` | Lashers / Pounders / rez bots (the slow group) |
| | `line_fight`, `army_broker` | spine push/retreat logic; single owner of orders to combat units |
| | `air_wing` | standing air wing (fighters, bombers) |
| | `rez_crew`, `raid_group`, `endgame`, `commander_guard` | rez/reclaim bots, raiders, "find and kill the last commander", commander evasion |
| Intel | `enemy_intel`, `recon_plan`, `scout_plan`, `scout_lanes` | remembered enemy info; scouting before and after contact |
| | `threat_map`, `threat_log` | where we are threatened (and a log for `threat_map_viz`) |
| | `map_model`, `unit_query` | map geometry relative to our base; unit classification |

**Used by shared files rather than a bot:** `escape_guard`, `nano_broker` (by `blueprint_placer.lua`), `resource_utils`
(documented in `agent_harness.py`).

**LINE_BOMB only (in progress):** `phase_plan`, `stance_loader`, `bomb_run`, `lab_recycler`.

Deploy list: `deploy.ps1`. Tests: `tests/` (see `tests/LUA_TESTING.md`).
