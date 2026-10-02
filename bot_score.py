#!/usr/bin/env python3
"""
bot_score.py - estimate how strong a bot's position is at a given moment: phi(state).

The end-of-match adjudicator in bot_testing.py scores `army_mv + 60 x metal_inc`. This is the
same idea taken further, framed the way reinforcement learning frames it: a win/loss reward
is far too sparse to learn from, so you shape it with a potential phi(s), an estimate of how
good a state is, and reward its change. phi is exactly "how strong is this position",
which is also what an early-ending match needs. See knowledge/scoring.md.

    phi = sum over metal terms (army, defence, income capital) x their multipliers
          - value at risk x (1 - warn_discount x warned_rate)

Everything is in metal-equivalents where it can be, so each term reads as "worth N metal".
Signals are registered functions of one team's tracker rows at one frame (plus, for the
privileged `enemy_*` signals, the opponent's own rows: the evaluator sees both processes,
the bots never do). Weights and parameters live in score_config.json. A signal whose
tracker fields are missing (older results) is skipped and listed, never counted as zero.

Usage:
    python bot_score.py result.json                       # both teams, config checkpoints
    python bot_score.py result.json --frames 7200,14400   # other checkpoints
    python bot_score.py result.json --detail 14400        # every signal at one frame
    python bot_score.py result.json --ref ref.json:0      # categories as % of a reference team
    python bot_score.py result.json --json

Adding a signal: write a function `def x(st): ...` returning a number, (number, note) or
None, decorate it with @signal(...), and give it a weight in score_config.json if it should
count towards phi. Role "add" = metal term, "mult" = multiplier on the terms named in
`applies`, "sub" = metal subtracted, "report" = shown only (other signals may read it).
"""

import argparse
import json
import math
import sys
from pathlib import Path

from find_weakness import FPS, Match, mmss

HERE = Path(__file__).resolve().parent
CONFIG_PATH = HERE / "score_config.json"
CATALOG_PATH = HERE / "knowledge" / "unit_catalog.json"
STALE = 1800        # frames: a row older than this at the scored frame is not "now"

CATEGORIES = ("materiel", "economy", "ability", "exposure", "awareness", "attrition")


# ── Registry ─────────────────────────────────────────────────────────────────

class Signal:
    def __init__(self, fn, name, category, role, unit, applies=()):
        self.fn, self.name, self.category, self.role = fn, name, category, role
        self.unit, self.applies, self.doc = unit, tuple(applies), (fn.__doc__ or "").strip()


SIGNALS: "list[Signal]" = []
BY_NAME: "dict[str, Signal]" = {}


def signal(name, category, role="report", unit="", applies=()):
    def deco(fn):
        s = Signal(fn, name, category, role, unit, applies)
        SIGNALS.append(s)
        BY_NAME[name] = s
        return fn
    return deco


def load_config(path=CONFIG_PATH):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def load_units(result):
    """name -> {air, metal, tech, ...}: the unit catalog, plus the [TRK] def rows the
    tracker logged in this match (they cover structures the catalog does not)."""
    units = {}
    if CATALOG_PATH.exists():
        for u in json.loads(CATALOG_PATH.read_text(encoding="utf-8")):
            units[u["name"]] = dict(u)
    for r in result.get("tracker_timeline", []):
        if r.get("kind") == "def" and "name" in r:
            u = units.setdefault(r["name"], {"name": r["name"]})
            u.setdefault("air", bool(r.get("canFly")))
    return units


# ── State: one team at one frame ─────────────────────────────────────────────

class State:
    def __init__(self, m, opp, frame, cfg, units):
        self.m, self.opp, self.f, self.cfg, self.units = m, opp, frame, cfg, units
        self._vals, self._notes = {}, {}

    def p(self, key):
        return self.cfg["params"][key]

    @property
    def H(self):
        return self.cfg["horizon_s"]

    def row(self, kind, opp=False):
        """The latest `kind` row at or before the frame, if it is recent enough to be 'now'."""
        m = self.opp if opp else self.m
        r = m.at(kind, self.f)
        return r if r is not None and r["frame"] >= self.f - STALE else None

    def get(self, kind, key, opp=False, default=None):
        r = self.row(kind, opp)
        return r.get(key, default) if r is not None else default

    def has(self, kind, key, opp=False):
        r = self.row(kind, opp)
        return r is not None and key in r

    def ev(self, name, opp=False):
        """Frame of an event if it happened by now."""
        t = (self.opp if opp else self.m).ev(name)
        return t if t is not None and t <= self.f else None

    def first_frame(self, kind, pred, opp=False):
        """First row of `kind` (up to now) satisfying pred, or None."""
        for r in (self.opp if opp else self.m).by_kind.get(kind, []):
            if r["frame"] > self.f:
                break
            if pred(r):
                return r["frame"]
        return None

    def val(self, name):
        if name not in self._vals:
            try:
                out = BY_NAME[name].fn(self)
            except Exception as ex:      # one broken signal must not sink the score
                out = (None, f"error: {ex!r}")
            v, note = out if isinstance(out, tuple) else (out, None)
            self._vals[name] = None if v is None or (isinstance(v, float) and math.isnan(v)) else v
            self._notes[name] = note
        return self._vals[name]

    def note(self, name):
        self.val(name)
        return self._notes.get(name)


def clamp(x, lo, hi):
    return max(lo, min(hi, x))


def comp_share(st, pred, opp=True):
    """Metal share of an army composition (`comp=name:count,...`, top 6 types) matching pred."""
    comp = st.get("army", "comp", opp=opp)
    if not comp or comp == "-":
        return None
    tot = hit = 0.0
    for part in comp.split(","):
        name, _, n = part.partition(":")
        u = st.units.get(name, {})
        mv = u.get("metal", 100) * int(n or 0)
        tot += mv
        if pred(u):
            hit += mv
    return hit / tot if tot > 0 else None


def enemy_has_air(st):
    """Does the enemy field air now? Privileged (their own rows), else what we have seen."""
    a = comp_share(st, lambda u: u.get("air"))
    if a is not None:
        return a > 0
    return (st.get("intel", "vis_air", default=0) or 0) > 0 or st.ev("first_enemy_air") is not None


# ── Materiel ─────────────────────────────────────────────────────────────────

def full_value(mv, ev, st):
    """Metal-equivalent value: metal + energy / energy_per_metal (game_mechanics 2.3)."""
    return mv + ev / st.p("energy_per_metal")


@signal("army_value", "materiel", "add", "metal")
def army_value(st):
    """Value of finished armed mobile units at metal + energy/70, weighted by average health.
    Energy matters: an air army costs ~2-3x its metal in energy (unit_catalog)."""
    mv = st.get("units", "army_mv")
    if mv is None:
        return None
    ev, src = st.get("units", "army_ev"), "logged"
    if ev is None:
        em, _, how = army_costs(st)
        ev, src = mv * em, f"estimated from army E/M ({how})"
    hp = st.get("army", "hp", default=1.0)
    val = full_value(mv, ev, st) * (hp if st.get("army", "n", default=0) else 1.0)
    return val, f"{mv:.0f} metal + {ev:.0f} energy ({src}) at {hp * 100:.0f}% hp"


@signal("defense_value", "materiel", "add", "metal")
def defense_value(st):
    """Static defences at metal + energy/70 (weighted below 1 in config: they cannot move)."""
    mv = st.get("units", "defense_mv")
    if mv is None:
        return None
    ev = st.get("units", "defense_ev")
    if ev is None:
        return mv, "metal only (energy not logged by this tracker)"
    return full_value(mv, ev, st), f"{mv:.0f} metal + {ev:.0f} energy"


@signal("army_coherence", "materiel", "mult", "x", applies=("army_value",))
def army_coherence(st):
    """One army beats the same units spread in groups: scales with the biggest group's share."""
    n, share = st.get("army", "n"), st.get("army", "main_share")
    if n is None or share is None:
        return None
    if n < st.p("coherence_min_army"):
        return 1.0, f"only {n} units"
    lo = st.p("coherence_floor")
    return lo + (1 - lo) * share, f"{share * 100:.0f}% in the main group of {n}"


@signal("counter_coverage", "materiel", "mult", "x", applies=("army_value", "defense_value"))
def counter_coverage(st):
    """Can what we have shoot what they field? For each enemy class (air / ground), the share
    of our armed units able to hit it, relative to that class's share of the enemy army."""
    armed = (st.get("units", "army", default=0) or 0) + (st.get("units", "defense", default=0) or 0)
    if not armed or not st.has("units", "army_hits_air"):
        return None
    a = comp_share(st, lambda u: u.get("air"))
    src = "their army"
    if a is None and st.get("army", "n", opp=True) == 0:
        return 1.0, "the enemy has no army to counter"
    if a is None:
        vm = st.get("intel", "vis_mv", default=0) or 0
        if vm <= 0:
            return None
        a, src = (st.get("intel", "vis_air_mv", default=0) or 0) / vm, "seen now"
    r_air = (st.get("units", "army_hits_air") + st.get("units", "def_hits_air", default=0)) / armed
    r_gnd = (st.get("units", "army_hits_ground") + st.get("units", "def_hits_ground", default=0)) / armed
    cov = ((1 - a) * min(1, r_gnd / max(1 - a, 0.1)) + a * min(1, r_air / max(a, 0.1)))
    lo = st.p("coverage_floor")
    return lo + (1 - lo) * cov, (f"enemy air {a * 100:.0f}% ({src}); ours hits air "
                                 f"{r_air * 100:.0f}%, ground {r_gnd * 100:.0f}%")


# ── Ability to act ───────────────────────────────────────────────────────────

@signal("slot_headroom", "ability", "report", "x")
def slot_headroom(st):
    """Room left under the unit cap. Past the cap, new production is only worth what it adds
    by replacing cheap units, so income is discounted as the last `cap_ramp` fills."""
    cap, tot = st.get("eco", "unit_cap"), st.get("eco", "units_total")
    if not cap or tot is None:
        return None
    h = clamp((1 - tot / cap) / st.p("cap_ramp"), st.p("cap_floor"), 1.0)
    army, mv = st.get("units", "army", default=0), st.get("units", "army_mv", default=0)
    per = f", {mv / army:.0f} metal per army unit" if army else ""
    return h, f"{tot}/{cap} units{per}"


@signal("production_reach", "ability", "report", "0-1")
def production_reach(st):
    """Share of factories whose units can get out: air labs always can, a ground lab needs a
    path to open ground. A boxed-in ground lab counts half if we have air transports."""
    u = st.row("units")
    if u is None or "ground_fac" not in u or not u.get("factory"):
        return None
    fac, g = u["factory"], u["ground_fac"]
    unknown, ok = u.get("fac_exit_unknown", 0), u.get("fac_exit_ok", 0)
    trapped = g - ok - unknown
    lift = 0.5 if u.get("air_trans", 0) > 0 else 0.0
    val = (fac - trapped + lift * trapped) / fac
    note = f"{trapped}/{g} ground labs boxed in" + (f", {unknown} untested" if unknown else "")
    if u.get("stuck_units"):
        note += f"; {u['stuck_units']} army units stuck at their factory"
    return val, note


@signal("expansion_capacity", "ability", "report", "0-1")
def expansion_capacity(st):
    """Could a builder put down a new factory right now? Share of sample points next to our
    builders where a T1 ground factory fits."""
    t = st.get("units", "build_tested")
    if not t:
        return None
    s = st.get("units", "build_sites", default=0)
    return s / t, f"{s}/{t} spots next to builders fit a factory"


@signal("army_rate", "ability", "report", "metal/s")
def army_rate(st):
    """How much ARMY metal per second this state could turn out right now: the SCARCEST of
    metal (income + bank over the horizon), energy (divided by the army's E/M cost ratio) and
    factory build power (x metal per build-power-second), each lab's support capped at what it
    can absorb (game_mechanics 2.5). Then scaled by unit-cap headroom."""
    e = st.row("eco")
    if e is None:
        return None
    H = st.H
    metal = e["metal_inc"] + e["metal"] / H
    em, mpbp, src = army_costs(st)
    energy = (e["energy_inc"] + e["energy"] / H) / em
    sides = {"metal": metal, "energy": energy}
    u = st.row("units")
    if u is not None:
        # fac_bp (newer tracker) is the build power that can reach a factory. Older rows
        # only have `bp`, all builders, which leaves the commander out.
        # Build power that can make things: factories (and nanos on them) whose units can get
        # out, plus mobile builders IF there is ground to build on (a new lab, more eco).
        # Older rows only have `bp`, all builders, which leaves the commander out.
        bp = None
        if "fac_bp_useful" in u:
            # Per factory: labs whose units can get out, support capped at what each absorbs.
            room = st.val("expansion_capacity")
            bp = u["fac_bp_useful"] + (u.get("mob_bp", 0) if room is None or room > 0 else 0)
        elif "fac_bp_open" in u:
            # Per-factory: only build power at labs whose units can get out.
            room = st.val("expansion_capacity")
            bp = u["fac_bp_open"] + (u.get("mob_bp", 0) if room is None or room > 0 else 0)
        elif "fac_bp" in u:
            # Older rows: one total, scaled by the share of labs that can get out.
            reach = st.val("production_reach")
            room = st.val("expansion_capacity")
            bp = (u["fac_bp"] * (1.0 if reach is None else reach)
                  + (u.get("mob_bp", 0) if room is None or room > 0 else 0))
        elif "bp" in u:
            bp = u["bp"] + (commander_bp(st) if st.row("cmdr") is not None else 0)
        if bp is not None:
            sides["bp"] = bp * mpbp
    binding = min(sides, key=sides.get)
    h = st.val("slot_headroom")
    rate = sides[binding] * (h if h is not None else 1.0)
    if u is not None and u.get("factory", 0) == 0:
        binding += "/nolab"
    note = ", ".join(f"{k} {v:.1f}" for k, v in sides.items())
    if h is not None and h < 1:
        binding += "+cap"
    st.army_binding = binding
    return rate, (f"binding: {binding} ({note}; cap x{h if h is not None else 1:.2f}; "
                  f"army E/M {em:.1f}, {mpbp:.3f} metal per bp-s from {src})")


def army_costs(st):
    """(energy per metal, metal per build-power-second, source) of what this team builds.
    Tracker fields if logged; else its own army composition priced from the unit catalog;
    else the config defaults."""
    em, mpbp = st.get("units", "army_em"), st.get("units", "army_m_per_bp")
    if em and mpbp:
        return em, mpbp, "tracker"
    comp = st.get("army", "comp")
    m = e = bt = 0.0
    for part in (comp or "-").split(","):
        name, _, n = part.partition(":")
        u = st.units.get(name)
        if u and u.get("buildtime"):
            k = int(n or 0)
            m, e, bt = m + k * u["metal"], e + k * u["energy"], bt + k * u["buildtime"]
    if m > 0 and bt > 0:
        return e / m, m / bt, "army mix"
    return st.p("army_em_default"), st.p("m_per_bp_default"), "defaults"


def commander_bp(st):
    for r in st.m.by_kind.get("def", []):
        if r.get("role") == "commander" and r.get("buildSpeed"):
            return r["buildSpeed"]
    return 300


@signal("spend_capacity", "ability", "report", "metal/s")
def spend_capacity(st):
    """How fast income can be spent on ANYTHING right now (game_mechanics 1.1: every job, eco
    included, draws BP x cost / build time, and pull is exactly that sum): the scarcest of
    metal available, what the builders are asking for (metal pull, interval average), and
    energy at the energy/metal ratio of what they are building. A permanent stall on this
    capacity is the ideal state (1.2); pull below income means income waits for placements."""
    e = st.row("eco")
    if e is None or "metal_pull" not in e:
        return None
    if "metal_pull_avg" not in e:
        # A single instant pull reading swings 2-4x between identical bots (mirror check,
        # 2026-09-24); only the interval average is steady enough to gate income on.
        return None, "needs the interval-averaged pull (tracker from 2026-09-24)"
    H = st.H
    avg = True
    pull = e.get("metal_pull_avg", e["metal_pull"])
    epull = e.get("energy_pull_avg", e.get("energy_pull", 0))
    einc = e.get("energy_inc_avg", e["energy_inc"])
    sides = {"metal": e.get("metal_inc_avg", e["metal_inc"]) + e["metal"] / H, "demand": pull}
    if pull > 0 and epull > 0:
        sides["energy"] = (einc + e["energy"] / H) / (epull / pull)
    binding = min(sides, key=sides.get)
    st.binding = binding
    note = ", ".join(f"{k} {v:.1f}" for k, v in sides.items())
    return sides[binding], (f"binding: {binding} ({note})"
                            + ("" if avg else "; pull is one instant reading (old tracker)"))


@signal("income_capital", "economy", "add", "metal")
def income_capital(st):
    """What the economy can put to use over the horizon, eco or army, at metal + energy/70
    (game_mechanics 2.3) -- the same scale as the assets it builds. Energy counts at the rate
    the builders actually use it alongside the metal they can spend (their own energy/metal
    mix), so energy nothing can use is not rewarded (the over-built energy of 11). Anything
    the bottleneck cannot use is kept at a discount (`surplus_value`): fixing the bottleneck
    would unlock it."""
    e = st.row("eco")
    if e is None:
        return None
    H, sv = st.H, st.p("surplus_value")
    avail = e["metal_inc"] + e["metal"] / H
    spend = st.val("spend_capacity")
    if spend is None:
        spend = avail
    spend = min(spend, avail)
    metal = H * (spend + sv * (avail - spend))
    # Energy: what goes with the metal spending, at the builders' own E/M mix.
    pull = e.get("metal_pull_avg", e.get("metal_pull", 0))
    epull = e.get("energy_pull_avg", e.get("energy_pull", 0))
    mix = epull / pull if pull > 0 and epull > 0 else army_costs(st)[0]
    e_avail = e.get("energy_inc_avg", e["energy_inc"]) + e["energy"] / H
    e_use = min(e_avail, spend * mix)
    energy = H * (e_use + sv * (e_avail - e_use)) / st.p("energy_per_metal")
    return metal + energy, (f"income {e['metal_inc']:.1f} m/s + {e['energy_inc']:.0f} e/s, bank "
                            f"{e['metal']:.0f} m; usable {spend:.1f} m/s + {e_use:.0f} e/s "
                            f"(E/M {mix:.1f}) = {metal:,.0f} + {energy:,.0f} metal-eq")


@signal("energy_stall", "economy", "mult", "x", applies=("income_capital",))
def energy_stall(st):
    """Share of the last 30 s spent energy-stalled. Weight 0 since v2: game_mechanics 1.2 says
    a controlled stall is the IDEAL state, and halving DRAGON_BOT's stall changed nothing
    (strategy_log 20260923_energy_lookahead). `waste` is the signal that matters."""
    s = st.get("eco", "stall_e")
    if s is None:
        return None
    return 1 - st.p("stall_penalty") * s, f"stalled {s * 100:.0f}% of the interval"


def _prev_row(st, kind):
    """The row of `kind` one snapshot before the current one."""
    cur = st.row(kind)
    if cur is None:
        return None, None
    prev = None
    for r in st.m.by_kind.get(kind, []):
        if r["frame"] >= cur["frame"]:
            break
        prev = r
    return cur, prev


@signal("waste", "economy", "report", "metal/s")
def waste(st):
    """Resources lost over the storage cap in the last interval (game_mechanics 1.3, 10):
    produced - used - stored, in metal-equivalent per second (energy / 70, the 2.3
    convention). The replay in 11 had the bot wasting 10-28% of its energy."""
    cur, prev = _prev_row(st, "eco")
    if cur is None or prev is None or "energy_produced" not in cur:
        return None
    dt = (cur["frame"] - prev["frame"]) / FPS
    if dt <= 0:
        return None
    out = {}
    for r in ("metal", "energy"):
        prod = cur[f"{r}_produced"] - prev[f"{r}_produced"]
        used = cur[f"{r}_used"] - prev[f"{r}_used"]
        lost = max(0.0, prod - used - (cur[r] - prev[r]))
        out[r] = (lost, lost / prod if prod > 0 else 0.0)
    rate = (out["metal"][0] + out["energy"][0] / st.p("energy_per_metal")) / dt
    return rate, (f"wasted {out['metal'][1] * 100:.0f}% of metal, {out['energy'][1] * 100:.0f}% of "
                  f"energy produced in the last {dt:.0f}s")


@signal("reclaimable", "economy", "report", "metal")
def reclaimable(st):
    """Wreck metal lying near the base (game_mechanics 1.4: worth taking only with BP to
    spend it). The tracker sums wrecks within 1500 elmos of the start only."""
    return st.get("eco", "wreck_metal")


@signal("stranded_bp", "ability", "report", "0-1")
def stranded_bp(st):
    """Share of build power sitting in idle nano turrets (game_mechanics 2.4: a finished grid's
    nanos should be airlifted to where the work is)."""
    u = st.row("units")
    if u is None or "nano_idle_bp" not in u or not u.get("bp"):
        return None
    return u["nano_idle_bp"] / u["bp"], f"{u['nano_idle_bp']:.0f} of {u['bp']:.0f} BP in idle nanos"


@signal("tech_level", "ability", "report", "x")
def tech_level(st):
    """Highest factory tech level (game_mechanics 4): what the bot can build, not just has."""
    u = st.row("units")
    if u is None:
        return None
    if "max_tech" in u:
        return u["max_tech"]
    return 2 if u.get("factory_t2", 0) else 1


@signal("home_guard", "exposure", "report", "metal")
def home_guard(st):
    """The local reserve a raid meets (game_mechanics 7.1): armed units and defences near the
    base that can hit ground. Reported; not yet in phi (calibrate against raid games first)."""
    u = st.row("units")
    if u is None or "home_guard_gnd_mv" not in u:
        return None
    eco = (u.get("mex_mv", 0) or 0) + (u.get("energy_mv", 0) or 0)
    return u["home_guard_gnd_mv"], (f"{u['home_guard_gnd_mv']:.0f} metal can hit ground, "
                                    f"{u['home_guard_air_mv']:.0f} can hit air, guarding "
                                    f"{eco:.0f} metal of mex/energy")


@signal("role_coverage", "materiel", "report", "0-1")
def role_coverage(st):
    """Share of the standing roles game_mechanics 7 calls for that exist: dedicated AA
    (baseline at all times, 7.3), a home guard (7.1), rez/repair (mandatory, 1.4), mobile
    radar/jammer (7) and air transports (2.1, 5)."""
    u = st.row("units")
    if u is None or "rez" not in u:
        return None
    roles = {"AA": u.get("aa_dedicated", 0) > 0, "home guard": u.get("home_guard_gnd_mv", 0) > 0,
             "rez": u.get("rez", 0) > 0, "radar/jammer": u.get("util_intel", 0) > 0,
             "transport": u.get("air_trans", 0) > 0}
    have = [k for k, v in roles.items() if v]
    return len(have) / len(roles), ("has " + (", ".join(have) or "none") + "; missing "
                                    + (", ".join(k for k, v in roles.items() if not v) or "none"))


# ── Awareness ────────────────────────────────────────────────────────────────

@signal("warned_rate", "awareness", "report", "0-1")
def warned_rate(st):
    """Share of enemy arrivals at the base that were seen at least `warned_lead_s` earlier."""
    n = st.get("intel", "arrivals_n")
    if n is not None:
        if n == 0:
            return None, "no enemy has reached the base"
        w = st.get("intel", "arrivals_warned_n", default=0)
        return w / n, f"{w}/{n} arrivals warned, median lead {st.get('intel', 'lead_med', default=0) / FPS:.0f}s"
    r = st.m.ev_row("first_enemy_near_base")
    if r is None or r["frame"] > st.f or "lead_frames" not in r:
        return None
    ok = r["lead_frames"] >= st.p("warned_lead_s") * FPS
    return (1.0 if ok else 0.0), (f"first raider only (old tracker): seen {r['lead_frames'] / FPS:.0f}s "
                                  f"/ {r.get('warned_dist', 0):.0f} elmos out")


@signal("fresh_intel", "awareness", "report", "0-1")
def fresh_intel(st):
    """Age-weighted knowledge of the zones that matter (home, corridor, enemy base, mex fields)."""
    w = st.p("fresh_zone_weights")
    parts = {z: st.get("intel", f"fresh_{z}") for z in w}
    parts = {z: (v if v is not None and v >= 0 else None) for z, v in parts.items()}   # -1 = no zone
    if all(v is None for v in parts.values()):
        return None
    tot = sum(w[z] for z, v in parts.items() if v is not None)
    val = sum(w[z] * v for z, v in parts.items() if v is not None) / tot
    return val, ", ".join(f"{z} {v:.2f}" for z, v in parts.items() if v is not None)


@signal("coverage_now", "awareness", "report", "0-1")
def coverage_now(st):
    """Context only: share of the map in LOS now, on radar now, and ever seen."""
    i = st.row("intel")
    if i is None:
        return None
    return i["los_frac"], (f"LOS {i['los_frac'] * 100:.0f}%, radar {i.get('radar_frac', 0) * 100:.0f}%, "
                           f"ever seen {i.get('explored_frac', 0) * 100:.0f}%")


def _total_mv(st, opp):
    parts = [st.get("units", k, opp=opp) for k in ("army_mv", "defense_mv", "mex_mv", "energy_mv")]
    return None if all(p is None for p in parts) else sum(p or 0 for p in parts)


@signal("enemy_known", "awareness", "report", "0-1")
def enemy_known(st):
    """Share of the enemy's real value we know about (privileged: divided by their own count)."""
    theirs = _total_mv(st, opp=True)
    known = st.get("intel", "believed_mv")
    how = "remembered"
    if known is None:
        known, how = st.get("intel", "vis_mv"), "visible now (no memory in this tracker)"
    if known is None or not theirs:
        return None
    return min(1.0, known / theirs), f"{known:.0f} of {theirs:.0f} metal, {how}"


@signal("surprise_losses", "awareness", "report", "metal")
def surprise_losses(st):
    """Metal lost to attackers we had not seen: the awareness share of our losses."""
    mv = st.get("combat", "lost_unseen_mv")
    if mv is None:
        return None
    tot = st.get("combat", "lost_enemy_mv", default=0)
    na = st.get("combat", "lost_noattr_mv", default=0)
    return mv, (f"{mv:.0f} of {tot:.0f} enemy-attributed metal lost to unseen attackers; "
                f"{na:.0f} lost with no attacker at all (self-d, or hidden kills)")


@signal("tech_foresight", "awareness", "report", "0-1")
def tech_foresight(st):
    """For each threat class the enemy has (air, nukes, T2): how soon after they had it did
    we see it? 1 = at once, 0 = `foresight_window_s` or more late / never. Privileged."""
    win = st.p("foresight_window_s") * FPS
    classes = {
        "air": (st.first_frame("army", lambda r: (comp_share_row(st, r) or 0) > 0, opp=True),
                st.ev("first_enemy_air")),
        "nuke": (st.first_frame("units", lambda r: r.get("silo", 0) > 0, opp=True),
                 st.ev("first_enemy_nuke")),
    }
    if st.opp.ev("first_t2_factory") is not None and "first_enemy_t2" in st.m.events:
        classes["t2"] = (st.ev("first_t2_factory", opp=True), st.ev("first_enemy_t2"))
    scores, notes = [], []
    for c, (had, seen) in classes.items():
        if had is None:
            continue
        late = (seen if seen is not None else st.f) - had
        scores.append(clamp(1 - late / win, 0, 1))
        hurt = ""
        if c == "air":
            t = st.first_frame("combat", lambda r: r.get("lost_to_air", 0) > 0)
            if t is not None and (seen is None or t < seen):
                hurt = f", first loss to air {mmss(t)} BEFORE it was seen"
        notes.append(f"{c}: they had it {mmss(had)}, seen "
                     f"{mmss(seen) if seen is not None else 'never'}{hurt}")
    if not scores:
        return None
    return sum(scores) / len(scores), "; ".join(notes)


def comp_share_row(st, row):
    comp = row.get("comp")
    if not comp or comp == "-":
        return None
    return sum(1 for part in comp.split(",") if st.units.get(part.partition(":")[0], {}).get("air"))


@signal("denial", "awareness", "report", "0-1")
def denial(st):
    """How much of our value the enemy sees right now (lower is better). Privileged."""
    ours, seen = _total_mv(st, opp=False), st.get("intel", "vis_mv", opp=True)
    if not ours or seen is None:
        return None
    return min(1.0, seen / ours), f"enemy sees {seen:.0f} of our {ours:.0f} metal"


# ── Exposure ─────────────────────────────────────────────────────────────────

@signal("value_at_risk", "exposure", "sub", "metal")
def value_at_risk(st):
    """Metal that a threat could take: factories outside dedicated AA (at a prior probability
    before enemy air is known: a standing baseline is needed at ALL times, game_mechanics
    7.3), factories outside anti-nuke while they have a silo, and a commander with enemies
    near and no friends -- whose loss is the GAME (1.5, 9), so its stake is everything else
    phi counts. Discounted by how often we see attacks coming (warned_rate)."""
    u = st.row("units")
    if u is None:
        return None
    fac, t2 = u.get("factory", 0), u.get("factory_t2", 0)
    fac_mv = (fac - t2) * st.p("fac_t1_mv") + t2 * st.p("fac_t2_mv")
    risk, parts = 0.0, []
    if fac and "fac_aa_ded_cover" in u:
        p_air = 1.0 if enemy_has_air(st) else st.p("air_prior")
        r = p_air * fac_mv * (1 - u["fac_aa_ded_cover"] / fac)
        if r > 0:
            risk += r
            parts.append(f"air {r:.0f} ({fac - u['fac_aa_ded_cover']}/{fac} labs without AA"
                         + ("" if p_air == 1 else ", no enemy air known yet") + ")")
    nuke = (st.get("units", "silo", opp=True, default=0) or 0) > 0 or st.ev("first_enemy_nuke") is not None
    if fac and nuke and "fac_antinuke_cover" in u:
        r = fac_mv * (1 - u["fac_antinuke_cover"] / fac)
        if r > 0:
            risk += r
            parts.append(f"nuke {r:.0f}")
    c = st.row("cmdr")
    if c is not None and c.get("enemy_near", 0) > 0 and c.get("friends_near", 0) == 0:
        stake = sum(st.val(n) or 0 for n in ("army_value", "defense_value", "income_capital"))
        r = st.p("commander_exposed_p") * stake * (1 - 0.5 * c.get("hp", 1))
        risk += r
        parts.append(f"commander {r:.0f} ({c['enemy_near']} enemies near, alone)")
    w = st.val("warned_rate")
    w = st.p("warned_prior") if w is None else w
    risk *= 1 - st.p("warn_discount") * w
    return risk, (", ".join(parts) + f"; x{1 - st.p('warn_discount') * w:.2f} for warning") if parts else "none"


# ── Attrition (flows, not state: reported for diagnosis, never in phi) ───────

@signal("trade_ratio", "attrition", "report", "x")
def trade_ratio(st):
    """Metal we destroyed per metal the enemy destroyed of ours (privileged: their own losses)."""
    lost = st.get("combat", "lost_enemy_mv")
    killed = st.get("combat", "lost_enemy_mv", opp=True)
    src = "their losses"
    if killed is None:
        killed, src = st.get("combat", "kills_seen_mv"), "kills we saw"
    if lost is None or killed is None or (lost == 0 and killed == 0):
        return None
    return killed / max(lost, 1), f"killed {killed:.0f} / lost {lost:.0f} metal ({src})"


# ── Scoring ──────────────────────────────────────────────────────────────────

def terminal(m, opp, frame):
    """'lost' / 'won' if a commander was KILLED (not the end-of-match self-destruct) by now."""
    for who, tag in ((m, "lost"), (opp, "won")):
        r = who.ev_row("commander_lost")
        if r and r["frame"] <= frame and r.get("killer") not in (None, "?"):
            return tag
    return None


def legacy_score(st):
    """The current adjudicator's formula, for comparison: army_mv + 60 x metal_inc."""
    a, i = st.get("units", "army_mv"), st.get("eco", "metal_inc")
    return None if a is None or i is None else a + 60 * i


def score_state(m, opp, frame, cfg, units):
    st = State(m, opp, frame, cfg, units)
    st.binding = st.army_binding = None
    w = {k: v.get("weight", 0) for k, v in cfg["signals"].items()}
    comps, skipped = {}, []
    mult = {}
    for s in SIGNALS:
        v = st.val(s.name)
        comps[s.name] = {"value": v, "note": st.note(s.name), "role": s.role,
                         "category": s.category, "weight": w.get(s.name, 0)}
        if v is None:
            skipped.append(s.name)
        elif s.role == "mult" and w.get(s.name):
            for t in s.applies:
                mult[t] = mult.get(t, 1.0) * (1 + w[s.name] * (v - 1))
    cats = {c: 0.0 for c in ("materiel", "economy", "exposure")}
    phi = 0.0
    for s in SIGNALS:
        c = comps[s.name]
        if c["value"] is None or s.role not in ("add", "sub"):
            continue
        contrib = c["weight"] * c["value"] * (mult.get(s.name, 1.0) if s.role == "add" else 1)
        if s.role == "sub":
            contrib = -contrib
        c["contribution"] = contrib
        cats[s.category] = cats.get(s.category, 0.0) + contrib
        phi += contrib
    aw = [comps[n]["value"] for n in ("warned_rate", "fresh_intel", "enemy_known", "tech_foresight")
          if comps[n]["value"] is not None]
    cats["awareness"] = sum(aw) / len(aw) if aw else None
    cats["ability"] = comps["army_rate"]["value"]
    cats["spend"] = comps["spend_capacity"]["value"]
    cats["attrition"] = comps["trade_ratio"]["value"]
    has_data = st.row("units") is not None and st.row("eco") is not None
    term = terminal(m, opp, frame)
    return {"frame": frame, "phi": 0.0 if term == "lost" else (phi if has_data else None),
            "terminal": term, "legacy": legacy_score(st), "binding": st.binding,
            "army_binding": st.army_binding,
            "categories": cats, "components": comps, "skipped": skipped}


def score_result(result, frames=None, cfg=None):
    """{team: {bot, config_version, checkpoints: [...], tempo}} for both teams."""
    cfg = cfg or load_config()
    frames = frames or cfg["checkpoints"]
    units = load_units(result)
    out = {}
    for t in (0, 1):
        m, opp = Match(result, t), Match(result, 1 - t)
        cps = [score_state(m, opp, f, cfg, units) for f in frames]
        vals = [c["phi"] for c in cps if c["phi"] is not None]
        out[t] = {"bot": result.get(f"bot{t}_name"), "config_version": cfg["version"],
                  "checkpoints": cps,
                  # tempo: mean phi over the checkpoints reached (being strong early counts)
                  "tempo": sum(vals) / len(vals) if vals else None}
    return out


def phi_summary(result, cfg=None):
    """Compact form for bot_testing.py's result: {team: {frame: phi}}."""
    s = score_result(result, cfg=cfg)
    return {"config_version": s[0]["config_version"],
            **{str(t): {str(c["frame"]): (round(c["phi"]) if c["phi"] is not None else None)
                        for c in s[t]["checkpoints"]} for t in (0, 1)}}


# ── Report ───────────────────────────────────────────────────────────────────

def _fmt(v, unit=""):
    if v is None:
        return "-"
    if unit in ("0-1", "x"):
        return f"{v:.2f}"
    if unit == "metal/s":
        return f"{v:.1f}"
    return f"{v:,.0f}"


def print_report(result, scored, detail=None, ref=None):
    print(f"winner: {result.get('winner')} ({result.get('winner_method')}), "
          f"config v{scored[0]['config_version']}")
    frames = [c["frame"] for c in scored[0]["checkpoints"]]
    for t in (0, 1):
        s = scored[t]
        print(f"\n=== Team {t}: {s['bot']} ===")
        print(f"  {'':<22}" + "".join(f"{mmss(f):>12}" for f in frames))
        rows = [("phi", "phi", ""), ("  materiel", "materiel", ""), ("  economy", "economy", ""),
                ("  exposure", "exposure", ""), ("spend capacity (m/s)", "spend", "metal/s"),
                ("army rate (metal/s)", "ability", "metal/s"),
                ("awareness (0-1)", "awareness", "0-1"), ("trade ratio", "attrition", "x"),
                ("legacy score", "legacy", "")]
        for label, key, unit in rows:
            vals = []
            for c in s["checkpoints"]:
                v = c[key] if key in ("phi", "legacy") else c["categories"].get(key)
                if key == "phi" and c["terminal"]:
                    vals.append(c["terminal"].upper())
                elif c["phi"] is None and not c["terminal"]:
                    vals.append("-")          # no data this late (match ended earlier)
                else:
                    vals.append(_fmt(v, unit))
            print(f"  {label:<22}" + "".join(f"{v:>12}" for v in vals))
        for label, key in (("spend binding", "binding"), ("army binding", "army_binding")):
            print(f"  {label:<22}" + "".join(
                f"{(c.get(key) or '-') if c['phi'] is not None else '-':>12}" for c in s["checkpoints"]))
        if s["tempo"] is not None:
            print(f"  tempo (mean phi): {s['tempo']:,.0f}")
        if ref:
            print_ref(s, ref)
        cps = [c for c in s["checkpoints"] if c["phi"] is not None and not c["terminal"]]
        pick = None
        if detail is not None:
            pick = next((c for c in s["checkpoints"] if c["frame"] == detail), None)
        elif cps:
            pick = cps[-1]
        if pick:
            print_detail(pick)


def print_detail(c):
    print(f"\n  signals at {mmss(c['frame'])}:")
    for s in SIGNALS:
        d = c["components"][s.name]
        contrib = d.get("contribution")
        tag = f"{contrib:+,.0f}" if contrib is not None else s.role
        print(f"    {s.name:<17} {_fmt(d['value'], s.unit):>9} {s.unit:<7} [{tag:>8}]  {d['note'] or ''}")
    if c["skipped"]:
        print(f"    skipped (no data in this result): {', '.join(c['skipped'])}")


def print_ref(s, ref):
    """Each category as a % of the reference team at the same frame."""
    by = {c["frame"]: c for c in ref["checkpoints"]}
    print(f"  vs reference {ref['bot']}:")
    for key in ("phi", "materiel", "economy", "ability", "awareness"):
        cells = []
        for c in s["checkpoints"]:
            r = by.get(c["frame"])
            a = c[key] if key == "phi" else c["categories"].get(key)
            b = (r[key] if key == "phi" else r["categories"].get(key)) if r else None
            cells.append(f"{100 * a / b:.0f}%" if a is not None and b else "-")
        print(f"    {key:<20}" + "".join(f"{v:>12}" for v in cells))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("result", help="result JSON saved with bot_testing.py --save-result")
    ap.add_argument("--frames", help="comma-separated game frames (default: config checkpoints)")
    ap.add_argument("--detail", type=int, help="frame to list every signal at (default: last scored)")
    ap.add_argument("--ref", help="reference result as PATH[:TEAM] (default team 0)")
    ap.add_argument("--config", default=str(CONFIG_PATH))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    cfg = load_config(args.config)
    result = json.loads(Path(args.result).read_text(encoding="utf-8"))
    frames = [int(x) for x in args.frames.split(",")] if args.frames else None
    if args.detail is not None and frames and args.detail not in frames:
        frames.append(args.detail)
    elif args.detail is not None and not frames:
        frames = sorted(set(cfg["checkpoints"]) | {args.detail})
    scored = score_result(result, frames, cfg)
    if args.json:
        json.dump(scored, sys.stdout, indent=2, default=str)
        return
    ref = None
    if args.ref:
        path, _, team = args.ref.rpartition(":") if args.ref[-2:-1] == ":" else (args.ref, "", "0")
        ref = score_result(json.loads(Path(path).read_text(encoding="utf-8")), frames, cfg)[int(team)]
    print_report(result, scored, args.detail, ref)


if __name__ == "__main__":
    main()
