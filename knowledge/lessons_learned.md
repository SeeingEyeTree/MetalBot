# Lessons Learned

Curated insights from agent runs and manual analysis. Updated automatically after each gauntlet.
New entries go at the top so the most recent observations appear first in the agent context.

---

## Ground armor needs its own farm and its own orders; the army must attack, not hold (2026-09-24)

27-min DRAGON_BOT vs RAIDER_BOT showed what the <20-min tests could not: the baseline floated
50-159k metal from 15:00 (structures filled ~1600 of the 2000-unit cap), fielded only air, and
its one `corvp` was walled in by the mex lattice (16-elmo gaps, a Tiger is 48 wide -- the whole
lattice is a wall to ground units). It lost the commander at ~26 min to RAIDER's Dragon swarm.

- **`correap` is the "Tiger"** (690 m, from `coravp`, 600 BP). `corftiger` is a scav-boss unit,
  not buildable. Only `corcv`/`coracv`/`corch`/`cormuskrat` can place a `coravp`; `corca` (air con)
  can place `corvp` and nanos anywhere, so a farm is: air cons place a seed `corvp` + nanos, the
  seed makes `corcv`, which place the `coravp`. Farms live outside the lattice beside a reserved
  lane (`armor_controller.lua`); cells are reserved by writing the macro's `assignedAnchors`.
- **BAR gives every new constructor a GUARD on its factory.** An "is it idle?" check on such a
  unit never passes; treat "empty queue or first command GUARD" as idle.
- **Units made while the eco compounds only slow it** (user): the farms are built early (capacity)
  but production waits for 15:00 or a >=45% metal bank.
- **Line units held near home** (nodes freeze whenever an enemy is within 600 elmos). From 6:30
  every line unit now attack-moves onto a ring around the enemy base. Against RAIDER_BOT this took
  commander kills from 26:03 (or none) to 13:41 / 15:24, both slot orders.
- Evidence is single matches vs the air exploiter fixture, not an `ab_test.py` verdict. phi at
  20:00 ranked the baseline higher (402k vs 178k) while the candidate won: phi rewards a bigger
  economy and does not see attack tempo.

## Compare bots within a match, not across matches (2026-09-24)

Most run-to-run noise is shared by both teams in a match. In one A/B, match 1 came out ~15%
richer than match 2 for *both* bots. `ab_test.py` now judges on the within-match ratio
(A value / B value), takes the geometric mean over both slot orders to cancel the slot bias,
and defaults to one match per slot. The within-match ratio isn't noise-free: over 8 matches
with no real effect its log sd was ~0.10 (same condition ranged 0.877–1.208), so the bar is
~2σ: ×1.15 at one match per slot, ×1.08 at three. Mirrors alone looked tighter (1.2–9.9%,
slot 0 ahead every time); four mirrors are too few to set a bar with.

Two DRAGON_BOT changes tested this way (energy look-ahead, air-con reserve) both moved their
mechanism clearly and army value at 8:00 not at all. Details in `knowledge/scoring.md` and
`strategy_log.jsonl`. Both were kept at the author's decision.

## The stats tracker was blind to enemies: GetVisibleUnits is camera-culled (2026-09-23)

`metalbot_stats_tracker.lua` found enemies with `Spring.GetVisibleUnits`, which returns units
in the **camera's** view. Headless processes have no real camera. In all 6 saved matches with
tracker data, a snapshot saw at most 1 enemy and never a radar blip, even while the same
process lost up to 30 units to named killers. Fixed by using `GetAllUnits()` + an ally check
(what `threat_map.lua` and the bots already do). A DRAGON mirror now sees up to 28 enemies in a
snapshot. **Every `vis_*` field and `first_enemy_*` event in older results is close to blind.**
So are the find_weakness detectors that read them (late_scouting, no_early_warning,
radar_warning_unused, the sighting half of no_counter_air). Don't use `GetVisibleUnits` for
game logic.

Found while building the state-value score (`bot_score.py`, `knowledge/scoring.md`). The same
work showed DRAGON_BOT's only ground lab (`corvp`) walled in by nanos around 8:30–9:00, after
which build power becomes the bottleneck (`fac_boxed` event, `production_reach` 0.5).

## Speed follows the sim now; where the frame time actually goes (2026-09-23)

A fixed 10x let the bots fall behind once a match got big: at ~600 units a side each bot
process only sims ~130 frames/s (~4.3x), so latency climbed to 150–450 frames in the last
minutes. `--speed auto` (default) adds a Speed Governor on the spectator host that steers the
speed (2x–40x) to hold the bots' order round trip near 30 frames. It reads the latency probe's
messages every 15 frames and adjusts every 0.25 real seconds; the engine's own speed control
only runs every 2 real seconds. DRAGON_BOT mirror, 11 min: ~20 frames for both teams the whole
way, speed ~11x → 7x → 2x.

`--profile` breakdown at ~600 units a side (per sim frame): engine + BAR gadgets ~88%, bot
widgets ~6% (macro controller ~0.35 ms per 10-frame tick, growing about linearly with unit
count), **BAR's stock UI widgets ~5%** (AdvPlayersList, Reclaim Field Highlight, Grid menu,
Top Bar... all running headless for nothing). A static pass over the bot Lua found no
superlinear hot paths: `blueprint_placer.ComputeBlockers` is O(n³) in name but runs once per
game over a few dozen items. The worst scaling ones are O(incidents × whole team):
`threat_map.ProductionUrgency` → `AvailableStrength` walks every owned unit (structures
included) per incident, every 30 frames, and `OnDamaged` scans all contacts per hit when the
attacker is unknown. Both are small today; they're the first to fix if the profile ever
shows `Unit_Controller` climbing.

Stock widgets that give orders — **Auto Repair Idle Builders, Clean Builder Queue** — also run
on both bot processes and touch the bots' units. Not changed yet.

## Team 1's order latency was a harness artifact; fixed without touching bots (2026-09-23)

The client-side latency behind `d5501fd` and the lab-controller grace period was measured
directly with a harness-only probe (`LATENCY_PROBE_WIDGET` in `bot_testing.py`: a LuaUI message
to itself every 15 frames, same server path as a unit order). Old layout, DRAGON_BOT mirror:
**team 0 (host) 32 frames, team 1 (client) 105–225 frames** — team 1 did everything 3–7
game-seconds late. Causes, from the Recoil source:
- A UDP client pays ~33 ms each way (`chunksPerSec = 30` hard-coded in `UDPConnection.cpp`; not
  configurable — `ServerSleepTime`, `NetworkLossFactor`, `UseNetMessageSmoothingBuffer` were
  already at their lowest-latency values). The host's own client uses an in-process connection
  and pays none of it. Real-time lag x sim rate = frames, so 100x made it enormous.
- Every engine process pins its main thread to the same "preferred" core (0x4000 here), so the
  two headless processes time-sliced one core.

Fix (`bot_testing.py` only): a third, bot-less **spectator process hosts** (`--server
spectator`, default) so both bots are identical UDP clients; each process gets its own main core
(`SetCoreAffinity`, `main_core_masks`); default **`--speed 10`**. Rejected: `spring-dedicated`
as host — it has no local client to pace to, generates frames on the wall clock, and at speed
100 left both bots 500→16 000 frames behind. A spectator host at speed 100 is also no good: with
no bot Lua it outruns the players (up to 2000 frames behind).

Verified, 3+ mirror matches per layout (team 1 minus team 0, and team 1 / team 0 metal produced
at frame 7200):

| layout | latency t0/t1 | first con bot | 10th mex | metal t1/t0 |
|---|---|---|---|---|
| old (host, 100x, shared core), 5 runs | 32 / 105–225 | +0 … +96 frames | −215 … +1275 | 0.74, 0.75, 0.76, 0.87, 1.07 |
| new (spectator, 10x), 4 runs | 20 / 20 | −11 … +9 | −450 … +414 | 0.84, 0.97, 1.04, 1.17 |

Team 1 fell behind in 4 of 5 old runs; the new runs scatter around 1.0 (what's left is ordinary
noise). **The slot-0 advantage measured before this date includes this effect**, so re-measure it
before blaming spawn geometry. The bot-side latency guards (grace periods, shift-queued orders)
are still worth keeping — 20 frames is not zero, and a real game has latency too.

## ⚠ MEASUREMENT VALIDITY — read this before trusting any result above

**Every result logged before 2026-09-18 ~04:00 is confounded and must not be used to rank
bots.** `bot_testing.py` had three independent defects that all favoured whichever bot was
passed as `--bot1` (team 0). Discovered by the obvious control that had never been run: a
**side-swap** (same two bots, slots exchanged) and a **mirror match** (one bot against
itself). The side swap reversed the winner every time, and the mirror match "proved" a bot
beat itself 2321 to 1143.

1. **Team 1 self-destructed its own commander in every match.** `setup_player` was called
   with `do_selfd=True` for P1 and `False` for P0. At `duration - 150` seconds team 1 killed
   its own commander; with `deathmode=com` that ended the game and handed team 0 a
   `game_over` win by construction. It also cut team 1's building time in half, which is
   exactly the ~2:1 units-built ratio seen in every logged match. **Every `winner_method:
   game_over` result in `strategy_log.jsonl` is this, not a real commander kill.**

2. **`fullview=1` does not give cross-team visibility in headless, and the harness assumed
   it did.** Each process only reliably sees its own team. `_parse_logs` read team 1's
   score from *P0's* log (`nc_p0[1] if nc_p0[1] > 0`), i.e. from the process that cannot
   see team 1 — undercounting whoever sat in slot 2 by roughly 5x. In one mirror match P0's
   log said team 1 built 341 units while P1's log said 1731. Same for the sanity check: P0's
   blind reading overwrote P1's correct one, which is why **team 1 shows "0 units at 1 min"
   in literally every historical result** — that `[FAIL]` was never real.

3. **The `[DRAW_SCORE]` adjudicator was computed inside a single process**, so it always
   concluded its own team was winning. For one and the same frame, P0 emitted
   `mv0=194262 mv1=12599` and P1 emitted `mv0=9904 mv1=54920`. Only the own-team half of
   each line is meaningful. It also keyed off `DRAW_FRAME` (135 000 frames = 75 game-min),
   which a 300s match never reaches (~31 000 frames), so the fair path never ran at all.

**Fixed 2026-09-18** in `bot_testing.py`: `do_selfd=False` for both players; the stats widget
now adjudicates on a wall-clock deadline both sides share; team 0's numbers always come from
P0 and team 1's from P1; the verdict compares P0's own-team `mv0` against P1's own-team
`mv1`. After the fix both teams pass the 1-minute sanity check for the first time.

**Rules going forward.** Never rank two bots on a single match. Always run both slot orders
and require the same bot to win both. Always mirror-match a new bot against itself first to
measure the residual slot bias before reading any margin as real. `units_built` alone is
still weak (team 0 saturates the ~2000 unit cap); prefer the `draw_score` army-metal verdict.

- **A large, genuine slot-0 advantage still remains after all three fixes, and it is a *bot*
  bug, not a harness one** [mirror match, 2026-09-18]. `champion_v1` against itself still
  scores mv0 198 280 / mv1 86 072. Team 0 spawns at (2400, 848) — the top-left corner — and
  team 1 at (9648, 11408), bottom-right. `macro_controller.lua` hardcodes its expansion
  direction: initial grids go west/south/north and `TryExpand` refuses any anchor with
  `anchorX > baseX + GRID_SPACING`, so the bot only ever expands *west*. From the top-left
  spawn that means expanding into its own safe corner; from the bottom-right spawn the same
  rule aims expansion at the middle of the map, straight into contested ground where it gets
  killed. The bot is written for one spawn. **Making expansion direction relative to the
  enemy (expand away from them, not always west) is the highest-value open improvement** —
  it should roughly halve the mirror-match gap, which is now the cleanest available
  regression metric.

## Unit-control architecture: the commander now survives the ground raid (2026-09-22)

DRAGON_BOT got a real unit-control architecture (see the plan and `bar_framework/`:
`map_model`, `threat_map`, `army_broker`, `scout_plan`, plus a `corvp` defence plant and a
production floor). The finish line was the exploiter fixtures, judged on `commander_lost` —
binary, and far above any noise floor. Real kills only (named killer, before the end-of-match
self-destruct); runs whose clock stalled were discarded.

Final matrix, **exact final build**, two runs per cell:

| matchup | before (step 4/5) | final build |
|---|---|---|
| GROUND_RAIDER_BOT, DRAGON slot 0 | **killed** 7:57, 8:53 (by `corgator`) | **survived 2/2** |
| GROUND_RAIDER_BOT, DRAGON slot 1 | — | killed 2/2 (6:49, 8:21) |
| RAIDER_BOT (air), DRAGON slot 0 | survived 2/2 | survived 2/2 |
| RAIDER_BOT (air), DRAGON slot 1 | — | 1/2 |

Pooling every valid run since steps 6–8 landed (several intermediate builds, so indicative
only): ground slot 0 survived 5/5, ground slot 1 4/7, air slot 0 4/4, air slot 1 6/10.
**Slot 0 is solved; slot 1 is roughly a coin toss.**
An earlier draft of this entry said "slot 1 survived 4/4" — that was an intermediate build and a
small sample, and the final matrix disproved it.

**Slot 1 is governed by macro timing, not unit control.** Across today's slot-1 runs the macro's
hand-off (which places the air lab when metal starts banking, and frees the con bot for the
vehicle plant) landed anywhere from **frame 6,780 to 11,370 — 3:46 to 6:19**. Every defensive
asset hangs off it, and the slot-1 raid lands ~5:48–6:20. Losses line up with late hand-offs:
- ground slot 1 loss: hand-off 5:02; the vehicle plant's build-queue order sat unbuilt for 1,810
  frames, was retried, and the raid destroyed its half-built nanoframe. Army was 0 at 6:00–7:00.
- air slot 1 loss: the air lab was only queued at 5:14 and never finished before the commander
  died at 6:33; the bombers landed at 5:27.

**Correction — it is NOT expansion direction.** An earlier draft blamed the spawn-geometry bug
(macro expanding into the contested middle). A DRAGON-vs-DRAGON mirror disproved that: every grid
on both sides sat within ~1,000 elmos of home, neither drifted more than ~7% toward the enemy,
and the two spawns are near-symmetric distances from their map edges. That note dates from an
older macro.

What the mirror actually shows (tracker `eco`/`units` rows, identical code both sides):

| time | slot 1 metal produced / slot 0 | build power s0 / s1 | mex s0 / s1 |
|---|---|---|---|
| 0:00–1:30 | 1.00 | equal until 1:30 | equal |
| 1:30 | 1.00 | **435 / 235** | 3 / 3 |
| 3:30 | 0.79 | 1170 / 970 | **14 / 6** |
| 4:00 | 0.73 | 1170 / 970 | 20 / 12 |
| 4:00–7:00 | 0.73–0.78, **flat** | | |

**The whole slot-1 deficit is created between ~1:30 and 4:00, then carried forward unchanged** —
after 4:00 both slots grow at the same rate. At the measured ~1.58 min doubling time, a 27% deficit
is ~45 s of lag, matching the 44 s hand-off gap in the same match (3:39 vs 4:23). It is not idle
builders: slot 1 had LESS idle BP (0–200 vs 150–1000). It is build power arriving later — about
one early builder's worth by 1:30 — i.e. something in the opening completes later on the client.
That is consistent with the `d5501fd` finding that client-side order latency was sabotaging team
1's opening; that fix cut skips 26 → 2, and this looks like the residue. **Next thing to
investigate: the opening's second con bot and first nanos on the client, frame by frame, in a
mirror match.**

A cheaper partial fix for defence, inside scope: the vehicle plant's fallback path (build queue,
used when the timer fires before hand-off) is unreliable — the reserved-con-bot path only exists
after hand-off.

**What each fix bought, in order found:** the vehicle plant was never built at first (the
build queue had no builders left after hand-off — a con bot is now held back for it); ground
slot 1 died until production urgency counted threats *approaching* as well as attacks already
landing (warning from pickets was otherwise wasted); air slot 1 died until the lab controller
got an order-grace period, front-of-queue insertion for defence, and a stall guard that no
longer blocks the floor (see the next entry).

## The order-latency bug came back in the lab controller (2026-09-22)

Against RAIDER_BOT from slot 1, DRAGON_BOT's commander died to bombers with **0–1 fighters
alive by 6:00**, while slot 0 had 4–5. The lab controller logged five scouts and two fighters
queued in eight seconds (4:56–5:04), yet the tracker showed `in_progress=0 fac_idle=2` at 5:00:
**both labs idle, nothing being built**.

Same cause as the macro bug fixed in `d5501fd`: reading a factory's queue back
(`GetFactoryCommands`) **lags on the client process**, and team 1 is the client. `QueueEmpty`
kept answering "empty" for orders already sent, so the controller re-ordered every tick. Scouts
were never counted because they did not exist yet (`UnitCreated` had not fired), so it kept
queueing more — and it only happens from slot 1, because the host sees its own orders
immediately. The macro got a grace period after each order (`ORDER_GRACE_FRAMES`, 30 → 90); the
lab controller never did. It now has `LAB_ORDER_GRACE = 120`.

**Rule: any widget that reads a queue back after writing it needs a grace period, or it will
double-order on the client.** Better, don't read back at all: `bar_framework/army_broker.lua`
tracks what it last ordered widget-side for exactly this reason. Symptoms to recognise: a unit
type overproduced from slot 1 only, and factories idle while the log says they were ordered.

Found in the same investigation:
- **The macro keeps the air lab's queue full of constructors**, so a lab controller that only
  acts on an empty queue may never get a turn. Defence units now go ahead of the queue via
  `CMD.INSERT` at position 1 (BAR's own `unit_factory_quota.lua` pattern; position 0 cancels
  the build in progress).
- **The stall guard blocked the defence floor**: the economy runs a deliberate stall through
  the whole growth phase, so "skip production while stalled" meant the floor was never built.
- **The harness rewrites `local DEBUG = false` to `true`** in bot files, and patches team IDs in
  bot files only — `bar_framework` modules are copied unpatched, so they must take team/ally IDs
  through `Init` rather than calling `Spring.GetMyAllyTeamID()`.
- **In slot 1 the air lab comes up at ~4:57 vs ~4:04 in slot 0** (spawn-geometry bug slowing the
  bottom-right macro), and bombers land ~5:24. No production priority can fully close a
  27-second window; that part is a macro problem.

## Army value at frame 14400 cannot see unit-control changes — measure the mechanism (2026-09-22)

The line fixes (width cap, active-span cap, muster pool, and the three lost constants) came
back `NO DIFFERENCE DEMONSTRATED` from `ab_test.py` against the step-3 bot: army value
25,215 / 14,819 vs 25,036 / 13,156 (slot 0 / slot 1). Taken at face value that says the
changes did nothing. They did a great deal — the metric just could not see it.

The same six result files, read for what the change actually targets (tracker `army` rows,
`n >= 3`, frames <= 18000), with `ab_test`'s own non-overlap bar:

| metric | step 4, slot 0 | step 3, slot 0 | step 4, slot 1 | step 3, slot 1 |
|---|---|---|---|---|
| `spread` | 1038–1109 | 2344–2528 | 801–986 | 2231–2515 |
| `main_share` | 0.87–0.89 | 0.59–0.73 | 0.82–0.90 | 0.58–0.67 |

**All four separated, zero overlap.** The army is ~2.5x more concentrated and went from ~4
groups to ~1.9. That is a demonstrated effect by the harness's own conservative standard.

**Replicated on independent hardware** (Pi 1, aarch64, its own A/B run): all four separated
again — spread 747–1029 / 439–711 vs 2305–2508 / 1958–2158, main_share 0.87–0.92 / 0.85–0.93
vs 0.65–0.70 / 0.48–0.62. Eight of eight comparisons across two machines. Pi 1's army-value
verdict was also `NO DIFFERENCE` (28,517 / 13,756 vs 26,707 / 13,613), with a 2.66x spread.

**Why army value was blind:** against OK_BOT almost no fighting happens before frame 18000 —
`pm_deaths` 0–0.33 and `lost_enemy_army_mv` 0–19 metal across all runs. DRAGON_BOT also fields
no army at all until ~6:00 (broker echo: `units=0` through minute 5). So at frame 14400 its army
is about two minutes old and has barely engaged, and army value is measuring how much was
*produced*, not how well it was *used*. Positioning, cohesion and retreat change *losses*, and
there are none yet to change.

**Rules this gives:**
- For a unit-control change, the A/B verdict on army value is expected to be `NO DIFFERENCE`
  and is not evidence either way. Compare the tracker field the change targets, across the
  same result files (`ab_test` keeps them in `%TEMP%\abtest_*`), using the non-overlap bar.
- Cohesion: `spread`, `main_share`, `groups`. Engagement quality: `pm_isolated / pm_deaths`,
  `pm_support_avg` — but only once there is combat to measure, which vs OK_BOT there is not.
- Threat response needs an opponent that actually attacks early: RAIDER_BOT / GROUND_RAIDER_BOT,
  judged on `commander_lost`, which is binary and far above any noise floor.
- Noise was unusually high in both A/Bs this session (worst within-condition spread 1.80x and
  1.81x vs the documented 1.14x), which is one more reason not to lean on army value here.

## Spring names the RECLAIMING unit as the attacker in UnitDestroyed (2026-09-22)

Building the threat map (`bar_framework/threat_map.lua`), own-unit losses were counted as
evidence of an attack. That raised a 470-point "respond"-band threat at **2:38** — minutes
before an Incisor could physically cross the map (`corgator` speed 85 needs ~4577 frames for
the 12,968-elmo cross-position spawn distance). The loss value 470 is exactly `corlab`'s metal
cost: it was the bot **reclaiming its own starter lab**, which the build order does by design.

The first fix — "only count a loss if `attackerID` is set, since a reclaim has no attacker" —
**did not work**, and the reason is the lesson: **Spring passes the reclaiming unit as
`attackerID`**, so our own nano eating our own lab arrives at `widget:UnitDestroyed` looking
identical to an enemy kill. The working test is the attacker's *ally team*:

```lua
if attackerID and Spring.GetUnitAllyTeam(attackerID) == myAllyID then
    attackerID = nil   -- our own reclaim, not an attack
end
```

Generalises: **`attackerID ~= nil` is not "an enemy did this".** This is the mechanism behind
the already-documented "bot reclaiming its own starter lab logged as an enemy loss" warning in
CLAUDE.md — that note says the symptom, this is the cause. Anything keying off `UnitDestroyed`
(loss accounting, threat detection, retreat triggers) needs the ally-team check, because this
bot reclaims its own buildings constantly: starter lab, grid retrofits, wind recycling.

Second bug found in the same pass: **incident severity must not be allowed to fall.** Threat
score depends on what is visible *right now*, so a raider stepping out of LOS made one attack
oscillate respond → watch → respond within seconds. Committing and recalling units on that
flicker is worse than not responding. Bands now only ever climb, and attacks end by expiring on
a timer (`INCIDENT_TTL`), not by momentarily looking calmer.

Verified against both exploiters, echo-only: GROUND_RAIDER_BOT registers `ground` at 5:53-6:42
(known arrival ~6:30-8:00) and RAIDER_BOT registers `air` at 5:29 escalating to alarm at 5:57
(known arrival ~4:30-5:00, commander kills 6:11-8:39) — i.e. the alarm lands *before* the kill
window. Bombers are the unseen-attacker case and still resolve to the `air` channel, because
the channel is inferred from recent nearby contacts when `attackerDefID` is unavailable.

## Client-side order latency was silently sabotaging team 1's opening (2026-09-22)

A DRAGON_BOT-vs-itself match showed team 0's opening completely clean (lab, con #1, con
#2, reclaim, all on schedule, one stray decay) while team 1 abandoned 9-20+ structures
mid-build in the same window, every run, 100% reproducible — including its own bot lab,
more than once in the same game. Chased with `blueprint_placer.lua`'s own (normally-off)
DEBUG logging rather than guessing: team 1 showed the SAME build order claimed, retried
3 times 30 frames apart with `cmd=none` (the builder's queried command queue read empty),
then SKIPped and reassigned to a different item — for cormex, corwin, AND corlab alike,
not one unit type. The stats log then showed the "abandoned" building complete moments
later anyway: **the order had genuinely landed; `Spring.GetUnitCommands()` just hadn't
caught up with it yet when the check ran.**

**Root cause: `ORDER_GRACE_FRAMES` (30 frames, tuned against host-side behaviour) is too
short for team 1, the network CLIENT side.** `bot_testing.py` runs team 0 as the host
and team 1 as a connecting player; a host process seeing its own just-issued order
reflected in `Spring.GetUnitCommands()` is near-instant, but the client side can take
several real seconds. One match, four minutes: **team 0 (host) — 0 skips, 0-1 retries.
Team 1 (client), same code, same match — 26 skips, 79 retries.** Ruled out first (and
worth recording as dead ends): `patch_team()` not covering `bar_framework/*.lua` or
`blueprint_placer.lua` — checked empirically, both `Spring.GetMyTeamID()` and
`GetMyAllyTeamID()` read correctly (0/0 and 1/1) on both sides regardless; disabling the
escape guard entirely — made it measurably WORSE (fewer nanos, lower income), since the
guard's job is freeing a genuinely walled-in builder and removing it just leaves that
builder stuck with nothing rescuing it.

**Fix, in `blueprint_placer.lua` (shared — every bot gets this):**
1. `ORDER_GRACE_FRAMES` 30 -> 90 frames.
2. Every distributed builder is now given a SECOND, shift-queued order the moment the
   first is issued (`FindShiftCandidate` mirrors `FindClaimable`'s own selection — strict
   order in the opening, nearest-in-range after it — so it is a genuine reservation, not
   a weaker guess), refilled every time the active order changes (on issue AND on
   promotion), not just once. A slow confirmation matters far less when the builder
   always has real, engine-side work queued regardless of what the poll currently reads.
   Reclaim-target items are excluded as *candidates* (their target isn't resolved until
   issue time) but still get something queued behind them once active.

Same match after the fix: team 1's skips dropped from 26 to 2 and self-decayed
structures from double digits to 0-2, run after run; team 0 stayed at 0. Verified across
DRAGON_BOT, RAIDER_BOT and GROUND_RAIDER_BOT (all share the file). **This is a
host-vs-client asymmetry in the harness, not a per-bot bug** — any future distributed
build order is exposed to it, and if this project ever runs a real (non-localhost)
multiplayer match, round-trip latency could be far worse than headless-localhost, so the
same class of fix (never trust a single order-landed check; always keep real work
queued) is worth re-checking there too.

**Two smaller bugs found chasing this, both fixed:**
- **The escape guard had no opening-item protection.** When a ground builder got walled
  in, it would reclaim the cheapest nearby structure to free itself — including a
  half-built OPENING item, sacrificing scarce early metal to eat one piece of its own
  base. Saw it reclaim the same partially-built wind four times in under 1000 frames.
  Fixed by excluding any item with `idx <= OPENING_ITEMS` from ever being offered as a
  reclaim candidate (`EG.Check`'s new optional `protected` set).
- **A nano guarding an idle factory spends its build power on nothing.** `GUARD` only
  assists what a factory is *currently* building; the bot lab sits genuinely idle for
  real stretches (between con #1 and con #2, briefly at game start), and
  `FactoryInReach` picked the nearest factory regardless of whether it had anything
  queued. Fixed in `DRAGON_BOT/macro_controller.lua` (and both raider variants, copied
  from it) by checking `Spring.GetFactoryCommands` is non-empty before offering a
  factory as an army target.

## Exploiter bots: RAIDER_BOT and GROUND_RAIDER_BOT test threat response on demand (2026-09-21)

`find_bot_weakness`'s own Limits section flagged this: there was no scripted early-raid
opponent, so `early_threat_undefended` could only be observed when OK_BOT happened to
raid, which it doesn't reliably. Built two deliberate "exploiter" fixtures instead —
DRAGON-derived bots whose whole job is to hit a known weak spot (no dedicated AA, no
defensive structures) as early as the economy allows, so threat response becomes
testable on demand rather than something to hope for.

**`build_order_sim.py` gained a `raid` mode**, config-file driven
(`raid_configs/*.json`) instead of a pile of CLI flags: a list of `{unit, count, by,
required}` milestones (e.g. "3 bombers by 230s, required"), an optional `max` cap per
unit, and a `weight` that raises how much the raid fraction counts against pure economy
in the search. `required` milestones prune any build order that cannot meet them, so the
sim is told what to prioritize, not begged for it. `blueprint_gen.py` exports the
chosen unit order as `M.units` for `lab_controller.lua` to queue, and (for ground units)
reserves an exit corridor in front of a factory (`CORRIDOR_ACTIONS`, exported as
`M.keepout`) so nothing else in the layout blocks it — `macro_controller.lua` keeps mex
grids off that rectangle and mirrors the whole blueprint 180 degrees when spawning in
the map's far corner, so the corridor always points at the enemy.

**RAIDER_BOT** (bombers, `corshad`) reaches the enemy base by ~4:30-5:00 and reliably
kills DRAGON_BOT's commander before its own economy properly scales (measured commander
kill at 6:11-8:39 across several runs). Bombers needed dynamic re-targeting to matter:
the first version picked the single nearest enemy unit (usually one nano) and, worse,
kept re-aiming at a target's STALE remembered value even after it was destroyed, so a
flattened cluster still "looked" valuable and every bomber kept bombing empty ground.
Fixed with a value-weighted cluster search (aim at the densest nearby group, not the
nearest unit) plus live re-checking: the aim's remaining value is recomputed continuously
and a bomb-drop schedules a fresh look 45 frames later.

**GROUND_RAIDER_BOT** (Incisors, `corgator`, with `corveng` fighter escorts against
Shuriken stun) is slower to arrive (~6:30-8:00) but equally effective once there — also
recorded a commander kill. Untested: whether the fighter escort actually stops a
Shuriken stun, since DRAGON_BOT never fielded one in any recorded run.

**Verdict on DRAGON_BOT, confirmed by both:** it has no answer to either raid style. Its
commander dies before nanos/army/AA exist in every recorded run against either exploiter
— this is `find_bot_weakness`'s previously-`Not exercised` finding, now demonstrated
rather than merely suspected. Saved matches and their `find_weakness.py` context are in
`knowledge/raid_runs/`. Both bots are copies of `DRAGON_BOT`'s opening logic, not
divergent forks — the client-latency fix above was verified on all three.

- **Bug worth flagging for anyone else deriving a bot from DRAGON_BOT's macro:** after
  the kickstart's bot lab is reclaimed, `botLabID` goes back to `nil`; the NEXT factory
  the macro sees (a raid variant's own vehicle plant) was silently adopted as "the bot
  lab", which made the macro order a `cormlv` minelayer as if it were a starter con bot.
  Any bot whose blueprint places a second, non-`corlab` ground factory needs the same
  explicit exclusion `GROUND_RAIDER_BOT/macro_controller.lua` now has.
- **The slot-0 test advantage has (at least) two separate causes, not one.** The
  existing champion_v1 finding above (hardcoded west-only expansion) is real for that
  bot line. Separately, per the user: OK_BOT has a hard-coded facing direction (always
  faces east), so from one spawn corner its production faces away from the enemy and its
  eco expands toward them — the opposite of what you want — while DRAGON-derived bots
  don't have this to the same degree. `ab_test.py` matters less for RAIDER_BOT /
  GROUND_RAIDER_BOT as a result; they are deliberate exploiter fixtures, not champion
  candidates, and should stay in their own folders rather than being merged into one.

## Scaling: the exponent is fixed at ~1.58 min/doubling (2026-09-21)

`DRAGON_BOT (formerly DISTRIBUTED_BO)` now runs kickstarter -> hand-off -> mex grids -> T2 retrofit.
Measured from replays (`replay_analysis.py` + a log-linear fit on the engine's own 15s
`TeamStatistics` samples). It beats OK_BOT 4x on army value by frame 25200.

### The doubling time does not move

| configuration | metal doubling | energy doubling | peak m/s |
|---|---|---|---|
| max_rate opening (6 min plan) | 1.59 min | 1.50 min | 3721 |
| em-ratio 8 opening (4.5 min plan) | 1.58 min | 1.50 min | 3575 |
| + T2 retrofit of finished grids | 1.56 min | 1.57 min | **7276** |

R^2 on the log fit is 0.98-0.99 in every case, over 12+ game-minutes and three doublings.
**Five quite different configurations all landed on ~1.58 min.** Changing the opening
plan, rebalancing energy against metal, moving the hand-off a minute earlier and doubling
income per unit all failed to move it. The exponent is set by how fast a grid reaches its
nano threshold and seeds the next one — everything else only changes where the curve
starts or stops.

### Retrofit raises the ceiling, not the exponent

Time to reach each income level is IDENTICAL with and without the T2 retrofit — 1600 m/s
at 12.25 min, 3200 m/s at 14.25 min in both — and then the retrofit run carries on to
6400 m/s at 16.25 min where the others simply stop. Peak income per live unit went
**0.73 -> 1.46 m/s**, exactly double, which is what replacing T1 mexes with T2 should do
when the unit cap, not metal, is the binding constraint.

Read the milestone table, not the "growth phase" fit: measured to its own peak the
retrofit run fits 1.65 min/doubling, but that is the last two minutes flattening against
the new ceiling dragging a log-linear fit, not slower compounding.

### Why this is close to the practical limit

Over the growth phase (2-16 game-min) of the retrofit run:

- metal: 1,122,717 produced, **89.4% spent, 0% floated**
- energy: 14,445,550 produced, 88.1% spent, 11.0% floated

Per-sample metal utilisation sits between 77% and 130% (over 100% = spending storage down
faster than it fills). There is no idle metal left to convert into growth, so a faster
exponent cannot come from spending *more* — only from spending on something with a shorter
payback, or from removing latency (travel, placement, the gap between a grid finishing and
the next being seeded).

### Retrofit mechanics that mattered

- **Eligibility must be "mostly done", not "done".** A 73-item grid driven by one air con
  almost never completes: gating retrofits on `done` meant exactly ONE grid in a whole
  game qualified. Switching to the placer's `mostlyDone` (70% of the queue) made them run
  in parallel. The same trap applies to anything keyed on a grid finishing.
- **Recycle the specialist builder.** A T2 con that finishes a retrofit goes straight back
  to the pool; without that you get one retrofit per con ever built.
- **A T2 mex is less metal-efficient than a T1.** Retrofit builders are stopped below 15%
  metal storage and resume above 30%, so a retrofit never competes with a normal grid for
  metal during a stall.
- **Overlay blueprints clear their own ground** (`clearBlockers`): a 5x5 fusion overlaps
  the corner mex and two winds, and a 4x4 T2 mex sits exactly on the T1 one. The placer
  reclaims the friendly *structure* in the way (never a builder, nano or factory) and then
  builds, so no hand-written reclaim entries are needed in the blueprint.

### An army is needed, and it is nearly free

Nano build power is split army/eco by what each nano is pouring into: a factory or a
mobile unit is army spending, a structure is eco. Target 30% army, 100% when unit-cap
headroom drops below 1000. Control is `CMD_GUARD` on a factory versus `CMD_STOP` (a
released nano falls back to auto-assisting nearby construction).

Two traps: build power is quantised in whole nanos, so a share-versus-dead-band controller
makes a single nano flip between 0% and 100% every tick — move a nano only when doing so
gets *closer* to the target. And **the unit controller never advances without scouts**: it
only sets a target after seeing 3+ enemies, so a bot that builds no scout parks its whole
army at home for the entire game. It now falls back to advancing on `DefaultTarget()`.

## Early-game macro: the sim-derived opening, executed distributed (2026-09-20)

A "kickstarter" bot (`DRAGON_BOT (formerly DISTRIBUTED_BO)`) that runs one ordered, sim-generated
build order with several builders sharing the queue. Reached **184 m/s at 6 game-min**
in-game, against ~50 m/s for OK_BOT-class bots at the same point. Everything below is from
that work. Engine-level facts it depends on are in `game_mechanics.md` §2.7.

### The handover point is measured, not guessed — frame 8000-9000

From a real replay (engine `TeamStatistics`, 15s samples, via `replay_analysis.py`):

| game-min | frame | metal produced | metal used | surplus | metal binned |
|---|---|---|---|---|---|
| 4.0 | 7200 | 46.0 | 43.0 | +3 | 0 |
| 4.5 | 8100 | 80.3 | 23.9 | **+56** | 0 |
| 5.0 | 9000 | 97.0 | 26.0 | +71 | **396 (starts)** |
| 5.5 | 9900 | 127.4 | 26.8 | +101 | 2194 |
| 6.0 | 10800 | 159.4 | 17.6 | +142 | 5535 |

**`used` FALLS from 43 to 17.6 m/s while production quadruples.** After ~4.5 min this bot is
not income-limited, it is *placement*-limited: builders cannot start frames fast enough to
spend what the mexes earn. 6763 metal was binned by minute 6.2. This is the same
"minutes 7+ are BP-limited" turning point as the section below, arriving ~2.5 min earlier
because the economy is faster — so **the crossover moves with the opening and must be
re-measured, not copied**. Trigger the handover on the condition (stored metal ≥ ~60% of cap
for ~5s), not on a frame number.

Only a replay from a **cleanly exited** game carries these stats; if the window is closed
mid-game the engine never writes the footer and `replay_analysis.py` reports `Duration: 0s`.

### The opening must be executed literally

Three separate attempts to be clever with the first ~20 buildings all lost ground:

- **Reordering by distance boxed the cons in.** Letting a builder take the nearest of the
  next N claimable items (instead of the lowest index) is a real win for walking time later,
  but in the dense opening cluster it has builders wall themselves in with their own
  buildings. Items 1-20 are now claimed in strict blueprint order (`OPENING_ITEMS`).
- **Leaving frames early kills them.** Walking away from a part-built frame at 85% is only
  safe once a *finished* nano turret covers it; early on there are none, and an unworked
  nanoframe decays and dies, losing the metal already spent.
- **Lowering the 85% handoff to 30% made it worse in game**, even though the reasoning is
  sound (nanos hold most of the build power, so a mobile builder is worth more placing the
  next frame than finishing this one). Tried at the point where `used` collapses, which is
  where it should have helped most. 0.85 is the setting; don't re-litigate without a
  measurement.

### Anchor the blueprint OFF the commander

A blueprint anchored on the commander's own position makes the engine shove the commander
aside before it can build — seconds lost at the worst possible moment, and the bot lab is
big enough to do it again later. Offsetting the whole layout diagonally (`(64, 64)` here)
clears the spawn while keeping the entire opening inside the commander's build range: it
places the first two winds, the lab, the first mex and both nanos **without moving at all**.
Check this arithmetic against the actual layout when the blueprint changes — build range is
`buildDistance + the target's footprint half-extent`, so ~152 elmos to a wind for a
commander, not 128.

### Sim constraints that changed the plan

- **Forcing a 2nd con bot 60s after the first raised the sim's plan from 170 to 265 m/s.**
  Constraining the search made it *better*, because one con was starving the queue of
  placements. Worth suspecting other "optimal" plans of the same thing.
- **Reclaiming the bot lab (+470 m) is part of the build order**, not an afterthought — the
  plan does not balance without it, and it must be gated on the last con having rolled out.
  Items the generator lays onto the freed ground have to wait for that reclaim, or they fail
  `TestBuildOrder` and get skipped permanently.
- **Energy floating is not worth optimising against.** Parking resources in a part-built
  structure was implemented end-to-end (sim action, generator flag, placer support) and then
  removed: in an idealised schedule the sim floats **13 energy** across 360s. The float a
  player sees comes from idle gaps the sim does not model, and the real waste is elsewhere —
  600 m of metal late in the plan, and 33.6% of all energy produced in the measured game.
  The M:E production ratio there was 0.12, i.e. the opening builds far more energy than this
  plan can spend.

### Caveat

All in-game figures here are single observations read off a live game, not `ab_test.py`
results — they are directional only. The bot also builds **zero combat units** after the lab
reclaim, so it loses on army value regardless of its economy; it is an economy skeleton
meant to hand over to the main game loop at the crossover above.

## Expansion is limited by PLACEMENTS, not by builders

Run `20260918_073000` bought an extra air con whenever stored metal exceeded 800 after
minute 6, to spend the surplus. It did not work, and the way it failed is the useful part:
**stored metal went UP, not down** — slot-0 stored metal ran above baseline at every
checkpoint (minute 8: 1143 vs 1008; minute 11: 4071 vs 2667). Extra cons did not become extra
grids; they became idle aircraft while metal kept accumulating.

So the throttle on expansion is **the number of valid placements**, not the number of builders
available to fill them. Adding build capacity of any kind — cons, nanos, assists — cannot
help, in either phase, for the same underlying reason.

Note also that *both* bots sit on 2667–4071 metal at minute 11. The waste is large and it is
not specific to any candidate. The open question is where to put that metal:

- `TryExpand` filters placements to `anchorX <= baseX + GRID_SPACING`, i.e. it only ever
  expands to one side of the base, which roughly halves the placements that can exist. (An
  earlier attempt to make this spawn-relative, `20260918_041530`, measured worse — but that
  was under the broken harness and judged on a single mirror ratio, so it is not settled and
  is worth re-testing properly.)
- Or spend it on production/tech rather than expansion once placements run out.

**Before adding build power anywhere, check that there is something for it to build.**

## The opening has TWO phases with OPPOSITE bottlenecks — check which one you are fixing

Stored metal for team 0, averaged over 6 runs of `champion_v1`-class bots:

| game-min | stored metal | metal income | what binds |
|---|---|---|---|
| 1 | 592 | 7 | spending down the starting stock |
| 2 | 375 | 12 | |
| 3 | 183 | 19 | |
| 4 | **57** | 30 | **metal-starved — BP is idle for want of metal** |
| 5 | 99 | 41 | |
| 6 | 182 | 57 | turning point |
| 7 | 646 | 93 | |
| 8 | 1544 | 118 | **metal piling up — BP-starved, surplus unspent** |
| 9 | 2258 | 136 | |
| 10 | 2077 | 166 | |

**Minutes 1–4 are metal-limited. Minutes 7+ are build-power-limited.** They need opposite
fixes, and a change aimed at the wrong phase does nothing at all.

This was established the expensive way: run `20260918_064500` added a second builder
(`CMD_GUARD` on the commander) for the first 5 minutes, reasoning that the commander's serial
~44-item queue was the critical path. Result: `NO DIFFERENCE DEMONSTRATED`, with metal income
at frame 9000 moving 41 → 42. Adding build power during the metal-starved phase cannot help,
because the build power already there is waiting on metal.

**Practical rules:**
- To improve **minutes 1–6**, the only lever is *more metal sooner* — earlier mexes, cheaper
  openings, less non-mex spending. Do not add builders, nanos or assists here.
- To improve **minutes 7+**, the lever is *more places to spend metal* — more parallel build
  jobs, more expansion slots in flight, more production. 2257 stored metal at minute 9 is
  pure waste, and it corroborates the older "metal hoarding" entries below (faster lab
  polling, relaxed stall guard), which were all really about this same surplus.
- Before proposing any economy change, decide which phase it targets and check the table.

## The measurement window, mapped (use `checkpoint_map.py`)

`checkpoint_map.py` charts within-condition spread (noise) against between-condition gap
(signal) at every sampled frame. Run on `20260918_025426` vs `baseline_001`, 3 repeats:

| frame | game-min | army noise | income noise |
|---|---|---|---|
| 3600 | 2 | 1.09 | 1.00 |
| 7200 | 4 | **1.07** | 1.18 |
| 10800 | 6 | **1.10** | 1.22 |
| 14400 | 8 | **1.14** | 1.30 |
| 18000 | 10 | 1.20–1.50 | 1.28–1.44 |
| 27000 | 15 | 1.40 | 1.60 |
| 36000 | 20 | 2.00 | 4.50 |

Three findings:

1. **Army value is QUIETER than metal income in the early-to-mid window** — the opposite of
   the intuition that combat makes it dirtier. Income is spiky because it tracks instantaneous
   build-power draw. `ab_test.py` now defaults to **army value at frame 14400**: about the
   latest point still under ~1.15x noise, so bots have had time to diverge from the shared
   scripted opening while the measurement is still trustworthy. **Detectable effect ≈ 15–20%.**

2. **Noise grows steeply with match length.** A longer match is a worse measurement. Do not
   raise `--duration` hoping for a cleaner signal.

3. **For the energy controller, signal never exceeded noise at ANY frame** (s/n peaked at
   1.00 and fell to 0.31 by frame 36000). Its effect is real but tiny — signal reached only
   1.42x by frame 36000 while noise there had reached 4.50x. That change is unmeasurable on
   this harness at any checkpoint, and no amount of rerunning fixes it.

**NOTE on trusting these numbers:** they come from n=3, so the floors are themselves uncertain
— frame 18000 measured 1.50x on one run and 1.20x on another. Treat them as indicative, and
re-measure the floor with a null run (`--bot-a X --bot-b X`) if a result hinges on it.

## Measure EARLY: noise compounds, so the checkpoint matters more than the metric

**Spread between byte-identical bots, measured over 6 null-case runs:**

| checkpoint | metric | spread |
|---|---|---|
| frame 9000 (5 game-min) | metal income | **1.06x** |
| frame 18000 (10 game-min) | metal income | 1.44x |
| frame 18000 (10 game-min) | army value | 1.50x |
| frame 27000 (15 game-min) | metal income | 1.68x |

At 5 game-minutes the runs are nearly identical (40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 42,
42 metal/sec). The divergence is not present at the start and grows as the match runs — two
identical bots drift apart, and by 15 minutes the drift is larger than any effect worth
chasing. **So the default metric is metal income at frame 9000**, which can resolve changes of
roughly 10% instead of needing 35%.

The consequence for experiment design is the opposite of the intuition: a *longer* match is a
*worse* measurement. Do not extend `--duration` hoping for a cleaner signal — it adds noise.
If a change only shows up late, it is probably not measurable on this harness at all.

Army value at frame 18000 is still reported for context and is the right metric for changes
meant to affect combat, but with a 1.50x floor it will usually say nothing, and that is an
honest answer rather than a failure of the run.

## ⚠ NOISE FLOOR — a consistent-looking result is not automatically a real one

**Identical bots produce a 1.12x gap.** `baseline_001` vs `baseline_001`, run through the
first version of `ab_test.py`, came back as *"B is better -- it leads in BOTH slots"*: slot 0
36 167 vs 32 233 (1.12x), slot 1 28 267 vs 26 396 (1.07x). Same bytes on both sides. So:

- **The run-to-run noise floor on army value at frame 18000 is at least 1.12x**, which is
  bigger than most margins worth chasing.
- **"Leads in both slot orders" is not sufficient evidence.** Slot bias is systematic, but
  run-to-run noise is not, and noise alone can produce a clean-looking sweep of both slots.
- Everything measured at 1.0-1.2x is **indistinguishable**, not better or worse. Three
  verdicts recorded on 2026-09-18 were retracted for exactly this reason — see
  `NOISE_FLOOR_CORRECTION` in `strategy_log.jsonl`.

`ab_test.py` now repeats each condition (`--repeat`, default 3) and only calls a winner when
the two bots' runs **do not overlap at all** in a slot (min of one > max of the other),
printing `NO DIFFERENCE DEMONSTRATED` otherwise. That is a deliberately conservative bar. It
also prints the observed within-condition spread next to the verdict, so the noise is visible
rather than implied.

**Practical consequence: this harness cannot resolve small changes.** A tuning tweak worth a
few percent is below the measurement floor no matter how many times it is run at this sample
size. Prefer changes big enough to clear the floor, and treat any narrow result as "unknown"
rather than banking it.

## Metric: use army value at game-frame 18000, not end state

**Slot 0 saturates the ~2000 unit cap in every 300s match (`nc0=1999` in run after run), so
end-of-match numbers cannot discriminate between two good bots** [2026-09-18]. End-state
army-value ratios of 2.3x-3.2x between slots collapse to about 1.45x at the frame-18000
(10 game-minute) checkpoint — most of the apparent slot gap is the capped team grinding down
the uncapped one after saturation, not an economic difference. `army_timeline` already records
frame-18000 samples per team; **use those, and compare the slot-1 figure**, since slot 0 is
cap-limited and reads nearly identical for any competent bot. Measured slot-1 army value at
10 min: `20260918_024045` 23 679, `champion_v1` 22 702 / 21 832, `20260918_041530` 17 278.

- **`champion_v1` is NOT demonstrably stronger than `20260918_024045`, and the energy
  controller's original "win" was a harness artifact** [2026-09-18]. Stacking the best
  per-file changes (rez-bot lab + unit controller from `20260918_024045`, closed-loop energy
  controller from `20260918_025426`) looked like a decisive 2268-1650 win, but that was
  measured under the broken harness. Re-run under the fixed harness in **both slot orders**,
  each bot wins from slot 0 and loses from slot 1 — they are indistinguishable. At the
  frame-18000 checkpoint `20260918_024045` is very slightly *ahead* in the disadvantaged slot.
  The stacking itself is still the right idea and `champion_v1` is a valid bot; there is just
  no evidence yet that the energy controller adds anything. It needs re-testing on its own,
  macro-only, against `baseline_001` under the fixed harness before it is credited.

## What has worked

- **`lab_controller.lua`'s generic fallback (used by any lab with no `LAB_QUEUES` entry,
  e.g. `corlab`, the T1 bot lab) silently excludes *every* `od.isBuilder` buildOption,
  which also excludes rez bots** [run 20260918_024045]. `cornecro` (Cortex's
  Graverobber: `canresurrect=true`, no buildOptions of its own) is itself a builder,
  so the old `GetBuildCache` filter (`not od.isBuilder`) meant no lab without an
  explicit queue could ever build one, regardless of anything `unit_controller.lua`
  did with it. Fixed by special-casing `od.canResurrect` into its own bucket *ahead*
  of the `isBuilder` exclusion, queued up to a target count the same way `SCOUT_TARGET`
  already works. Also confirmed `UnitDefs[defID].canResurrect` is the reliable engine
  flag for detecting rez-bot-type units — better than name-matching, since `cornecro`
  contains no obviously rez-related substring. Paired with retreat-to-rez-bot logic in
  `unit_controller.lua` (critically wounded units now path toward the nearest living
  rez bot instead of always to the commander, and rez bots prioritize healing damaged
  allies over resurrecting wrecks over holding position behind the front). Result:
  game_over win vs baseline_001, 1805 vs 499 units built, army value 29614 (332 alive)
  vs 495 (3 alive) at 10 min — though note baseline's own early-game weakness (0 units
  at the 1-min sanity check) inflates this margin independent of the rez-bot change;
  worth a rerun against a stronger opponent before crediting all of the margin to this.

- **Node-assignment span should scale with unit count, and reinforcements should mass up
  before committing to the line** [run 20260918_024155]. User observed units getting very
  stretched out instead of fighting as a group. `AssignUnitPositions` in
  `unit_controller.lua` always spread units round-robin across the *entire* thrust window
  (11 nodes) and *all* available wing nodes (up to ~21, spanning most of the ~3000-elmo
  contact line) regardless of how many units actually existed -- a 10-unit army could end
  up one unit per node, flung across the whole line, especially early-to-mid game when
  armies are still small. Fixed two ways: (1) both the thrust-node span and wing-node span
  are now capped by `ceil(unitCount / UNITS_PER_NODE)` (4 units/node), centred/nearest to
  the existing window, so a small force only occupies as many adjacent nodes as it has
  units to fill and only spreads to the full line once the army is large enough to justify
  it -- wing candidates are also sorted by distance to the thrust node so they cluster near
  the fight instead of scattering to the map edges; (2) added a reinforcement "muster" pool
  -- newly finished combat units are held out of line orders until either 4 have massed up
  or 30s elapses, then released together, instead of trickling out of the factory one at a
  time onto a line where they'd arrive piecemeal. Result: decisive win, army value at 10 min
  34911 (267 alive) vs baseline's 451 (8 alive, nearly wiped) -- baseline's high per-unit
  combat losses (22x corshad, 4x corvp) are consistent with units still arriving stretched
  thin and getting picked off individually. Lesson: any system that distributes units across
  a fixed number of slots/nodes/waypoints should scale the number of *active* slots with
  actual unit count, not just fill every available slot regardless of army size.

- **Raising the retreat-HP threshold and matching mismatched enemy-detection radii in
  `unit_controller.lua` wins decisively, and neither had ever been tuned before**
  [run 20260918_064114]. Every prior tuning run touched `macro_controller.lua` (energy
  grid) or `lab_controller.lua` (poll rate, stall guard, unit ratios) — the combat-side
  retreat/advance constants were still at their original, never-revisited values.
  `RETREAT_HP` at 0.15 let units get ordered to retreat too late to actually survive the
  trip (a unit that low often eats one more hit before clearing the fight); raised to
  0.30. Also found `LOCAL_ENEMY_RADIUS` (500, used for the per-unit FIGHT-vs-MOVE check)
  didn't match `NODE_ENEMY_RADIUS` (600, used to flag a node "engaged") — a genuine
  latent inconsistency, not just a tuning gap, that could put a unit on MOVE orders
  while its own node was already flagged as under attack. Matched both to 600, and
  raised `ADVANCE_MIN_UNITS` 5->10 so the line doesn't push forward on too thin a mass.
  Result: game_over win, 810 vs 602 units built, army value 32519 (236 alive) vs
  baseline's 1260 (19 alive) at 10 min. Worth checking other pairs of constants that
  are supposed to represent "the same" range/threshold but live as separate literals —
  they can silently drift apart like this one did.

- **Interrupt/priority fixes for mex-grid nanos have to live in the per-bot file, not
  `blueprint_placer.lua`** [run 20260916_000756]. This directly resolves seed observation #3
  below ("interrupt mechanism exists but doesn't actually elevate priority correctly").
  `blueprint_placer.lua` is a *shared* file -- `bot_testing.py`'s `copy_shared_deps` always
  copies it from the repo root for both teams, ignoring anything with that name inside a
  candidate folder -- so a fix written there would apply equally to both sides and can't
  produce a one-sided A/B result. The actual fix went in `macro_controller.lua`: (1) a nano
  placed as part of a mex grid is never given a follow-up order once its own construction
  finishes, so it just sits idle instead of helping finish the grid's mex extractors --
  fixed by scanning for idle nanos within build range of a mex currently under construction
  and giving them a direct build order; (2) `blueprint_placer.lua`'s metal-stall interrupt
  only fires once a builder goes idle on its own, so a con already busy on a non-mex item
  (corrl, a nano, etc.) keeps sinking metal into something that can't finish instead of
  jumping to a mex -- fixed by stopping and redirecting it directly when metal is stalling;
  (3) the engine's actual builder-priority command is `GameCMD.PRIORITY` (a Low/High toggle,
  {0}/{1}), used to keep mex-assisting nanos at high priority and drop every other known nano
  to low priority for the duration of a stall, restoring everyone once it clears. Result:
  game_over win, 538 vs 337 units built, army value 39585 (291 alive) vs baseline's 0 (fully
  wiped) at 10 min.

- **Peeling a fast-unit "raider" slice off the wing pool to exploit undefended flanks wins
  decisively** [run 20260916_040637]. The node-curve contact line in `unit_controller.lua`
  had no concept of the enemy's *weakest* point -- wing units just held position along the
  same line the main thrust engaged on, so both armies converged and traded in the map's
  contested middle while the wide-open sides sat undefended (matches game_mechanics.md §6:
  no fixed front line / no terrain to anchor on). Added lateral density binning of visible
  enemies (every 5s scan) relative to the contact line's width; when one bin has <=40% of
  the average bin count (min 6-enemy sample to trust it), up to 25% of total army value --
  the fastest wing units -- reroutes via a lateral waypoint through that corridor straight
  to the enemy base (estimated as the mirror of our own base, since the map is symmetric),
  gated on the main thrust already meeting ADVANCE_MIN_UNITS so it never hollows out the
  line. Result: game_over win, army value 38110 vs 1352 at 10 min, and the opponent's
  combat-loss breakdown showed its *economy buildings* destroyed (mexes, wind, nanos, the
  T2 lab) rather than just army units -- confirming raiders actually reached the base
  instead of trading in the centre. This implements the "Raiders" role from
  game_mechanics.md §7, which existed on paper but had no code before this run. Worth
  running back-to-back with different opponents/seeds before fully trusting the margin,
  since one match vs baseline_001 isn't a large sample.

- **Moving just the air lab earlier (not the whole labs-first reorder) nearly doubles mid-game
  metal income** [run 20260915_221208].
  Distinct from the labs-first experiments below: this leaves all mex/wind ordering untouched
  and only moves one entry. In the stock `com_starter.lua` blueprint the air lab (`corap`) is
  item #27 of 46 in the commander's serial solo build queue (~300 BP, no assist). The air lab
  unlocks air cons, and air cons drive the entire automated mex-grid expansion engine
  (`StartAirExpansion`/`TryExpand`) — so that expansion system sat idle for minutes waiting
  behind ~26 hand-placed mex/wind items the commander was building alone. A
  `BuildOrderedComLayout()` helper in `macro_controller.lua` moves `corap` to immediately
  follow `corlab` (bot lab) — nothing else in the queue changes position — without touching
  the shared blueprint file, so baseline_001 is unaffected. Cost a small amount of near-term
  economy (37.55 vs 39.92 m/s at 5 min) but produced 257.96 vs 139.46 m/s at 15 min (~1.85x)
  and 117904 vs 11183 army metal-value at 20 min. Baseline also hoarded 1631 metal at 15 min
  vs candidate's 59, confirming baseline's BP was going unused while waiting on the delayed
  expansion engine. Lesson: when an automated expansion/production system is gated behind a
  specific unit, check where that gating unit sits in any hand-authored build queue — a late
  position can silently stall the automated system for most of the opening even though
  nothing is technically broken. This is a much narrower, cheaper change than reordering
  the whole queue (see labs-first entries below) and doesn't carry the same mex-delay cost.

- **Energy improvements beat labs-first reordering** [run 20260915_220651].
  Instead of building labs before mexes (which delayed 10+ mexes by 2+ min, hurting income),
  keeping the original build order but adding target_e_grid=2, energy-float-cap=0.85,
  stall-threshold=300, and commander-guard-conBot2 crushed baseline 1357→439 units (3.1x).
  Metal income at 10 min was 3.2x better (137 vs 42). Key lesson: mex income compounds;
  the early-lab gain doesn't justify the mex delay. Original order is better.

- **Faster lab polling (60→30 frames) dramatically improves production throughput** [run 20260915_143222].
  Baseline was hoarding 1548 metal at 15 min because its labs sat idle up to 2 seconds between
  productions. Halving the check interval closed that gap and dropped stored metal to 237.

- **Relaxing the stall guard fixes metal hoarding** [run 20260915_143222].
  Baseline stall check skipped queuing on *either* resource stalling + metal<50. This left labs
  idle mid-stall even though the engine already rate-limits individual build jobs automatically.
  Changing to (both stalls AND metal<20) let production continue through single-resource stalls,
  improving army value from 14k→131k at 20 min (9x).

- **`cormist` is a valid Cortex vehicle-plant unit** — confirmed built and lost by both bots.
  Safe to include in LAB_QUEUES for vehicle plant.

---

## What has failed

- **Labs-first build order hurts metal income enough to lose the economic game** [run 20260915_143859].
  Reordering `QueueComBlueprint` to build factories before mexes gave an earlier army (391 vs 101
  total units, 18k vs 150 metal-value army at 10 min) but delayed 10+ mexes by ~2 minutes. Metal
  income was worse at every checkpoint (28 vs 39 at 5 min; 58 vs 87 at 10 min; 75 vs 115 at 15 min).
  Baseline recovered from near-zero army to 609 units and won via commander kill by 18 min.
  Lesson: mex income compounds; a 2-minute mex delay costs more metal than early labs gain.
  The original build order (mexes interspersed) is better for macro even if labs arrive later.

---

## Seed observations (from manual analysis of OK_BOT)

These come from `game_mechanics.md` §10 and pre-agent play-testing. They are the known starting
weaknesses of `baseline_001`.

1. **Early economy lags behind good play** — even with zero enemy interaction in the first 3–5
   minutes the bot ends up noticeably behind. Two confirmed contributing factors: energy grids
   are not being built correctly, and the opening doesn't scale as aggressively as it should.

2. **Energy grid construction is broken** — the bot does not reliably fill in the energy
   buildings required to back its build-power demand. This causes frequent energy stalls.

3. **Priority system is only partially implemented** — when there's a resource stall, builders
   working on jobs that would relieve that stall (e.g. wind/fusion during an energy stall)
   should be bumped to high priority. The interrupt mechanism exists but doesn't actually
   elevate priority correctly.

4. **Defense interrupt is crude** — when enemies are detected near a grid cell the bot builds
   defenses, then reclaims them when enemies leave. This wastes metal and BP on buildings that
   don't persist.

5. **Commander hunting is unimplemented** — if the bot is economically dominant but the enemy
   commander is hiding somewhere, the game stalls indefinitely. Needed: detect "we've already
   won" (no visible enemy production/units for N minutes) and then scout + send bombers.

6. **"Units built" is a weak proxy for quality** — better signals: metal wasted over the
   storage cap, time spent stalled, and actual win/loss by commander kill. Prefer real
   win/loss data as the admission criterion.
