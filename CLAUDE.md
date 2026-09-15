# MetalBot — Beyond All Reason Bot Development

## What this project is

MetalBot is an AI bot for the RTS game Beyond All Reason (BAR), implemented as Spring engine Lua widgets. The bot runs headlessly (no display) in a dedicated test harness (`bot_testing.py`) so it can be developed and benchmarked automatically.

## Bot structure

A bot is a **folder** containing three Lua widget files:

| File | Responsibility |
|---|---|
| `macro_controller.lua` | Economy: commander build order, mex expansion, factory placement |
| `lab_controller.lua` | Factory queues: what units each lab builds and in what ratio |
| `unit_controller.lua` | Combat/scouts: where units move and how they fight |

The existing bot is `OK_BOT/`. Copy it as a starting point for a new bot.

### Key Lua API calls used by bots

```lua
Spring.GetMyTeamID()           -- returns 0 or 1 (patched at test time)
Spring.GetTeamUnits(teamID)    -- list of unit IDs for a team
Spring.GetUnitDefID(uid)       -- unit definition index
Spring.GetUnitPosition(uid)    -- x, y, z world coords
Spring.GiveOrderToUnit(uid, CMD.MOVE, {x,y,z}, {})
Spring.GiveOrderToUnit(uid, CMD.FIGHT, {x,y,z}, {})
Spring.GetTeamResources(teamID, "metal")  -- returns current, storage, pull, income, expense
UnitDefs[defID].name           -- unit internal name (e.g. "cormex", "corcom")
UnitDefs[defID].customParams.iscommander  -- true for commanders
```

Widgets respond to Spring callbacks:
- `widget:GameStart()` — game clock begins
- `widget:GameFrame(n)` — called every frame (30 fps game-time)
- `widget:UnitCreated(uid, defID, teamID, builderID)`
- `widget:UnitDestroyed(uid, defID, teamID, attackerID, ...)`
- `widget:UnitFinished(uid, defID, teamID)`

## Running a test

### Locally (Windows)

```powershell
cd C:\Users\malco\OneDrive\Documents\GitHub\MetalBot
python bot_testing.py --bot1 OK_BOT --bot2 MY_BOT --duration 300 --save-replay
```

- `--bot1` / `--bot2` — folder names (relative to repo) or absolute paths
- `--duration` — real-wall-clock seconds to run (game runs at 100x speed internally)
- `--save-replay` — saves a `.sdfz` replay to BAR's demos folder

### On Pi 1 (dme43@192.168.1.170)

Pi 1 is fully set up with the ARM64 BAR engine and a copy of the repo at `~/MetalBot`.

```bash
ssh -i ~/.ssh/id_ed25519_nopass dme43@192.168.1.170 \
  "cd ~/MetalBot && BAR_DATA_DIR=/home/dme43/bar_data python3 bot_testing.py \
   --bot1 OK_BOT --bot2 MY_BOT --duration 300 --save-replay"
```

After the game, copy the replay back:
```powershell
scp -i ~/.ssh/id_ed25519_nopass `
  "dme43@192.168.1.170:/home/dme43/bar_data/demos/*.sdfz" `
  "C:\Users\malco\AppData\Local\Programs\Beyond-All-Reason\data\demos\"
```

### On Pi 2 (iamtree@192.168.1.172)

Pi 2 has SSH key auth set up but **has not been provisioned** with BAR data or the MetalBot repo yet. Before running tests on Pi 2, you need to provision it the same way as Pi 1 (copy engine, maps, packages, pool, rapid dirs, and the repo). See the Pi 1 setup history in git log / conversation history.

## Reading test results

The test prints a summary at the end:

```
Non-commander units built:
  Team 0 (BOT_A): 758    ← more units = better economy/production
  Team 1 (BOT_B): 602

Sanity checks:
  [PASS] Team 0 built 758 non-commander unit(s)
  [PASS] Team 1 built 602 non-commander unit(s)
```

- **Units built** is the primary metric — more units = stronger economy and production pipeline.
- If a team built 0 units, the bot crashed or failed to connect.
- The game ends when a commander dies (if self-d triggers) or when `--duration` real-seconds elapse.
- Game runs at ~100x speed; 300 real-seconds ≈ 8 game-hours of simulation.

## Deploying changes

After editing any Lua file, run the deploy skill so changes are reflected in the BAR widget folder:

```
/deploy
```

Or the deploy skill runs automatically when a `.lua` file is created or modified.

## Project layout

```
MetalBot/
  bot_testing.py       — test harness (run this to test bots)
  OK_BOT/              — reference bot (Cortex faction)
    macro_controller.lua
    lab_controller.lua
    unit_controller.lua
  blueprint_placer.lua — shared helper (mex grid expansion)
  blueprints/          — mex grid layout data files
```
