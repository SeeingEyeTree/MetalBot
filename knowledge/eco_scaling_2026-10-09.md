# Eco scaling bench and the grid fix (2026-10-09)

Bench: `python eco_scaling.py run --server single [--lt KEY=VAL ...]` (ECO_BENCH vs INACTIVE_BOT, 17 min).
`candidates/ECO_BENCH` = LINE_CLICK_v13d macro, SPINE=false, no-op lab/unit controllers (army share 0).
Single-mode noise on the bench is small (4 identical runs: 12:00 income 594-608); 15:00+ is noisier (2.5k-5.4k with the fix).

Baseline (v13d eco): 12:00 ~600 m/s, 15:00 ~1400, 2.0-2.2 min/doubling to 10:00 then 2.5-3.1.
DRAGON_BOT on the same bench: 703 @ 12:00, 1731 @ 15:00, steady 2.1-2.2 -- the old "1600 m/s at 12:15" is NOT
reproducible with the current harness (older 2k cap / different measure), so it is a target, not a regression to find.

Cause: from ~6:00 metal banked 4-14k while only 4-8 grids were open (GRID_FAST_INCOME 250 gated expansion; "bank"
rule 15 s gap, max 4 opening), grids were built in blueprint order (nanos first) not by resource pressure.

Fix (LT overrides in the macro): GRID_BALANCE=true, GRID_INTR_MIN_NANOS=0, GRID_FAST_INCOME=90,
GRIDS_OPENING_MAX=8, GRID_FAST_ENERGY=0.05.  Bench: 12:00 ~1450 m/s (1413/1460/1479), 15:00 2.5-5.4k, 17:00 4.8-7.4k.
= `candidates/LINE_CLICK_v15` (v13d + these).  One 20-min single-mode match v15 vs v13d: v15 END_SCORE 386k vs 97k
(army 100k vs 41k, income 4766 vs 932 at 20:00).  One game only -- not an A/B.

Tried and worse: AIR_CON_RESERVE 4-8, GRID_BANK_GAP 5 s + GRIDS_OPENING 4 + GRID_BANK 200 (opening too aggressive:
4:00 income 44-61 vs 73).  Single knobs on the old behaviour: GRIDS_OPENING_MAX=8 alone ~+15% at 12:00; GRID_BALANCE alone +30%.

Open: 6:00-8:00 is still flat (~110 -> 250 m/s); the air lab makes ~20 cons/min (linear) -- a 2nd air lab is the next lever;
army share > 0 and the model in eco_scaling.py are unvalidated against a real bot.

## Spread at 15:00 (2.5k-5.4k between identical runs) -- cause and what to measure

Identical runs are the same until ~12:00 (income within 5%) and time to 1600 m/s is 12.5 +/- 0.5 min in every config; the climb
to 3200-5000 m/s then has a timing spread of 1-2.5 min.  Income triples in ~2 min there, so a fixed-time sample (15:00) turns a
+-30 s shift into 2x.  Mechanism: grids keep their builders in low-metal work (winds), metal sits at its storage cap (pull
~1100 m/s flat for ~2 min, bank 80k+), and the move onto T2 retrofits / fusions waits for T2 cons (2 per capstone T2 air lab;
each retrofit uses a distinct T2 con) and for grids to become retrofit-eligible.  Eligibility came at 70% built / finished, or
when "unit cap tight" (4000/5000 units) fired -- at 13:54 in the fast run, 16:13 in the slow one.

Tried (3 replicates each; max/min income at 15:00 / 17:00): v15 alone 2.1 / 1.5; + RETROFIT_EARLY (grid retrofit-eligible once
its nanos are up) 1.8 / 1.07, time to 3200 m/s within 1.5 min -- ADOPTED in ECO_BENCH and LINE_CLICK_v15; + TIGHT_ON_FLOAT (fire
the cap-tight rule when metal sits >50% of storage for 20 s) 1.5 / 1.24; + UPGRADE_CONS_PER_LAB=5 1.5 / 1.33 -- no clear gain,
left off (code in line_transition, default false).

Measure with `python eco_scaling.py spread run1.json run2.json run3.json`: use time-to-milestone and 12:00 / 17:00 income, not
15:00.  Needs >= 3 replicates per bot (single mode, 3 in parallel ~4.5 min).  The remaining 15:00 spread is the surge itself.

## Army-share tests (ARMY_BENCH): 20% floor and the surge schedule

`candidates/ARMY_BENCH` = ECO_BENCH macro with SPINE=true, v13d lab controller, and a stub unit controller that counts every
finished mobile non-builder unit's metal (`[TRK] bench army_spent`), walks it 1800 elmos from the base and self-destructs it
25 s later.  spine.lua got `CFG.SCHEDULE` ({{frame, share}}) and `CFG.STRICT` (threat and unit-cap overrides off).
`python eco_scaling.py run --schedule 3:0.2 --server single` / `shares result.json --baseline <0% runs>`.

Results (one run each, 17 min):
- 20% floor from 3:00 (2 runs): actual army = 27.7% of metal used (target 20%).  Income vs the math (0% baseline growth slowed
  by (1-share)): measured/expected 0.93 @8:00, 0.86 @10:00, 1.03 @12:00, 1.15 @14:00, 1.20 @16:00 -- near the math, but the
  baseline itself varies +-20% at 14-16 min, so only 8-12 min is a tight check.
- SURGE 0:0, 5:0.3, 8:0.8, 10:1.0, 12:0, 14:0.3: the share does NOT control spend.  Army finished (m/s) per minute:
  34 (30%), 76-88 (80%, 100%), 65 -> 35 (0%), 430-480 (30% again).  Total metal used at the 80-100% steps was 275-575 m/s, so
  army was 16-35% of spend at a target of 80-100%: the share only sets how many spine nanos are released for army; the grids keep
  spending whatever they can, and the spine cannot absorb 80-100% of a growing income (labs/nanos not built).  At 0% the lab
  controller still builds floor units (17.8% over 0-5:00, 17% at 12-14:00).  Income at 10:00-16:00 was 1.8x-5.5x the "math"
  value for the schedule because the army never took the share.

## Making the share bind (spend governor), 2026-10-09 later

Problem: the spine's army_share only released spine nanos; grids and the lab controller's floor units ignored it.
Added (all behind switches, other bots unchanged): `bar_framework/spend_governor.lua` (LT.CFG.SHARE_GOV), spine `SetBoost/SetHold/Strict`,
a strict gate in ARMY_BENCH's lab_controller (share 0 or held => no army from ANY lab), `LAB_GATE_AV=false / MAX_OPENING=4 /
NANO_BATCH=12 / NANO_INFLIGHT_MAX=20 / EXPAND_FROM=3600` in the bench's spine settings.  The governor measures actual metal
spend per builder (buildSpeed x current build power x target cost/buildTime), army = mobile non-builder targets, everything else
(grids, spine cells) = eco.  Army over share: lower the spine's demand multiplier and hold lab queues.  Army under share and
its builders starved of metal with the bank empty: pause the grid pipeline.  Metal floating always un-pauses eco.

Results (one run each, army spend as a share of metal used, in-progress spend counted):
- 0% (constant, 17 min): 0.1%.  0% windows inside a schedule: 0.0%, 1.2%, 8.3% (the tail of queued T2 units after 100%).
- 20%: 19.0, 16.0, 20.6, 23.2 (ok); constant 3:00-17:00: 27.4% (over).
- 80%: 73.4% (ok).
- 100%: 50.0% / 53.3% / 40.5% (was 17-35%): the army needs labs + nanos STANDING; the T2 cell takes ~3 min to stand after the
  demand appears (spine log: standing capacity 0 for 3 min at 100%, then realized share 75-85%).  Capacity, not control, is what is left.
- Cost: with the 20% floor, income at 12:00 is 445 m/s vs 718 with the old spine and ~1450 at 0%; measured/expected vs the "math"
  0.78 (8:00), 0.65 (10:00), 0.66 (12:00), 0.45 (16:00).  The math only charges the unit metal; the spine's labs/nanos/T2 cells
  (thousands of metal) are infrastructure that grows nothing.  The governor's eco pauses were ~16% of samples.
