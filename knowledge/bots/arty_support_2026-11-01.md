# CORE_v4: arty support (Quakers), lab-order API, air lift (2026-11-01)

User request: the T2 phase only adds Tigers, which add no new capability (less DPS and HP per metal than a Brute; 410 vs 350 range barely
matters). Keep the T1 army and the stances as they are. Add a **one-time capability on top of them**:
- an earlier T2 vehicle plant;
- **3 raid groups x 5 Quakers** (`cormart`: 420 alpha, so 5 one-shot a 2k-hp Brute) from 300 m/s income;
- each of those groups **screens its Quakers** ("keep them alive and always firing") instead of raiding;
- **flak trucks with every group**: always 2, 6 under air pressure;
- slow support units **moved by light air transport** to 800 behind their group;
- support always comes **ahead of the stance loop** in the labs (a "spine API" with priorities), unless the spine itself is under attack.

Later in the same session the user added: **no waiting at home**. Groups go out as before. Their support is flown to them, and a group still
waiting for its support stays out on the map without diving.

## What exists now (all opt-in; CORE_v4 turns it on)

| Piece | File | What it does |
|---|---|---|
| Lab-order API | `bar_framework/lab_orders.lua` (`WG.LabOrders`; lab_rules `SUPPORT_ORDERS`) | `Request(key, { picks, n, tier })` renewed every tick. **high** = prio 147 (just under the air rush), paused while a raid group is within 1500 of a spine lab (`[LO] high tier PAUSED`); **normal** = prio 60. For each lab: the best pick any usable lab can build; one waiting insert per lab across all requests, requests served in turn. The books come from the real queues and `UnitCreated(builderID)`, not from picks. The army budget is charged when a unit starts. `Wanted()` = first picks only a spine lab could make, which `slot_spine.SetRequired` turns into a planned lab with share 0.05 past the army-value gate. Replaces `group-support` / `support-rush` in CORE_v4. `[LO]` rows. |
| Broker fix | `lab_broker.lua` `PENDING_FIRST` | An `ahead` want is not asked for a pick while the lab's pending gate is shut. Before this, the pick's bookkeeping ran and the unit was then dropped (why flak orders went missing). Off by default; on in CORE_v4. |
| Arty element | `support/arty.lua` | Latched on once income has stayed at 300 or more for 20 s. 5 Quakers per raid group, and `groups = 3` raises click_army `MAX_GROUPS` to 3 (`army_groups.MinGroups`). A Quaker far from its post (group core − 800 along the axis) is flown there, unless the group is at home (then it walks). Landed Quakers stand in a line abreast and FIGHT 220 ahead toward the target. They advance only while the screen is in front (`screenOk`), stop inside 85% of their range, and step back on danger. Publishes `rec.arty` (and `mb.artyOn`). |
| AA element | `support/aa.lua` | `MOVE = true` (CORE_v4): MOVE only, plus `SET_TARGET` (34923) on the nearest enemy air unit within 1.1x its range. Flown out like the Quakers. With arty on and a T2 plant standing: `n_arty` 2 / `n_arty_air` 6, flak trucks only (a Lasher in the pool goes back to the escort). `MOVE` off = the old FIGHT spiral. |
| Ownership | `unit_runtime.lua` `SUPPORT_FIRST`, `SUPPORT_OFF_GRACE_S` | A new AA unit goes to the elements once the base screen has 2 (was 40% of all ground AA). No `range_kite` on element AA. A short aa element adopts GROUND_AA *escorts* (never the screen). An element switched off keeps its units 120 s. |
| click_army | `ESCORT`, `RESERVE`, `AA_PACE` (`M.SetSupport`, fed by army_groups every tick) | **ESCORT**: a group with 2+ landed Quakers away from home does not raid. Its core stands as a screen 350 ahead of the Quakers, FIGHTs what comes within 500 of the screen (never past 800 from them) and falls back onto them at threat > 1.3x the core. Targets are picked with a short distance scale (1200). **RESERVE**: Quakers on the way, or fewer than 2 AA with the group under air pressure, means SURVIVE skirmish / orbit and never a dive. **AA_PACE**: the AA within 1500 but more than 500 behind holds the core 250 ahead of it. |
| Air lift | `bar_framework/air_lift.lua` (`WG.AirLift`; unit_runtime `AIR_LIFT`) | A pool of `corvalk` (all but the ferry's, `WG.NcFerryTids`). Each job goes to the nearest idle transport. The **whole flight** is checked against `EI.ThreatAt(air)` (fighters seen lately count); the drop steps 400 back toward home up to 8 times, and if no step clears it the unit walks. Transports come through `LO` (`lift:transport`): at least 2 while arty is on, one per waiting job, at most 6. `[LIFT]` rows. |
| T1 air lab in the block | `nano_cols/fronts.lua` `NC_T1_AIR_LAB` (CORE_v4 280) | One `airlab` block once income reaches 280. A plain lab (fighters, Shurikens, the lift's transports), not an air-con lab. |
| raid record | `raid_response.lua` | `mb.raid.groups = { {x, z, value} }`, for the high-tier pause. |

**Raid-only machine + eco bursts (user, same day).**
- `machines/v4_rows_raid.lua` (CORE_v4 `MACHINE`): rows_eco_legacy without `t1_hold` / `t2_hold`. The hold stances handed the army to the maneuver blobs, which stops the raid groups and their support.
- New signal `home_quiet_s` (`signals.lua`): seconds since an enemy ground group was last on our side (cover_defence `lastThreatF`, radar dots too) or a raid was at our base.
- Share node `eco_burst` (0.25): `push_high` → `eco_burst` at 10:00+, raid stance, `home_quiet_s >= 45`, not `bad_trade`, and at least 90 s at push_high. Back after 90 s, or at once when `home_quiet_s < 5`.
- The user's reasoning: DEFENCE_BOT never threatens our side, so there is room to eco in bursts.
- eco_sim (2 seeds; no enemy, so the bursts fire every ~3 min): 20:00 income 3.6k → 4.6k (×1.26).

**Pacing (user 2026-11-02, from a replay: groups "flip flopping in direction and not moving continually ... glacial speed").**
- **Engine probe (scratchpad, not in the repo).** A widget **cannot cap a unit's speed**. `MOVE` with a 4th param of 52 still ran a gator at 76 /s, `MOVE` + `{"ctrl"}` to a gator+Lasher array likewise, and `CMD.SET_WANTED_MAX_SPEED` is nil. The user's ctrl+right-click is recorded as a plain MOVE with CONTROL_KEY; the engine applies the slowest-unit speed only to a player's own selection. BAR caps speed only in synced gadgets (`SetGroundMoveTypeData`).
- **The causes.**
  1. AA post = core − 250 while AA pace held the core at AA + 250: each waited for the other.
  2. The Quakers advanced only while `screenOk`, and the screen formed on them.
  3. Groups flipped between reserve (to the target) and escort (back to the Quakers).
  4. army_broker re-sends a move only after the goal moved 250, so a creeping goal became stop-go.
- **Now.**
  - **The slow units set the pace and always move.** Quakers always FIGHT 600 ahead (150 once the target is inside 85% of their range). They pull back only when the ground threat at the line is more than 1.0x the escorting screen's value (`rec.screenV`).
  - **The fast front units chase a goal that leads the slow units.** The goal is their position + velocity x `PACE_LEAD_S` (3 s), sent with `spec.eps` 60 and `urgent` (1 Hz) through the new army_broker per-claim threshold. This covers the escort screen (leads the Quakers), the AA post (leads the core / Quakers) and AA pace (leads the AA).
  - Reinforcements far behind still walk to the core at full speed.
  - Escort mode has hysteresis: on at 1500 (`ESCORT_JOIN_R`), off at 3000 (`ESCORT_LEAVE_R`).

- **Games with pacing (2026-11-02, two in parallel, full 20 min, no errors, no desync):**
  - **vs CORE_ROWS_ECO: won on phi**, end score 323k vs 59k. Their income at 20:00 was 305 vs our 3.5k. 0 Quakers, flak or transports lost. Escort group #9 moved (4629,3892) → (7675,7269) between 17:52 and 19:52, ~52 /s, close to Quaker top speed (game 3 crept at ~17 /s). Escort on 3x / off 1x. No eco burst (they kept raiding our side).
  - **vs DEFENCE_BOT: lost on phi**, the closest of the 7 games (phi at 20:00 23.0k vs 25.2k). Income 3.3k vs 4.6k; DEFENCE_BOT's 20:00 income was 6.1-7.6k in games 2-5.
    - 51 escort rows, mostly at its base (7.4-8.8k, 7.5-8.4k): "covers", 3x "falls back".
    - 4 Quakers, 6 flak and 12 transports lost. 44 lifts done.
    - **50 Lashers lost**: the 10-31 `when_air` 12-per-group Lasher rule, before the T2 plant.
    - One eco burst (10:41).

- **Hard-raid signal (2026-11-02).**
  - In the DEFENCE_BOT game above, `home_quiet_s` reset on lone scouts and fighters (raid_response `OUR_HALF` intruders of value 26-73): one burst at 10:41, then none until a real attack at 18:17.
  - Now only a raid we cannot easily handle resets it:
    - raid_response: threat near the eco (scouts 0.1) >= `HARD_SHARE` 0.2 x income x `HARD_S` 20 (floor 150) with committed < need → `mb.raidHardF`;
    - cover_defence: uncovered value >= the same → `lastHardF`;
    - a large bomber raid.
  - The user asked for "20 s of 20% army spend", 4000 at 1k m/s.
  - **Game 7** (vs DEFENCE_BOT, flat 400 version): **DRAW on phi**, the best of 8 games against it.
    - Bursts at 10:41, 13:46, 16:51, 19:56, every one ended by its own 90 s timer. Income at 20:00 4.3k vs 5.3k.
    - 0 eco buildings lost to the enemy. 14 Quakers, 6 transports and 16 Lashers lost.
  - The income-scaled version is deployed, not yet run.

**Tzar swap + better retreats (user 2026-11-02: "the quakers did exactly what I wanted ... they just might not be the right unit").**
- **`support/stop.lua` ("stopping power").** 2 Tzars (`corgol`, role `heavy_t2_veh`: 1650 metal, speed 39, range 650, aoe 292) per group, for 3 groups from 300 m/s.
  - It is a fresh copy of `support/arty.lua` (own latch) with `UNIT` and `TARGET = "density"`: SET_TARGET on the enemy ground unit in range whose 250-radius clump scores best.
  - Score = enemies − 1.5 x friends − 0.5 x dist / range; it must hit more enemies than friends.
  - CORE_v4 now uses `stop` instead of `arty`; putting `arty` back restores the Quakers.
  - `mb.stopOn` drives the AA sizes and the standing heavy transports.
- **Heavy transports.**
  - air_lift pools `corvalk` + `corseah` + `corhvytrans` and gives a job to a transport that can carry the unit (`AT.CanCarry`: the Tzar's size 4 > corvalk's 3).
  - `lift:heavy` (MIN_HEAVY 2 while stopOn, MAX_HEAVY 4).
  - Lab requests take `require = false` so the spine never plans a lab for transports. Before that it planned a 2900-metal T2 air lab for corseah; corhvytrans comes from the T1 air labs.
- **Re-routing.** Owners call `LIFT.Request` every tick while their unit is in the air, too. When the spot moves more than 400, the transport is re-routed: a new UNLOAD while carrying, a new Move while picking up. The route is checked again, and the unit is set down short of it, toward home, when no route is clear. Pool units in the air go home.
- **One retreat decision.** click_army's escort sets `g.posture` "back" when the threat at the escorted units is more than 1.3x the core, and "advance" under 1.0x (hysteresis). army_groups passes it as `rec.posture`. The escorted units step back 300 at a time (MOVE), the screen stays 100 in front of where they will be, and the AA follows them.
- **No going home.** A group that escorts landed units is no longer ended as "group spent" (FALL_FRAC) unless its core is gone. It steps back with them and reinforcements join it.
- eco_sim (2 seeds, vs the Quaker version): 20:00 income 4.5k vs 5.0k. 6/6 Tzars, 14 lifts, in-flight re-routes seen. Only coravp was required.

- **Games 8-9 (Tzars).**
  - Game 8 had a re-route bug: the safe drop was compared with the ask, so transports re-routed every 2 s (748 / 431x) and pickups restarted. Fixed: compare with the last ask (`j.reqX`); while picking up, only move the drop.
  - Game 9 vs DEFENCE_BOT: **lost on phi** 366k vs 486k (led 32k vs 23k at 10:00).
    - Escort ON 5, steps back / advances again 5 / 5, 4 eco bursts, 54 re-routes, 9 set-downs.
    - 2 Tzars, 4 heavy transports and 0 Lashers lost.
  - Game 9 vs CORE_ROWS_ECO: **won on phi** 212k vs 145k; 63 Lashers lost.

**T1 stopping power (`support/t1stop.lua`, user 2026-11-02, vs CORE_ROWS_ECO's raids).**
- **What it is.** Up to 3 HOME records (army_groups, kind "home", ids -1..-3) of 12 Pounders. Each holds a sector of the base: front, then ±0.95 rad, 1300 from the eco footprint's centre. The Pounders stand in a line, FIGHT a raid within 1400 and keep within a 700 leash.
- **When.** Raid pressure is an average over 180 s of "a raid worth >= 10% x income x 20 s at the eco". 0.25 / 0.45 / 0.65 → 1 / 2 / 3 groups, never fewer later.
- **How fast.** The want grows by one Pounder per 20 s (`WantTotal`), ordered at the "normal" lab tier (`tier` in the element cfg).
- **Tzars defend first.** Home records also take 2 Tzars (`home = { t1stop, stop = { n = 2 } }`) and come first in the hand-out. At home the Tzars hold the sector (arty.lua's "home" branch) and keep the density target.
- **Game 10 vs CORE_ROWS_ECO: won on phi, 198k vs 187k** (narrower than game 9's 212k vs 145k; one game each).
  - 1 home group at 10:15 (pressure 0.25), 2 later; 24/24 Pounders and 10/10 Tzars by 20:00.
  - Pounders: 0 lost, 8 kills. **Tzars: 2 lost, 94 enemy units killed.**
  - Our 20:00 income was 1.2k (game 9: 1.9k). Eco lost to raids is about the same (20 mex / 50 wind / 20 nano vs 44 / 28 / 10), so the drop is probably the support cost. Lashers lost: 54.

- **Last round (user 2026-11-02).**
  - **t1stop.** The ramp is a spend budget (`SPEND_FRAC` 0.05 of income; one Pounder's metal per step) instead of 1 per 20 s. `PRESS_1..3` lowered to 0.15 / 0.30 / 0.45.
  - **Tzar hand-out.** Elements with `RANK = "density"` (stop) are handed out to the records with the most enemy ground units within 1000 first (`army_groups.DENSITY_R`).
  - **Tzar targeting.**
    - +`HP_W` 2.0 x (1 − hp fraction).
    - Sticky: keep the target unless another scores `STICK` 1.5 x better (+1).
    - Focus fire: a line shares its first unit's target when it is in range.
- **Game 11 vs CORE_ROWS_ECO: won on phi, 295k vs 78k**, the biggest margin of the 4 games against it. Their income at 20:00 was 469 vs our 2.8k. We were behind at 10:00 (25k vs 37k).
  - Home groups at 8:02 (pressure 0.15), 9:49, 13:32; 12/24 Pounders by 11:05, 36/36 by 16:05.
  - Pounders: 0 lost, 23 kills. Tzars 12/12: 4 lost, 34 kills. Lashers lost: 2.
  - **Eco lost to raids was the highest of the ROWS games** (116 mex, 102 nanos, 68 winds vs 20-44 / 10-20 / 28-50). The sectors (1300 from the footprint centre) do not cover where ROWS hit; placing the sectors where raids land is the next step.

Not changed: stances (still `t2_raid` Tigers), the T1 army. `t2_raid` still makes Tigers. The arty is extra.

## Tests

- eco_sim, CORE_v4, 4 seeds, no vacuum (first versus final version). The sim has no enemy army, so escort / reserve run against the enemy commander only.

  | | 10:00 | 14:00 | 16:00 | 20:00 |
  |---|---|---|---|---|
  | baseline | 321 | 871 | 1388 | 3994 |
  | arty (final) | 334 | 824 | 1166 | 3027 |

  - The T2 plant comes 0:23-2:10 earlier (planned at the arty switch, about 9:50).
  - All 4 seeds reach 15/15 Quakers and 6/6 flak trucks (no air in the sim) between 14:00 and 16:30.
  - 21-23 lifts per game, none failed.
  - The cost is about 15 x 400 + 6 x 470 metal of support plus the plant. eco_sim is ~1.3x optimistic late.
- Existing suites: the same 7 failures as before (stances moved to `stances/legacy/`); the rest pass. `order_check.py`'s saved baseline predates the 10-30
  spawn move, so it can no longer show "same orders" for the other bots. The new paths were checked by reading instead: every one is behind a flag
  that defaults off (aa `MOVE`, `REJECT_POOL`, `ADOPT_OWNS`, `SUPPORT_FIRST`, `SUPPORT_ORDERS`, `PENDING_FIRST`, `ESCORT` / `RESERVE` / `AA_PACE`,
  `AIR_LIFT`, `NC_T1_AIR_LAB`).
- **Game 1** (vs DEFENCE_BOT, `--server single`, cut at 17:32 by the 750 s wall clock: not a verdict). DEFENCE_BOT led on phi at the cut (income 4.2k vs 2.1k);
  CORE_v4 led at 4/6/8/10 min. No Lua errors, no desync.
  - Arty on 9:52, the T2 plant stood at 10:37, `RAIDAIR` came on at 10:45 (so 18 flak wanted), AA 18/18 by 15:30, arty 15/15 by 16:30.
  - **0 Quakers and 0 flak trucks lost to the enemy**, but **15 transports lost** (14 to Vampires).
  - Bugs it showed, all fixed for game 2:
    1. Flak inserts at position 1 jumped two waiting Quaker inserts for 2.5 min (one Quaker 10:54-13:30). Fix: one waiting LO insert per lab, round-robin.
    2. AA pace held a group at a flak truck still at home 8.6 km back. Fix: only AA within 1500 counts.
    3. All 3 groups were reserves for ~4 min while waiting for 3 of 6 AA each. Fix: 2 is enough.
    4. Groups launched from the stage took their Quakers at home and escorted them across the map at Quaker pace (escort rows at 3.6k,1.6k). Fix: no escort at home; the group raids out, then its Quakers are flown to it.
    5. The lift checked only the drop point. Fix: the whole route.
- **Game 2** (the game-1 fixes, full 20 min): **lost on phi**. Income at 20:00 was 3.9k vs 6.6k and army 100k vs 127k; CORE_v4 led at 4 to 10 min (37.8k vs 19.8k at 10:00).
  - `RAIDAIR` came on at 7:42, before arty: 36 Lashers (the 10-31 `n_t1` 12 rule), all lost.
  - The T2 plant was required at 7:44 (the flak truck is the first AA pick) but stood only at **13:02**. It was in a block opened that second, with no nanos built, one con, and the watchdog replaced the con 3 times. Arty 15/15 at 16:30.
  - Lost: 14 Quakers (all to Wasps) and 22 transports (all to fighters: 18 Vampires, 4 Avengers).
  - Escorts again crept ~1 km per minute: the 220 step was under army_broker's 250 re-send threshold, and the escort held the group at the Quakers. Fixes: STEP 600, LIFT_DIST 1800, and a route check that remembers enemy fighters for 30 s within 1500 of the route.
- **Game 3** (game-2 fixes; old machine): **lost on phi**, closer. Income 5.1k vs 6.1k, army 92k vs 107k; CORE_v4 led at 4 to 10 min (32.5k vs 9.9k at 10:00).
  - 0 Quakers, 0 flak trucks and 14 transports lost (12 Vampires); 12 lifts done; 87 flights blocked by the route check (those units walked).
  - **Escort mode never engaged.** The rule "Quakers within 2500 of the target" never held: the reserve group orbits its target, and the Quakers stay 800 behind its core. Fix (`ESCORT_JOIN_R` 1500): escort once the Quakers are within 1500 of the group's core.
- **Game 4** (raid-only machine; run in parallel with game 3, cut at 19:39 by the wall clock): lost on phi.
  - Income 3.0k vs 7.6k, army 125k vs 134k.
  - The machine never entered a hold stance. 35 lifts done; 8 transports and 3 Quakers lost; no escort (it ran the old escort rule).
- **Game 5** (escort-join fix, no eco bursts; vs DEFENCE_BOT): lost on phi.
  - Income 4.2k vs 6.1k, army 113k vs 218k; CORE_v4 led through 10:00.
  - Quakers 15/15, 0 Quakers and 0 flak lost, 10 transports lost, 33 lifts done.
  - Escort engaged 12 times, one of them 1.1 km from the spawn. "Home" was measured from `MM.Base()` (the footprint centre). Fix: `MM.BaseDist` (the nearest eco building) <= 1500. Not yet seen in a game.
- **vs GROUND_RAIDER_BOT** (eco bursts on): won; its commander was killed by Incisors at 8:16, before arty or bursts.
- **vs CORE_ROWS_ECO** (eco bursts on): won; its commander was killed at 17:34. CORE_ROWS_ECO was ahead on phi from 6:00 (35k vs 26k at 10:00).
  - **No eco burst fired**: ROWS raided our side all game (share `attack` <-> `push_high`), as the rule intends.
  - **20 Quakers lost, all to Brutes / Incisors**; no escort engaged. Lifts were often blocked ("no clear route"; 14 jobs waiting at 17:30), so the Quakers walked out alone behind groups that were reserves, and ground raiders caught them.
  - The arty is weakest against an army that fights on our side.

## Open
- Transports have no fighter cover; the route check only avoids air threat that is known.
- The T2 plant is built by the spine's one con (`CON_CAP` 1 until 10:00). In eco_sim it took 2-3 min to build; in game 1 it took 43 s.
- `t2_raid` keeps adding coravps for Tigers (game 1: 7 coravps by 16:30). Whether Tigers are still worth it next to the arty is the user's call.
- Escort mode is untested against a real push into a defended base (the game-1 escorts saw no threat). Quaker firing was not measured directly. Read it from the replay or the `[LED] fight` rows.
- Air rush (`interrupt` tier) is still lab_rules' own flush want.
