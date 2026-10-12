# LINE_BOT

A human-style opening that scales by building a **line** of mex/wind slots, then hands off to TILE_BOT's mex-grid
system through an air lab. Since 2026-10-07 it also has an army: a **vehicle lab on the line seeds TILE_BOT's spine**
(lab/unit controllers are TILE_BOT's copies; they read `WG.Spine`). `CFG.SPINE = false` in the macro gives the
old economy-only bot (`candidates/LINE_NOSPINE/` is that variant, the A/B baseline).

Files: `LINE_BOT/macro_controller.lua`, `bar_framework/line_crew.lua` (the line), `bar_framework/line_transition.lua`
(the hand-off, the vehicle lab, the spine glue and everything after), `bar_framework/spine.lua` (shared with TILE_BOT;
`Start(frame, {deferOpen})`, `OpenFirst`, `AdoptLab`, `env.CellOK` were added for this bot), `blueprints/general/line_com.lua`
(the starter), `tests/test_line_crew.lua`. History: `SPINE_BRIEF.md`.

### Spine / vehicle lab / starter-lab reclaim (added 2026-10-07; stub-tested, NOT yet measured in a real match)

- **Vehicle lab (`corvp`)** on 4 slots (2x2) of the outer lane the air lab did not take, + 2 nanos beside it. The site is
  claimed (slots `reserved`) as soon as an outer lane has a builder and a free 2x2 block (lane 3 first); the air lab
  then uses the other lane. The lab is **queued backwards from `CFG.VP_DONE_FRAME` (4:30)**: start = deadline - build
  time (with the con + nanos in reach) - 10 s, and never before the air lab is queued. Reference: the human's lab was
  done at 3:57, the bot's air lab ~4:00, human units hit the bot base ~5:30 (replay `2026-10-06_02-34-40`, read by hand:
  the parsed replay has no unit events). Faces outward (to the lane corridor, 48 wide) - **check in a real game that
  units get out**.
- **Spine** (`[LT] ... spine: cell 1 at`): reserved when the air lab finishes (before the first grid cell is seeded).
  **Cell 1 sits directly in front of the vehicle lab**, just outside the line on the lab's side (`SPINE_GAP`), so the lab's
  two nanos reach it; labs face away from the line and the **stack runs parallel to the line** (custom `geo` from
  `SPINE.GeometryFor`). Grid cells keep off every spine cell and exit lane (`T.OverlapsSpine`, since the lattices differ).
  Cell 1 opens when the vehicle lab finishes (`SPINE.AdoptLab(.., VP_CONS=1)` + `OpenFirst`). **Air cons never build the
  spine** (`GroundOnly`): only the vehicle lab's ground cons (and the cons the spine's own labs make) do, and **only one
  ground con** exists until cell 1 is built (`SPINE_EARLY_CONS`; the first real run made 3 from the vp and 3 from the
  cell's lab). **Air cons are capped at 3** (alive + ordered) until the air lab's two nanos stand (`AIR_CON_CAP_EARLY`;
  the first run capped until the first grid was 30% built = 7:00, which starved grids 4-8 of cons for ~150 s and flattened
  income at 4:30-6:00; 30% is kept only as a fallback).
- **Line turned -90 degrees (2026-10-07):** it now runs ACROSS the enemy axis (`LC.Rotation`). The outer lane on the map-centre
  side (`T.enemyLane`) takes the vehicle lab and the spine (labs face the enemy); the other outer lane (`T.awayLane`) takes
  the air lab, and the first grid goes beyond it. **Grid cells never go past the line's enemy-facing edge**
  (`T.OnEnemySide` in `Collect`), so the grids grow away from the enemy and sideways along the line.
- **Builder fixes from the user's watching (2026-10-07):** con #1 now walks a **route round the west end of the starter**
  (`LC.LANE_ROUTES[2]`) after its first nano instead of through the choke where the commander stands (it got stuck
  there); the vehicle lab job is **urgent** (the lane's con drops the slot it is on, `job.urgent`/`c.preempt`) and **every
  nano in reach is put on the lab frame** the moment it appears (`LT.OnJobStarted`; also for the air lab); only the FIRST
  `corlab` is the starter lab (`TS.botLabSeen`), so the spine cell's lab is no longer taken for it (it was counted as a
  line con source, 5 extra cons). A builder that does not reach a stop in 20 s twice skips the stop.
- **Bug fixed (real run 2026-10-07, 6:30): an enemy raid killed an air con, `LT.OnUnitDestroyed` set the grid session's
  `builderID = nil`, the placer's `GetUnitDefID(nil)` threw and BAR removed the whole Macro Controller widget.** Dead
  builder ids are kept now (the placer ends the session itself). Job-done handler errors are logged too.
- **Starter bot lab is reclaimed** (nanos in reach, `[LN] ... starter lab reclaim`) once the 3 cons are out and the air
  lab is queued: its metal funds the vehicle lab.
- An "eco buildings before nanos" reorder of the first grids was tried and **removed** (the user saw the grids not
  starting properly); grids start exactly as before. The 2:30-6:30 income stall below is still open.

## What it does

1. **Starter** (`line_com`): commander places 2 mex, 2 wind, bot lab, 3 wind (+ first nano by con #1) without walking.
   Con #1 comes out of the lab and builds the nano; the commander finishes ALL its starter items, then guards the
   lab until con #1 is out, then joins its lane. While con #1 places one of the first 2 nanos the commander guards it.
2. **The line**: 4 lanes (commander + up to 3 cons), 2 slot rows each, 16 slots per row (64 elmos, 4x4 cells). A
   builder walks its corridor one way only. Each slot gets a mex, or a wind when energy is the pressed resource.
   Nanos go in the nano column (con #1's lane only) when neither resource is under pressure (build power short).
   Cons are queued by income (20 / 30 m/s), bank (130) or a 45 s timer.
3. ~~Energy storage~~ (removed 2026-10-07: the user had added it without a reason).
4. **Transition** (`line_transition.lua`):
   - Site = the 6 open slots (3 columns x 2 rows) of an outer lane (4, else 3) closest to that lane's con, plus 2
     open slots beside it for nanos. **Nothing is reserved up front.** The site is re-picked every tick; it is
     claimed early only when the lane is down to 14 open slots, so a saturated line cannot eat it.
   - Trigger: `T = lab buildTime / (con BP + BP of nanos in range)`; queue the lab when
     `metal bank + metal income * T >= lab metal cost` (metal only; energy is logged), or at 6:00 whatever the bank.
   - The lab is a `line_crew` job on that con (issued between items, never over a frame in progress), then 2 nanos
     in the open slots beside it, then idle nanos guard the lab while it owes air cons.
   - First grid: 48 elmos (3 cells) beyond the line's outer edge on the lab's side, centred on the lab; later grids
     follow adjacency expansion minus any cell overlapping the line.
   - From here it is TILE_BOT's grid system: 2 grids "opening" at once (+1 per 500 metal banked, 15 s apart),
     air-con reserve of 2, **spend-pressure hand-off** (0.15 under-spending / 0.60 short / 0.30 else),
     **capstone** T2 air lab per grid, **retrofit** of grids at 70% built by T2 air cons (stopped below 15% metal
     storage, resumed above 30%), and **unit-cap relief** (below 1000 units of headroom or 20% of the cap: no more
     wind, all grids retrofit-eligible, rationed wind reclaim, 2x2 wind blocks -> one fusion / T2 mex).
   - Not ported: the nuke-silo capstone on grid 4, TILE_BOT's energy look-ahead grid interrupt
     (plain `GRID_INTERRUPTS` are used; so `SPINE.EnergyShort` is unused). The spine IS ported (above).

Log lines: `[LN]` (line, cons, status every 15 s), `[LT]` (lab plan, lab, grids, retrofits, consolidation).

## Measured (one run, 2026-10-07, read from infolog; not an A/B)

- Metal income doubled about every **1.7 min from 6:00 to 12:00** (156 -> 1786 m/s); 1.4 min at its best.
- First retrofit 7:08, 42 retrofits and 49 grids by 17:30.
- After ~12:00 doubling slowed to 2.6-3.6 min; at 17:30 metal AND energy sat at the storage cap (350k / 287k) with
  pull 3.5k vs income 6.1k and 40 factories idle. The unit cap was not the limit (2268 / 5000 at 15:00).
  An economy bot with no army has nothing left to spend on: that is what the spine is for.
- Energy was still stalling at 3:30-5:30 (bank 2-13%) even after the wind fix.
- NOT verified: that retrofits complete and raise income; the real `corap` footprint fitting the 192x128 site
  (the log prints `[LT] air lab ... footprint`); the consolidation path in a real game (stub only).

## Latest run (2026-10-07, after the `fast` grid rule; one run, from infolog, not an A/B) - "good enough"

Reached the unit cap: 4005 / 5000 at 15:02 (consolidation on; previous run had 2268 at 15:00), 113 grids, 104
retrofits. Metal income 166 m/s at 6:00 -> 6917 at 16:30 (42x, ~1.95 min per doubling; previous run ~2.07, within
noise). The difference that is clear is how much it builds, not the doubling rate.

Grid pacing in `ReleaseCandidates` (crude, works, leave it): `pace` (< 2 grids opening), `bank` (>= 500 metal, one per
15 s), `fast` (>= 3000 metal AND an idle air con AND energy bank >= 20%; no gap, one cell per 10-frame pass).
The `fast` rule exists because 10:00-17:30 of the earlier run showed 4-10 idle cons, 16-18 cells waiting and
230-350k metal banked with one grid per 15 s. There is no cap on the number of grids besides the unit cap
(consolidation at < 1000 units of headroom stops new cells) and valid terrain / line overlap.

### Weak points still open (found in that run; none fixed)

1. **Early energy stall, the biggest one.** 2:30-4:30 metal income was 35, 37, 42, 42, 61 m/s: ~1.5 min of almost no
   growth while the energy bank sat at 3-16% of storage. Wind-vs-mex now also keys on the energy bank
   (`LC.WIND_LOW_FRAC`), but energy still stalls here. Candidates: more winds earlier in the line, the energy
   storage trigger (400 e/s) is too late to help, the lab and grids start before energy can feed them.
2. **Grids flat at 5 from 4:30 to 6:30** while energy was 11-31% full (and the `fast` rule is off below 20% energy and
   3000 metal). Grids are energy-limited here; the grid count resumed once the bank passed 500 at ~6:30.
3. **7:30-9:00 income dip**: 355 -> 500 m/s in 1.5 min (~3 min per doubling) with the metal bank rising to 2209 and
   energy 29-56%. Not diagnosed. First retrofits start at ~7:08; a retrofit reclaims T1 mexes and winds before the
   T2 replacements exist, so it may dip income (guess, check `[LT] retrofit started` against the income rows).
4. After the cap (15:00+) 22-27 air cons sit idle with 336k metal banked and the grid count stops at 113: expected
   for an economy-only bot, this is what the spine port (`SPINE_BRIEF.md`) is for.

### Session 2026-10-07 (afternoon): fixes from reading the 20:02 match (infolog + replay). Deployed, NOT re-run after the last four

Found in the log, fixed (stub tests pass: `test_line_crew.lua` 297, `test_tile_bot.lua` 159):

1. **13 grids open at once at 6:00 with the line 40% unbuilt.** `bank`/`fast` in `ReleaseCandidates` had no limit on
   grids opening. Now: line unbuilt (`LC.SlotsRemaining(L) > 0`) -> only `pace` (2 open); line built -> `bank`/`fast`
   up to `GRIDS_OPENING_MAX` (4).
2. **Line nanos only built air cons.** `UpdateLabAssist` guarded the air lab with every idle nano in reach whenever an
   air con was on order (nearly always). Now only the lab's own two nanos (`T.labNanoIDs`) while the line is unbuilt.
3. **Nano build rule.** A big metal float must NOT add nanos during an energy stall (energy is the limit, not build
   power; I got this wrong first). Instead `LC.NanoFloorShort`: >= 1 line nano per 8 finished slots
   (`LC.SLOTS_PER_NANO`), then the old rule (both utilisations < 0.8). While energy stalls, `FocusNanosOnWind` sends
   the line's nanos in reach onto the wind being built (`PRIO.CLEAR`, above the lab guard, below hand-offs).
4. **Mex-or-wind signal** is `LC.WantWind` (logs `[LN] ... slot choice -> wind (stall|pull|float)`): wind on a stall,
   on energy pull > 90% of income with the bank < 60%, or on a growing metal float with energy not spare; else mex.
   User confirmed this helped a lot. Thresholds are guesses (`LC.WIND_*`).
5. **`fast-income` grid trigger**: smoothed metal income >= 550 M/s (`GRID_FAST_INCOME`) + an idle air con + energy
   bank >= 20% opens a cell at once, ignoring the bank and `GRIDS_OPENING_MAX`. Reason: the spine spends everything, the
   bank sits near 0 from 5:30, so the bank >= 500 / >= 3000 triggers never fired (14-16 min: 750-890 M/s, 1 grid
   opening, 8-10 cells waiting).
6. **Parked nanos leaked.** `PARK-LEAK=27` of 28 at 15:28: a queued WAIT does not stop a nano auto-assisting, so the
   share throttle did nothing. `nano_broker.Park` now sends STOP + the on/off command (0) and every other order
   switches the nano back on first. UNVERIFIED in the engine: the `PARK-LEAK` figure in the `[SPINE]` line must be ~0.

**Army share vs actual spend (20:02 match; army spend = d(army_mv + lost_army_mv), rough, lags in-progress units):**
share 100% (threat) 4:30-10:30 -> actual 10-41%: the pipeline was the limit (`capacity=0` until 8:28, first spine lab
~6:28), not the share. Share 20% at 11:00-16:30 -> actual 14-63% (mostly 25-35%): the leak (item 6), and at
`MEXREADY` the nano allowance is sized for 100% (`nanoShare = 1`). Re-measure after item 6.

**Follow-up the same evening (army test + `fast-income` run).** Metal income M/s at 6 / 10 / 12 / 14 min: 20:02 run
(spine, before `fast-income`) 90 / 285 / 432 / 601; live run after `fast-income` (spine on, 46 grids by 14:23)
98 / 370 / 591 / 894; `candidates/LINE_NOSPINE` vs INACTIVE_BOT (headless, 17 min) 124 / 434 / 654 / 831, 957 at 16,
1038 at 17 (but 51k banked, pull 254: nothing to spend on). So: the army costs ~15-25% of income at 6-12 min, the grid
pacing was the bigger loss (`fast-income`: +49% at 14 min, level with no-army). The 6917 M/s of the earlier run is NOT
reproduced by either (about 1000 at 17 min) - treat it as unexplained. Not an A/B (one run each). The paragraph below
is the earlier worry; the evidence above mostly answers it.

**Possible big slowdown (earlier worry; see the follow-up above).** In that run metal income was 90 M/s at 6:00 and
888 M/s at 16:30, with 20 cells opened and 5 grids finished by 16:36. The earlier "good enough" run above had 166 ->
6917 M/s and 113 grids. Not a clean comparison (the spine was added in between and now takes 25-60% of spend, and
grids 2..N were held to `pace` until the line was built, ~7:00 vs 13 open by 6:00 before), but the gap is 8x at 16:30
and no A/B has been run. Items 1 and 5 may be what made it slower; item 5 is the part meant to fix it. First thing to
check in the next run: `[LT] grid cell ... opened (fast-income ...)` appearing from ~550 M/s and income at 16:30.
If grids are still slow: raise `GRIDS_OPENING` (2) or let the line gate allow `GRIDS_OPENING` + 1 while it builds.
Then `ab_test.py --bot-a LINE_BOT --bot-b candidates/LINE_NOSPINE`.

How to check these next time: the `[LN] m:ss status` rows (metal/energy income, pull, bank %) and `[LT] m:ss phase`
rows (grids, idle / ordered air cons) in `infolog.txt`; `[TRK] eco ... units_total= unit_cap=` for the unit count.

## Lessons (bugs found while building this; each cost a run)

- **A crew builder is almost never idle.** `line_crew` starts the next slot item in the same step the last one
  finishes, so "wait until the commander is idle, then help con #1" never fired. Use the `c.hold` flag: the macro
  sets it, the crew stops after the current item, the macro sees `phase == "idle"` and acts.
- **`HasClaimable` cannot see reserved items.** The placer queues each builder's next order (`shiftNext`, item
  `reservedBy`); a reserved item is not claimable by anyone, so right after the lab the commander looked
  workless and left for its lane, skipping the 3rd wind. "Has starter work" must also count `shiftNext` and any
  unfinished item the builder can build (`CommanderHasStarterWork`).
- **Energy utilisation lies once energy stalls.** Reported pull is capped at income, so `pull / (income + bank/30)`
  sits at ~0.99 and never clears a 1.0 threshold: every slot stayed a mex with the energy bank at 3-4% for minutes.
  Wind is now also chosen when the energy bank < 25% of storage (`LC.WIND_LOW_FRAC`) and energy is the more pressed.
- **Do not reserve slots for the lab.** A fixed reserved block looked arbitrary and was wrong; take the closest open
  block when needed. But a saturated line has no open block, hence the early claim at <= 14 open slots.
- **Do not drop the late-game system when giving the opening a better start.** The first transition port left out
  retrofits, the capstone T2 lab (the only source of T2 cons) and the spend-pressure hand-off; late-game doubling
  went from ~1.7 min to ~2.2 min and grids sat unfinished while metal floated.
- `deploy.ps1` defaults to DRAGON_BOT: **`.\deploy.ps1 -Bot LINE_BOT`**.

## Testing

```powershell
# stub test (the system python has lupa with a Lua 5.1 runtime; lua is not on PATH)
python -c "from lupa.lua51 import LuaRuntime; l=LuaRuntime(); l.execute('arg={}'); l.execute(open('tests/test_line_crew.lua',encoding='utf-8').read())"
# real match
python bot_testing.py --bot1 LINE_BOT --bot2 TILE_BOT --duration 600 --save-replay
# PURE ECONOMY test (income curve, grid pacing, line): opponent = INACTIVE_BOT (does nothing). OK_BOT attacks and
# confounds the income. candidates/LINE_NOSPINE = no army at all.
python bot_testing.py --bot1 candidates/LINE_NOSPINE --bot2 INACTIVE_BOT --end-minutes 17 --save-result out.json
```

The stub builds everything instantly: it checks code paths (lab, nanos, first grid beyond the line, retrofits,
consolidation, energy storage), not how the bot plays. `~/.../Beyond-All-Reason/data/infolog.txt` holds several
runs back to back; the last one starts at the last `[LN] line laid out`. Compare bots with `ab_test.py`, not one match.
