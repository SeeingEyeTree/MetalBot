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

### Via Tailscale (recommended)

Both Pis are accessible via Tailscale. This method works from anywhere and automatically handles results:

**Pi 1** (dme43@100.68.112.80, local 192.168.1.170) — has `~/MetalBot` and `~/bar_data`; runs matches
**Pi 2** (iamtree@100.86.20.115, local 192.168.1.172) — has the USB flash drive AND `~/MetalBot`/`~/bar_data` (provisioned 2026-09-15 via a direct Pi-to-Pi tar transfer from Pi 1); runs matches too

```powershell
python remote_testing.py --bot1 OK_BOT --bot2 MY_BOT --pi-host 100.68.112.80 --save-replay
```

Options:
- `--pi-host 100.68.112.80` — Tailscale IP for Pi 1 (dme43)
- `--pi-host 100.86.20.115` — Tailscale IP for Pi 2 (iamtree)
- `--usb-mount /mnt/usb` — USB drive mount path (auto-detected; the drive currently actually sits at `/media/iamtree/USB321FD`, not `/mnt/usb`)
- `--result-dir metalbot_results` — Relative path on USB for saving results

All results/replays are archived to iamtree's USB regardless of which Pi ran the match — see `remote_testing.archive_to_iamtree()`.
- `--skip-deploy` — Skip syncing bot files (faster for iterative tests)

Results are automatically saved to USB flash drive and synced back if available.

### Direct SSH (legacy method)

For direct SSH without Tailscale:

```bash
ssh -i ~/.ssh/id_ed25519_nopass dme43@192.168.1.170 \
  "cd ~/MetalBot && BAR_DATA_DIR=/home/dme43/bar_data python3 bot_testing.py \
   --bot1 OK_BOT --bot2 MY_BOT --duration 300 --save-replay"
```

Copy replays back:
```powershell
scp -i ~/.ssh/id_ed25519_nopass `
  "dme43@192.168.1.170:/home/dme43/bar_data/demos/*.sdfz" `
  "C:\Users\malco\AppData\Local\Programs\Beyond-All-Reason\data\demos\"
```

### Pi Setup (for new Pi provisioning)

Both Pi 1 and Pi 2 have `~/MetalBot` as a real git clone (branch `bot-testing-v2`) and
`~/bar_data` with the engine + game content (aarch64 Debian 12 build). To update either
Pi with newly committed code:
```bash
ssh -i ~/.ssh/id_ed25519_nopass dme43@100.68.112.80   "cd ~/MetalBot && git pull"
ssh -i ~/.ssh/id_ed25519_nopass iamtree@100.86.20.115 "cd ~/MetalBot && git pull"
```
`git pull` only picks up committed + pushed changes — uncommitted local edits still need
manual scp. `bar_data/` is not part of the git repo.

For provisioning a brand-new Pi: install git (`sudo apt install git`), clone the repo, then
copy `~/bar_data` from an existing provisioned Pi (same architecture required — both current
Pis are aarch64). A same-LAN Pi-to-Pi copy won't work directly between these two specific
Pis ("No route to host" between their 192.168.1.x addresses) — route it over their Tailscale
IPs instead, e.g. `tar -C ~ -cf - bar_data | ssh iamtree@<new-pi-tailscale-ip> "tar -C ~ -xf -"`.

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

**Do not compare two bots with a single match.** There is a large advantage to whichever bot
is passed as `--bot1` (slot 0) — large enough that a bot beats *itself* from slot 0. Use:

```powershell
python ab_test.py --bot-a candidates/MY_BOT --bot-b pool/bots/champion_v1
```

It runs each slot order three times and only calls a winner when the two bots' runs do not
overlap at all. **`NO DIFFERENCE DEMONSTRATED` is the normal honest outcome** — log it as
that, not as a narrow win or regression.

Two separately measured reasons a single match proves nothing: the slot-0 advantage above,
and run-to-run noise between byte-identical bots.

**Noise compounds, so measure early.** Spread between identical bots, army value: 1.07x at
frame 7200, 1.14x at 14400, ~1.35x at 18000, 2.00x at 36000. `ab_test.py` defaults to **army
value at frame 14400** (8 game-min) — the latest point still under ~1.15x noise. **Detectable
effect ≈ 15–20%; anything smaller is not measurable here at any frame.** A *longer* match is a
*worse* measurement — do not raise `--duration` hoping for a cleaner signal.

Use `python checkpoint_map.py <abtest-temp-dir>` to chart signal against noise per frame when
a result is ambiguous.

- **Army metal value at frame 18000** (10 game-minutes) is the metric, not units built. Slot 0
  saturates the ~2000 unit cap in a 300s match, so end-of-match numbers can't tell two
  competent bots apart.
- Each team's numbers must be read from its own process — team 0 from P0, team 1 from P1.
  `fullview=1` does not give cross-team visibility in headless.
- If a team built 0 units, the bot crashed or failed to connect.
- Game runs at ~100x speed; a 300s match reaches roughly frame 31 000 (~17 game-minutes).
- Lua errors mentioning `gui_pip.lua` / `CreateShader` are BAR's own stock widget failing
  headless. They appear in every run and are harmless.

Everything in `knowledge/strategy_log.jsonl` logged before 2026-09-18 was measured under a
broken harness and is void — see the top of `knowledge/lessons_learned.md`.

## Deploying changes

After editing any Lua file, run the deploy skill so changes are reflected in the BAR widget folder:

```
/deploy
```

Or the deploy skill runs automatically when a `.lua` file is created or modified.

## Project layout

```
MetalBot/
  bot_testing.py       — test harness (single match; rarely what you want directly)
  ab_test.py           — CORRECT way to compare two bots: both slot orders, frame-18000 metric
  OK_BOT/              — reference bot (Cortex faction)
    macro_controller.lua
    lab_controller.lua
    unit_controller.lua
  blueprint_placer.lua — shared helper (mex grid expansion)
  blueprints/          — mex grid layout data files
```
