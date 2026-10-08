# TILE_V2 (candidate; TILE_BOT is untouched and stays the main bot)

Changes from TILE_BOT, from a review of a BARb (hard) game on 2026-10-05. TILE_BOT floated
25k metal at the storage cap from 13:30 to 24:00, never left T2, took raid damage with no
ground defence, and killed ~4k of BARb's army with 214k of its own.

| Change | File | Why |
|---|---|---|
| `float` spine policy: banked metal (>=3000 and >=25% of storage) raises army_share, up to 1 at 60%; `EXPAND_MARGIN` 1.6 | macro_controller.lua (set at spine load, `bar_framework` is unchanged) | spine spent a flat 20% of income |
| `AIR_CONS_PER_CELL` 2 | macro_controller.lua | raiders killed the first T1 spine lab 3x as a nanoframe, then no cons existed to retry it: spine stuck at 1 cell, capacity 0, all game |
| Commander evade (`commander_guard`, evade only, never retired) | macro_controller.lua | a raid of ~11 corgators killed the commander at 7:43 in one run; it dodged 3 raids in the next |
| `ASSAULT`: line units advance as one blob toward the enemy base when army >= 15k and >= 3x the enemy value (unscouted enemy presumed `1500 x minutes past 5:00`) | unit_controller.lua | the contact line crept and the army sat 3-5k from base |
| Fighter floor += armyCount/12 | lab_controller.lua | a clumped 430-unit army with 4-5 AA lost ~75k to ~20 Dragons |

Added after the first in-game test (2026-10-05, user feedback; none of this has been run yet):

| Change | File | Why |
|---|---|---|
| Con bots by metal INCOME, not banked metal: con #2 at 20 m/s, the spine's con after 2 cons are out at 30, rows 3-4 at 40 / 50 (`CFG.CON_INCOME`, `SPINE_CON_AFTER`; 150 s fallback) | macro_controller.lua | the opening sat metal-stalled at ~9 m/s; a con is 2-3 mexes delayed and adds little build power |
| The commander is a stand-in con on a tile row (mex + wind only) until cons exist (`CFG.COMMANDER_PLACES`). The con that takes its row over finishes the tile it is on, builds the rest, then a nano-only pass on tiles flagged `nanoSkipped`. It yields at the air-lab hand-off (<= 15 s) | macro_controller.lua, bar_framework/tile_crew.lua (`AddCommander`, `Yield`, `PickTile`) | placement, not just assistance, while there is one con; nanos are the one thing it cannot build |
| Spine's extra con is ordered by income (above) and starts the spine when it comes out (~3:30 in the earlier test); the vehicle plant is first in the T1 cell | macro_controller.lua | plant + 2 nanos by 5:00 (user confirmed it hit that) |
| A grid whose air con dies keeps its session and gets a replacement (`BP_PLACER.Orphan` / `Reassign`) | blueprint_placer.lua, macro_controller.lua | the placer used to mark it done, half-built |

Watch in the log: `[MC] con #N queued ... (income X)`, `[TC] commander takes row`, `commander leaves row`,
`con N will take over row`, `tile X nanos done`, `extra con bot ordered for the spine`.

**Slot tiles (2026-10-05, `CFG.TILE_STYLE`):** `bar_framework/slot_crew.lua` replaces the fixed con_bot_grid tiles with
strips (2 slot rows / lane / nano row / lane / 2 slot rows, 16 x 25 cells, 2 x 2 strips = 64 slots + 16 nano spots) where
every slot takes a mex or a wind, chosen when built (mex unless energy is the binding resource, a nano when neither metal
nor energy is under pressure). `candidates/TILE_V2_slots` is TILE_V2 with `TILE_STYLE = "slots"`. Tests:
`tests/test_slot_tile.lua` (264 geometry checks), `tests/test_slot_smoke.lua` (stub run). One real headless match
(n=1, not a result): no Lua errors, all slots filled by ~6:00, but 35 winds vs 29 mexes with the first rule, which is why
wind now needs U_energy > 1. Not benchmarked yet; compare with `eco_bench.py ... --set TILE_STYLE=slots` against `cur`.

**Lines mode (`LINES_FOREVER`, test version, `candidates/TILE_V2_slots`):** every slot takes a nano, mex (big slots only)
or wind; nanos are placed by `NanoScore` (near other nanos, most free slots in range); a con stays on a frame until it
finishes (no early hand-off); strip rows are added whenever the free slots run low, until the map edge; mex grids are OFF;
the air lab is built by the commander on 6 reserved big slots inside a line (`SC.ReserveLab`) and the commander returns to
placing afterwards; the spine's "economy up" test is 30 built slots + 4 nanos. Tests: `tests/test_slot_tile.lua` (341),
`tests/test_slot_smoke.lua` and `... lines` (15 / 22). Not run in the real engine yet; not benchmarked.

**Lanes, lab in the rows, seeded first grid (2026-10-06, `candidates/TILE_V2_slots`, fixed block):**
- One builder per lane (`slot_crew` lanes = strip + side): con 1 on strip 1 side 1, the commander on the other side of the
  same nano row, later cons on the lanes nearest strip 1; a builder only takes its lane's slots and moves to a free lane when
  its own is done. Verified in the engine: `con takes lane (strip 1, side 1)`, `commander takes lane (strip 1, side 2)`.
- The air lab bay (3 x 2 big slots on the commander's side) is kept free from the moment the commander takes its lane;
  the commander builds the lab there and rejoins its lane afterwards. Verified: lab up ~11 s after the hand-off.
- Seeded first grid (`CFG.SEED_FIRST_GRID`, `bar_framework/nano_lift.lua`): air lab makes ONE air con then ONE corvalk; the con
  starts one grid, the transport lifts the 2 nanos with the fewest open slots onto the capstone footprint; seeds are reclaimed
  when the grid has 10 nanos. Engine probe: `cornanotc cantBeTransported=false mass=700`, `corvalk transportMass=750`: it works.
  Fixes found by real runs: the factory's guard order overwrote the first LOAD (wait 75 frames, re-send), the second drop
  spot was built over (re-test the spot at drop time, 8 candidates, never strand a nano), raw income spiked on the bot-lab
  reclaim (latch on smoothed income >= 100 for 5 s, or bank >= 1200).
- NOT achieved yet: in 3 single headless matches the first grid never reached 10 nanos (seeds never reclaimed) and the bank
  piled to 3k+ from ~4:30 with pull about half of income: one air con (cap 1) plus idle line nanos plus the commander walking
  leave build power unused. used@5:00 6.8-7.6k and @7:30 15.7-22.5k (n=1 each, noisy) against 8.3-9.1k / 24.9-25.0k for the
  fixed tiles (n=8). Next lever: more BP on the first grid (keep the line cons working, higher SEED_AIR_CON_CAP).

**Measured:** `ab_test.py` vs TILE_BOT at frame 14400 (5k cap): 1.018, NO DIFFERENCE (opening not broken).
Late-game effects are NOT measured: frame 36000 has a 2.00x noise floor. Single 24-minute runs vs
GROUND_RAIDER_BOT: won on score 3 of 3 (one early-lost commander before evade was added); spine
recovered to 2 T1 labs once air cons were added. The blind assault (before the presumed-enemy floor)
lost ~75k army; the floor and AA change were NOT re-run afterwards.
**Not done:** T3 labs (max_tech stayed 2 in every run), early ground defence (turrets), a late
energy grid (`blueprints/general/fussion_grid_60x60.lua` has two `tbd` placeholder entries and is
mostly nanos).

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

## Helper air cons + longer lines
- SEED_METHOD=helpers: no transport lift. The air lab makes SEED_AIR_CON_CAP (3) air cons; the 2 after the grid's con guard it until the grid has HELPER_NANOS (2) built nanos (any later grid with fewer gets helpers too), then are released. SEED_METHOD=lift keeps the nano_lift version.
- LINE_EXTRA_ROWS=4: 4 more strip rows are reserved from the start (block bounds/spine cells) and added as free slots run low, then the lines stop (slot_crew SC.EXTRA_ROWS).

