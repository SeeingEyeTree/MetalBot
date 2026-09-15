# Lessons Learned

Curated insights from agent runs and manual analysis. Updated automatically after each gauntlet.
New entries go at the top so the most recent observations appear first in the agent context.

---

## What has worked

*(No agent runs yet — entries will be added here as the tournament runs.)*

---

## What has failed

*(No agent runs yet — entries will be added here as the tournament runs.)*

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
