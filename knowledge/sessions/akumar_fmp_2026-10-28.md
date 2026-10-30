# CORE_ROWS_ECO vs BM_akumar6, Full Metal Plate (2026-10-28) -- game review

## The game
- **Replay:** `data/demos/2026-10-28_04-58-33-049_Full Metal Plate 1.7_2026.07.04.sdfz`
- **Players:** team 0 = BM_akumar6 (skill 56, rank 7). They played **Armada**: the lobby said Cortex, but the units are arm*.
  Team 1 = the bot (CORE_ROWS_ECO, played under [Blahaj]IamTree).
- **Result:** our commander was killed by a Thor at **29:25**.
- **The bot played the whole game.** It gave 10k+ widget orders a minute. Only 6 orders were manual, all at 19:xx.
- **The code that played** = the repo's working tree on 10-28 (uncommitted T1 overhaul included). The newest deployed file is from 23:36 on 10-27. So this was the **first real game of the T1 stances** (`t1_hold` / `t1_push` / `raid_sections`).

**Logs.** The original infolog was overwritten, and the Ledger Logger was off in BAR's widget config (no `metalbot_ledger_*.log` for that game).
The logs here were rebuilt by `replay_logs.py`: the replay played back with the bot's widgets for team 1, plus the tracker, ledger and state dump for both teams.
- Files in `akumar_fmp_2026-10-28/`: `infolog.txt`, `team0.log`, `team1.log`, `result.json` (git-ignored; rebuild in ~11 min), and `teamstats.json` (the engine's own per-team stats).
- **Check:** the tracker's metal produced matches the engine's to within 1% for both teams at every checkpoint.
- Rows that only read the game (`[TRK]`, `[LED]`, `[SNAP]`) are exact. Decision rows (`[FSM]`, `[CK]`, `[LT]`, ...) are a reconstruction. They are consistent with what happened: for example, Brutes appear after each `t1_push`, and the raid groups end on the stance flips.

## Numbers side by side

Engine stats (metal produced per second, averaged over the minute) and finished units (`[SNAP]`):

| min | income akumar | income bot | akumar mexes | bot mexes | akumar builders (cv+consul) | bot builders (ck+ca+cv) |
|---|---|---|---|---|---|---|
| 6 | 109 | 111 | 57 | 48 | 14 | 13 |
| 8 | 243 | 170 | 116 | 71 | 21 | 20 |
| 10 | 389 | 214 | 179 | 78 | 31 | 22 |
| 12 | 761 | 213 | 377 | 100 | 76 | 40 |
| 14 | 1374 | 378 | 649 | 199 | 92 | 44 |
| 18 | 2798 | 1530 | 1249 | 592 | 155 | 59 |
| 22 | 3730 | 1455 | 1601 | 598 | 157 | ~40 |

- **Even until about 6:30, then the bot's income goes flat from 9:00 to 12:00** (188 -> 214 -> 213 -> 213 m/s). By 12:00 akumar has 3.5x the income.
  eco_sim gives this bot 358 m/s at 12:00 *with no enemy*. Even that is under half of akumar's 761.

Where the metal went over the whole game (`ledger_report.py`):

| | bot | akumar |
|---|---|---|
| army (ground + air) | 59% (35 + 24) | 37% |
| eco | **10%** | 25% |
| build power | 29% | 11% |
| defence | **0%** | 26% (251 beamers, 84 flak, 47 ambushers) |
| unspent | 24% (late: idle labs) | 48% ("nothing to build", bank full from 6:00) |

- **Value lost / killed:** bot 1088k / 713k (ratio 0.66); akumar 716k / 952k.
- **Eco killed by the bot over the whole game: 0.** Enemy build power killed: 169k, against 610k of ours lost.

## Timeline
- **0:15-2:00** akumar opens with a vehicle lab and **8 Rovers by 2:00**, sent to every corner of the map.
  The bot's opening is fine: 9-11 m/s, even with akumar.
- **2:13-3:58** Rovers reach our base with no warning (seen 564 elmos away, lead 0 s).
  We kill 8 Rovers for 0 losses. This was "eaten" / "I am surrounded"; the "die to 1 scout" bug is gone.
- **2:57** `start -> t1_hold`: `proj_ratio=0.46`, because the "enemy army" it counted was 450 metal of Rovers.
  The opening raid (group #1, launched 2:50) ends 7 s later.
- **5:33 / 6:01** air lab, first grid. The second spine opens at 6:33 (16 nanos held).
- **6:05** `t1_push`. Raid group #2 (11 units) goes for an **armnanotc in akumar's main base, 7.5 km away**.
- **6:47** share -> `attack` (1.0): `enemy_near_base=674`, a few Flashes and Rovers on our half.
- **7:17** `t1_push -> t1_hold` (`under_attack`). Group #2 "ends" with **0 of 11 lost after 41 s**: recalled before it got there.
  `CON HOLD: air con skipped` (also at 8:41, 9:14, 9:44).
- **8:32-11:07** share `attack` = 1.0 for 2.5 minutes. This is the flat-income window.
  - **8:35** akumar's 68 Flashes raid the line: we lose 20 winds, 15 mexes, 7 cons and 14 Rascals (6.3k of build power) and kill all 68.
  - **9:02** the next push is recalled the same way (groups #3 / #4, 0 kills).
- **9:29-12:00+** the **SLOW group sits at home**: "SLOW group #5 (base): 61 -> 118 screen, enemy av near=0". This was "units too afk".
- **9:30** 10 grids open, "aircons free 0 ordered 0", "T1 air con deficit".
  The capstones become T1 air labs (10:06, 11:06, 15:57). No capstone ever became a T2 lab.
- **11:13** `t1_push` with `enemy_vs_army=0.09`, `proj_ratio=8.07`: the bot thought it was far ahead.
  akumar's army was small because their metal was in mexes and towers.
- **12:00** akumar has an experimental gantry (armshltx): Razorbacks from 14:00, Thors from 18:00.
- **13:45** 14 Pounders die attacking into akumar's half (lost 4.9k, killed 0.4k).
- **14:07** `under_attack` again -> share 1.0.
  **14:31** fight near our base, 174 s: we lose 198 units (63 Pounders, 44 Bladewings), 33k; we kill 9k (mostly Rovers).
- **14:30** first T2 lab queued (`T2BOT_INCOME` 600 m/s gate), done 15:32. 15:07 `t2_hold`.
- **17:18** `late`: the unit cap is 75% full. The bot has 800 winds; akumar has 123.
- **17:37-24:09** one long fight just south of our base (8293, 6041), 392 s.
  We lose 469k (219k army, **235k build power**) and kill 378k (139k of their build power).
- **18:58-28:35** 5 Dragon sink labs on the **west (enemy) side** of the base at x=7816.
  They have 0-3 helpers, are never finished, and are killed by Ambushers and Thors. From 18:30, 409k of metal goes unspent ("idle_labs").
- **20:00** "T2 cons alive 0" up to here, while 31 grids wait for a retrofit and the spine pools have T2 cons standing idle. Only 6-7 T2 mexes all game.
- **24:15** 5 Thors killed for 747 (the best trade of the game). **29:25** commander killed by a Thor.

## What akumar did better
1. **Took the whole map.** Full Metal Plate is metal everywhere, and akumar had 76 builders at 12:00 and 155 at 18:00, mostly Consuls, laying 1,700 T1 mexes.
   Energy came from fusions and advanced fusions, not winds.
   The bot keeps its eco in compact lanes and grids around the start, and its 12 line cons stay "line 12+0" from 6:00 to 21:00.
2. **Defended the eco with towers, not the army.** 26% of spend went on defence (beamers along the mex field, flak, ambushers).
   So the bot's raids found nothing cheap to kill, and its gunships flew into flak.
3. **Teched early:** advanced vehicle plant ~8:00, T2 cons by 10:00, gantry at 12:00. The bot: T2 lab at 15:32.
4. **Cheap harassment that cost the bot far more than it cost akumar:** 8 Rovers at 2:00, then up to 148 Rovers roaming.
   They kept the bot's `under_attack` signal on, which recalled every raid and held the army share at 100%.

## Implemented 2026-10-29
The low-risk items, each opt-in and switched on in CORE_ROWS_ECO. Order streams of STANCE_ECO2, RAID_BOT and DRAGON_ECO are identical (`order_check.py`), and all 60 test suites pass.

| Item | What was done | Where |
|---|---|---|
| 1 | `ARMY_SHARE_MAX` 0.8: the share is never above 80%, whatever the machine, the air-rush rule or `plan.share` say. | `strategy.lua` maxShare, `macro_runtime.lua` |
| 1 | raid_response `THREAT_HOME`: the raid record's `home` value counts only groups within 1200 of the eco footprint, with scouts at 0.1. `under_attack`, `enemy_near_base`, the con hold and `unless_raided` read it. | `raid_response.lua`, `signals.lua`, `macro_runtime.lua`, `lab_rules.lua` |
| 2 | `machines/rows_default.lua` v3, linear: `start` -> `start_brutes` -> `t2_raid` -> `late`, with `t1_hold` / `t2_hold` as last resorts. `t1_push` is gone, and being attacked no longer pulls a raid stance home. | `machines/rows_default.lua` |
| 2 | `RAID_CARRY`: a flip to hold never recalls a raid. | `unit_runtime.lua` |
| 3 | `idle_value.lua`: the stat, as signals and `[IDLE]` rows, and in the `[LED]` spend row. It reports only; nothing acts on it yet. | `idle_value.lua`, `unit_runtime.lua`, `ledger_logger.lua` |
| 4 | click_army `LEG_LEAD` 600: each move ends 600 past the front-most unit. | `click_army.lua` |
| 5 | unit_runtime `PICKET`: 2 air scouts fly a line across the approach, 40% of the way out, from 4:00. Lab want `picket-scout`. | `unit_runtime.lua`, `lab_rules.lua` |
| 10 | lab_rules `AIR_AA_GATE`: no Shurikens or Wasps while enemy AA is at least 2000 and at least our air value. A live raid at home lifts the gate. | `lab_rules.lua` |
| 11a | enemy_intel `BLIP_SCOUT_SPEED` 120: a fast radar dot is a scout, not army. | `enemy_intel.lua`, via unit_runtime `ENEMY_INTEL` |
| 11b | New signals: `enemy_def`, `enemy_mexes`, `enemy_income_est`, `eco_ratio`. | `signals.lua`, `enemy_intel.lua` Facts |
| 13 | The ledger reads home again at GameStart, and lazily while it is still unknown. | `ledger_logger.lua` |
| extra | `air_transport.lua`: tested in the engine. The Valkyrie lifts a nano and a con but **not an HLLT** (mass 10200 against its transportmass 750); the T2 transport (corseah) lifts the HLLT. | `air_transport.lua`, `tests/engine/transport_test.py` |

## Fixes and features, ranked (merged with the user's notes, 2026-10-29)
**The main lesson (user):** a unit that is built takes metal out of the eco, so it has to create a problem for the enemy, by attacking or defending. Otherwise the eco was killed for nothing.
- Eco pays for itself in about 40 s. A unit that is not causing trouble on the enemy's side within about 80 s should have been eco.
- At 7:00 the bot had spent 26k against akumar's 19k and had 7k of army value against 4k, yet all the pressure was on the bot's side of the map. Its army was Pounders that never got across in time.

Each item gives the evidence, where it lives in the code, and how to test it (testing policy: eco_sim for anything without fighting, else one real game).

1. **Bound the army share: at most 80% army, at least 20% eco while eco can be built. Never 100% army.** (user)
   Also fix why the share sat at 1.0: `under_attack` / `enemy_near_base` fire on cheap scouts anywhere on our half (mine).
   - **Evidence:**
     - 800 metal inside "our territory" = 7 Flashes or 22 Rovers. With raid_response `OUR_HALF` on, that territory is half the map.
     - Share at 1.0 from 8:32-11:07 (the flat-income window) and from 14:07.
     - Pushes recalled at 7:17, 9:02 and 14:07; air cons held 7:17-9:44.
   - **Fix:**
     - Clamp the share (the `attack` node = 0.8, or a cap in the share governor).
     - Count only intruders near our assets (`MM.BaseDist`), weighted by what they can kill (scouts count little).
     - Leave the `attack` node on a value that ignores scouts.
   - **Code:** `bar_framework/signals.lua`, `raid_response.lua`, `machines/rows_default.lua`, `fsm.lua`.
   - **Test:** one real 10-15 min game. `[FSM]` share <= 0.8 all game; `[LED]` `to_eco` >= 20% of pull.
2. **A raid-first stance machine.** (user; the evidence is mine)
   - **Fix (user):**
     - Remove `t1_push`; keep only raid and hold.
     - Stay in raid as much as possible. Hold only when really behind with no way to make a threat on the enemy side.
     - A raid does not come home after losing a few units halfway. Even if it kills nothing, it pulls enemy units to it and buys time, for about 10% of the army.
   - **Evidence (mine):**
     - The 6:36 raid had one hurt unit retreat, evaded at 7:15, and ended at 7:17 on the stance flip.
     - Every group targeted a nano in the main base 7.5 km away.
     - 0 enemy eco was killed all game.
   - **Why the raids came home:** the stance-change handover in `unit_runtime.lua` gives every ground unit to the maneuver blobs (`MD_RETURN`).
     The only exceptions were 5 raider-type units (`RAID_SQUAD`) and units already within `COMMIT_R` (2000) of their target.
     click_army then saw "0 of 11 left" and ended the group as "spent".
   - **DONE 2026-10-29: `RAID_CARRY`** (unit_runtime option, on in CORE_ROWS_ECO; needs `RAID_SQUAD`). The user's call: "never fully recall a raid".
     - On a flip into hold, every unit of an attacking click_army group stays with click_army, like a released raid section, until it dies.
     - Its own retreat, escape and spent rules still apply.
     - Logged as `[UnitCtrl] m:ss stance a -> b: N raiding units keep going (RAID_CARRY)`.
     - There is no "home in real danger" exception: raid_response still answers with the units at home.
   - **Still open (mine):** target nearer exposed eco (eco value in a radius, divided by distance, less the defence nearby).
   - **Code:** `machines/rows_default.lua`, `click_army.lua` (target score), `unit_runtime.lua` (StanceHandover).
   - **Test:** one real game. `[CK]` kills > 0; `[LED] fight` `killed_eco` > 0.
3. **A unit has to earn its keep: an idle-value stat.** (user)
   A unit group that is not within ~15 s of a comparable amount of enemy value loses value. Units standing around count as losses in the army-value signals and the ledger.
   - **What it would have caught:**
     - The SLOW group (Pounders) at home 9:29-12:00+: a 61-118-unit "(base)" screen with no enemy near.
     - At ~4:00 the grunts that had killed the Rovers all stayed at base with nothing on radar. 2-3 could have gone out to scout or make trouble (minor).
   - **Code:** `value_weights.lua` / `ledger_logger.lua` (the stat); `av_rates.lua` / `signals.lua` (use it); `click_army.lua` slow group (act on it).
   - **Test:** one real game.
4. **Push in larger move steps.** (user)
   - Units turn and accelerate. A short move makes them reach the point, slow down, then speed up again for the next one. That is part of why the 11:00 push (a 680% army lead) was so slow.
   - Give moves that lead the group by a larger distance.
   - **Code:** the waypoint step in `click_army.lua` / `raid_group.lua`.
   - **Test:** one real game (time from launch to first contact).
5. **Scouting and warning time.** (user)
   - **Evidence:**
     - Air scouts or ground patrols in the middle of the map would have given much more warning; the army stood in the middle for a while.
     - The 9:00 raid got in with a 100% army lead: a scouting and unit-position failure.
     - akumar's air scouts at 12-13 min found the whole bot army. That is the example to copy.
   - **Fix:** patrol and air-scout posts on the routes into the base (`scout_net` `CREEP`, radar posts).
   - **Test:** one real game (tracker `lead_med`, `arrivals_warned_n`).
6. **Build power ahead of income.** (mine)
   - **Evidence:**
     - 7:00-13:00: `to_bp` 45-101 m/s against `to_eco` 11-36, and `bp_use` 0.22-0.40.
     - The second spine opened at 6:33 with 16 nanos.
     - `NANO_UTIL_GATE` was switched off in 077080b.
   - **Fix:** no new nanos or spine blocks while `bp_use` < ~0.6 and the bank is empty.
   - **Test:** eco_sim.
7. **Tech timing, the T2 lab's exit, and the retrofits.** (both)
   - **Evidence (user):**
     - The push finally arrived at 13:00, but akumar had T3 and the bot had no T2 lab: the stance edges need moving.
     - The T2 bot lab built in the line has no exit: mexes and winds block it. Place it so it always has one.
     - The mex grids were never retrofitted.
   - **Evidence (mine):**
     - The T2 lab waits for `T2BOT_INCOME` 600 m/s (queued 14:30).
     - `RETROFIT_FLOAT_CONS` needs a 20% metal bank, which never happens.
     - The retrofit jobs never used the spine pools' idle T2 cons: "T2 cons alive 0" while `[CB]` showed spine 11+8.
     - Air-con deficits turned every grid capstone into a T1 air lab.
   - **Code:** `line_transition/t2bot_lab.lua` (gate, site and exit), `grid_retrofit.lua`, `con_broker.lua`, the edges in `rows_default.lua`.
   - **Test:** eco_sim (T2 lab time, retrofits started), plus a check of the lab's exit path.
8. **Energy: fusions earlier, to save unit slots.** (the table below)
   - **Evidence:** 800-900 winds; the cap was 75% full at 17:18 (forcing `late`).
   - **Test:** eco_sim (income at 20:00, units in use at 20:00).
9. **The metal sink, and scaling energy and metal for it.** (both)
   - **Evidence:**
     - 5 sink labs at x=7816 (the enemy side), 0-3 helpers, never finished, killed by Ambushers and Thors.
     - 409k of metal unspent, with idle labs, from 18:30.
     - User: by 23:00 the spines' build power was lost, and energy and metal had never scaled for the sink.
   - **Do NOT move the sink (user 2026-10-29):**
     - Behind the base it uses eco space.
     - Along our side of the map it is farther from the spine, so reinforcements take longer.
     - Next to the spine is one of the safest spots: that area is defended first and is where units are made, so it always has a baseline of units.
     - It was only a problem because the bot was losing and fighting on its own side of the map.
   - **Still worth looking at:** assist the sink labs from the idle spine pools (0-3 helpers), and fill idle labs before ordering new sink labs.
   - **Code:** `metal_sink.lua`.
   - **Test:** eco_sim vacuum game.
10. **Air spent into flak.** (mine)
    - **Evidence:** 24% of spend went to air: 232 Bladewings killed, Rapiers 84 -> 27, against 25 -> 84 flak and Hawks.
    - **Fix:** cut the gunship and stun share when the scouted enemy AA is high.
    - **Test:** one real game.
11. **The army-value signals miss what the enemy is doing.** (mine)
    - **(a) Radar dots priced as army.** At 2:55, `[AV]` "enemy scouted 450" gave `proj_ratio` 0.46, and `start -> t1_hold` ended the opening raid.
      - Seen scouts are already excluded: the Rover is `groundscout`, so `UQ.is_scout` is true and `EI.ArmyValue` skips it.
      - But `EI.BLIPS` adds every moving radar dot, priced from the armed types seen so far. None had been seen yet, so each dot got `BLIP_DEFAULT` = 150.
      - So 3 Rovers on radar (31 metal each) counted as 450 of army.
      - **Fix:** a dot faster than the fastest armed type seen, or faster than about 120 elmos/s, counts as a scout (value ~0). The tracker already decodes speed 166 as Rascal / Saber / Rapier.
        Also a much lower `BLIP_DEFAULT`, or 0, while no armed enemy has been seen.
      - **Code:** `enemy_intel.lua` (`BlipValue`, `BLIP_DEFAULT`).
    - **(b) Army lead vs where the enemy put its metal.** At 11:13, `enemy_vs_army` was 0.09 (we "lead" 11x), yet akumar had 3.5x our income. Their metal was in mexes, towers and a T3 gantry, which army value does not count.
      - The bot's 'lead' was real but temporary and had no target.
      - **Fix idea:** two signals for the machine. `enemy_def`: the scouted static defence along the raid targets. `eco_ratio`: our income against the believed enemy income (scouted mexes x yield, plus labs and tech seen).
        With those, the machine sees "we are ahead in army but behind in eco: raid now, before tech arrives", instead of "far ahead: sit".
      - With `t1_push` removed (item 2), this mostly feeds the raid-versus-hold choice and item 3.
12. **Rez bots need better logic.** (user; a general item)
13. **Tools.** (mine)
    - **The ledger's scout section is empty in every game against a person.** It reads home at `Initialize`, before the starts are picked (`ledger_logger.lua:313`).
    - **The Ledger Logger was disabled** for this game.
    - **`replay_logs.py`** is new.

**Out of scope for now (user):**
- A new system to replace the mex grid scaling, and a faster-starting eco. The grids came online slowly, and the income lost meanwhile went into an army that could not reach the enemy.
- Static defence around the enemy (as akumar did), and a forward spine at a good static position, so slow, cost-effective units are built near the enemy and get value in time.

**Removed from my list:**
- "Spread mexes with many more cons on a metal-everywhere map". The user says that is wrong.
- Home-side towers. Replaced by the user's forward-static idea.

## Your notes vs mine
| Point | User | Mine |
|---|---|---|
| Army that never threatens the enemy side (Pounders, slow push) | yes (the main lesson) | yes (slow group at home, raids recalled) |
| Raids pulled back too early | yes (after losses halfway) | yes (stance flip on `under_attack`) |
| Share at 100% army; eco floor | yes (20% eco floor, max 80% army) | yes (share 1.0 8:32-11:07, set off by scouts) |
| Remove `t1_push`, raid-first machine | yes | -- |
| Idle-value stat | yes | -- |
| Larger move steps (turn and acceleration) | yes | -- |
| Scouting and warning (air scouts, patrols, the 9:00 raid) | yes | partly (Rovers arrived with 0 s warning at 2:13) |
| Grunts at 4:00 should go out | yes (minor) | -- |
| T2 late, T2 lab exit blocked, no retrofits | yes | yes (600 m/s gate, float gate, idle spine T2 cons) |
| Sink, energy and metal scaling late | yes | yes (sink on the enemy side, never finished) |
| Rez bots | yes | -- |
| Static near the enemy + forward spine | yes (future) | -- |
| Build power ahead of income (`bp_use` 0.2-0.4) | -- | yes |
| `under_attack` set off by scouts | -- | yes |
| Raid target choice (far nano, 0 eco killed) | -- | yes |
| Winds fill the unit cap | (fusion question) | yes |
| Air into flak | -- | yes |
| Scouts in army value; `enemy_vs_army` 0.09 | -- | yes |
| Ledger scout bug; logger disabled | -- | yes |

## Energy: wind vs fusion vs advanced fusion (Cortex, this BAR version)
Unit defs come from the game's `[UDEF]` dump.
- Wind on Full Metal Plate is a constant 25 (`windMin` = `windMax` = 25), so one turbine makes 25 E/s.
- "BPs" = build-power-seconds (`buildTime`). One nano is 200 BP.
- "Payback (M+E)" counts metal at 70 E per metal (the T1 converter rate).

| unit | E/s | E/s per 1k metal | E/s per 1k energy | E/s per 1k BPs | BPs per E/s | 1 nano builds it in | payback (E cost) | payback (M+E) | E/s per unit slot | E/s per footprint square | HP per E/s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| corwin | 25 | **581** | **142.9** | **14.9** | 67 | 8 s | 7 s | **127 s** | 25 | 0.69 | 8.8 |
| corsolar | 20 | 133 | (0 E cost) | 7.1 | 140 | 14 s | 0 s | 525 s | 20 | 0.20 | 17.8 |
| coradvsol | 80 | 216 | 20.0 | 9.8 | 102 | 41 s | 50 s | 374 s | 80 | 1.25 | 15.0 |
| corfus (T2) | 850 | 236 | 38.6 | 14.4 | 69 | 295 s | 26 s | 322 s | 850 | 8.5 | 5.1 |
| corafus (T2) | 3000 | 309 | 62.5 | 9.1 | 110 | 1650 s | 16 s | 242 s | **3000** | **20.8** | 3.1 |

Armada, for reference: armfus 750 E/s for 3350 M / 18000 E / 54000 BPs; armafus 3000 E/s for 9700 M / 69000 E / 313000 BPs.

What the same energy costs:

| | as winds | as the plant |
|---|---|---|
| **1 corfus = 34 winds** | 1462 M + 5950 E + 57k BPs, **34 unit slots** | 3600 M + 22000 E + 59k BPs, 1 slot |
| **1 corafus = 120 winds** | 5160 M + 21000 E + 202k BPs, **120 slots** | 9700 M + 48000 E + 330k BPs, 1 slot |

Reading it:
- **On FMP, wind is the cheapest energy by metal and by energy cost, and it equals the fusion on build power.**
  - Wind gives 2.5x a fusion's E/s per metal and 1.9x an afus's.
  - What fusions buy: unit slots (34:1), space (12x the E/s per square, so more fits within nano reach), and fewer targets. The price is metal.
- **The bot's 800 winds at ~18:00 = 20k E/s.** That much costs about 34k M as winds, 85k M as fusions, or 65k M as afus.
  The fusions cost about 51k M more, roughly 1 minute of the bot's income at 15:00, and give back 776 unit slots (26% of the 3000 cap).
- **Fusion vs afus:**
  - The afus is cheaper per metal (309 vs 236 E/s per 1k M) but needs 1.6x the build power per E/s, and one nano takes 27 min to build it.
  - So: fusions while build power is the limit, afus when metal is.
  - Both need T2 cons, which ties this to item 7.
- **Fusions are fragile per E/s** (HP per E/s 5.1 and 3.1, against wind's 8.8). Losing one costs 850-3000 E/s at once, and they explode on death. They belong behind the base, with AA.
- **Suggested order:**
  1. Winds until the unit count starts to matter (a few hundred winds, or the cap past ~40%).
  2. Fusions as soon as T2 cons exist.
  3. Replace the winds near the spine to free slots.
  eco_sim can rank the switch point by income and units in use at 20:00.

## What worked
- The early Rover harass was handled: 8 Rovers killed for 0 losses.
- The 8:35 Flash raid was wiped out: 68 Flashes killed.
- 5 Thors were killed for 747 at 24:15.
- The 17:37 fight killed 139k of akumar's build power.
- The T1 stances all fired (3 `t1_push` / `t1_hold` round trips, `raid_sections` released a blob at 4:45).
- No Lua errors.
