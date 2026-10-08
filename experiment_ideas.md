# Experiment Ideas for Agents

Status: draft v1 (2026-10-08). Compiled from Tree's notes and answers. Base bot for all experiments: **LINE_CLICK** (the current main bot). Each idea is written as: idea, hypothesis, what to build, how to judge it, open questions.

**Judging all of these:** "non-commander units built" is a bad metric (see `game_mechanics.md` §10). Prefer win/loss, metal wasted over the storage cap, time stalled, and damage dealt to the enemy eco. Add more tracked metrics from replays as needed.

**Tuning rule for anything that spends on a new category:** the cost range is tuned, not fixed up front. Overspending is the failure mode to watch for (e.g. spent a lot on artillery and the enemy units just walked over it).

---

## 1. Nukes

**Idea.** Use nukes as a way to break the economy or the army, with targeting driven by scouting.

**Hypothesis.** A nuke always gets through unless the enemy has anti-nuke, so any opponent has to start building anti-nuke, which costs them. Nukes can be very effective.

**Targeting logic.**
- Scout for enemy anti-nuke first.
- No anti-nuke seen: nuke the **eco** (first priority).
- Anti-nuke present: nuke the **army blob** instead.
- Eco is the first target, army blobs are also good targets.

**To build.** Nuke target selection that reads scouting data, plus a check for anti-nuke presence. Needs the scouting system (see `game_mechanics.md` §6.2) to report anti-nuke.

**Open questions.** Does the bot build its own anti-nuke in response to enemy nukes (probably yes, needed anyway)? How many launchers and when?

---

## 2. Skuttles and spy bots

**Idea.** Use units that hit a big area at once for army-blob killing.

**Skuttles.** Large area of effect, can cloak. If the enemy has no radar, they walk up to the enemy blob and self-destruct for a big radius. Used against **army blobs**, not eco. (From §8: about 755 M / 27k E, can kill about 5k metal of units; self-destruct is a bigger explosion than dying.)

**Spy bots.** Similar approach, but they only **stun** units (EMP on everything around them, friend and foe). Still very helpful.

**Hypothesis.** A cheap unit that trades for a blob is far above its cost when it lands.

**To build.** An approach path that avoids enemy radar coverage, a trigger when the blob is dense, and detonation logic. Needs enemy radar knowledge from scouting.

**Open questions.** What does the bot do when the enemy does have radar? (Tree said §8's radar-jam-by-transport trick is still out of scope.)

---

## 3. LRPC (and Basilisk, Calamity) with defense creep

**Idea.** Static long-range artillery built far enough from the enemy base to hit it and kill eco, protected by defense creep.

**Hypothesis.** If there is a lot of defense around the artillery, the enemy has to sacrifice a lot to kill it. Tree notes he personally dislikes artillery, but that should not inform strategy.

**Note on §7.3.** `game_mechanics.md` says artillery is not favored on this map. This experiment is the exception: static siege backed by creep, not mobile artillery in the army. Update the doc if it works.

**To build.**
- Mobile build power to place the static buildings (they cannot move).
- Placement rule: build each new piece within range of the current ones so they protect each other.
- Cost tuned empirically (see tuning rule above).

**Open questions.** Which of LRPC, Basilisk and Calamity first? How much BP goes to the siege versus the main spine?

---

## 4. Dedicated energy grid (fix late-game energy scaling)

**Problem.** Late game the bot has too much metal to spend, but units need more energy, and the mex grids have a fixed amount of space for energy. There is no space in the mex grids for more fusions, so it cannot build more E.

**Idea.** Add a dedicated energy grid, separate from the mex grids.

**Reference.** `blueprints/general/fussion_grid_60x60.lua` in the MetalBot repo. A different layout could be made.

**Hypothesis.** Removing the energy cap lets the bot actually spend its metal late game and removes the late energy stall.

**Watch out.** `game_mechanics.md` §11: the old bot consistently *over*-built energy early at the expense of mex expansion. A new grid must only open late, with a hard ceiling, so this does not repeat.

**Open questions (need an answer from Tree).** What opens a new energy grid: an E-stall fraction, the E/M ratio, or spine capacity? Fusion only, or fusion plus wind? Where should it go so a single raid cannot kill it?

---

## 5. T3 unit exploration

**Units to test:** Behemoth, Juggernaut, Catapult, Shiva, Demon.

**Idea.** Test T3 units from the gantry beyond the single reference unit the spine currently makes (Demon).

**Hypothesis.** A mix of T3 units does better than one reference unit. This ties to "Not done: a doctrine mix in the lab queues" in `spine_plan.md`.

**To build.** Lab queue mix for the gantry, then compare unit by unit.

**Open questions.** Which enemy builds does each one counter? Which are for the main army and which are support?

---

## 6. Defense creep (Bulwark, Persecutor, Scorpion)

**Idea.** Build defenses toward the enemy with BP right there to build them quickly.

**Details.**
- Towers go **slightly behind the front** to anchor it and make it harder to dislodge.
- They give a place to **heal**, since there is BP at the creep.
- The creep runs **alongside the main army**. It is basically the proxy base idea (§6.1): forward BP and labs behind the front with real defenses, no eco.
- **No retreat and no reclaim.** If it is overrun, it is lost. It is a commitment.
- A T2 con places the tower, and Twitchers assist for build power.

**Hypothesis.** Quick build power at the front lets the army hold ground and heal, and gives the siege (idea 3) something to stand behind.

**Open questions.** How many Twitchers per con? What stops the creep (contact, distance from the enemy base)?

---

## 7. Bombing runs

**Idea.** Hold bombers back, size up enemy air defense, then strike eco in one big pass.

**Details.**
- Get a rough idea of the enemy's AA.
- Build enough **fighters** to beat their fighters, and enough **bombers** to tank some ground AA, so they get **one pass on the eco**.
- The bombers will die, but if they drop one round of bombs it counts as a success.
- Bombers wait in the **mex grids**, which should be well defended.
- Target priority: **valuable eco**.
- The RADIER bot has some bomber targeting, but Tree says it is not the best.

**To build.** An AA estimate from scouting, a fighter/bomber count rule, a launch trigger, and a target picker that ranks eco by value.

**Open questions.** What does RADIER's targeting do now, and where is it weak? Needs a look at the RADIER code.

---

## Still unresolved

- Separate branches of LINE_CLICK per experiment, or options one bot picks between mid-game?
- RADIER's bomber targeting (what it does, where it falls short).
- Energy grid trigger rule and placement (idea 4).
- Twitcher count per con (idea 6).
