# Scoring a position: the state value phi

`bot_score.py` estimates how strong a bot's position is at a moment in the game. `score_eval.py`
checks whether that estimate is any good. Weights live in `score_config.json`. This file explains
why the score is built the way it is and keeps a log of changes and validation results. Revisit it
as data comes in.

## Why a state value and not "who won"

A reward that says only win or lose at the end is far too sparse to learn from. With BAR's action
space, even with layers of abstraction, a learner would almost never connect a decision to the
outcome. Reinforcement learning handles this with **potential-based shaping**: define a
potential phi(s), an estimate of how good a state is, and reward the change `γ·phi(s') − phi(s)`.
This leaves the optimal policy unchanged (Ng et al. 1999) and gives feedback at every step.

We are not training a model, but the idea carries over directly:

- **Scoring a match that ends early** is the same problem: estimate V(state) at the cutoff.
- **Finding where a bot is weak** means looking at which parts of phi are low, not only the total.
- **Changes in phi over time** show *when* a bot lost ground (the raid at 7:30, not "it lost").

## Principles

1. **Metal-equivalents.** Every term that can be priced in metal is. Then terms add up and each
   one reads as "worth N metal". The old adjudicator (`army_mv + 60 × metal_inc`) already did this.
2. **Bottleneck, not sum, for capacity.** What a bot can do is limited by its scarcest input.
3. **Own view for the bot, privileged view for grading.** Each process logs only its own team. The
   scorer has both logs, so some signals (`enemy_known`, `tech_foresight`, `denial`,
   `trade_ratio`) compare one team's knowledge with the other team's truth. That is fine for
   grading a bot. A bot can never use it.
4. **Computed offline from `tracker_timeline`**, so any old result can be re-scored when the
   weights change. Missing fields mean a signal is skipped, never counted as zero.
5. **State, not flow.** Attrition (trade ratio) is reported but never added to phi. Losses already
   show up as army that is not there.
6. **Report-only until validated.** phi does not decide match winners until `score_eval.py` shows
   it predicts outcomes at least as well as the legacy score, with a measured noise floor.

## phi

    phi = Σ metal terms × their multipliers − value_at_risk × (1 − warn_discount × warned_rate)

| Category | Signal | Role | Meaning | game_mechanics.md |
|---|---|---|---|---|
| materiel | `army_value` | add | army at metal + energy/70 × average health | 7.4, 2.3 |
| | `defense_value` | add (×0.5) | static defences at metal + energy/70; they cannot move | 2.3 |
| | `army_coherence` | × army | one army beats the same units spread out (`main_share`) | 7.4 flanking |
| | `counter_coverage` | × army, defence | share of our armed units that can hit each enemy class, relative to that class's share of their army | 7.3 |
| | `role_coverage` | report | share of standing roles present: dedicated AA, home guard, rez, radar/jammer, transports | 7, 1.4, 2.1 |
| economy | `income_capital` | add | what can be put to use over H = 60 s, **eco or army** (`spend_capacity`), at metal + the energy spent alongside it ÷ 70. Income that can't be used counts at 25% | 1.1, 2.3 |
| | `energy_stall` | × income, **weight 0 since v2** | time spent energy-stalled. A controlled stall is ideal | 1.2 |
| | `waste` | report | metal + energy/70 lost over the storage cap per second (produced − used − stored) | 1.3, 10, 11 |
| | `reclaimable` | report | wreck metal near the base | 1.4 |
| ability | `spend_capacity` | feeds income | **min(metal available, builders' pull, energy ÷ E/M of what is being built)**. "demand" binding = income waits for placements | 1.1, 1.2 |
| | `army_rate` | report | **min(metal, energy ÷ army E/M, factory BP × metal per bp-s) × unit-cap headroom**; each lab's support BP capped at ~2.5 s of its typical unit (`fac_bp_useful`) | 2.5 |
| | `production_reach` | report | share of factories whose units can get out (a boxed-in ground lab counts half with air transports) | 2.5, 5 |
| | `expansion_capacity` | feeds army rate | share of spots next to builders where a T1 lab fits; builders' BP only counts if there is room | 2.6 |
| | `slot_headroom` | feeds army rate | income is worth less as the last 10% of the unit cap fills | 3 |
| | `stranded_bp` | report | share of BP sitting in idle nano turrets | 2.4 |
| | `tech_level` | report | highest factory tech level | 4 |
| awareness | see below | report / feeds risk | | 6.2 |
| exposure | `value_at_risk` | subtract | labs outside dedicated AA (at a 0.3 prior before enemy air is known); outside anti-nuke while a silo exists; a lone commander with enemies near, **staked at 0.3 × everything else phi counts** since its loss is the game | 7.3, 1.5, 9 |
| | `home_guard` | report | armed value near the base that can hit ground / air | 7.1 |
| attrition | `trade_ratio` | report | metal killed ÷ metal lost | |

### Ability to act

Two questions, kept apart since v2. **Can income be spent at all** (`spend_capacity`)?
game_mechanics 1.1: every job draws BP × cost / build time, and metal pull is exactly that sum,
so pull (interval average) is the builders' spending capacity. **How much army** could this state
produce right now (`army_rate`), and could it add production if it had to? A bot with high income but no factory, no energy for its air
army, or its only lab walled in by nanos is weaker than its income says. The report names the
binding constraint at every checkpoint, which points straight at the fix.

Tracker fields (`units` row): `fac_bp`, `mob_bp`, `army_em`, `army_m_per_bp`, `build_sites` /
`build_tested`, `ground_fac`, `fac_exit_ok`, `fac_exit_unknown`, `stuck_units`, `air_trans`, plus a
`fac_boxed` event. The exit test uses `Spring.RequestPath` from just outside the factory door towards
three goals. It works in headless.

### Awareness

Information has no value in itself. It is worth something only when it changes a decision in time.
So awareness mostly enters phi as a **discount on expected losses** (`warned_rate` scales
`value_at_risk`). Its own category score is reported and weighted 0 until it proves predictive.

| Signal | Meaning |
|---|---|
| `fresh_intel` | age-weighted knowledge (`exp(−age/45 s)`, radar counts half) of four zones: home, the corridor between starts, the enemy base, outlying mex fields. The enemy start is mirrored when it can't be read (init `foe_src`) |
| `warned_rate` | share of armed enemies reaching our base that we had contacted (LOS or radar) ≥ 20 s earlier; plus the median lead |
| `enemy_known` | our remembered enemy value (seen in the last 5 min, not seen to die) ÷ their real value |
| `surprise_losses` | enemy-attributed losses whose killer was not in sight in the last 10 s |
| `tech_foresight` | for air, nukes and T2: how soon after the enemy had it did we see it; also flags "hurt before seen" |
| `denial` | how much of our value the enemy sees (lower is better) |
| `coverage_now` | context only: LOS / radar / ever seen |

## Coverage of game_mechanics.md (checked 2026-09-24)

Every section was compared with phi. What changed in v2 is in the table above. What is still
not covered, and why:

- **6.1 proxy bases / eco exposed near the fight (11):** needs positions of our eco and of the
  enemy army. The tracker keeps remembered enemies without positions. Next candidate if raids
  or eco crippling become the problem.
- **7.1 raid exposure in phi:** `home_guard` is reported, not scored. It needs raid games to
  calibrate how much guard a given eco needs.
- **7.2 retreating wounded units / 1.4 healing:** behaviour, not state. `army_value` weights by
  health, which overstates the loss when repair is nearby (healing is free).
- **7.4 DPS, range, speed:** army is valued by cost. The map is large and fast units matter (5),
  which cost doesn't capture.
- **9 "we've won" detection:** phi comparing both sides is exactly that signal offline, but it
  uses the opponent's own rows. A bot-side version would have to use `believed_mv`.
- **8 skuttles / spies, cloaked units:** out of scope, and the tracker can't see cloak (7.5).
- **Energy value** is covered since v3 (metal + energy/70, the author's call). The doc's
  "E×70" typo is fixed.
- **Factory value at risk** (`fac_t1_mv`, `fac_t2_mv`) is still metal-only.

## Measurement notes

- **Fixed 2026-09-23: the tracker's enemy scan was camera-culled.** It used
  `Spring.GetVisibleUnits`, which returns units in the camera's view. Headless processes saw at
  most one enemy per snapshot and no radar blips in every match logged before this date, while
  losing dozens of units to named killers. It now uses `GetAllUnits()` + ally check (as
  `threat_map.lua` does). All `vis_*` fields and `first_enemy_*` events in older results are
  close to blind. So are the `find_weakness.py` detectors that use them (late_scouting,
  no_early_warning, no_counter_air's sighting side, radar_warning_unused).
- `lost_noattr_*` counts finished units lost with no attacker at all. Own reclaims name the
  reclaimer (lessons_learned, 2026-09-22), so these are self-destructs or kills the engine hid
  from this process. In the first mirror test every enemy kill carried its attacker, so hidden
  kills look rare. Keep watching it.
- Army E/M and metal per bp-s come from the tracker (`army_em`, `army_m_per_bp`). For older
  results they come from the army mix priced with `knowledge/unit_catalog.json` (which now has
  `energy` and `buildtime`), and then the config defaults (median T1 ground unit: 11.5 E/M,
  0.064 m/bp-s).
- `STALE` = 1800 frames: a row older than that at the scored frame is not "now", so phi is `-`
  after a team's data ends. A checkpoint after a commander **kill** reads WON / LOST (phi 0).
  The end-of-match self-destruct (`killer=?`) doesn't count.

## Validation log

### v3 (2026-09-24): energy valued at 1/70 of metal

The author's decision: capture energy value, using game_mechanics 2.3's metal + energy/70 (the
doc's "E×70" typo was fixed the same day). Army and defence are valued at full cost (tracker
`army_ev` / `defense_ev`; older results estimate army energy from army E/M). `income_capital`
adds the energy the builders use alongside the metal they can spend, at their own E/M mix, ÷ 70.
Energy that nothing can use counts only at `surplus_value`, so over-built energy (11) isn't
rewarded.

Two measurement fixes found while checking it:
- **`spend_capacity` needs the interval-averaged pull.** A single instant pull reading (all
  results before 2026-09-24) swung 2–4× between identical bots and made phi's mirror noise
  1.55× at 4:00. It now returns nothing without `metal_pull_avg`, and income falls back to all
  of it being usable. Mirror noise after: phi 1.04 / 1.05 / 1.15 at 4/6/8 min, about the same as legacy
  (1.07 / 1.06 / 1.12).
- **`score_eval.py` excludes mirrors from predictive validity.** A mirror's "winner" is noise.

Predictive check on what is left: 5 decided games, 4 of them decided *by the legacy formula*
at a wall-clock cut and 1 by a commander kill (phi calls that one 11.6k vs 3.1k). Hits:
phi 43%, legacy 64%, army_rate 100%, materiel 86%, economy 29%. Counting energy isn't what
lowered phi: with energy switched off it did slightly worse (9/20 vs 10/20 checkpoints). The
difference from v1 is that v1 limited income by the *army* production rate. That happened to
match these exploiter-vs-bot verdicts, but game_mechanics 1.1 says every kind of spending
counts. **Don't tune phi toward end_score winners**: that just rebuilds the legacy formula.
Validating phi needs outcomes the legacy formula didn't decide: commander kills, and games run
past the unit cap.

### v2 (2026-09-24): checked against game_mechanics.md

Changes: `energy_stall` weight 0 (1.2); income usable = `spend_capacity` (1.1); `army_rate`
(was `spendable_rate`) caps lab support BP (2.5); AA risk prior 0.3 before enemy air (7.3);
commander risk = 0.3 × (army + defence + income capital) × (1 − hp/2) instead of a flat 5,000
(1.5, 9); new report signals `waste`, `reclaimable`, `stranded_bp`, `tech_level`, `home_guard`,
`role_coverage`. New tracker fields: `metal_pull_avg` / `energy_pull_avg` / `*_inc_avg`,
`fac_bp_useful`, `nano_idle_bp`, `home_guard_gnd_mv` / `home_guard_air_mv`, `rez`, `util_intel`,
`max_tech`. First result: on the merged-DRAGON mirror, v2 names "demand" as the spend binding at
4–8 min. That's what the energy experiment found by hand; v1 said "energy".

### v1 (2026-09-23): smoke test, not a verdict

`score_eval.py knowledge/raid_runs knowledge/threat_logs` on 5 decided games (all involving
exploiter bots). Higher value → winner:

| metric | 2:00 | 4:00 | 6:00 | 7:00 |
|---|---|---|---|---|
| phi | 1/5 | 4/5 | 5/5 | 5/5 |
| legacy (`army_mv + 60·inc`) | 2/3 | 3/5 | 2/5 | 4/5 |

Five games of lopsided matchups prove nothing about telling two competent bots apart. Next:

1. **Noise floor.** DRAGON_BOT vs itself, ~6 runs with `--save-result`, then `score_eval.py` on
   them. phi is only useful for A/B if its mirror spread at frame 14400 is ≤ army value's ~1.14×.
   The first two 10-minute mirrors gave phi ratios at 8:00 of 1.26× and 1.00×, and at 9:30–10:00
   of 1.04× and 1.27×.
2. **Predictive validity on close games**, e.g. DRAGON_BOT vs recent candidates, run to
   `--end-minutes 20+`, then `score_eval.py --fit 14400` once there are ~30 decided games. The fitted
   per-category weights replace the hand-set ones. Bump `version` and log the change here.
3. `find_weakness.py` could cite the low component (for example, binding = bp because
   `production_reach` is 0.5).

### Using phi to improve DRAGON_BOT (2026-09-23): what it can and cannot tell you

phi said "binding: energy" for 4–8 min, and the raw data agreed: every mirror run was
energy-stalled 60–90% of 5:00–6:00 while 1.4–2.3k metal banked. The fix (an energy
interrupt that looks 30 s ahead) halved the stall (0.256 → 0.115 over 6 A/B team-runs) but
did not change banked metal, production or army at 8:00. **A binding constraint in phi is a
capacity estimate, not proof of what limits growth.** Remove it, and check that the thing it
was supposed to unlock actually moved (bank, pull versus income, production) before believing
it. The growth rate is set by grid-to-grid latency (lessons_learned, "Scaling"), which phi
doesn't model yet. A candidate signal: time from a grid opening to a builder starting on it
(`[MC] grid N waited` log line).

Both changes (energy look-ahead, air-con reserve) fired as designed at no measured cost and
were merged into DRAGON_BOT at the author's decision. Neither is a measured win.

Scoring fix from the same work: `production_reach` scaled ALL factory build power by the
share of labs that could get out, so one boxed vehicle plant halved the air lab's build power
too, and phi read "binding: bp" at 9:00. The tracker now logs `fac_bp_open` (build power only
at labs whose units can get out), and `spendable_rate` uses it when present. This makes a
boxed lab cost *less* than before; it doesn't favour either change above.

### Things phi has already surfaced

- DRAGON_BOT's only ground lab (`corvp`) gets walled in by nanos around 8:30–9:00 in a mirror
  (`fac_boxed ... best_path=0`). From then on its build power is the binding constraint (~240
  metal/s usable of ~410 income). Confirmed by the author: the base layout was never designed to
  scale. Not being fixed now.
- DRAGON_BOT reclaims its starter lab around 4:00, so it has no factory for a while. phi now credits
  builders with free ground, so income still counts as spendable.
