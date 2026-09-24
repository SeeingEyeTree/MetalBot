#!/usr/bin/env python3
"""
find_weakness.py - turn one match's tracker data into a ranked list of bot weaknesses.

The stats tracker (metalbot_stats_tracker.lua) logs, per team and from that team's own
point of view, economy, units, intel, losses and milestone events. bot_testing.py saves
them as result["tracker_timeline"]. This script reads that and runs one detector per
failure class -- each one a way a bot has actually been observed to lose:

    early_threat_undefended   an enemy arrived / hit us early and nothing was there to answer
    no_early_warning          the first threat was already at the base when first seen
    late_scouting             enemy not found until late, or little of the map ever seen
    no_counter_air            enemy air seen, we have no unit/defence that can shoot air
    no_ground_defense         armed enemy ground units seen, we cannot shoot ground
    builder_attrition         constructors died and were not replaced
    metal_float               metal at storage cap while income goes unspent
    production_idle           factories sitting empty while metal is banked
    undefended_economy        we lose economy buildings and have no defensive structures
    slow_macro                early-economy milestones far behind a reference
    unit_cap_pressure         close to the unit cap
    army_scattered            army strung out / far from home while the base is hit
    bad_trades                we take far more damage than we deal
    piecemeal_engagement      units die in ones and twos: few friends near when they fall
    aa_coverage_gap           enemy air present, factories / commander outside dedicated AA cover
    strategic_exposure        enemy nukes / long-range guns and no anti-nuke or answer
    commander_exposed         the commander (its loss ends the game) is alone, far out, or was killed
    radar_warning_unused      radar saw the enemy long before anything else did

Usage:
    python find_weakness.py result.json              # both teams
    python find_weakness.py result.json --team 0
    python find_weakness.py result.json --json       # machine-readable

It reports weaknesses; it does not fix anything. Severity is 0-100 and is a ranking aid,
not a measurement: read the evidence. One game is one sample and slot 0 is favoured
(see CLAUDE.md), so treat findings as hypotheses to confirm, not verdicts.
"""

import argparse
import json
import sys
from pathlib import Path

FPS = 30
MIN = 60 * FPS


def mmss(frame):
    s = int(frame / FPS)
    return f"{s // 60}:{s % 60:02d}"


# Reference points for the slow_macro detector. Source: this project's own matches on
# 2026-09-21 (DRAGON_BOT's early macro, judged good by the author) and the human-vs-bot
# replay in knowledge/game_mechanics.md section 11. Single samples: a guide, not a law.
BENCH = {
    "first_mex": 300, "first_energy": 520, "first_factory": 1300,
    "mex_10": 6000, "mex_25": 8500,
    # cumulative metal produced by 7:30 (frame 13500); the human in the section-11 replay
    # had 29,718 at that point.
    "metal_produced_13500": 29718,
}


class Match:
    def __init__(self, result, team):
        self.r = result
        self.team = team
        rows = [x for x in result.get("tracker_timeline", []) if x.get("team") == team]
        # Nothing after the game effectively ended counts: once a commander dies (or the
        # harness self-destructs both at the end-of-match limit) the team collapses, and
        # "no constructors" / "raider at the base" from then on is the ending, not a weakness.
        cutoff = min([x["frame"] for x in rows
                      if x["kind"] == "event" and x.get("name") == "commander_lost"] or [10 ** 9])
        ds = result.get("draw_score")
        if ds and ds.get(f"frame{team}") is not None:
            cutoff = min(cutoff, ds[f"frame{team}"])
        self.cutoff = cutoff
        rows = [x for x in rows if x["frame"] <= cutoff]
        self.rows = rows
        self.by_kind = {}
        for x in rows:
            self.by_kind.setdefault(x["kind"], []).append(x)
        for k in self.by_kind:
            self.by_kind[k].sort(key=lambda x: x["frame"])
        self.events = {}
        for x in self.by_kind.get("event", []):
            self.events.setdefault(x.get("name"), []).append(x)
        opp = 1 - team
        self.opp_rows = [x for x in result.get("tracker_timeline", []) if x.get("team") == opp]
        self.end = max((x["frame"] for x in rows), default=0)

    def ev(self, name):
        """Frame of the first occurrence of an event, or None."""
        e = self.events.get(name)
        return e[0]["frame"] if e else None

    def ev_row(self, name):
        e = self.events.get(name)
        return e[0] if e else None

    def at(self, kind, frame):
        """The last row of `kind` at or before `frame`."""
        best = None
        for x in self.by_kind.get(kind, []):
            if x["frame"] <= frame:
                best = x
            else:
                break
        return best

    def series(self, kind, key):
        return [(x["frame"], x[key]) for x in self.by_kind.get(kind, []) if key in x]

    def has_data(self):
        return bool(self.by_kind.get("units")) and bool(self.by_kind.get("eco"))


def finding(fid, sev, title, evidence, hint):
    return {"id": fid, "severity": int(max(0, min(100, sev))), "title": title,
            "evidence": evidence, "hint": hint}


# ── Detectors ────────────────────────────────────────────────────────────────

def early_threat_undefended(m):
    """First threat inside the first 8 minutes with nothing to answer it.
    'Answer' = an army unit or a defensive structure standing within 30 s."""
    # first_loss only counts as a threat when the tracker attributes losses to the enemy:
    # older data logged the bot's own reclaims (e.g. its starter lab) as "losses".
    attributed = "lost_enemy_n" in (m.at("combat", m.end) or {})
    cand = [(m.ev("first_enemy_near_base"), "enemy near base"),
            (m.ev("first_damage_taken"), "first damage taken")]
    if attributed:
        cand.append((m.ev("first_loss"), "first loss to the enemy"))
    cand = [(f, n) for f, n in cand if f is not None]
    if not cand:
        return None
    t, what = min(cand)
    if t > 8 * MIN:
        return None
    answered = [m.ev("first_army"), m.ev("first_defense")]
    answered = [a for a in answered if a is not None and a <= t + 30 * FPS]
    if answered:
        return None
    after = m.at("combat", t + 3 * MIN) or {}
    before = m.at("combat", t - 1) or {}
    key = "lost_enemy_mv" if attributed else "lost_mv"
    lost = after.get(key, 0) - before.get(key, 0)
    ev = [f"first threat ({what}) at {mmss(t)}",
          f"first army unit: {mmss(m.ev('first_army')) if m.ev('first_army') else 'never'}, "
          f"first defensive structure: {mmss(m.ev('first_defense')) if m.ev('first_defense') else 'never'}",
          f"metal lost in the 3 min after: {lost:.0f}"]
    near = m.ev_row("first_enemy_near_base")
    if near:
        ev.append(f"first raider: {near.get('def')}")
    sev = 55 + min(35, 35 * (1 - t / (8 * MIN))) + min(10, lost / 200)
    return finding("early_threat_undefended", sev,
                   "Early enemy contact with nothing to answer it", ev,
                   "unit_controller/macro: a defence interrupt (a few LLTs or an early lab); "
                   "must not delay the hand-off to grids")


def no_early_warning(m):
    r = m.ev_row("first_enemy_near_base")
    if not r:
        return None
    warned, lead = r.get("warned_dist", 0), r.get("lead_frames", 0)
    if lead > 20 * FPS and warned > 2500:
        return None
    sev = 35 + (25 if lead <= 3 * FPS else 10) + (15 if r["frame"] < 5 * MIN else 0)
    return finding("no_early_warning", sev,
                   "First raider was already at the base when first seen",
                   [f"{r.get('def')} reached the base at {mmss(r['frame'])}; first seen "
                    f"{warned:.0f} elmos away, {lead / FPS:.0f}s before it arrived"],
                   "scouting: earlier / wider scouts or radar; see late_scouting")


def late_scouting(m):
    seen = m.ev("first_enemy_seen")
    ev, sev = [], 0
    if seen is None:
        ev.append(f"enemy never seen in {mmss(m.end)}")
        sev += 40
    elif seen > 5 * MIN:
        ev.append(f"enemy first seen at {mmss(seen)}")
        sev += min(40, 10 + (seen - 5 * MIN) / MIN * 4)
    exp10 = m.at("intel", 10 * MIN)
    if exp10 and "explored_frac" in exp10:
        ev.append(f"map ever seen by 10:00: {exp10['explored_frac'] * 100:.0f}%, in LOS now "
                  f"{exp10['los_frac'] * 100:.0f}%, on radar {exp10.get('radar_frac', 0) * 100:.0f}%")
        if exp10["explored_frac"] < 0.35:
            sev += 25
    if sev < 20:
        return None
    return finding("late_scouting", sev, "Enemy found late / little of the map scouted", ev,
                   "unit_controller: scouts (fast air), radar coverage")


def no_counter_air(m):
    """Enemy air is killing us (or was seen) and we have nothing that can shoot it."""
    units = m.by_kind.get("units", [])
    combat = m.at("combat", m.end) or {}
    seen = [x for x in m.by_kind.get("intel", []) if x.get("vis_air", 0) > 0]
    lost_air = combat.get("lost_to_air", 0)
    if not seen and lost_air < 5:
        return None
    first = seen[0]["frame"] if seen else None
    if lost_air >= 5:
        # when did the air losses start? use the first combat row with any
        t_air = next((c["frame"] for c in m.by_kind.get("combat", []) if c.get("lost_to_air", 0) > 0),
                     None)
        first = min(x for x in (first, t_air) if x is not None)
    after = [u for u in units if u["frame"] >= first]
    bare = [u for u in after if u.get("aa_dedicated", 0) == 0
            and u.get("army_hits_air", 0) + u.get("def_hits_air", 0) <= 0.2 * max(u.get("army", 0), 1)]
    if len(bare) < 3 and lost_air < 5:
        return None
    aa_first = m.ev("first_aa")
    ev = [f"enemy air first seen / first killing us at {mmss(first)}",
          f"units lost to air attackers: {lost_air}  (killers: {combat.get('killers', '-')})",
          f"no dedicated AA standing in {len([u for u in after if u.get('aa_dedicated', 0) == 0])} "
          f"of {len(after)} later snapshots; first dedicated AA built: "
          f"{mmss(aa_first) if aa_first else 'never'}",
          f"damage dealt over the whole game: {combat.get('dmg_dealt', 0):.0f}"]
    has_aa = any(u.get("aa_dedicated", 0) > 0 for u in after)
    if has_aa:
        # AA exists, so this is about where it stands, not whether it exists.
        return finding("no_counter_air", 25 + min(20, lost_air), "Enemy air kills units although AA exists",
                       ev, "lab_controller/macro: see aa_coverage_gap - AA placement, and enough of it")
    sev = 40 + min(30, lost_air * 1.5) + min(20, len(bare) * 3)
    return finding("no_counter_air", sev, "Enemy air is killing units and nothing can shoot it", ev,
                   "lab_controller: standing AA baseline (game_mechanics 7.3), reactive scaling")


def no_ground_defense(m):
    intel = [x for x in m.by_kind.get("intel", []) if x.get("vis_ground", 0) > 0]
    if not intel:
        return None
    first = intel[0]["frame"]
    bare = [u for u in m.by_kind.get("units", []) if u["frame"] >= first
            and u.get("army_hits_ground", 0) + u.get("def_hits_ground", 0) == 0]
    if len(bare) < 3:
        return None
    return finding("no_ground_defense", 45 + min(30, len(bare) * 3),
                   "Enemy ground units seen, nothing able to shoot ground",
                   [f"ground enemies first seen {mmss(first)}; {len(bare)} snapshots with no "
                    "ground-capable unit or defence"],
                   "lab_controller: mixed composition / cheap ground defence")


def builder_attrition(m):
    dead = [e["frame"] for e in m.events.get("cons_all_dead", [])]
    back = [(e["frame"], e.get("waited", 0)) for e in m.events.get("cons_restored", [])]
    lost = (m.at("combat", m.end) or {}).get("lost_cons", 0)
    if not dead and lost < 3:
        return None
    waits = [w for _, w in back]
    stuck_since = None
    if dead and len(back) < len(dead):
        stuck_since = dead[-1]
    frames_without = sum(waits) + ((m.end - stuck_since) if stuck_since else 0)
    ev = [f"constructors lost: {lost}; times with none alive: {len(dead)}",
          f"total time with no constructors: {frames_without / FPS:.0f}s"
          + (f" (still none at {mmss(m.end)})" if stuck_since else "")]
    if not dead and lost >= 3:
        ev.append("(had constructors left throughout, but is losing them steadily)")
    sev = 25 + min(60, frames_without / FPS / 3) + (15 if stuck_since else 0)
    if not dead:
        sev = 25 + min(25, lost * 3)
    return finding("builder_attrition", sev, "Constructors die and are not replaced", ev,
                   "lab_controller/macro: keep a minimum builder count, rebuild on death")


def metal_float(m):
    rows = [e for e in m.by_kind.get("eco", []) if e["frame"] >= 8 * MIN
            and e.get("metal_cap", 0) > 0]
    if not rows:
        return None
    full = [e for e in rows if e["metal"] >= 0.9 * e["metal_cap"]]
    if len(full) < 3:
        return None
    worst = max(full, key=lambda e: e["metal"])
    unspent = [1 - e["metal_pull"] / e["metal_inc"] for e in full if e.get("metal_inc", 0) > 0]
    ev = [f"metal at >=90% of storage in {len(full)} of {len(rows)} snapshots after 8:00",
          f"peak banked {worst['metal']:.0f} of {worst['metal_cap']:.0f} at {mmss(worst['frame'])}",
          f"while full, {100 * sum(unspent) / max(len(unspent), 1):.0f}% of income went unspent"
          f" (pull vs income)"]
    last = full[-1]
    if last.get("unit_cap"):
        ev.append(f"units {last.get('units_total')}/{last['unit_cap']} (cap not the limit)"
                  if last.get("units_total", 0) < 0.9 * last["unit_cap"]
                  else f"units {last.get('units_total')}/{last['unit_cap']} - AT THE UNIT CAP")
    sev = 30 + min(45, len(full) * 4) + min(15, worst["metal"] / 5000)
    return finding("metal_float", sev, "Metal banked at the cap: income is not being spent", ev,
                   "lab_controller/macro: more production or a use for surplus (defences, "
                   "more factories); see also production_idle")


def production_idle(m):
    bad = []
    for u in m.by_kind.get("units", []):
        if u["frame"] < 5 * MIN or u.get("factory", 0) < 1 or "fac_busy" not in u:
            continue
        e = m.at("eco", u["frame"]) or {}
        rich = e.get("metal_cap", 0) > 0 and e.get("metal", 0) > 0.3 * e["metal_cap"]
        if rich and u["fac_idle"] >= max(1, u["factory"] * 0.5):
            bad.append((u["frame"], u["fac_idle"], u["factory"], e["metal"]))
    if len(bad) < 3:
        return None
    return finding("production_idle", 30 + min(45, len(bad) * 4),
                   "Factories idle while metal is banked",
                   [f"{len(bad)} snapshots with >=half the factories empty and >30% metal stored",
                    f"e.g. {mmss(bad[0][0])}: {bad[0][1]}/{bad[0][2]} idle, {bad[0][3]:.0f} metal"],
                   "lab_controller: keep every factory queued")


def undefended_economy(m):
    c = m.at("combat", m.end) or {}
    u = m.at("units", m.end) or {}
    if "lost_enemy_eco_mv" not in c:
        return None        # old data: cannot tell enemy kills from the bot's own reclaims
    lost_eco = c["lost_enemy_eco_mv"]
    if lost_eco < 2000 or u.get("defense", 0) > 2:
        return None
    return finding("undefended_economy", 30 + min(40, lost_eco / 1000),
                   "The enemy is destroying economy and no defensive structures exist",
                   [f"economy metal destroyed by the enemy: {lost_eco:.0f} "
                    f"({c.get('lost_enemy_eco_n', 0)} units; {c.get('lost_eco_mv', 0):.0f} "
                    "including the bot's own reclaims)",
                    f"defensive structures standing: {u.get('defense', 0)}",
                    f"killers: {c.get('killers', '-')}"],
                   "macro: defences at expansions / a response to raids (game_mechanics 7.1)")


def slow_macro(m):
    ev, sev = [], 0
    for name in ("first_mex", "first_energy", "first_factory", "mex_10", "mex_25"):
        f = m.ev(name)
        b = BENCH[name]
        if f is None:
            ev.append(f"{name}: never")
            sev += 12
        elif f > b * 1.3:
            ev.append(f"{name} at {mmss(f)} vs reference {mmss(b)}")
            sev += min(15, (f / b - 1) * 20)
    e = m.at("eco", 13500)
    if e and e["frame"] >= 12600 and e.get("metal_produced"):
        ratio = e["metal_produced"] / BENCH["metal_produced_13500"]
        if ratio < 0.7:
            ev.append(f"cumulative metal by 7:30: {e['metal_produced']:.0f} = "
                      f"{ratio:.2f}x the reference {BENCH['metal_produced_13500']}")
            sev += (0.7 - ratio) * 60
    early = [x["stall_m"] for x in m.by_kind.get("eco", []) if 1 * MIN <= x["frame"] <= 6 * MIN]
    if early and sum(early) / len(early) > 0.3:
        ev.append(f"metal-starved {100 * sum(early) / len(early):.0f}% of the time in minutes 1-6")
        sev += 10
    if sev < 20:
        return None
    return finding("slow_macro", sev, "Early economy is behind the reference", ev,
                   "macro_controller: opening order, mex/energy balance (lessons_learned)")


def unit_cap_pressure(m):
    e = [x for x in m.by_kind.get("eco", []) if x.get("unit_cap", 0) > 0
         and x.get("units_total", 0) >= 0.9 * x["unit_cap"]]
    if not e:
        return None
    return finding("unit_cap_pressure", 30 + min(30, len(e) * 5), "At the unit cap",
                   [f"{len(e)} snapshots at >=90% of the unit cap "
                    f"(first {mmss(e[0]['frame'])}: {e[0]['units_total']}/{e[0]['unit_cap']})"],
                   "macro: cheaper/fewer economy units; reclaim; unit-cap awareness")


def army_scattered(m):
    rows = [a for a in m.by_kind.get("army", []) if a.get("n", 0) >= 10]
    bad = [a for a in rows if a["spread"] > 1200]
    if len(bad) < 3:
        return None
    w = max(bad, key=lambda a: a["spread"])
    c = m.at("combat", m.end) or {}
    return finding("army_scattered", 25 + min(35, len(bad) * 3),
                   "Army is strung out across the map",
                   [f"{len(bad)} of {len(rows)} snapshots with mean spread >1200 elmos",
                    f"worst {w['spread']:.0f} at {mmss(w['frame'])} ({w['n']} units, "
                    f"{w['dist_base']:.0f} from base)",
                    f"units lost: {c.get('lost_army_n', 0)} army"],
                   "unit_controller: rally/regroup before advancing")


def bad_trades(m):
    c = m.at("combat", m.end) or {}
    d, r = c.get("dmg_dealt", 0), c.get("dmg_recv", 0)
    if r < 20000 or d <= 0 or r / d < 2.0:
        return None
    return finding("bad_trades", 30 + min(40, (r / d - 2) * 15),
                   "Taking much more damage than dealing",
                   [f"damage received {r:.0f} vs dealt {d:.0f} ({r / d:.1f}x)",
                    f"killers: {c.get('killers', '-')}"],
                   "unit_controller/lab_controller: composition and engagement rules")


def piecemeal_engagement(m):
    """Units fight in ones and twos instead of together."""
    c = m.at("combat", m.end) or {}
    n, iso = c.get("pm_deaths", 0), c.get("pm_isolated", 0)
    rows = [a for a in m.by_kind.get("army", []) if a.get("n", 0) >= 10 and "groups" in a]
    split = [a for a in rows if a["groups"] >= 3 and a["main_share"] < 0.5]
    ev, sev = [], 0
    if n >= 15 and iso / n >= 0.4:
        ev.append(f"{iso} of {n} sampled army deaths had <=2 friendly army units within 600 elmos "
                  f"(average support {c.get('pm_support_avg', 0):.1f} units)")
        sev += 30 + min(30, iso / n * 40)
    if len(split) >= 3:
        w = max(split, key=lambda a: a["groups"])
        ev.append(f"army in 3+ separate groups with <50% in the biggest in {len(split)} of "
                  f"{len(rows)} snapshots; worst {w['groups']} groups at {mmss(w['frame'])} "
                  f"(main group {w['main_share'] * 100:.0f}%)")
        sev += 20 + min(20, len(split) * 2)
    if not ev:
        return None
    return finding("piecemeal_engagement", sev, "Units fight in ones and twos", ev,
                   "unit_controller: gather before engaging; retreat wounded units to the nano "
                   "cluster; see also army_scattered")


def aa_coverage_gap(m):
    """Enemy air is about, but factories / the commander are outside dedicated-AA range."""
    combat = m.at("combat", m.end) or {}
    t_air = m.ev("first_enemy_air")
    if t_air is None and combat.get("lost_to_air", 0) < 3:
        return None
    units = [u for u in m.by_kind.get("units", []) if "fac_aa_ded_cover" in u]
    if not units or all(u.get("aa_dedicated", 0) == 0 for u in units):
        return None            # no AA at all: no_counter_air already says it
    start = t_air if t_air is not None else 0
    late = [u for u in units if u["frame"] >= start and u.get("factory", 0) >= 1]
    bad = [u for u in late if u["fac_aa_ded_cover"] * 2 < u["factory"]]
    cm = [r for r in m.by_kind.get("cmdr", []) if r["frame"] >= start]
    cm_bad = [r for r in cm if r.get("aa_ded_cover", 1) == 0]
    if len(bad) < 3 and len(cm_bad) < 3:
        return None
    ev = []
    if bad:
        w = min(bad, key=lambda u: u["fac_aa_ded_cover"] / max(u["factory"], 1))
        ev.append(f"in {len(bad)} of {len(late)} snapshots fewer than half the factories have "
                  f"dedicated AA within 800 elmos (worst {mmss(w['frame'])}: "
                  f"{w['fac_aa_ded_cover']}/{w['factory']})")
    if cm_bad:
        ev.append(f"commander outside dedicated-AA cover in {len(cm_bad)} of {len(cm)} snapshots")
    ev.append(f"units lost to air attackers: {combat.get('lost_to_air', 0)}")
    return finding("aa_coverage_gap", 35 + min(30, len(bad) * 3 + len(cm_bad) * 3),
                   "AA exists but does not cover the factories / commander", ev,
                   "lab_controller/macro: put AA where the value is (production, commander)")


def strategic_exposure(m):
    """Nukes and long-range guns, and what stands between them and the base."""
    last = m.at("units", m.end) or {}
    anti = last.get("antinuke", 0)
    bank = max((e.get("metal", 0) for e in m.by_kind.get("eco", [])), default=0)
    ev, sev = [], 0
    t = m.ev("first_enemy_nuke")
    if t is not None:
        r = m.ev_row("first_enemy_nuke")
        ev.append(f"enemy nuke launcher seen at {mmss(t)} ({r.get('def')})")
        if anti == 0:
            ev.append("no anti-nuke standing")
            sev += 65
        elif last.get("factory", 0) and last.get("fac_antinuke_cover", 0) < last["factory"]:
            ev.append(f"anti-nuke covers only {last.get('fac_antinuke_cover', 0)} of "
                      f"{last['factory']} factories")
            sev += 35
    t = m.ev("first_enemy_lrpc")
    if t is not None:
        r = m.ev_row("first_enemy_lrpc")
        ev.append(f"enemy long-range gun seen at {mmss(t)} ({r.get('def')}); own LRPC/counter: "
                  f"{last.get('lrpc', 0)}")
        sev += 25
    if t is None and m.ev("first_enemy_nuke") is None and m.end >= 25 * MIN and bank >= 20000 \
            and anti == 0:
        ev.append(f"late game with up to {bank:.0f} metal banked and no anti-nuke; no enemy "
                  "strategic weapon was SEEN, so this is exposure, not a confirmed loss")
        sev += 25
    if not ev:
        return None
    return finding("strategic_exposure", sev, "Exposed to nukes / long-range guns", ev,
                   "macro/lab_controller: anti-nuke over the production cluster once silos are "
                   "seen; scouting for silos; raid or out-range LRPCs")


def commander_exposed(m):
    """Losing the commander loses the game."""
    rows = m.by_kind.get("cmdr", [])
    ev, sev = [], 0
    lost = m.ev_row("commander_lost")
    if lost and lost.get("killer") not in (None, "?"):
        prior = [r for r in rows if r["frame"] < lost["frame"]]
        ev.append(f"commander killed by {lost.get('killer')} at {mmss(lost['frame'])}")
        if prior:
            r = prior[-1]
            ev.append(f"last check {mmss(r['frame'])}: {r['friends_near']} friendly army/defences and "
                      f"{r['aa_ded_cover']} dedicated AA within 800 elmos, {r['dist_base']:.0f} "
                      f"elmos from base, hp {r['hp'] * 100:.0f}%")
        sev += 45
    alone = [r for r in rows if r.get("enemy_near", 0) > 0 and r.get("friends_near", 0) == 0]
    if len(alone) >= 2:
        ev.append(f"in {len(alone)} snapshots enemies were within 800 elmos of the commander "
                  "with no friendly army or defence near it")
        sev += 20 + min(20, len(alone) * 4)
    far = [r for r in rows if r.get("dist_base", 0) > 1500]
    if len(far) >= 3:
        ev.append(f"commander was >1500 elmos from base in {len(far)} of {len(rows)} snapshots")
        sev += 10
    if not ev:
        return None
    return finding("commander_exposed", sev, "The commander is exposed", ev,
                   "unit_controller/macro: keep the commander with defences and the nano cluster; "
                   "escape logic when enemies approach")


def radar_warning_unused(m):
    """Radar contacts long before line of sight: an opportunity to respond earlier."""
    rc, seen = m.ev("first_radar_contact"), m.ev("first_enemy_seen")
    if rc is None:
        return None
    lead = (seen - rc) if seen is not None else (m.end - rc)
    if lead < 60 * FPS:
        return None
    ev = [f"first radar contact at {mmss(rc)}; first enemy in line of sight "
          f"{mmss(seen) if seen is not None else 'never'} - {lead / FPS:.0f}s earlier"]
    mv = m.ev_row("first_radar_moving")
    if mv:
        ev.append(f"first moving blip at {mmss(mv['frame'])}: speed {mv.get('speed')} elmos/s matches "
                  f"{mv.get('n_cands')} unit types, e.g. {mv.get('cands')} (either/or until seen)")
    return finding("radar_warning_unused", 20 + min(30, lead / MIN * 3),
                   "Radar saw the enemy long before anything else did (opportunity)", ev,
                   "unit_controller: act on radar contacts (decode speed via WG.StatsTracker."
                   "DecodeSpeed): send interceptors/scouts, start defences")


DETECTORS = [early_threat_undefended, no_early_warning, late_scouting, no_counter_air,
             no_ground_defense, builder_attrition, metal_float, production_idle,
             undefended_economy, slow_macro, unit_cap_pressure, army_scattered, bad_trades,
             piecemeal_engagement, aa_coverage_gap, strategic_exposure, commander_exposed,
             radar_warning_unused]


def compare(m):
    """Own economy against the opponent's, each read from its own process."""
    out = []
    opp = Match(m.r, 1 - m.team)
    for f in (7200, 14400, 21600):
        a, b = m.at("eco", f), opp.at("eco", f)
        if a and b and a["frame"] >= f - 900 and b["frame"] >= f - 900 and b.get("metal_produced"):
            out.append((f, a["metal_produced"] / b["metal_produced"],
                        a["metal_inc"], b["metal_inc"]))
    return out


def analyse(result, team):
    m = Match(result, team)
    if not m.has_data():
        return m, [], []
    found = []
    for d in DETECTORS:
        try:
            r = d(m)
        except Exception as ex:        # a detector bug must not hide the others
            r = finding(d.__name__ + "_error", 0, f"detector {d.__name__} failed", [repr(ex)], "")
        if r:
            found.append(r)
    found.sort(key=lambda x: -x["severity"])
    return m, found, compare(m)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("result", help="result JSON saved with bot_testing.py --save-result")
    ap.add_argument("--team", type=int, choices=(0, 1), help="analyse one team (default both)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    result = json.loads(Path(args.result).read_text(encoding="utf-8"))
    names = {0: result.get("bot0_name"), 1: result.get("bot1_name")}
    teams = [args.team] if args.team is not None else [0, 1]
    out = {}
    for t in teams:
        m, found, cmp_ = analyse(result, t)
        out[t] = {"bot": names[t], "findings": found,
                  "economy_vs_opponent": [{"frame": f, "produced_ratio": round(r, 2),
                                           "income": a, "opp_income": b} for f, r, a, b in cmp_],
                  "has_data": m.has_data()}
    if args.json:
        json.dump(out, sys.stdout, indent=2)
        return

    print(f"winner: {result.get('winner')} ({result.get('winner_method')}), "
          f"end_reason: {result.get('end_reason')}")
    for t in teams:
        o = out[t]
        print(f"\n=== Team {t}: {o['bot']} ===")
        if not o["has_data"]:
            print("  no tracker data (was the tracker widget installed?)")
            continue
        for e in o["economy_vs_opponent"]:
            print(f"  economy at {mmss(e['frame'])}: produced {e['produced_ratio']:.2f}x the "
                  f"opponent's cumulative metal; income {e['income']:.0f} vs {e['opp_income']:.0f}")
        if not o["findings"]:
            print("  no weaknesses flagged by the detectors")
        for i, f in enumerate(o["findings"], 1):
            print(f"\n  {i}. [{f['severity']:>3}] {f['title']}  ({f['id']})")
            for line in f["evidence"]:
                print(f"       - {line}")
            if f["hint"]:
                print(f"       -> {f['hint']}")


if __name__ == "__main__":
    main()
