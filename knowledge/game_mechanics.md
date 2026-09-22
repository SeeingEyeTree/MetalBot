# Beyond All Reason — Game Mechanics Reference

This document exists so that an agent working on MetalBot understands *why* the code does what it does, not just *what* it does. It was compiled by interviewing Tree (the project owner) directly, plus his written notes (`Bar notes.pdf`). Treat it as ground truth over any prior assumptions about RTS games in general — BAR (and the Spring engine it runs on) has specific mechanics that don't match other RTS games.

**Scope note:** this bot currently targets one specific map — a flat, symmetric, full metal-plate map, 1v1 only, Cortex faction. Several sections below describe map-specific simplifications (no terrain, no naval, uniform mex value) that would not hold on a different map. Where that matters, it's called out.

---

## 1. Resources

There are exactly two *resources*: **Metal (M)** and **Energy (E)**. Build Power (BP) is not a resource — it's an attribute some units/buildings have (see §2).

- **Metal** comes from metal extractors (mexes) built on metal spots, plus reclaim (see §1.3).
- **Energy** comes from wind turbines and fusion reactors (on this map — solar exists too but is not the plan here). The target map has constant wind speed 25, so wind is reliably the most metal-efficient energy source; fusion has good BP-for-cost and energy-for-cost but is more expensive up front.
- You can convert energy → metal via metal makers, but it's less efficient than just building more mexes. Not a priority.

### 1.1 How spending actually works

Every unit/building has a **metal cost**, an **energy cost**, and a **build time**. The rate something is built at is `available BP × (cost / build_time)` per resource, capped by however much BP is actually assigned to it. Concretely, a unit with 100 build time, 100 metal cost, 1000 energy cost, being built with 10 BP, consumes metal at 10/s and energy at 100/s and finishes in 10 seconds. This means **BP determines the *rate* resources are consumed at**, not just build speed in the abstract — resource consumption and construction progress are the same thing.

### 1.2 Stalling

"Stalling" means you have more BP demanding a resource than you have income of that resource. When this happens:

- All active build jobs' resource draw is capped by combined income (plus whatever is in storage).
- **High-priority** jobs get first claim on whatever resource is available; only the leftover is spread evenly across all normal/low-priority jobs.
- Metal stalls and energy stalls behave identically — it's just "not enough of resource X for all the BP currently trying to spend it."
- Being in a *permanent, controlled* stall is actually the ideal state: it means every unit of resource produced is being used the instant it's produced, which is the most efficient possible use of eco. The problem is only *uncontrolled* stalling, where important things (units, key buildings) are starved because something less important got there first. That's what the priority system exists to prevent — see §7.

### 1.3 Storage

- Metal/energy beyond your current storage cap is **wasted** — it does not queue or overflow anywhere.
- Most economy buildings contribute a small amount of storage; dedicated storage buildings raise the cap more.
- Storage is a controlled buffer, not a goal — having some lets you spend in bursts (e.g. absorbing a large reclaim windfall), but resources sitting in storage aren't helping you win *right now* the way spent resources are.

### 1.4 Reclaim, resurrection, and healing

These matter a lot economically, more than a beginner would guess:

- A dead unit leaves a wreck worth roughly **~70% of its original metal cost**. Reclaiming wrecks near the front line can generate a large, sudden metal windfall.
- The hard part isn't getting the metal, it's **having enough BP and useful jobs to spend it on** immediately (see storage note above) — a big reclaim spike is only valuable if you can turn it into units/buildings right away.
- **Resurrecting** a dead unit is slower than reclaiming (it has to be rezzed, then healed), but it skips reinforcement travel time entirely, since the unit reappears near the front instead of walking there from the base. This is a meaningful advantage on a large map.
- **Healing** a damaged (not dead) unit costs *only time*, no resources. Always worth doing when possible.
- **Graverobbers** (reclaim/heal/rez unit) are considered a required unit type for a "fully functional" bot — not optional.
- There are no trees on this map, so tree-reclaim isn't a factor here (would matter on other maps).

### 1.5 The commander

- Produces roughly **2 M/s and 30 E/s**, and has about **300 BP** — this is what bootstraps the entire economy at game start.
- Only meaningfully important in the **opening** (first few minutes): building the first labs/nanos and getting initial mex/energy going.
- After the opening, the commander contributes little — the rest of the economy dwarfs it.
- The commander does **not** fight, does **not** get involved in tech progression (T2 labs come from cons, not the commander), and its only "combat" tools are D-gun and self-destruct, neither of which are part of the current plan.
- Losing the commander is **instant game loss** (see §8), so keeping it safe (cloak + stay near a jammer) matters far more than using it for anything active once the opening is done.

---

## 2. Build Power & Construction

### 2.1 What BP is

BP is an attribute of certain units/buildings ("builders"). It determines how fast they can push metal/energy into a construction job (see §1.1's formula). BP is not consumed or spent itself — spending it just means directing it at a job.

- **Nanos** (nanoturrets): stationary, but the best BP-per-cost ratio. Cannot move themselves, but can be picked up and airlifted by an air transport to a new location (literally moving the building, not a separate "mobile nano" unit type).
- **Mobile constructors ("cons")**: worse BP-per-cost ratio, but can walk to wherever they're needed. T1 mobile con BP is roughly in the 60–95 range.
- Because a bot has effectively unlimited APM, using air transports to relocate nanos as their local jobs finish is a real, viable strategy — more efficient than only ever building new nanos or relying purely on mobile cons.

### 2.2 Assist stacking

Multiple builders (any mix of nanos, cons, or a factory's own BP) assisting the **same job** simply **sum their BP linearly**. Two 50-BP nanos on one job = 100 BP on that job. There's no cap or diminishing returns on the number of assisters.

There is **no functional difference** between a builder that "owns" a job (placed it) versus one "assisting" it, once the job is placed — BP is BP. The one place ownership matters is **blueprint placement rules**: a T1 con cannot place a T2 building, and a T2 con cannot place a T1 building. Each builder type has its own placeable set. Once *any* legal builder has placed something, any other builder can assist it regardless of tier.

### 2.3 Cost-effectiveness reference (Cortex, ballpark)

| Unit | Metal | Energy | BP | Total cost (M + E×70) | BP per cost |
|---|---:|---:|---:|---:|---:|
| Nano turret (conturet) | 230 | 3200 | 200 | 276 | 0.725 |
| Con turret + 0.3× air transport | 252.2 | 3635 | 200 | 304 | 0.658 |
| Cor bot (mobile kbot con) | 120 | 1750 | 85 | 145 | 0.586 |
| Cor vec (mobile vehicle con) | 145 | 2100 | 95 | 175 | 0.543 |
| Cor air (mobile air con) | 115 | 2200 | 65 | 146 | 0.445 |

"Total cost" here uses the simplified conversion **metal + energy×70** to make M/E comparable in one number. The "+0.3× air transport" row approximates the real cost of a nano once you account for likely needing to relocate it at some point. Nanos are clearly the most BP-efficient, at the cost of needing transport logistics to reposition. Exact numbers for any unit can be pulled from the local Beyond-All-Reason-project repo (`C:\Users\malco\OneDrive\Documents\GitHub\Beyond-All-Reason-project\units`) if more precision is ever needed.

### 2.4 The mex-grid / blueprint system

To avoid needing full "what to build, who builds it, where exactly" decisions for every single mex, the bot uses a **pre-planned grid layout**: a square grid, currently 30×30 (240×240 elmos), that can be built by any air con from a shared pool into any open grid slot. This raises the abstraction level — the bot mostly just decides "build the next grid" at a high level rather than micromanaging individual buildings. Smaller (15×15) or larger (60×60) grids can be substituted using the same overall pattern. It's an intentional simplification, not a perfect model of optimal building placement.

**Nano relocation logic**: since nanos are stationary, the bot needs to decide when a nano's local grid has no more work (e.g. a T1 mex grid is fully built and has no planned T2 upgrade) and should be airlifted elsewhere. A reasonable heuristic: track idle time per nano, and/or flag a grid as "done, no future upgrades" once finished, to trigger relocation.

### 2.5 Factories and their own BP

Factories have their own internal BP for producing units, but need external BP support (assisting cons/nanos) to be effective. A single factory has a practical ceiling on how much assist BP it can usefully absorb:

- Units have to physically walk out of the factory before the next one starts; if only one factory is in range, some of that support BP goes idle waiting.
- BP also has a **ramp-up cost** when switching tasks — it doesn't jump straight to 100%, though this ramp is fast. This mostly matters for very cheap/low-BP-cost units and can be treated as a minor effect for now.
- **Rule of thumb**: don't provide more support BP to a lab than it would take to build its main unit type in ~2.5 seconds. E.g. if a lab's main unit costs 12,000 BP-equivalent, ~24 nanos worth of support is a reasonable target. This is approximate — a lab that builds multiple unit types with different BP costs is harder to size precisely, and it's generally safer to lean toward *more* BP than less.

### 2.6 Build range and line of sight

**Line of sight does not matter for building.** A builder can place or assist construction anywhere within its build range, including in fog of war. (Elevation-based sight-blocking exists in the engine but is irrelevant on this map, since it's flat.)

### 2.7 Issuing build orders from a widget

All three verified in headless test runs on 2026-09-20, each after it had already cost a
diagnostic match to find:

- **Build orders take the building's CENTRE**, and `UnitDef.xsize` / `zsize` count 8-elmo
  half-cells, so footprint elmos = `xsize * 8` (`corwin` xsize=6 = 48 elmos = 3 cells;
  `corlab` xsize=12 = 96 elmos). An odd-footprint building's centre therefore sits at
  `8 mod 16`, not on the 16-grid — placing it on the grid makes the engine snap it.
- **While a builder walks to the site, the engine pushes a MOVE (`CMD.MOVE` = 10) command
  in FRONT of the build order.** So `Spring.GetUnitCommands(uid, 1)` returns the move, not
  the build. Checking only `cmds[1]` reads as "the order was dropped" for the entire walk —
  scan the first few commands instead.
- **An abandoned nanoframe decays and dies**, taking the metal already spent on it with it.
  Anything that makes a builder walk away from a partly-built frame (a skip, a re-claim, a
  replaced order) must leave something else able to finish it, or that metal is simply lost.
- **Build alignment depends on footprint parity.** An even footprint (4x4 mex) centres on a
  multiple of 16; an odd one (3x3 wind) centres on a multiple of 16 **plus 8**. Snapping
  everything to a plain multiple of 16 puts odd-footprint buildings half a cell out, which
  overlaps a neighbour and leaves holes in a grid. `Spring.Pos2BuildPos(defID, x, y, z)` is
  the engine's own answer and should be preferred to any arithmetic.
- **A factory's auto-guard order on a new unit arrives AFTER `UnitFinished`.** A single
  `CMD_STOP` in that callback is overwritten, and the unit sits assisting the factory
  forever, permanently "busy". Stop it again on a short delay and/or in `UnitFromFactory`.
- **Lua 5.1 allows a function at most 60 UPVALUES**, and every file-level local a
  function mentions is one of them. A widget that crosses the line does not error at
  runtime — it silently fails to load, with only a line in `infolog.txt`:
  `Failed to load: x.lua (...: function at line N has more than 60 upvalues)`. A big
  `GameFrame` that touches most of the file's state hits this eventually; the fix is to
  split it into per-concern functions, since each one then gets its own budget. (The
  separate 200-*locals*-per-chunk limit is a different ceiling and is rarely the one hit
  first.) Note `luac`/Lua 5.4+ allow 255 upvalues, so a syntax check on a newer Lua will
  NOT catch this.
- **The engine only writes a replay's footer on a clean shutdown.** A match killed by a
  wall-clock deadline leaves a 0-byte `.sdfz` that no parser can read, and
  `replay_analysis.py` reports `Duration: 0s`. End matches by a *game frame* trigger (both
  sides self-destruct their commander symmetrically) and give the process time to quit.
  Note `os.clock()` in a widget is CPU time, not wall time, so clock-based deadlines drift
  per process and are not symmetric. This also happens on an ABRUPTLY-CLOSED local client
  session (not just a headless wall-clock kill): the file need not be near-empty — one
  observed case was 826 KB with a genuine ~5 MB packet stream inside — but
  `durationMs`/`numPlayers`/`numTeams`/`teamStatSize` in the footer are all zero, so
  `replay_analysis.py` has nothing to read even though the game was real. Only a proper
  end-of-game/quit flow writes usable stats; there is currently no fallback that
  reconstructs them from the raw packet stream.
- **`Spring.GetUnitCommands()` can lag well behind an order that has actually landed, and
  the lag is asymmetric between the match HOST and a connecting CLIENT.** In
  `bot_testing.py`, team 0 runs as the host and team 1 connects as a player; querying a
  just-issued order's presence in `Spring.GetUnitCommands()` is near-instant for the host's
  own units but can take several real seconds on the client side. `blueprint_placer.lua`
  polls this to confirm a build order landed before trusting it (`ORDER_GRACE_FRAMES`,
  historically 30 frames / 1s, tuned against host-side behaviour); on the client side the
  order had genuinely landed — the building completed moments later regardless — but the
  query still read empty at the 30-frame check, so the code judged it dropped and
  re-tasked the builder onto a different item, abandoning a real, in-progress structure.
  Measured on one match: team 0 (host) 0 skips in 4 minutes, team 1 (client) 26, same code,
  same conditions. Fixed by raising the grace period (90 frames) and, more importantly, by
  never depending on a single poll being timely at all: every distributed builder is now
  given a second, shift-queued order the moment the first is issued, refilled every time
  the active order changes — so a slow confirmation matters far less, since the builder
  always has real engine-side work queued regardless of what the query currently shows.
  Post-fix: 2 skips instead of 26. See `knowledge/lessons_learned.md` "Client-side order
  latency" for the full trace. This is a harness/engine-interaction fact, not specific to
  any one bot, and headless-localhost latency may understate what a real (non-localhost)
  multiplayer match would show.

---

## 3. Unit Cap

The game enforces a per-player unit cap (a CPU/performance safeguard, default ~2000, likely to be raised to ~5000 for this project). **Everything counts toward it** — mexes, wind turbines, army units, nanos, all of it. At the cap, labs stop starting new units and builders can't place new blueprints. Not expected to be a major issue in practice, but worth the bot being aware it exists.

There is, as far as known, **no separate build-queue length limit**.

---

## 4. Tech Progression

- **T1 → T2 → T3**, all tiers are in scope for this project (not just T1/T2).
- Progression: the commander builds a T1 lab. T1 cons (produced from that lab, or built by the commander) can build more T1 buildings, **and** can build a T2 lab of the *same type* (a T1 bot lab → T2 bot lab, a T1 air lab → T2 air lab, etc.).
- A T2 con (from a T2 lab) can build a **T3 lab**. Any T2 con of any lab-type can do this — it's not restricted to matching types the way T1→T2 is.
- The commander is **not involved** in unlocking T2 or beyond — that's entirely a T1-con job.
- A T2 lab simply unlocks the ability to produce T2 units and T2 cons; it doesn't otherwise change the model.

---

## 5. Faction & Lab Types

- The bot is currently **Cortex-only** ("cor" unit prefixes: corvec, corbot, corair, etc.) for simplicity. New logic should be written with half an eye toward cross-faction compatibility (the two factions largely have units filling equivalent roles), but faction-agnosticism is **not a current priority**.
- Relevant lab types on this map: **bot lab (kbot)**, **vehicle lab**, and **air lab**.
- **Never build a hover lab.** Naval and amphibious labs are irrelevant on this map (no water).
- Air is considered genuinely valuable here, not just a side option — the map is large, so fast units matter a lot. Notable air units: **Shuriken** (strong anti-raid / light-AA-countered unit), **T2 gunships** (very strong if left uncontested), and **air transports** for both troop movement and nano relocation (§2.4).

---

## 6. Map & Positioning

The bot's current target map:

- **Symmetric**, spawns anywhere along a strip on each side. Supports arbitrary team counts/sizes in general, but **this project only targets 1v1**.
- **"Full metal plate"**: mexes can be built anywhere, and every mex spot is worth exactly the same regardless of location — there is no "richer" or "poorer" territory.
- **Perfectly flat**: no elevation, no chokepoints, no ramps, no geometric features of any kind. Terrain-based tactics (high ground, bottlenecks) are not a factor on this map.
- **No fixed front line.** Since there's no geography to anchor on, the front line is wherever the two armies happen to currently be — purely dynamic, shifting as either side pushes or retreats.

### 6.1 Proxy bases

A proxy base is a forward concentration of **BP and labs** (to produce units/defenses closer to the fighting), sitting somewhat behind the front line — **not** a forward economic expansion. Building mexes/eco at a proxy base is a mistake: it's more exposed, and more importantly it means BP there is producing economy instead of units, which defeats the purpose of having pushed BP forward in the first place. If a proxy base is lost and there isn't much BP elsewhere, the bot may not be able to field enough army to defend even with unlimited resources — so proxy bases need real defenses around them.

### 6.2 Scouting

Since the map layout itself is static and known in advance, scouting isn't about discovering terrain — it's purely about **finding the enemy and tracking their army/production state**, mainly via fast air scouts. Radar coverage matters for map awareness in general, though the bot's exact ability to exploit radar/scouting info well is still an open question in practice.

---

## 7. Army Composition & Roles

Ideal role breakdown for army composition (not all currently implemented, but the target shape):

| Role | Purpose |
|---|---|
| **Raiders** | Fast units probing for weakly-defended points; harass economy, force a response. Not meant to punch through a real defense. |
| **Main army** | The core force, generally always trying to engage/fight rather than sit idle. |
| **Draw-fire / spam ("Grunt")** | Cheap, disposable units mixed directly into the main army so they soak hits that would otherwise land on more valuable units. `Grunt` is the specific unit for this role currently. |
| **AA** | Necessary baseline defense against air — see §7.3. |
| **Utility (mobile radar / mobile jammer / anti-nuke)** | Cheap, fragile, high-value-when-alive support units. Once T2 is available, worth having as a standing role. |
| **Combat engineers** | Mobile cons that build defenses/BP closer to the front. Travel a bit **behind** the main army/front line (they're fragile and shouldn't be building or healing directly in the line of fire). |
| **Rez bots (Graverobbers)** | Battlefield reclaim/heal/resurrect — see §1.4. Considered mandatory for a complete bot. |
| **Anti-raid** | Fast units held back specifically to intercept raids before they reach the base — Shuriken called out as a good fit for a while. |

Artillery is explicitly **not favored** on this flat, cover-less map — could theoretically work with good play, but isn't part of the intended composition.

### 7.1 Raid response

Raids are generally visible with plenty of warning time, since a raiding force has to travel a real distance to reach anything. The correct response is to **send local/reserve reinforcements to intercept**, not to pull units from the main army — pulled units are slower than the raiders and will lose ground for nothing, since they can't catch a faster unit that's already retreating anyway. Redirecting BP to build defenses in the raider's path is also a good response. **Do not chase a faster, retreating raiding unit** — it cannot be caught.

### 7.2 Micro priorities

Micro is explicitly **not the current priority** — correct unit composition and positioning gets most of the value on their own. The one micro behavior considered a hard requirement: **retreat low-HP units that are part of the main army** to heal. Raid units, by contrast, should **not** retreat — they're expendable/committed once sent.

### 7.3 AA posture

Needs a standing **baseline** at all times (getting caught with zero AA against a bomber run is just an instant loss), scaling up **reactively** once the enemy is seen investing in air. The right baseline/reactive balance is something to tune empirically through actual test games rather than derive analytically.

### 7.4 Combat model notes

- Combat is mostly HP vs. DPS, range, and speed, with one exception the author has confirmed: **some units do different damage to air targets** (anti-air weapons carry their own air damage). So a unit can be strong or weak against air independent of its ground stats. The exact rules are not verified against the unit definitions.
- **Flanking damage** is real: a unit hit from multiple directions in quick succession takes multiplied damage (roughly up to ~2×, exact values unconfirmed). Not a current priority to model explicitly, but worth knowing it exists.
- Terrain does not affect combat on this map (see §6).

### 7.5 Threats and mechanics the bots do not yet handle

Confirmed by the author (2026-09-21). None of these has a detector or counter in any bot yet; the
stats tracker records what it can (see `metalbot_stats_tracker.lua`).

- **Nukes and anti-nukes.** Nuclear silos are a real late-game threat, and a bot banking tens of
  thousands of metal with a clustered production base is a natural target. The counter is an anti-nuke
  covering the production cluster. Tracked: own `antinuke`, `silo`, `fac_antinuke_cover`; enemy
  `first_enemy_nuke` / `first_enemy_antinuke` / `vis_nuke`.
- **Long-range plasma cannons (LRPCs) and the "lol cannon".** Static long-range guns (LRPC-class and
  the very-long-range "lol cannon") can hit a base from outside its defences and are especially
  dangerous to a bot with a low unit count. Tracked as a static ground-attack weapon of very long range
  (`lrpc`, `first_enemy_lrpc`, `vis_lrpc`). Classification is from weapon data and is unverified: check
  the `[TRK] def` lines.
- **Cloaked / stealth units (spy bots, skuttles).** They cannot be detected without counter-intrusion
  equipment. How realistic it is to build detection across a large front is an open question, so this is
  a **note only**: it is *not* tracked and *not* modelled. A bot that loses units to something it never
  saw may be losing them to this.
- **Air has no repair pads or air bases** (they were removed from the game). **Bombers are one-way**:
  they should never retreat to heal, and their attrition is not itself a weakness. Do not flag it.
- **Radar blips can be partly identified by speed.** A radar-only contact has no unit type, but if it
  moves its speed can be measured, and every unit type has a known speed. Several types share a speed,
  so the honest answer is a list ("either/or") until the unit is seen. The tracker does this
  (`first_radar_moving`, `blip_*`, and `WG.StatsTracker.DecodeSpeed(speed)` for a bot to call).
- **Piecemeal engagement and AA coverage** are measured, not just assumed: `pm_*` (were our units
  alone when they died?), `groups` / `main_share` (is the army in one group?), `fac_aa_cover` /
  `fac_aa_ded_cover` (do the factories have air cover?), and the `cmdr` row (is the commander alone?).

Hypotheses not yet confirmed by the author (treat as ideas, not facts): nano turrets healing units in
range could serve as a free repair network; wrecks near the base are free metal (`wreck_metal`); and
the unit cap may crowd out the army when most of it is economy structures (compare `units_total`
against `unit_cap` and the per-role counts).

---

## 8. Advanced / Optional Tactics (not current priorities)

These are noted for completeness — interesting, but explicitly **not** things the first working version of the bot needs to reason about. Revisit later if there's bandwidth.

- **Skuttles**: ~755 M / 27k E, can kill ~5k metal worth of units if they land a hit well-microed. Explode on death (bigger explosion if self-destructed rather than killed), damaging everything nearby. Countered by range + radar; a radar jammer (ground-based or carried by an air transport) can mask the skuttle's radar signature, at which point only active counter-intrusion detection would catch it. Only worth attempting with a solid understanding of how the underlying systems interact.
- **Spy bots**: invisible unless an enemy unit is nearby; self-destruct applies EMP to **all** units around them, friend or foe. Die normally if killed outright (no special death effect).

---

## 9. Endgame & Win Conditions

- Bots **do not resign**. The only way a game ends is killing the enemy commander (or hitting the test harness's `--duration` time limit).
- If the bot has effectively already won (dominant economically/militarily) but the enemy commander isn't near the fighting, the bot can get **stuck in a won game** indefinitely unless it actively hunts the commander down.
- Intended behavior once "we've won" is detected: **scout the map, then send bombers to kill the commander.**
- **Open problem:** there is currently no implemented heuristic for *detecting* "we've won" (e.g. enemy has had no visible production/units for some time). This needs design work.

---

## 10. Known Bot Issues (context for anyone working on this codebase)

- **Early scaling is the main known weakness.** In test games, even with zero enemy interaction in the first 3–5 minutes, the bot ends up noticeably behind in economy relative to good play. Two known contributing factors: energy grids currently aren't being built correctly, and the general opening isn't scaling as aggressively as it should be.
- **Priority system is only partially implemented.** The intended design (§1.2): when there's a stall, nanos/builders working on jobs that would relieve that specific stall (e.g. wind/fusion jobs during an energy stall) should be bumped to high priority. Interrupts currently exist but don't actually elevate priority the way they should — this is a known gap.
- **Defense interrupt is crude.** Current behavior: when enemy units are detected near a grid, the bot builds defenses there; once the enemy leaves, it reclaims those defenses to continue normal construction. Described by Tree as "not well thought out" — a candidate for improvement, not a finished system.
- **"Non-commander units built" (the current headline metric in `bot_testing.py`) is not actually a good measure of bot quality.** Better signals to track: metal wasted over the storage cap, time spent stalled, and eventually actual win/loss via commander kill. The intent is to keep **adding** more tracked metrics over time from replays rather than relying on one number — more visibility into what's actually happening in a game is always valuable when deciding whether a change helped.

---

## 11. Replay-Derived Evidence

This section gets updated as replays are analyzed with `replay_analysis.py` (see repo root; results accumulate in `knowledge/replay_history.jsonl`). Unlike the rest of this document, these are measured facts from actual games, not descriptions of mechanics.

### 2026-09-03: IamTree (bot, Cortex) vs. ajBunker (human, Armada) — bot lost

Source: `2026-09-03_03-11-26-935_Full Metal Plate 1.7_2026.07.04.sdfz`. Extracted from the replay's own recorded team-statistics history (sampled every 15s), not a re-simulation.

**The eco gap opens immediately, well before any combat, and keeps widening.** Both sides' metal income rates were within 20% of each other for the first ~90 seconds. From roughly t=100s onward, the bot's metal-income growth rate falls steadily behind the human's — by t=450s (7:30), with **zero combat having happened yet**, the human had produced 29,718 cumulative metal to the bot's 13,726 (2.16×), and the human's instantaneous metal income rate was already ~2.5× the bot's. This directly confirms the "early scaling" problem noted in §10 — it isn't a one-time hiccup, it's a continuous divergence starting almost from the opening.

**The bot substantially over-invests in energy relative to metal, consistently, all game.** The bot's metal:energy production ratio stayed in the 0.055–0.073 range for the entire game; the human's stayed in 0.085–0.097 — the human consistently produced proportionally *more* metal per unit of energy at every single checkpoint. Correspondingly, the bot wasted (energyExcess) 10–28% of its energy production between roughly t=180s and t=450s (peaking at 28% around t=225s / 3:45), while the human's waste stayed under ~6% for the same stretch. This is concrete, quantified support for the "bot doesn't build energy grids correctly" note in §10 — the fix isn't about energy production being too low, it's that the bot is building more energy than its metal/mex expansion and BP can ever use, at the direct expense of mex expansion.

**First combat contact was at t=465s (7:45)**, at which point the bot already had less than half the human's cumulative economy — the battle's outcome was arguably already decided by the eco gap. The decisive engagement happened in a ~30-second window from t≈495s to t≈525s: the bot's cumulative units-lost jumped from 18 to 188 in that single window (170 units lost in 30 seconds), while the human's kills jumped from 3 to 122. By game end the bot had dealt 10,868 damage while receiving 84,136 (a 0.13 dealt:received ratio); the human dealt 68,520 while receiving 29,612 (2.31 ratio). Final kill counts: bot killed 14 units total, lost 216; human killed 129, lost 41.

**The bot never recovered after that engagement.** Its metal income rate collapsed to near-zero (2–9 M/s, down from a peak of ~103 M/s) for the rest of the game, while the human's stayed above 200 M/s and kept climbing. Units-produced and damage numbers for the bot are essentially flat from t=540s to the end. This suggests the loss wasn't just "lost a fight" — the bot's economy itself got crippled in the same engagement (consistent with §6.1's warning about not concentrating BP/eco somewhere exposed), and there's no visible recovery/regroup behavior afterward. Worth checking directly: was BP/mex overly concentrated near wherever this fight happened, and is there any bot logic at all for rebuilding economy after a bad engagement rather than just continuing to feed units into a losing position?

**Takeaway for prioritization:** the data points at the opening/early-macro allocation logic (specifically the metal-vs-energy build balance in `macro_controller.lua`) as the highest-leverage fix, ahead of combat micro or unit composition — the game was arguably already lost on economy alone by the time the armies met, independent of how the fight itself was fought.

## Glossary

- **Elmo**: the base engine distance unit (Spring engine). Grid cells in this project are 240×240 elmos (a 30×30 grid).
- **BP**: Build Power — the rate-of-construction attribute of builders/factories.
- **Mex**: metal extractor, the building that produces metal from a metal spot.
- **Nano / nanoturret**: stationary builder, best BP-per-cost, must be airlifted to relocate.
- **Con / constructor**: mobile builder (bot/vehicle/air variants), worse BP-per-cost but can walk.
- **Stall**: BP demand for a resource exceeds current income of that resource.
- **Reclaim**: recovering metal value from a wreck (or a live unit/feature, though not relevant on this map).
- **Rez / resurrect**: reviving a dead unit from its wreck (via a Graverobber-type unit), skipping travel time to the front.
- **Grid / mex grid / blueprint grid**: the pre-planned 30×30-elmo layout pattern used to simplify expansion decisions.
- **Proxy base**: a forward concentration of BP/labs near the front line, deliberately without eco.
- **kbot**: a "K-Bot" — the legged/bot-type unit chassis, as opposed to vehicle (wheeled/tracked) or air units.
- **D-gun**: the commander's special short-range high-damage weapon (not currently used in this bot's plan).
