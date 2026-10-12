# Frontier crew (TODO, noted 2026-10-12)

Needed by experiment_ideas.md #3 (LRPC / Basilisk / Calamity with defence creep) and #6 (defence creep with forward BP).
Not built yet.

What it is: a mobile crew (a T2 con plus Twitchers for build power) that follows the army front and places STATIC
structures where they protect each other: each new piece goes within range of the pieces already standing, slightly
behind the front. No retreat and no reclaim: if overrun it is lost (a commitment).

Pieces to build:
- placement rule: next site = a point within `support_range` of existing pieces, behind the front line (from click_army's
  stage/front), on buildable ground, not on a lane;
- crew management: one T2 con + N assisting Twitchers, kept with the army (a behaviour on bar_framework/behavior_host:
  `follow_front`), BP shared through the nano_broker idea but with mobile units;
- build driver: blueprint_placer in single-builder mode with a growing layout (one entry added per placed piece);
- budget: a stance share for "static" spend, tuned empirically (overspending on artillery the enemy walks over is the
  failure mode, per experiment_ideas.md).
- trigger: a `switch`/`army_share` hook on game_state (front position, enemy static defence = state.facts.staticDef,
  blobs from state.blobs).
