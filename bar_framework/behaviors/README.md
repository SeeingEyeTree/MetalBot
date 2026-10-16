# Behaviours (plug-and-play unit control)

The unit-control counterpart of `blueprint_placer`: a behaviour is a table in this folder, `behavior_host.lua` runs it,
`strategy.lua` decides which unit gets which behaviour and how much to spend. Tests: `tests/test_behavior_host.lua`,
`tests/test_strategy.lua` (`python tests/run_lua.py <file>`).

## Using one

```lua
local BH = VFS.Include("LuaUI/Widgets/bar_framework/behavior_host.lua")
local host = BH.New{ give = optionalOrderSink }         -- default: Spring.GiveOrderToUnit
host:Assign(uid, "kite", { step = 400 })                -- one behaviour, tunables overridden for this unit
host:Assign(uid, { "kite", "advance" }, { kite = { step = 150 } })   -- stack: first one that claims the unit wins
-- every ~10 frames:
host:Update(frame, ctx)    -- ctx = { EnemiesNear = fn, TargetsNear = fn, Axis = fn, Clamp = fn, Speed = fn }
```

Or let the stance do it: a unit in `stances/<name>.lua` (or typed into the editor's behaviour boxes) carries
`behaviors = {"kite"}` and `cfg = {kite = {step = 400}}`; `strat:Assign(host, uid, defID)` attaches them.

## Writing one

```lua
return { name = "mine", cfg = { radius = 600 },          -- every tunable here, overridable per assignment
  Init = function(st) st.n = 0 end,                      -- per-cohort state
  Update = function(st, group, ctx, frame, host)         -- group = {cfg, list={{uid,x,z,v,def,hp}}, cx, cz, value}
      host:Order(frame, uid, CMD, x, z)                  -- de-duplicated; host:Translate keeps formation
      return true | nil | { [uid] = true }               -- claimed (acted) / not acted / acted for these
  end,
  Describe = function(cfg) return "text" end }
```

Units with the same behaviour and identical overrides form one cohort and move together; different overrides are a
separate cohort, so one file serves Lashers (step 400) and Pounders (step 150).

## Available

| Behaviour | What it does | ctx it needs |
|---|---|---|
| `kite` | back off from ANY approaching enemy, threat-weighted (replaces slow_front's fast-only Chargers rule) | `EnemiesNear` (`{uid,x,z,range,value,mobile,vx,vz}`), optional `Axis`, `Clamp`, `Speed` |
| `stun_target` | spread a pack over nearby targets; `stuns=true` Shurikens, `stuns=false` Wasps (extracted from `AssignStuns`) | `TargetsNear` (`{id,x,z,hp,mhp,para,value}`) |

| `range_kite` | per unit: keep the nearest armed mobile enemy at the edge of OUR range (step back when it is inside 85%, to 95%); not against an enemy that outranges us, not while `ctx.Defending(uid)` (raid response / home guard: move in front). RAID_BOT's Demons and Banishers | `EnemiesNear`; optional `Range`, `Defending`, `Clamp`, `Speed` |
| `intercept` | raid response: responders MOVE to a point AHEAD of the raiders on their path to the asset it threatens (re-aimed every tick, spread across the path); can't catch them -> block between raiders and asset; raiders stopped -> FIGHT | `ClusterOf(uid)`, `Assets()`; optional `Order`, `Speed`, `Clamp` |
| `shadow` | per unit: a fast unit tails the nearest armed enemy at ~92% of its own sight radius (backs off when closer, closes in when farther), chases the last seen spot, else rides 700 elmos ahead of the friendly army; hurt -> back to the army; `max` = how many of the cohort shadow. `stances/shadow_test.lua` (`/give corgator 20`) | `EnemiesNear`; optional `Sight`, `Friends`, `Axis`, `Clamp` |

STANCE_BOT's raid response (user 2026-10-12): `unit_controller.DispatchResponses` assigns fast responders to `intercept`
(slow ones keep FIGHT), publishes `mb.raid` / `mb.airLosses`; `lab_controller` then queues only Shurikens (fighters if the raid is
air or our air units are dying to fighters) in the T1 air lab and swaps slow picks for fast ones until 2x the raid's value is ordered;
`click_army` `SET_TARGET = true` keeps attack groups MOVEing past the target and gives each unit SET_TARGET on the best building in
its weapon range. Tests: `tests/test_intercept.lua`, `tests/test_set_target.lua`.

### Dragon behaviours (DRAGON_ECO; assigned through the stance's `extras`, run by the unit controller's host)
| Behaviour | What it does | ctx it needs |
|---|---|---|
| `dragon_raid` | first in the stack. Once `wave` (50) Dragons are not in a wave they launch together; the wave's target is the enemy commander, else build power, else anti-air, else the closest eco (else the nearest structure, else the base), re-picked every `retarget` frames and at once when the target dies; MOVE until within `arrive`, then ATTACK the unit in view (FIGHT its place otherwise); a wave under `min_left` goes back to waiting | `EnemyBase`, `EnemyRecords`, `EnemyCommander` |
| `dragon_defend` | the Dragons waiting for a wave FIGHT intruder groups inside the perimeter (the nearest, `mult` x their value), then gather at the Dragon lab | `Intruders`, `Gather` |

### Army behaviours (a stack run by `click_army.lua` in DIRECT mode)

The whole ground army is ONE cohort running a stack, first claim wins (`ARMY_BEHAVIORS` in the bot's `unit_controller.lua`;
tunables in `ARMY_BEHAVIOR_CFG = { flank = { every = 4 } }`; delete a name to switch it off). They share one table,
`ctx.shared`, that `pick_target` fills. Orders go through army_broker, so retreat / respond still outrank them.

| Behaviour | What it does |
|---|---|
| `pick_target` | 1-3 different shared targets (`count` = number or `function(sh, frame)`; default 1 under 20 units, 2 under 50, else 3), build power near an enemy lab ALWAYS first (`labBP`), held 1200 frames; publishes `shared.targets`, army size/value, enemy value; claims nothing |
| `commander_strike` | enemy commander in the open -> every unit goes for it |
| `flank` | every 6th unit circles 2600 elmos wide, then hits a second target |
| `spread` | no resistance -> every 2nd unit splits over the best targets |
| `run_by` | big army -> every 2nd unit MOVEs past the defence, FIGHTs near the target |
| `steer` | ported from click_army's LegPoint + FlankPoint: steers round enemy armed units (flank waypoint beside an enemy army on the path, 1000-elmo legs turned up to ~70 degrees); claims only when a detour is needed, before `attack_target` |
| `squad_retreat` | ported from click_army's UpdateSquads: a hurt squad (<= 6 units under 60% health with enemies near) retreats at RETREAT priority; first in the stack |
| `attack_target` | whatever is left FIGHTs to the shared targets, split 50/30/20 (70% on lab build power) (last in the stack) |

A new army behaviour reads `ctx.shared` (`targets target tx tz labBP n total cx cz enemyV`) and the ctx functions `Rank` (k different targets, lab build power first), `TopTargets`, `ThreatAt`,
`Commander`, `Clamp`, `Foe`, `Alive`, `Log` (built in `click_army.lua`, `NewArmyHost`).

### Bomber behaviours
`bomber_run` is assigned to bombers instead of the army stack: `CA.Init{ cfg = { BOMBER_BEHAVIORS = { "bomber_run" }, BOMBER_BEHAVIOR_CFG = {} } }`
(replaces click_army's built-in bomber run; empty list = the built-in). 8+ bombers strike together every 2700 frames, build power near an enemy lab first.
Tests: `python tests/run_lua.py tests/test_army_behaviors.lua`.

**What uses what:** `python behavior_usage.py` (scans the bots' `ARMY_BEHAVIORS` and the stances' `behaviors`).

Not yet moved onto the host: rez crew, Pounder screen, commander evade, scouts (still in `slow_front`, `commander_guard`,
`scout_lanes`). Each can be ported by wrapping its existing Update as a behaviour.
