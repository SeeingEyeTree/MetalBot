# Proxy base, second version (CORE_v4, 2026-11-08)

This note follows the proof of concept in `area_defence_2026-11-08.md` ("Proxy base, proof of concept"). There, the lab died at 11:22 to about 30 Incisors. No wall stood, and only 543 metal of army was at the lab.

## The user's request
> It should come in one wave and the normal ground army should create the beach head. When the proxy signal comes in 2 of the army groups should stop raiding and be pulled in as defenders for the area where the base will be ... The t1 lab in the proxy base should just make pounders ... It can ignore the stance ... air trans 8 and then just build more. The air trans should move as one group and be escorted by the fighters, some of the shurikens should also get sent to the proxy base ... Have the vech lab make 4 t1 cons that just make twin guards ... a few Thistles ... quickly get up a t2 lab to make tzars, and then swap over to t2 static. Scorpion and Persecutor ... a t2 con with ~15 nanos around it building rows of Basilisk. The basilisk should target shields first then bp, then fusions/afus then labs ... Check if there is a API call for target kill confirmation. Pull in normal units to defend, wall + static then lrpc.

**Budget (user's choice): the proxy has first call on metal.** Its labs are not charged to the army budget. Its cons build at HIGH builder priority.

## What it is
`proxy_base.lua` is now a state machine. It publishes `WG.ProxyBase.state` and moves through three states:

**1. Beachhead.** The macro option is `BEACH`; the unit side is unit_runtime `PROXY_ARMY`.
- `click_army` `M.Retask` turns the 2 biggest raid groups into proxy groups (state `"proxy"`, `UpdateHold`).
- A proxy group walks to the spot, then FIGHTs every enemy unit or building within `PROXY_CLEAR_R` 900. After that it stands a MOVE line across the spot→enemy axis, 400 out.
- `FastCount` skips proxy groups, so new raid groups still launch.
- For `PROXY_REINFORCE_S` 150 s, new fast units join the proxy groups until they are worth `PROXY_WANT_AV` 6000.
- The groups keep their Tzar / AA elements (army_groups) and the AA escorts.
- GO comes when a proxy group is at the spot and it has been clear for 10 s. GO also comes after `BEACH_WAIT_S` 150 s at most.
- area_defence declares the proxy area as soon as the spot is chosen. Its settings:
  - the spot itself counts as a member;
  - the front faces the enemy's build power from the spot;
  - its threat net is 1800 wide (not 3000);
  - it never reclaims, and its walls take Tzars;
  - its threats do not count for the main base's launch gate or `def_*` signals (they are in `mb.defence.proxy`).

**2. Con.**
- The air con flies at the start of the beachhead and waits 2500 short of the spot (the convoy's rally point). It places the T1 vehicle plant at GO.
- The nanos come by convoy (sink_lift `CONVOY`, `NANOS` 8):
  - the transports are ordered at the high tier during the beachhead;
  - all 8 nanos are loaded and flown to the rally point;
  - they fly in together after GO;
  - a partial wave goes only 60 s after GO.
- `WG.ProxyConvoy` is published. air_wing `ESCORT` puts every wing fighter on a point 350 ahead of the transports.

**3. Hold.**
- `proxy/crew.lua` owns the proxy's builders: the air con plus the T1 lab's cons (owner "proxy" in the con broker).
- Each con takes the first short item of the `BUILD` list. The list order: 4 nanos, 4 Twin Guards, 2 Thistles, the T2 lab, 15 Basilisk-block nanos, 3 Scorpions, 1 Persecutor, Basilisks (up to 40), then more nanos, Twin Guards, Thistles and T2 static.
- An item that finds no spot is passed over for 20 s.
- The proxy's nanos help frames in their reach, else a busy con in reach, else the lab.
- The labs make what the crew says, through lab_rules' `proxy-lab` want (`lab.only`):
  - T1 lab: 2 Pounders, then cons up to 4, then Pounders;
  - T2 lab: 4 T2 cons, then Tzars.
- Proxy labs take no lab_orders requests, so slot_spine still plans its own labs.
- Units the proxy labs make belong to the proxy's walls (area_defence `NoteCreated` → wall `home`).
- A third of the air squad (at least 4) belongs to the proxy once its lab stands.
- The Basilisk block stands 700 beside the lab, across the enemy axis, so the guns (range 4950) keep their reach.
- The proxy groups raid again once 6 T2 defences stand and the proxy's threats have been covered for 2 minutes (`RELEASE_STATIC`). They are also released when the proxy is lost.

**LRPC fire** (`lrpc_fire.lua`, unit_runtime `LRPC`):
- Every Basilisk takes enemy buildings from enemy_intel's records, in tiers: shields (new `shield` class flag, from `customParams.shield_power`), build power (not labs), fusions / AFUS (energy ≥ 700), labs, other eco, anything.
- Inside a tier, the most valuable first. A target takes enough guns for 3 volleys.
- The order is ATTACK on the remembered position, so it works on ghosts.

## Kill confirmation (the API question)
There is no direct engine call for this:
- An enemy's `UnitDestroyed` reaches a widget only in line of sight (BAR's `api_widget_events` gadget).
- Engine ghosts are invisible to widgets.
- `widget:Explosion` is synced-only.

What works (`kill_confirm.lua`):
- **Wreck.** BAR sets `featureVisibility = 3`, so features are always visible, and enemy `FeatureCreated` reaches widgets. A wreck at the target's spot whose `GetFeatureResurrect` is the target's unit means it died. This is most likely the "explosion through fog" the user sees: our own shell's impact, plus the wreck popping in.
- **Radar dot gone.** A target's dot disappears without a `UnitLeftRadar` (that callin fires only on a LOS change, never on death).
- **Seen.** Its death happens in our sight.
- **Hits.** BAR's `widget:VisibleExplosion` sends our own shells' impacts even in fog. It comes from a gfx gadget that may not run headless, so shots are also counted from the guns' reload.
- **Probably dead.** No confirmation after 2x the shots a target needs: it is put last until seen again.
- **Cross-check.** The live own-team `unitsKilled` (`Spring.GetTeamStatsHistory(team, n, n)`) is logged.

Caveats:
- A nanoframe leaves no wreck.
- Overkill can leave a heap, which is matched by spot.
- Unit ids are reused.
- In `--server single` the shim leaks `VisibleExplosion` for every team, so only impacts owned by our own units count.

## Results
**eco_sim** (CORE_v4, seed 1). A patch file publishes the enemy's build power at the mirrored spawn, since the sim has no enemy.
- Beachhead at 8:00; GO at 9:30; lab frame at 9:45.
- One 8-transport wave with 10–18 fighters on it.
- T2 lab about 3 min after the lab.
- First Basilisk at about 17:30; 9–11 by 22:00.
- 0 Lua errors.

**Game 1** (20 min vs CORE_v4_022f31f, single). Loss on phi (238k vs 264k); phi led at 10:00.
- The raid groups at 8:00 were 14 and 6 units. One was gone before it arrived.
- Convoys left with 2 transports.
- 15 air cons were sent, most lost.
- Try 1 never got a lab. Try 2's lab stood 15:15–16:27 and **its crew built nothing**: BAR's `unit_auto_repair_idle_builders` gives every idle builder an order, so "queue empty" never happened. The sim does not run that widget.
- Fixes:
  - the crew orders its cons whenever they have no crew item, whatever else is in their queue;
  - the air con checks the head of its queue;
  - the reinforcement rule;
  - a full wave before GO;
  - proxy air only once the lab stands.

**Game 2** (same opponent). **Win on phi**; end 261k vs 162k, income 2.1k vs 1.5k m/s.
- Beachhead at 8:56 (no enemy build power was seen before). GO at 10:02 with 45 units worth 6.2k.
- 7 of 8 transports came in together at 10:41. Lab finished at 11:08.
- **The proxy held 9 minutes.** By 18:00 it had 8 Twin Guards, 4 Thistles, the T2 lab (14:15), 4 Scorpions, 2 Persecutors and 15 row nanos.
- It fell at 20:11 to a big push, with the first Basilisks only planned. **No Basilisk fired.**
- Bugs found:
  - **Wall Tzars.** The proxy walls' want of 2 Tzars each made the main T2 labs build "wall Tzars": 36 made. With no home they joined the main base's walls, which want none, and stood idle (the user saw 14 at ~17:00 in game 1). Fixed: the main walls' want and count leave out the proxy's walls and the proxy's own Tzars; the proxy's Tzars go to the raid groups when it is lost.
  - **Wall Pounder count.** A wall area's Pounder count was every Pounder in the team, so the proxy got 12 walls and its own Pounders stood one or none to a wall. Fixed: per-area count.
  - **Basilisks too late.** The row nanos now follow the T2 lab, and a smaller first T2 batch (3 Scorpions, 1 Persecutor) comes before the Basilisks.
- These fixes are not yet seen in a real game.

## Round 3 (user, after game 2)
> Make sure the proxy base builds a jammer (castro and shroud) first then lab then radar. t1 then t2 ... Have the convoy and air con hug the side of the map ... the main base probably never needs tzars to defend ... 45k metal in tzars ... make sure the nanos that are part of the proxy base are high prio ... adds a t1 bot lab after the t2 vech to make rez bots ... keep pulling raid groups in as needed to defend ... Only build one Basilisk at a time and have the other t2 cons keep building static ... in a grid ... towards the enemy.

Then, mid-game: "I think it is better to trans a ground vech or bot con than using an air con."

**Changes.**
- **Opening.** The builder puts up a Castro first, then the lab. The crew list starts with the radar. The T2 cons start with the Shroud and the advanced radar (new roles `jammer_t1`, `jammer_t2`, `radar_t2`, `rez_bot`).
- **Edge route.** `edge_route.lua` builds a path round the map's border rectangle, choosing the direction that stays SAFE_D (3.5k) from the enemy's build power, else the farther one. The convoy flies it to a rally point on the route (2500 short), waits there up to 150 s for the whole wave, then flies in along the edge. The air con (fallback only) uses the same route.
- **Ground con in the convoy** (`GROUND_CON`).
  - A ground con borrowed from the spine (`CB.TakeAny`, a corcv) rides in the convoy as a 9th transport (the site's `carry`).
  - When it lands, it builds the jammer and the lab. The landed nanos help whatever frame it is building.
  - The air con is used only if no ground con can be borrowed or lifted, or if the ground con dies first.
  - The lab timeout only counts while the builder is at the spot.
  - Game 3 showed why: the air cons flew the 15k edge route alone; one died waiting, and the next was 5k out when the timeout ran out. No lab came in 3 tries.
- **Tzars.** The main walls never ask for or take Tzars (see the game 2 bug). Main-base Tzars come only from the raid groups' stop element (9 made in game 4). The proxy's T2 lab makes its own.
- **High builder priority** for the proxy's cons, its landed and built nanos, and its labs. The order is sent again a second later, because BAR's Builder Priority widget sets new builders LOW.
- **Rez bots.** A T1 bot lab follows the T2 lab and keeps 6 rez bots. Units the proxy labs make are remembered (`NET.proxyBorn`). rez_broker's `home` job (prio 75) keeps them at the proxy: wrecks within 1200, else a damaged building there, else waiting at the spot.
- **More groups as needed.** `PROXY_ARMY` checks the proxy's built cover. If it is short (margin < 1) for 15 s, one more raid group is taken (up to 4), and new units join until the proxy groups are worth 1.5x the threat (at least 6000). This repeats every 60 s, even after the groups were released.
- **One Basilisk at a time** (`parallel = 1`). The other T2 cons build Scorpions and Persecutors in a grid toward the enemy (rows across the axis, 130 apart, ±700 to the sides, up to 1300 out; 2 Scorpions : 1 Persecutor). The T1 cons do the same with Twin Guards and Thistles once their list is done. The grids keep clear of the Basilisk block.

**Game 4** (30 min vs CORE_v4_022f31f, single). **Won by game over**: the enemy commander was killed at 27:50 by our Dragons.
- Phi at 10:00 was 33.1k vs 25.1k.
- Proxy timeline (spot on the bottom edge, 4.0k from the enemy's build power):
  - beachhead 8:00 → GO 8:42;
  - the 9-transport convoy with the ground con flew in at 11:25;
  - Castro 11:43, lab 11:53;
  - T2 lab 15:05, bot lab ~14:30, Shroud and advanced radar by 17:00, 15 row nanos.
- **The lab stood from 11:53 to the end.** `PROXY: more` fired 4 times.
- **Basilisks.** First at 20:04, then one every 1–2 min; 6 standing at ~26:00. 54 target orders, all tier 2 (enemy nanos), 3 at labs. **No kill confirmed:** every target ended "probably dead" after ~4 shots. Nanos may leave no wreck, and ghosts have no radar dot. The team's live `unitsKilled` rose by 318 while they fired.
- The forward static grid took losses (19 Scorpions lost by 26:00).

## Round 4: the ramp, the landing, the cap mode (user, 2026-11-08 / 09)

### Proxy ramp (`proxy/crew.lua`, `proxy/static_group.lua`, `proxy/lrpc_block.lua`, `proxy/t3_block.lua`)
Ground cons only: no air cons at the proxy and no air-con fallback; the landing borrow is retried. Every con has a ROLE.

**Core.** Castro, radar, nanos, Twin Guards, Thistles, the T2 lab, the bot lab (6 rez bots), a T1 air lab once a Basilisk stands (a Finch every 30 s), T1 static grids, and grid nanos (1 per 4 grid defences).

**Static build groups** (3 T2 + 8 T1 cons, up to 4 groups):
- The first T2 con of a group places the item and the other 10 guard it.
- The items, in order:
  1. Shroud;
  2. T2 radar;
  3. a T2 radar next to any Persecutor / Bulwark with no radar within 2100;
  4. AA (Birdshot : Screamer 2 : 1, one per 5 ground defences);
  5. 10 Scorpions, then Persecutor : Bulwark 1 : 1.
- They go on a grid toward the enemy.
- A new group comes when every group is full and building and metal is not stalled.

**Guns** (one gun con, one at a time):
- Basilisks go round the T3 blocks' nanos, on the 3 sides that are not the lab's exit.
- After 15 Basilisks and 20:00: Calamity blocks.
  - Two 8×8 nano squares on one diagonal and two 3×3 Calamity squares on the other (the user's picture), all on the 16-elmo build grid.
  - A block centre off the grid made nanos snap onto each other (42 of 96 failed in eco_sim).

**T3 labs:** up to 3, each from the user's blueprint (`blueprints/general/t3_lab.lua`: 96 nanos, exit +x, turned toward the enemy). They make Behemoths; the unit side (`[JUGG]`) MOVEs each one on the enemy's build power.

**Labs:**
- T1 lab: Pounders while the proxy walls are short (`mb.defence.proxy.wallShort`), but 1 con per 2 Pounders while the roles want cons.
- T2 lab: T2 cons for the roles, then Tzars.
- When the block / T3 nano crews are short, they take T1 cons from the groups.

**Priority:** every 2nd proxy nano is HIGH ("it starved the bots whole eco"); the nanos are otherwise not ordered (BAR's own nano behaviour). Cons and labs are HIGH.

**Guns:** Basilisks and Calamities are set to fire at will. The proxy scouts fly to the spots the guns fire at (`lrpc_fire.TargetPoints`, the next one every 20 s), else orbit the enemy's build power.

**The lab's spot:** the chosen spot, else rings out to 480. A spot where the order is at the head of the con's queue but makes no frame for 20 s is given up. The proxy's centre moves to the lab.

### Landing, synced (user: "too slow and telegraphed")
- The proxy groups wait at a STAGE 2500 short of the spot on the edge route (with the convoy).
- GO comes when they are there AND the convoy is loaded at its rally point (BEACH_WAIT_S 240 at most).
- Then the groups move onto the spot and every transport lands at once: no gathering, no route wait.
- The convoy carries a ground con; the transports fly home round the edge after unloading.
- The groups' line stands 300 past the static's front edge (2200 at most).

### Cap mode (`cap_mode.lua`, macro_runtime `CAP_MODE`; unit_runtime `NET.CapStep`; lab_rules whitelist)
- **On at 90% of the cap** (off below 85%), keeping 200 slots free for Dragons and the proxy.
- **T1 eco:** mexes and winds are reclaimed by a nano in reach, else self-destructed. The nano block stops recovering and releases nanos past T1.
- **Labs:** only Dragons, air scouts, Condors, Demons, Behemoths and cons; queues are purged.
- **Army:**
  - Fighters, Wasps, Shurikens and T1 army are self-destructed (the proxy's own excepted).
  - Everything else attacks: 8 groups from 600 value, no hold-home / AA gate, no home guards.
- **The nano block's eco budget** `NC_UNIT_FRAC` is 0.55 in CORE_v4 (was 0.7 = 2100 of 3000).

### Spine (CORE_v4)
No T2 bot lab and no T2 bot block con; the T3 lab is an `AIR_LABS` lab (a T2 air con places it). The user: "The bot lab that makes cons for the spine got blocked."

### Games (30 min vs CORE_v4_022f31f, single)
**All won by game over.**

| Game | Killer of the enemy commander | Notes |
|---|---|---|
| Game 8 | a Basilisk, 25:07 | |
| Game 9 | Dragons | The ramp stalled: Pounders only, so no block nanos. Fixed. |
| Game 10 | Dragons | The landing failed: a thin guard at GO. |
| Game 11 (synced landing) | a proxy **Behemoth**, 24:21 | GO 10:47, lab 11:29; 128 block nanos, 15 Basilisks, 2 T3 labs |

- **Kill confirmation fired** for the first time in game 9: "dot gone" 4, probably dead 2.
- **The Condor scout waves never showed in a real game** (`SCOUTS` = 0 now); the proxy's air lab scouts replace them.

## Not done / next
- **Kill confirmation by wreck is unproven.** A test needs a target that leaves a wreck (a fusion or a lab), or the replay checked for features at the shot spots.
- The forward static grid loses many Scorpions; maybe start it closer, or behind the walls.
- The Basilisk block holds ~11 guns; a second block for more.
- T2 cons come slowly (the T2 lab builds them alone at first): the first sim Basilisk lands at ~17:30.
- Spare main-base Tzars could be flown to the proxy's walls (air_lift already lifts Tzars).
- The proxy's own statics are the only static defence; the main base's construction squad is still a stub.
- `[LRPC]` targeting and kill confirmation have not fired in a real game yet.

## Round 5 (2026-11-09, eco_sim only)
- **Labs in a row.** In game 12 the bot lab blocked the T2 lab's exit, so no Tzars came out and no new T2 cons were made. Now the T2 vehicle, bot and air labs stand in a row beside the T1 lab, across its exit (same facing, `LAB_GAP` 240). No building may stand in any proxy lab's exit lane (`InExit` checks every lab, the T3 labs included).
- **T3 lab con fallback.** Block 2's T3 lab was never built. If no group has a spare T2 con, any T2 con with no item in a gun or group role becomes the T3 lab's builder.
- **eco_sim** (seed 1, 28 min, enemyBP patch): 0 Lua errors.
  - The labs went up side by side at 11648, z 6560 / 7040 (T1) / 7520 / 8240.
  - T3 lab 1 was up at 16:39 and T3 lab 2 at 22:39; block 3 was planned at 25:54.
  - 15 Basilisks, 192 of 196 T3 nanos.

## Round 6 (2026-11-09): hot spots, the perimeter group, Behemoth exits, 5 Scorpions
The user, with a picture of the proxy's static all on one side of the fight: "if it tries to place a building and it dies twice it should pull back a little bit and build perscuters insted of scorpians. It also needs to build static to cover the whole permiter ... it should slowlly create a group to build along the whole perimiter, make sure it would inclused the planed buildings, the extra t3 labs and calamites ... lower the threshold to 5 scorpians ... make sure there is a t2 lab sized hole for them to walk out of."
- **Hot spots** (`crew.lua` `Fail`, `HOT_*`, `PULL`). Front static attempts are counted as lost when their frame is killed, or when the group's con dies while on them, once per item. Two losses within `HOT_R` 300 make a hot spot, which lasts `HOT_S` 360 s:
  - No grid spot is used within 300 across the enemy axis of it, from `PULL` 300 behind it outward.
  - One Persecutor goes in 300 back toward the lab (static_group: right after the radars).
  - No Scorpions are built while any spot is hot.
  - Logged as `[PROXY] crew: HOT spot`.
- **Scorpions:** 5 before Persecutor / Bulwark (was 10).
- **Perimeter group** (role `gp`, `PERIM_T2` 2 + `PERIM_T1` 4). It starts once group 1 is full, or 4 min after group 1, or with group 2. Its ring:
  - It wraps everything the proxy has, except the front grid, plus the planned T3 blocks and Calamity blocks. The ring is a support-function envelope round discs, `PERIM_PAD` 300 out, with a slot every `PERIM_STEP` 380.
  - It builds the same mix as the front groups at the slot farthest from any defence of the same class (ground / AA).
  - Once every slot has one within 0.6 × step, it builds on the front grid instead.
  - Its items are flagged `perim` and do not count toward `CR.Front`.
- **Planned ahead** (`Replan`, every 2 min once T3 block 1 is placed). It reserves every T3 block still to come (up to `T3_MAX`) and `PLAN_BLOCKS` 2 Calamity blocks:
  - `Reserved` keeps other buildings out of them, the perimeter wraps them, and `T3Plan` / `AddBlock` use the planned spot when it is still clear.
  - `LB.Centre` now also tries farther out and farther back (eco_sim: a proxy by the map's east edge had no room for its first Calamity block, in round 5 as well).
- **Behemoth exit.** A T3 lab's lane, planned ones included, is `EXIT_LEN_T3` 3000 long and ±130 wide. Nothing is placed in it, and a Calamity block may not touch it.
  - A new T3 block prefers a spot whose lane is clear of what already stands out to 1400 (`T3_LANE_CHECK`); without one it is placed as before.
- **eco_sim** (seed 1, 28 min, enemyBP patch): 0 Lua errors.
  - T3 labs were up at 17:04 and 23:30; the third was placed at 26:42.
  - At 14:29 two T3 blocks and two Calamity blocks were planned ahead; Calamity block 1 was placed on its planned spot at 27:15.
  - The perimeter group started at 15:27; by 27:22 it had 7 standing on a 29-slot ring.
  - Income at 20:00 was 2425 m/s (round 5: 2203).
- **Game 13** (standard spawns, 30 min vs CORE_v4_022f31f): **won**, the enemy commander killed by a Dragon at 25:56. The proxy (lab 11648,6784, up 12:28) stood to the end, but it was contested hard:
  - Lost: 20 front static attempts, the T2 lab once (rebuilt, up 22:25), a T3 lab frame, 37 T3 nanos and 4 Basilisks. One T3 lab up, at 21:09.
  - Six hot spots fired; the pull-back Persecutors were placed.
  - **The perimeter failed.** The second planned Calamity block was 3300 from the lab, the ring reached out there, and the perimeter cons died on the way (one hot spot was at 8344,3941). 0 perimeter defences stood at 26:00.
  - Fixed: blocks are planned only within `PLAN_R` 2400 of the lab (the limit is inside the room test, so a nearer spot is taken). A perimeter slot is skipped while hot, and scores its gap − `PERIM_NEAR_W` 0.3 × its distance from the lab, so the near holes go first.
  - eco_sim after the fix: 3 T3 blocks planned near, at 14:29, and all built on their planned spots; T3 labs up at 17:14 and 23:07; Calamity block 1 at 26:41 (no near room left to plan it); perimeter 8 standing on 28 slots; 0 Lua errors.
- **Spawn variations** (30 min vs CORE_v4_022f31f; where the proxy went):

| Game | Spawns | Proxy spot | Result |
|---|---|---|---|
| 14 | close | 11648,9088 (east edge) | Won (Dragon, 24:58). The con was shot down 3 times before landing, so the lab went up only at 18:09. The T2 lab frame was killed 6 times on one spot and never stood. |
| 15 | swapped corners | 11648,6016 (east edge) | Won (Dragon, ~27:00). The proxy held: 2 T3 labs, 8 Basilisks, 2 hot spots. |
| 16 | left vs right | 11648,2688 (east edge, north) | Won (Dragon, ~28:08). The proxy held: T2 lab 15:19, 2 T3 labs, 10 Basilisks, 8 hot spots, 17 grid Twin Guards lost. |
| 17 | top vs bottom | 2432,11648 (south edge, west) | Won (Reaper, 20:20). No T2 lab yet, 2 hot spots. |

  Fixed after game 14: a lab frame killed twice on one spot gives that spot up (`labLost`), and the row's next spot is used.

## Round 7 (2026-11-09): static slots, more AA, the labs blueprint, 3 cons in the convoy
User: "add more aa in the static grid. I like the idea it works like the line with slots and you just fill the slots ... If cons are dying to air it should build more aa, it should also fill in a whole row before going to the next one. For the labs build you can just use the blue print I uploaded". Then, mid-change: "The con that builds the lab does not seem to move with the main convy. Also bring 3".
- **Slots.** The static grid is a fixed list of slots, computed once per proxy spot (`Slots`):
  - Rows run across the enemy axis, `GRID` 130 apart from `SLOT_F0` 300 out to 2400, each `GRID` wide out to `GRID_LAT` 900 on each side.
  - The order is a snake: odd rows left to right, even rows right to left.
  - Every grid kind takes the first free slot within its own reach (`f1`), so a row fills before the next starts and the cons walk along a row. This covers the T1 Twin Guards, Thistles and nanos and the T2 Scorpions, Persecutors, Bulwarks, Birdshots and Screamers.
  - A slot whose ground is blocked is looked at again after a minute. Hot spots, exit lanes, reserved blocks and the labs blueprint are skipped.
  - The crew summary logs `N slot rows full`.
- **AA.** One per `AA_EVERY` 3 ground defences (was 5). The crew counts losses to air (`CR.OnDestroyed` now gets the attacker's def). When air has killed `AIR_LOSSES` 2 of its cons or buildings within `AIR_WINDOW_S` 180, the rule is one AA per ground defence plus one.
- **Labs blueprint** (`blueprints/general/proxy_labs.lua`, the user's second, ring version):
  - The T2 vehicle lab, air lab and bot lab stand in a column with exits on +x and 14 nanos round them. The core list's nanos fill those 14 spots (`nano2` n = 14).
  - The block is turned to the T1 lab's facing, with the T1 lab at one end of the column, then slid along it until it clears what stands round the T1 lab (the convoy's ring of nanos), nearest first. Every blueprint nano reaches every blueprint lab (at most 347 apart; nano range is 400).
  - The air lab keeps its drawn orientation (air units need no exit). The blueprint is reserved from the first crew tick. With no room for it, the old row is used.
- **3 ground cons in the convoy** (`GROUND_CONS` 3, CORE_v4). In game 14 the one con was shot down at the rally point, and each replacement was borrowed after the convoy had gone and flew in alone (3 lost; lab at 18:09).
  - Now 3 are borrowed and all ride in the one wave; sink_lift waits up to `CARRY_WAIT_S` 90 for them once its nanos are ready (site `carryWant`).
  - The first con down places the jammer and the lab, and the others guard it. If it dies, the next landed con takes over. All of them join the crew when the lab stands.
- **eco_sim** (seed 1): 0 Lua errors. The convoy carried 11 transports (8 nanos + 3 cons), GO was at 12:01, all 3 cons landed at 12:46-47, and the lab was up at 12:57.
  - The blueprint went at 11560,7472, with the T1 lab at its air lab's end, facing west. The T2 lab was up at 15:12; T3 labs were placed at 16:07, 21:06 and 27:30.
  - Income at 20:00 was 3062 m/s.
- **Is the army pulled in given to area_defence? No.** The proxy groups stay click_army groups (state "proxy": clear the spot, then hold a MOVE line `PROXY_LINE_OUT` + the static's front out). area_defence's borrowed-army pool skips units in click_army groups (`CA.InGroup`). Its proxy area has its own walls (Pounders and Tzars from the proxy labs) and 1/3 of the air squad. Its margin does not count the proxy groups, so a short margin pulls in MORE groups (`ProxyMore`).
- **Game 18 vs DEFENCE_BOT** (standard spawns, 30 min, single): **won**, our Dragon killed its commander at 29:22. This is the first win over DEFENCE_BOT; before it was 0 won, 1 drawn, the rest lost.
  - DEFENCE_BOT out-earned us until 25:00 (8.3k vs 6.9k m/s), then its income fell to 4.5k and its army from 2.28M to 1.61M by 29:00.
  - The proxy went at 5504,11648 (south edge). It was weak:
    - The wave left with 1 of 3 cons (no free spine con 8:00-11:30), and that con died landing. The late ones flew alone and 3 died, so the lab went up only at 16:06.
    - Air killed cons (`air hot` from 17:50, so AA went up). The T2 lab was up at 20:58.
    - 1 T3 lab with 96 nanos, 5 Basilisks, 9 `[JUGG]` rows. LRPC: kills confirmed by wreck 2, dot gone 3, seen 1.
    - The labs blueprint was placed (T1 lab at its bot lab's end, facing north).
  - Fixed after it: the borrow may take a con off a nano block job (`allowBlock`). When still short, the proxy asks the labs for T1 vehicle cons (lab_orders `proxy:cons`, high tier). eco_sim: all 3 cons by 8:25 (two made on request), 11 transports, GO 11:13, all 3 landed, proxy lab 11:47 (earliest yet), T2 lab 13:59, T3 labs 16:30 and 22:41.

## Round 8 (2026-11-09): fighters and flak at the proxy
User, after game 18: "keep some figs closer to the proxy base. Have the figs with the convy stay around the base. You can just pull them from the main base. It does not need to keep them all. Keep figs at the proxy to defend and send more as needed, the aa helps but it can't be there at the start. You could also just have the t2 lab make flack if needed."
- **PROXY GUARD** (`air_wing.lua`, `PROXY_*`; unit_runtime passes `proxy = WG.ProxyBase`). It starts once the convoy is down (GO given and the con / lab there).
  - `PROXY_FIGHTERS` 6 wing fighters FIGHT round the proxy: 4 points `PROXY_ORBIT` 450 out, moving on every 10 s. The nearest are picked first, so the escort stays; the guard is sticky.
  - More come while enemy armed air is seen within `PROXY_AIR_R` 2500 of the proxy (`PROXY_AIR_MARGIN` 1.5 × its value, in fighters of the wing's average value). The guard doubles while the crew is losing to air (`WG.ProxyBase.airHot`). At most `PROXY_FIGHTERS_MAX` 20.
  - The rest of the wing hunts, strikes or waits as before. `[AW] PROXY GUARD` rows.
- **Flak trucks.** While the crew is losing to air (`AirHot`), the proxy T2 lab makes flak trucks (`aa_flak_truck`, up to `FLAK_TRUCKS` 6 standing) ahead of cons and Tzars. The unit side holds them in a ring 350 round the proxy (role `PROXY_AA`, RAID priority).
- eco_sim: the escort ended at 11:33 and its 6 fighters became the guard. 0 Lua errors.
- **Guard, revised** (user: "You need way more than 6 fighters. All the ones that came with the escort should stay. You want to keep them around the ring not circleling around"):
  - Every escort fighter stays; the escort is all the wing's fighters. The guard is at least `PROXY_FIGHTERS` 20, plus `PROXY_FIGHTERS` more while losing to air, and more for enemy air seen near the proxy. The cap is `PROXY_FIGHTERS_MAX` 60, or the escort's size if that is larger.
  - Each fighter holds its own fixed post, evenly round a ring `PROXY_ORBIT` 700 from the proxy, by uid order. It FIGHTs at its post: no circling.
  - eco_sim: the escort ended at 11:33 and all 25 of its fighters stayed.
- **Game 19 vs DEFENCE_BOT** (it ran the 6-fighter circling guard, before the revision): **won**, our Dragon killed its commander at 27:55.
  - The 3-con convoy worked: all 3 cons by 8:25, 11 transports, GO 11:44, all 3 landed (12:03-12:09), proxy lab 12:22 (game 18: 16:06).
  - The guard grew and shrank with the enemy air seen (6-20 fighters).
  - **The proxy never got a T2 lab.** The blueprint's T2 lab spot became unbuildable (a bad cell, or something built there) and `Spot` returned nothing, with no fallback. The crew sat on T1 static all game (40 Twin Guards, 32 front attempts lost, 6 hot spots).
  - Fixed: a blueprint lab spot that cannot be used falls back to the row beside the T1 lab (logged once a minute).
- **Keep the blueprint's ground clear** (user, during game 20: "The t2 lab did not get built since there were units in the way and twin gaurds were built in it spot. Make sure you keep the area for buildings clear"). Game 20 was stopped and rerun after these fixes:
  - `Reserved` checks `InBP` (1.5 × each lab's half-size, plus the nano spots), so every placement path keeps off the blueprint's unbuilt spots. That includes defense_crew's last-resort ring search, which had no blueprint check; that hole is the likely way Twin Guards got onto the T2 lab spot.
  - **The yard** (`ClearYard`, every 3 s): our ground units on a blueprint spot with no frame yet get a MOVE out of it, except that spot's builder. eco_sim: 38 moved at landing, then a few a minute.
  - `WG.ProxyBase.keepOut` lists the unbuilt lab spots. The proxy's flak-truck ring and the sink lift's top-up nanos (site `keepOut`) avoid them; the lift's nanos had stood on the air lab's spot.
  - **The grid.** The blueprint's origin is now snapped to the 16-elmo build grid. The T1 lab is 0 mod 16 and the column 8 mod 16, so the whole block had sat 8 off the grid; each piece snapped its own way and the blueprint's own nanos took the air lab's ground.
  - eco_sim: the T2 lab (13:31), bot lab and air lab (19:30) all stood on their blueprint spots. 0 Lua errors.
- **Game 20 vs DEFENCE_BOT** (rerun after the yard fixes): **won**, our Dragon killed its commander at 29:43, the third win in a row over DEFENCE_BOT.
  - GO 11:11, all 3 cons landed, and all 32 escort fighters stayed at the proxy. Proxy lab 11:53.
  - The T2 lab went up on its blueprint spot at 13:28. The bot lab's spot was blocked, so it took the row; the air lab stood.
  - By 29:00: 2 T3 labs, 12 Basilisks, 4 hot spots, only 12 front attempts lost.
  - **The guard wore down:** DEFENCE_BOT's air (3-6k value near the proxy) took it from 32 to 3-10, and nothing replaced the losses.
- Fixed after game 20:
  - **Guard replacements.** The guard asks the labs (lab_orders `proxy:fighters`, high tier, `fighter_t2` then `fighter_t1`) for its shortfall against its strength at landing, or what the enemy air there needs, whichever is more (`[AW] PROXY GUARD short` rows).
  - **The proxy groups' MOVE line** (click_army PROXY) is pushed out of `WG.ProxyBase.keepOut`. The line's Incisors stood on the blueprint's bot lab spot and walked back after every yard sweep. eco_sim: the bot lab went up on its spot at 12:50.
