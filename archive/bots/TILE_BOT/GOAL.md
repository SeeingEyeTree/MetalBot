# TILE_BOT

DRAGON_BOT's macro controller with its early game replaced by a human player's opening. That
player reached ~29-30k metal spent by 7:00-7:30 and never banked. DRAGON_BOT reaches ~20k and holds
~2k metal (sometimes floating) while it hands off from its spiral kick-starter to the mex grids.

**Army side from SPINE_BOT**: the GitHub Desktop stash of 2026-10-04 18:08, which is newer
than origin/main's v0.2. It adds T2/T3 labs held until ground army value >= lab cost, army share
from 3:00 (its early air-con cap of 3 and its adoption of the opening's con bots are not used
here: the cap starved the grids while metal floated, and the cons are reclaimed instead),
Shurikens kept home (`RG.NEVER_RAID`, set by the unit controller), and `NANO.PRIO.SPINE`/`Park`
(v0.2's spine called them but its nano_broker lacked them).

Air cons go to the FRONT of the air lab's queue (`CMD.INSERT`), ahead of fighters.
- `lab_controller.lua` and `unit_controller.lua` are SPINE_BOT's, unchanged.
- `bar_framework/spine.lua`, `bar_framework/line_fight.lua` and `blueprints/general/T1-3Spine.lua`
  came over with them.
- The macro controller carries SPINE_BOT's hooks: no army/eco nano balancer, the spine starts at
  the hand-off, it gets first call on new air cons, and it sets `WG.Spine` for the lab controller.
- The spine's base is the tile block's grid cell whose spine stack lands wholly outside the block,
  nearest the enemy (`SpineBase`).
- The opening's bot lab only counts `corck` from itself as tile cons. SPINE's lab controller also
  makes rez bots there after 5:00.

Everything else after the air lab (mex grids, retrofits, consolidation) is DRAGON_BOT's.

Reference replay: `2026-10-05_16-54-20-711_Full Metal Plate 1.7_2026.07.04.sdfz` (player vs
NullAI): 8.6k metal used at 5:00, 13.0k at 6:00.

## The opening

1. **Commander** builds `blueprints/general/bad_com_start.lua`: mex, mex, wind, wind, bot lab
   (facing east, as in the replay), 3 wind, nano, 2 mex, 4 wind, radar.
   - It cannot build the nano. Con #1 builds it while the commander guards con #1.
   - Afterwards the commander assists the lab while a con is queued, otherwise the nearest con
     still building.
2. **Tile block** (`bar_framework/tile_crew.lua`): a 4x4 grid of 240-elmo tiles. The commander's
   tile sits in the second row; every other tile is `blueprints/general/con_bot_grid.lua`.
   - **4 con bots, one per row.** Con #1 takes the row beside the commander. Each next con is
     queued only when metal reaches 130, or 45 s after the previous one.
   - A con walks to its tile's standing point (tile-local (8, 32)), where every building is in
     range, then builds the tile without moving.
   - Interrupts choose its next job: wind on a projected energy stall, mex on a metal stall, and a
     nano when metal banks (>= 300 and >= 25% of storage; this one never preempts).
   - **Direction:** rows grow away from the map centre along the enemy axis, and columns grow
     toward it. The tiles turn with the columns. In the reference replay this gives rows +z and
     columns +x, which is what the player did.
3. **Hand-off:** at >= 40 m/s metal income, held for 5 s, an air lab goes into the open area of
   the finished tile nearest the commander.
   - Never in row 0: each row's open areas join into one corridor, and row 0's corridor is how
     the bot lab's units get out.
   - The mex grids then grow from the block's edges; the block is exactly 2x2 grid cells.
   - Every free cell around the block is open to the mex grids from the start, including both ends
     of the rows (two grids per side, each against two tiles). Nothing is held back for the cons.
   - Once the air lab is up, the opening's builders are retired. The bot lab is reclaimed by the
     nanos around it, and the lab controller is told to leave it alone (`WG.TileLabHold`).
     Each con is reclaimed where it stands when it finishes its row. No more cons are queued.

## Measured so far (2026-10-05, vs NullAI, metal used at 7:30)

- **30.9k** (14:46 game): 1-2 grids open before 6:00, the commander and nanos helping the tile
  rows, rows done by 7:10. This is the shape to keep.
- **23.9k** (15:16 game): 6 grids opened at 4:00, and every nano in reach plus the commander was
  pulled onto the air lab. Income was flat at 68 m/s from 5 to 6 min with 1.3-1.7k banked, and
  the rows finished a minute late.

**Consistency** (headless TILE_BOT mirror matches to 8 min, metal used at 7:30, 8 samples per
row; these run lower than local games vs NullAI because the two bots fight):

| Version | Mean | sd | Range |
|---|---|---|---|
| Baseline (2026-10-05 evening) | 22.6k | 1.25k | 21.1-25.1k |
| Tile "bank -> nano" interrupt removed | 23.9k | 1.10k | 21.5-24.8k |
| + banking with no cell waiting offers cells next to any assigned grid | **25.2k** | **0.76k** | 24.1-26.0k |

The runs split on whether tile cons switched to building nanos when metal banked at about 4:00,
which stalled the rows. Later, air cons sat idle with 2k banked because new cells only appeared
once a grid had 7/12 nanos. Your own reference game (2026-10-04 16:16 vs BARb) used 28.5k at
7:00 and 34.8k at 7:30.

Earlier, that led to three changes:
- Grid pacing: `GRIDS_OPENING` = 2, plus one per 15 s while banking >= 500.
- The air lab only gets idle nanos, at the lowest priority, and never the commander.
- Tile interrupts rank actual energy shortage > metal > projected energy > bank.

Not yet measured.

## What should move (tracker / logs)

- `metal_pull_avg` vs `metal_inc_avg`, plus the eco row's float and stall fractions. The bank
  should stay low through 3-7 min.
- Metal used at 5:00, 6:00 and 7:00 (replay checkpoints). Targets: the human's 8.6k / 13.0k /
  ~29k.
- `[MC] con #N queued/out`, `[TC] tile ... done in Ns`, `[MC] HAND-OFF frame=`.
- `fac_boxed` / `fac_exit_ok`: the bot lab's exit corridor must stay open.

Tunables are in `CFG` at the top of `macro_controller.lua`: `CON_BANK_TRIGGER`,
`CON_FALLBACK_FRAMES`, `BANK_NANO_*` and `AIR_LAB_INCOME`.

## Shared-code changes made for it

`blueprint_placer.lua`:

- A per-state `interruptMinNanos` option (default 2, unchanged).
- A per-interrupt `noPreempt` flag.
- **Facing fix:** `RotateFacing(f, r) = (f - r) % 4`. The old `(f + r)` sent a non-square
  factory's exit the wrong way at rotations 1 and 3. Rotations 0 and 2 and all footprints are
  unchanged.
