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
