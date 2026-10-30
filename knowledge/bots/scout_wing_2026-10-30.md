# Scout wing + scout labs (2026-10-30)

User request: "constant scouting of the map to find enemy units ... from 8 mins plus, it always needs to reinforce itself ... a focus at
the start a little outside the enemy base and then around our base and then map. Air scouts are better for scouting units, ground scouts
are better for posts. You can extend the line a little bit and add your own air, ground lab and nanos."

On in `candidates/CORE_v4` (macro `LT_CFG.SCOUT_LAB = true`, unit `SCOUT_WING = {}`, lab `SCOUT_LAB_DEPTH = 2`; PICKET removed).
Branch `scout-wing` (off `main`).

## Why the old scouting did not give map vision

- No air scouts in practice: the line's only T1 air lab is held for air cons (`WG.TileLabHold`), so PICKET's two Finches were never built
  (akumar game: 133 scout orders, all corfav, none from corap).
- Scouts were inserted into army-lab queues (`scout-ahead`) and `plan.support = "unless_raided"` zeroes them during a raid.
- scout_net is many overlapping jobs with mixed air/ground units and untested tunables.

## What was built

| Piece | File | What it does |
|---|---|---|
| Scout labs | `bar_framework/line_transition/scout_lab.lua` | A T1 air lab (corap) and a T1 vehicle lab (corvp; Cortex's bot lab builds no scout) past the end of lane 4 (`SCOUT_LAB_LANES`), 4 and 9 columns out, 2 nanos each. Air lab from 7:00 (`SCOUT_LAB_FRAME`; user: the wing up by ~9:30 is the target, 8:00 was arbitrary), vehicle lab at 250 m/s income (`SCOUT_LAB_GND_*`); both urgent; lab first, then nanos; the builder is on HIGH priority while on those jobs; labs + nanos stay HIGH (`SCOUT_LAB_HIGH`). A dead lab is rebuilt 60 s later (`SCOUT_LAB_REBUILD_S`). `WG.ScoutLabs = { air, ground }`. |
| Lab queues | `bar_framework/lab_rules.lua` | `scout-lab` want (prio 200, topup `SCOUT_LAB_DEPTH`, `lab.only`): orders while `WG.MetalBot.scoutWing` is short of that lab's kind; not cut by raids, not charged to the army budget. Units born there are not counted as scout_net's scouts. Once a scout lab stands, the army labs' `scout` / `scout-ahead` stop (the `scout-first` floor of `SCOUTS_FIRST` stays). |
| The wing | `bar_framework/scout_wing.lua` (unit_runtime `SCOUT_WING`) | Owns every unit the scout labs make (army_broker `PRIO.SCOUT`, role `WING`). Want: air 6 + 1 per 100 m/s (max 16), ground 4 + 1 per 150 m/s (max 10). |

Air scouts, jobs filled in this order (a loss is refilled from the job below):
1. **ringE** (3): orbit 8 waypoints round the **enemy footprint**: the centre of their known buildings (labs x3, else their spawn); each
   waypoint `RING_E_MARGIN` (1300) outside the farthest known enemy building in its sector (and the two neighbours; buildings more than
   `FOOTPRINT_MAX` 4500 out are outlying eco, left to the rovers), at least `RING_E_MIN` 1800. So the ring grows as they build out.
   Recent ring losses push it out 300 each (max 1500); a waypoint inside known anti-air (`EI.ThreatAt` air) steps out 300 at a time.
2. **ringH** (2): orbit our eco footprint (`MM.Base` / `BaseRadius`) 1500 out: warning on the approaches.
3. **rover** (rest): 1024-elmo cells, each with the frame it was last in our LOS. Score = zone (enemy band 3, home band 2, map 1, inside
   the enemy footprint 0.5) x staleness (capped 3 min) x (1 + 3 x an enemy group last seen there and not in view + 0.5 for a known enemy
   building) / (1 + danger: losses there + known AA) / (1 + distance / 4000). Re-pick on arrival, after 10 s, or when the cell is seen.

Ground scouts hold posts (hold fire, hold position): the middle of the axis and its flanks (0.35 D), our approaches (footprint radius +
1200, at 0 / +-40 deg), then 0.3 / 0.7 of the way and their flanks. A post where one died steps back 500 toward home for 90 s.

`[SW]` rows every 30 s (also kept in `result["bot_echo"]`): have/want per kind, jobs, posts manned, `cov60` (share of map cells seen in
the last 60 s), enemy mobile units in view, made/lost, the enemy ring's size.

## eco_sim (vacuum-free, 3 seeds, CORE_v4)

- Lab timing (final config, air lab at 7:00, `ecosim/runs/sw_on7`): air lab stands 8:10 / 8:19 / 8:23; the wing is full (7-9 air) by
  9:11-9:24 in all three seeds; vehicle lab 74-92 s after its 250 m/s gate (~9:30-11:00).  (6:00: lab 7:19, 5-7 air by 8:20.)
- Reinforcement (`--patch` killing a Finch every 20 s from 9:00 and the air lab at 12:00): the wing held 8-9 of 9-10 air; the lab was
  rebuilt (13-16 s with its nanos alive) and the wing refilled to 16.
- Cost: geo-mean income vs the same bot with `SCOUT_LAB=false` (`sw_base`): final config (7:00) 12:00 0.94x, 16:00 0.87x, 20:00 0.92x
  (air lab at 6:00: 0.91x / 0.82x / 0.84x; at 6:30: 0.97x / 0.84x / 0.90x; the per-seed spread is large, one seed was above baseline at 20:00).
  The sim has no enemy, so it shows only the cost (labs ~1.2k metal, nanos ~0.9k + 13k E, Finch 51 m + 1450 E each), never the value.
- Two fixes from the sim: a scout lab with low builder priority got nothing in a metal stall (one Finch took 3 min) -> HIGH priority;
  the vehicle lab went to the builder that had just been given the spam lab -> prefer a builder with no jobs.

## Real games (single client, 15 min, CORE_v4 vs CORE_ROWS_ECO)

- Game 1 (nanos first, vehicle lab not urgent): air lab queued 6:30, frame up 7:42, done 9:47; the vehicle lab never came (it waited
  behind lane 4's slots for 6.5 min). `[SW]` rows were not kept by the harness then. -> lab first, builder HIGH, both labs urgent,
  `[SW]` added to `BOT_ECHO_TAGS`.
- Game 2 (lab first, air lab gate 6:30; queued 6:45, stood 8:11 with no nano near the frame): 1 Finch at 8:42, 6 at 9:42, 11 at 10:42;
  vehicle lab queued 10:07, stood 11:18. `[SW]` 11:12: cov60 98% of map cells, 155 enemy mobile units in view, enemy ring outside 268
  buildings (footprint radius 500 -> 4480 as their rows grew). Tracker, our team: `fresh_enemy` 0.22 (9:00) -> 0.50 (10:00) -> 0.56
  (11:00), explored 45% -> 81%; game 1 (wing late) had `fresh_enemy` 0.07 at 10:00. No wing scout died (the enemy, CORE_ROWS_ECO,
  lost its commander at 11:25), so losses to real AA are untested.  -> the air lab gate moved to 7:00 (user: up by ~9:30).

## Game 3: 25-min CORE_v4 vs CORE_ROWS_ECO (main 34897c6; ended ~19:30 on the wall-clock backstop, CORE_ROWS_ECO won on phi)

Replay: `BAR data/demos/2026-10-30_22-20-20-550_Full Metal Plate 1.7_2026.07.04.sdfz`.  The scouting did NOT hold up:
- Slow start: air lab 8:16, but 1 Finch at 9:17, 4 at 10:17 (the lab alone, its nanos still to come; metal stall 13% at 8:00).
- Attrition beat production: from 9:30 ~4-5 air scouts died a minute; made 78 / lost 76 air by 18:47 (190 corfink lost in all, PICKET's
  included: ~9.7k metal + ~275k energy).  The wing sat at 1-2 of 13 air at 13:47, 17:47, 18:47.  Ground: made 37 / lost 28.
- The enemy ring was in the wrong place: CORE_ROWS_ECO's buildings spread so far (footprint radius 711 -> ~4400) that the ring sat
  ~4400 + 1300 + 1500 (loss push) = ~7200 from their centre, on a map whose bases are ~10.6k apart: it orbited near OUR side.
- Tracker: our `fresh_enemy` 0.12-0.15 (8-14 min) -> 0.05 (16:00) -> 0.003 (18:00); theirs (no wing) 0.34-0.47.  `cov60` (any cell
  touched in 60 s) said 38-97%: a passing scout touches many cells, so it overstates vision -- read `fresh_enemy` instead.
- Arrivals warned: ours 237 of 257 (lead_med 3270), theirs 11 of 14.  Both scout labs died at 19:04 when the base was overrun.

Fixes to try: cap the enemy ring (a fraction of the base-to-base distance, not the footprint's far edge; robust footprint percentile);
loss push should not move the ring onto our half; nanos before scouts start, or the scouts built ahead of them; scouts kept off
known AA / enemy groups harder (losses ~4/min); per-kind loss rate in [SW].

## Open

- The enemy ring has not been seen against real AA yet; `RING_E_MARGIN` / `AA_AVOID` are first guesses.
- scout_net still runs the army labs' scouts (FIND floor of 6, creep); it no longer gets new scouts once a scout lab stands.
- The lab site is "past the end of lane 4" -- on a map where that is off the map edge it tries lanes 3, 2, 1 after three failures.
