# HuK replays: what his orders look like (2026-10-25)
Cross-player comparison (all 6 replays, both sides) is at the end. Source: 3 of 6 replays in the user's Downloads folder have **HuK** (Comet Catcher 5 min, Canis River 8 min and 30 min; all 1v1).
The other three (Full Metal Plate, Red Comet, Cape Violet) are other players and were not analysed.
**Method / limits.** bar-py-env playback needs the demo's own engine + game archive: only engine 2026.07.04 is installed and the old
game archives are not on springfiles, so playback failed. Used `node replay_commands.mjs <sdfz> out.json` (human COMMAND/SELECT
packets, no unit positions or types) and analysed orders only. Scripts: `huk_replays_2026-10-25/route_report.py`, `single_unit_report.py`
(expect `rN.json` next to them; N, player number hardcoded in the last line). Three games, three maps: lateral numbers partly reflect map layout.

## Findings
1. **Armies arrive from the side, on a multi-leg shift-queued FIGHT route.** Along the base->enemy axis (prog 0..1) the waypoints at prog 0.3-0.8
   sit 1,500-3,500 elmos off the axis (almost every order, both games), then the last queued legs close in to prog ~1.0 (the enemy base).
   Typical: `F Fq Fq Fq` = 4 legs, e.g. prog 0.75/-1341 -> 0.92/-1398 -> 0.97/-1181 -> 0.98/-345. Existing `flank`/`steer` use ONE waypoint
   beside a seen enemy cluster, or a fixed offset for every 6th unit; his is the whole group, an arc, no enemy sighting needed.
2. **Many small groups, not one blob.** 56-63 army orders (selection >= 5) in a 5-8 min game, 336 in the 30 min game; median group 6-13, 20-60 late.
   Groups are re-selected and re-sent every few seconds, often to different sides (lateral sign flips between orders).
3. **Stage, then strike.** Plain MOVE to a point at prog 0.6-0.75 (units idle there), later FIGHT from the staging point. MOVE is ~65% of army orders, FIGHT ~30%.
4. **(Corrected) No group formation lines.** The 6-param MOVEs (two points, widths 22-180) occur ONLY with one unit selected (HuK 141+600, BCTV 490, Walnut 129 of the 6-param MOVEs vs 0 with 2+ selected): they are the hand-drawn path of finding 6, not formations. Group MOVEs are plain 3-param clicks.
5. **Triple-tap moves.** A big share of group MOVEs are 3 near-identical MOVEs within ~1 s (hops of a few dozen elmos). Likely order refresh, low value.
6. **One or two units are steered by hand along a drawn path.** Selection of 1 unit: bursts at ~10 MOVEs/s, ~60-120 elmos apart, reversing direction
   in 5-25% of hops. 7-41 distinct units per game; one unit (id 4397) is steered 116 times over 30 min. These are scouts/raiders weaving; no enemy positions in the data,
   so the reason (dodging, edge-of-range) is a guess.
7. **Almost no group retreat micro.** FIGHT followed by a pull-back MOVE within 20 s: 3, 2 and 7 times per game. He wins by arriving on the wrong side, not by kiting.

## Ideas (all opt-in, next to what exists; none implemented)
- `arc_route` army behaviour: whole group takes a queued 3-4 leg arc (side kept per group, alternate sides between groups) ending at the target; offset 1,500-3,000.
- Smaller, more frequent groups from the army broker (groups of 6-13 sent every ~10 s) instead of waiting for a big blob; compare on `[CK]` rows (BP/eco killed).
- Staging point: MOVE to a point at prog ~0.65 before FIGHT.
- Drawn-path scout: a scout/raider following a smooth curve around seen defences (extends `steer` leg choice to 1 unit).
Measure with `[CK]`/`[SF]` rows, then ab_test; the effect must be big to show (see CLAUDE.md measurement rules).

## All six replays, both players (added same day; `route_report.py` style numbers, `an4`-type summary)
group orders = selections >= 5; mid |lat| = median offset from the base-base axis of waypoints at 30-80% of the way.
| game | player | min | grp orders/min | median group | MOVE/FIGHT | mid |lat| | multi-leg FIGHT routes | single-unit cmds (top unit) |
|---|---|---|---|---|---|---|---|---|
| Full Metal Plate | SuicidalWalnut | 35 | 3.4 | 54 | 250/14 | 2662 | 0 | 195 (15) |
| Full Metal Plate | TM_Spodie99 | 35 | 2.6 | 44 | 128/3 (+9 ATTACK) | 1524 | 0 | 179 (31) |
| Comet Catcher | HuK | 5 | 12.0 | 7 | 105/81 | 1216 | 7 | 177 (69) |
| Comet Catcher | Yadem | 5 | 5.3 | 12 | 110/0 | 500 | 0 | 338 (117) |
| Canis River | HuK | 8 | 7.0 | 7 | 95/77 | 741 | 9 | 278 (101) |
| Canis River | WilliamBuxtonFan | 8 | 3.6 | 6 | 87/0 | 1181 | 0 | 111 (38) |
| Canis River (long) | HuK | 31 | 11.0 | 13 | 483/228 | 2050 | 8 | 655 (116) |
| Canis River (long) | WilliamBuxtonFan | 31 | 10.0 | 10 | 791/4 | 1096 | 0 | 628 (141) |
| Red Comet | TM_autopilot | 15 | 4.6 | 6 | 357/0 | 1248 | 0 | 423 (70) |
| Red Comet | PRO_BCTV | 15 | 7.2 | 12 | 233/46 | 810 | 0 | 363 (113) |
| Cape Violet | TM_autopilot | 15 | 0.5 | 7 | 20/0 | 997 | 0 | 208 (34) |
| Cape Violet | PRO_BCTV | 15 | 3.3 | 11 | 63/24 | 1709 | 0 | 555 (219) |
Who won is not in these files (not looked up).
What this changes:
- **HuK is the odd one: he uses FIGHT (attack-move) for 35-45% of group orders and builds the multi-leg queued routes; everyone else is ~100% MOVE** (also
  matches paintkid's "only MOVE"). The other players move units and let them shoot whatever they meet on the way; HuK commands attack-moves along an arc.
- **Big-blob style exists too**: Full Metal Plate players move 44-54 units at 3 orders/min, far off-axis (Walnut 2662). HuK/BCTV/Autopilot move 6-13 at a time.
- **Off-axis routing is common, not HuK-only** (|lat| 800-2700 for most), so a flank offset is the shared trait; the *queued FIGHT arc* is HuK's.
- **Hand-steering one unit is universal** (100-220 commands on the top unit in every game; BCTV's 219 in 15 min). Likely a scout/commander/fast raider; worth a closer look
  (unit types are unknown from commands alone; selecting the id earlier in the replay's BUILD/SELECT stream could reveal it).
