# MetalBot

A bot for the RTS [Beyond All Reason](https://www.beyondallreason.info/) (BAR), written as Spring engine Lua widgets and developed
headlessly: matches run with no display, so changes can be benchmarked automatically.

The goal of this repo is **CORE**, a strong, configurable baseline bot. CORE plays the whole game (economy, scouting, defence, army
production, army control). A *strategy* is a small config on top of it, so trying a new idea means writing a few lines, not a new bot.

- [Quick start](#quick-start)
- [How CORE is put together](#how-core-is-put-together)
- [Swapping the strategy](#swapping-the-strategy)
- [Testing a change](#testing-a-change)
- [Repository layout](#repository-layout)
- [Further reading](#further-reading)

## Quick start

You need Windows, a Beyond All Reason install (the harness finds it under `%LOCALAPPDATA%\Programs\Beyond-All-Reason`),
Python 3 and PowerShell. Optional: `pip install lupa` (Lua unit tests, `eco_sim.py`), and Node.js + `npm install` (replay analysis).

```powershell
.\deploy.ps1                                  # copy CORE and the framework into BAR's LuaUI\Widgets
.\deploy.ps1 -Bot candidates\AIR_TIMING       # ...or another bot folder

# one 10-minute headless game, CORE (slot 0) against an opponent that builds nothing
python bot_testing.py --bot1 candidates/CORE --bot2 INACTIVE_BOT --server single --end-minutes 10

# the economy simulator: the real bot code against a simulated engine, ~25 s for a 20-minute game
python eco_sim.py run --bot candidates/CORE --seeds 1-4 --no-vacuum
```

To play it in the real game, deploy it, then enable the Macro / Lab / Unit Controller widgets in BAR.

## How CORE is put together

A bot is a **folder of three widgets**. In CORE each is a thin file (20-40 lines) that passes a config table to a framework module;
all the logic is in [`bar_framework/`](bar_framework/README.md).

| Widget | Runs | What it owns |
|---|---|---|
| `macro_controller.lua` | `bar_framework/macro_runtime.lua` | Economy: the commander's opening, the "line" of mex/wind slots, air labs, mex/energy grids, the unit-producing "spine" of labs and nano turrets, the metal sink, and the **strategy** (stances, army share, stance switching) |
| `lab_controller.lua` | `bar_framework/lab_rules.lua` | What every factory queues: constructors, scouts, anti-air, rez bots, defenders, and the stance's army comp |
| `unit_controller.lua` | `bar_framework/unit_runtime.lua` | Where units go: scouting, raid response, home defence, anti-air, and the army (`click_army`, `maneuver_defence`, `bomb_run`, ...) |

Every module has a `CFG` table of defaults. A bot overrides only what it wants different, and an unknown key is logged as a typo.
The keys are documented at the top of each runtime file (`M.DEFAULTS` in `macro_runtime.lua`, `M.TUNABLES` in `lab_rules.lua`, the header of
`unit_runtime.lua`).

### What every strategy keeps

These are the **background systems**. They run the same whatever the strategy is, and a new strategy should not turn them off:

- **Economy**: line, mex and energy grids, retrofits, energy and storage, grid and line recovery, capstone silos and anti-nuke.
- **Spine**: the labs and nano turrets that make units; its size follows the army share.
- **Scouting**: scouts, radar, ring and creep scouting (`scout_net`), depth scouts, the enemy-location signal.
- **Defence**: raid response, home defence, anti-air, the Shuriken floor, rez bots, commander safety.
- **Metal sink**: extra labs that turn surplus income into decoys and Dragons once the spine cannot spend it.

### What a strategy is

> **A strategy = army share + unit comp.**

| Part | Where | Decides |
|---|---|---|
| **Stances** | `stances/<name>.lua` | What the army is made of: units with a share of army spend, per-unit behaviours (`kite`, `range_kite`, `intercept`, ...), and a `plan` that picks how the army is played (`army = "hold"`, `"defend"`, `"maneuver"`, `"perimeter"`, bomber runs, ...) |
| **Army share** | `share_machine` in a machine file | What fraction of income goes to the army instead of the economy: a fixed number per node, or a hook (`match_enemy`, `v16_share`) |
| **Switching** | `stance_machine` in a machine file | A finite state machine: nodes are stances, edges are conditions over named signals (enemy located, army ratio, income, unit-cap fill, ...) |

Both machines live in one data file, `machines/<name>.lua` (CORE loads `core_default` with `MACHINE = "core_default"`). Edit it by hand or
graphically in `machine_editor.html`; the format and the signal list are in `machines/README.md` and `bar_framework/signals.lua`. A new "when"
rule is an edge or a signal, not a new hook. The older `STANCE` / `HOLD_STANCE` / `LATE_STANCE` / `PLAN` / `SHARE` options still work and are
the fallback when `MACHINE` is false or its file fails its checks.

Stance files are plain Lua tables. `stances/README.md` describes the format, and `stance_editor.html` edits them.

## Swapping the strategy

[`candidates/CORE`](candidates/CORE) is the baseline. A variant is a copy of the folder with a different config, and nothing else.
[`candidates/AIR_TIMING`](candidates/AIR_TIMING) is the worked example: CORE plus a boom-then-bomber strategy, in about 40 lines. It still
uses the older option-style switches (`BURST_SWITCH`); `machines/air_timing.lua` is the same rules written as a machine (not wired in yet).

1. **Copy the folder**: `candidates/CORE` -> `candidates/MY_BOT`. The `lab_controller.lua` and `unit_controller.lua` usually stay as they are.
2. **Write the stances** you need in `stances/` (copy `hold.lua` or `anvil_open.lua` and change the units and shares). A stance is:
   ```lua
   local M = {}
   M.name = "my_open"
   M.plan = { army = "defend" }                 -- how the army is played
   M.units = {
     { n = "corgator", share = 0.40, tag = "mass" },
     { n = "cormort",  share = 0.60, tag = "quality", behaviors = { "kite" } },
   }
   return M
   ```
3. **Write the machine** `machines/my_bot.lua` (copy `core_default.lua`): the stance nodes and the conditions that move between them, plus
   the army-share nodes. Check it with `python fsm_index.py --check machines/my_bot.lua`.
4. **Point the macro controller at it** in `MACRO.Install(widget, WG, { ... })`:
   ```lua
   NAME    = "MY_BOT",
   MACHINE = "my_bot",     -- machines/my_bot.lua
   STANCE  = "my_open",    -- opening stance (the machine's initial node should match)
   ```
   Everything not listed keeps CORE's value (`MACRO.Install` merges your table over `M.DEFAULTS`). Copy CORE's economy keys
   (`LT_CFG`, `SPINE_CFG`, `SINK*`) unchanged.
5. **Test it** (next section), then deploy with `.\deploy.ps1 -Bot candidates\MY_BOT`.

Rules of thumb:

- **Change the strategy, not the machinery.** Do not rewrite the lab or unit controller for a new strategy. New behaviour goes into the
  framework as an opt-in option (default off) or a stance `plan` field, next to what is there.
- **Do not drop a background system** because the strategy does not mention it.
- Other ready-made examples: `DEFENCE_BOT` (maneuver-defence stances), `IRON_TIDE` (boom -> hold -> Shiva push), `SHIVA_BOT`,
  `CORE_HUMAN` (empty unit controller: a person micros the army, `stance_panel.lua` picks the stance and share).

## Testing a change

| Change touches | Test with |
|---|---|
| Economy, build orders, army *production*, scouting patterns | **`eco_sim.py`**: the bot's real widgets against a simulated engine (no fighting, no enemy). `python eco_sim.py run --bot candidates/MY_BOT --seeds 1-4 --no-vacuum`, then `compare` against CORE |
| Anything where the army fights | **One real game**, long enough to see the change (10 minutes for an early-game change): `python bot_testing.py --bot1 candidates/MY_BOT --bot2 candidates/CORE --server single --end-minutes 10` |

Notes:

- `--server single` runs both bots in one engine process (about 4x faster, a third of the RAM). Several single games can run in parallel.
- Look for `Sync error` in a game log before trusting anything past about 10 game-minutes (`result["desync"]`).
- Slot 0 has an edge, and one game cannot rank two bots. For close calls use `ab_test.py` (both slot orders); `NO DIFFERENCE DEMONSTRATED`
  is the normal honest answer for a small effect.
- Results: `bot_score.py` (the state-value score phi, which also decides the end-of-match winner), `find_weakness.py` (ranks likely
  weaknesses from the stats tracker), `ledger_report.py`, `unit_report.py`, `replay_analysis.py` (needs Node).
- `python tests/run_tests.py` runs the plain-Lua unit suites (lupa). Use it after refactors. Add a new test only for something that broke
  in a real game. See `tests/LUA_TESTING.md`.

## Repository layout

```
candidates/        bots: CORE (the baseline) and variants, each a folder of 3 widgets
bar_framework/     all the bot logic: runtimes, brokers, economy, army, scouting (its own README lists every module)
stances/           unit comps / army plans a strategy picks from
machines/          state machines: when to change stance and army share (editor: machine_editor.html)
blueprints/        build layouts the economy places (+ blueprint_placer.lua, blueprints_data.lua)
ecosim/, eco_sim.py   the economy simulator
bot_testing.py, single_client.py, ab_test.py, series.py   the headless match harness
bot_score.py, find_weakness.py, ledger_report.py, replay_analysis.py   result analysis
metalbot_stats_tracker.lua, ledger_logger.lua, human_control_logger.lua   logging widgets (deployed with the bot)
tests/             plain-Lua suites (spring_stub.lua + test_*.lua) and checks
knowledge/         game mechanics, design notes per bot, session logs, scoring notes (knowledge/README.md indexes it)
archive/           retired bots, modules and tests, kept for reference, never deployed
OK_BOT, INACTIVE_BOT, RAIDER_BOT, GROUND_RAIDER_BOT   fixed opponents for tests (reference, do-nothing, two exploiters)
```

`candidates/` also holds older bots (`LINE_CLICK_v16`, `STANCE_BOT`, `RAID_BOT`, `DRAGON_ECO`, ...). They are earlier steps toward CORE,
kept as regression opponents and as examples, and CORE supersedes them.

## Further reading

- `bar_framework/README.md`: what each framework module does and who uses it; `WG_CHANNELS.md` for cross-widget state.
- `knowledge/README.md`: index of the design notes; `knowledge/eco_sim.md` for the simulator; `knowledge/scoring.md` for phi.
- `CLAUDE.md`: working notes for AI-assisted development of this repo (testing policy, measurement rules, history).
- Game mechanics: `knowledge/game_mechanics.md`, `knowledge/economy_numbers.md`.

Licensed under the GNU GPL v3 (see `LICENSE`).
