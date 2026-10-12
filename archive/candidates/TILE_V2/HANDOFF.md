# TILE_V2 slot tiles: handoff notes (2026-10-06)

## State
- Source of truth: `candidates/TILE_V2/macro_controller.lua` (CFG `TILE_STYLE="blueprint"`). `candidates/TILE_V2_slots/` is the generated copy with `TILE_STYLE="slots"` (regenerate with the scratchpad `mk_slots.py`: it only swaps `TILE_STYLE` and `LINES_FOREVER`). If that script is lost, copy the three files and edit those two lines.
- Deploy on this PC: `powershell -File deploy.ps1 -Bot candidates\TILE_V2_slots`. The last deploy included the latest changes below. NONE of the latest changes has been run in a real match.
- Tests (all passing at the end): `tests/test_slot_tile.lua` (418), `tests/test_tile_bot.lua` (159), `tests/test_slot_smoke.lua` (modes: none = 22, `early` = 26, `lines` = 22). Run through lupa (`lupa.lua51`) with cwd = repo root.
- `TILE_BOT/` is untouched. `candidates/TILE_V2_base` = pre-early-eco baseline for benchmarks.

## Latest changes (untested in the engine)
1. **Longer lines:** `CFG.LINE_EXTRA_ROWS=4`. `SC.EXTRA_ROWS` makes `UpdateBounds` reserve 4 more strip rows from the start (so spine/grid cells avoid them). Rows are added when free slots < MIN_FREE + 4*cons; `AddStripRow` refuses j >= STRIPS_Z+EXTRA_ROWS and the map margin. On refusal `noMoreRows` is set and the reservation is released.
2. **Helper air cons replace the transport lift:** `CFG.SEED_METHOD="helpers"`, `SEED_AIR_CON_CAP=3`, `HELPER_NANOS=2`, `HELPERS_PER_GRID=2`. `StartGridExpansion` queues 3 air cons. In `UnitFinished`, an air con that arrives while a grid with a live builder has < 2 built nanos becomes a helper (`AC.HelperTarget/AddHelper`). It gets CMD.GUARD on the grid's con 35 frames later (after the lab's own guard order lands), is re-guarded if idle, and is released into `freeAirCons` + `AC.TryAssign` once the grid has >= 2 built nanos. Logs: `[MC] air con N helps con M ...`, `[MC] helper air con N released`. `SEED_METHOD="lift"` keeps the nano_lift/transport version (`bar_framework/nano_lift.lua`).
   - Possible problems to check: the `pendingStops[#pendingStops]=nil` line drops the last queued stop (assumes it is the one just added); helpers count against the air-con cap until `normalGrids`; guard may not assist nano builds the way a direct assist would. If guard does not work, use `CMD.REPAIR` on the con's current build target or `Spring.GiveOrderToUnit(CMD.GUARD)` on the nano itself.

## Open problems (from real games)
- Slot design economy was below the fixed-tile design in single matches (about 6.8-7.6k metal used @5:00 and 15.7-22.5k @7:30 vs 8.3-9.1k / ~25k for tiles, n=8).
- The first grid never reached 10 nanos, and 2-3k metal sat banked from ~4:30 (one air con, idle line nanos, commander walking). Mid-game BP starvation after the lines finish.
- Single matches are noise: use `eco_bench.py` (n mirror matches) and `ab_test.py`. TreeServer can run these in parallel.

## Human replays used as a guide
Demos are in `%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\demos\` (map Full Metal Plate 1.7).
- **`2026-10-06_03-38-02-508_...sdfz`** (played 23:43 on 2026-10-05): the user's own game that the slot design is modelled on. Spent well for the first ~3 min, then dipped. It is a one-player game with no recorded team stats and its infolog was overwritten, so the post-3:00 dip has no numbers. The lane/lab/seeded-grid design came from the user's description of it.
- The user also pointed to "the last replay vs BarbAI" and "the latest replay" where the bot keeps up with the user's eco until the user walks across the map and kills it. Which files those are was NOT recorded. Likely candidates are the newest demos (`2026-10-06_04-55-50`, `2026-10-06_05-10-09`, `2026-10-06_02-34-40`), but ask the user to confirm.
- Reading them: `python replay_analysis.py "<path>.sdfz" --no-history`.

## Design reminders
- Slot block: 2x2 strips of 16x25 cells, lanes per side, one builder per lane, commander on the other side of the first con, air lab in a reserved bay inside the rows, no "skip at 90% built" for these blocks (user's instruction), no early frame hand-off, never abandon a "building" frame.
- User preferences: tests games themselves; "Deploy it here" = deploy.ps1 on this PC; don't touch TILE_BOT; macro is at the 200-locals limit (put new helpers on `TS`/`AC` tables); a function may use at most 60 upvalues.
