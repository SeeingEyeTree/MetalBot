"""eco_ledger.py -- where did the metal and the build power go in the opening?

    python eco_ledger.py <result.json | infolog.txt> [--team 0] [--until 7.5]

Reads the stats tracker's [TRK] eco/units rows (and the macro's [MC] BP lines when the log
has them) and prints, every 30 game-seconds up to --until minutes:

  * metal used so far, bank, income, pull, energy float, metal stall
  * what the metal bought: mex, wind (energy), nanos, cons, other (labs, air cons, army,
    anything the tracker does not itemise = used - the rest)
  * build power: nano BP split by what the nanos were doing, and mobile builders
    building / walking / idle (BP lines are logged every 30 s of game time)

Class costs not in the tracker rows use the unit costs in the log (cornanotc 230m,
con bot 120m); mex and energy come from the tracker's own `mex_mv` / `energy_mv`.
Input may be a bot_testing result (`--save-result`) or a raw infolog; for an infolog the
LAST game in it is read.
"""
import argparse
import json
import re
import sys

NANO_M = 230.0
CON_M = 120.0
FPS = 30


def parse_fields(text):
    d = {}
    for tok in text.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            d[k] = v
    return d


def num(d, k, default=0.0):
    try:
        return float(d.get(k, default))
    except (TypeError, ValueError):
        return default


def load(path, team):
    """-> (rows_by_kind: {kind: {frame: dict}}, bp_lines: [(frame, text)])"""
    rows = {}
    bp = []
    if path.lower().endswith(".json"):
        data = json.load(open(path, encoding="utf-8"))
        for r in data.get("tracker_timeline", []):
            if r.get("team") != team:
                continue
            rows.setdefault(r["kind"], {})[int(r["frame"])] = r
        for line in data.get("log_excerpt", []) or []:
            if isinstance(line, str):
                for ln in line.splitlines():
                    m = re.search(r"\[f=0*(\d+)\] \[MC\] BP (.*)", ln)
                    if m:
                        bp.append((int(m.group(1)), m.group(2)))
        return rows, bp
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    start = 0
    for i, ln in enumerate(lines):
        if "[TRK] init" in ln:
            start = i
    for ln in lines[start:]:
        m = re.search(r"\[f=0*(\d+)\] \[TRK\] (eco|units|cmdr|army|combat|intel) (.*)", ln)
        if m:
            d = parse_fields(m.group(3))
            if int(d.get("team", team)) == team:
                rows.setdefault(m.group(2), {})[int(d.get("frame", m.group(1)))] = d
            continue
        m = re.search(r"\[f=0*(\d+)\] \[MC\] BP (.*)", ln)
        if m:
            bp.append((int(m.group(1)), m.group(2)))
    return rows, bp


def parse_bp(text):
    """'4:00 nano eco=3/600 reclaim=2/400 | aircon  | con build=2/170 walk=3/255 | com walk=1/300 | frames ...'
    -> {'nano': {'eco': (n, bp)}, 'aircon': {...}, 'con': {...}, 'com': {...}}"""
    out = {}
    for sec in text.split("|"):
        sec = sec.strip()
        m = re.match(r"(?:\d+:\d+\s+)?(nano|aircon|con|com)\b(.*)", sec)
        if not m:
            continue
        states = {}
        for st, n, b in re.findall(r"(\w+)=(\d+)/(\d+)", m.group(2)):
            states[st] = (int(n), int(b))
        out[m.group(1)] = states
    return out


def bp_sum(states, *names):
    return sum(states.get(n, (0, 0))[1] for n in names)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--team", type=int, default=0)
    ap.add_argument("--until", type=float, default=7.5, help="game minutes (default 7.5)")
    a = ap.parse_args()

    rows, bp = load(a.path, a.team)
    eco, units = rows.get("eco", {}), rows.get("units", {})
    if not eco:
        sys.exit("no [TRK] eco rows found for team %d" % a.team)
    bp_by_frame = {}
    for f, t in bp:
        bp_by_frame[f] = parse_bp(t)

    last = int(a.until * 60 * FPS)
    print("time   used   bank   inc  pull  eFlt stall | mex#  m    wind#  m    nano#  m     con#  m   other_m | nanoBP(bld/rec/oth)  mobBP(bld/walk/idle)")
    for f in sorted(eco):
        if f > last:
            break
        e = eco[f]
        u = units.get(f, {})
        used = num(e, "metal_used")
        mex_m, wind_m = num(u, "mex_mv"), num(u, "energy_mv")
        nanos, cons = num(u, "nano"), num(u, "con")
        nano_m, con_m = nanos * NANO_M, cons * CON_M
        other = used - mex_m - wind_m - nano_m - con_m
        b = bp_by_frame.get(f) or bp_by_frame.get(f - 1) or bp_by_frame.get(f + 1)
        if b:
            n = b.get("nano", {})
            nano_bp = "%d/%d/%d" % (bp_sum(n, "eco", "unit"), bp_sum(n, "reclaim"),
                                   bp_sum(n, "idle", "other", "park", "lab_idle", "guard"))
            mobs = {}
            for who in ("aircon", "con", "com"):
                for st, (cnt, bpv) in b.get(who, {}).items():
                    mobs[st] = mobs.get(st, 0) + bpv
            mob_bp = "%d/%d/%d" % (mobs.get("build", 0), mobs.get("walk", 0), mobs.get("idle", 0))
        else:
            nano_bp = mob_bp = "-"
        print("%2d:%02d %6.0f %6.0f %5.1f %5.1f %4.2f %4.2f | %3d %5.0f  %3d %5.0f  %3d %5.0f  %3d %5.0f %7.0f | %-20s %s" % (
            f // 1800, (f // 30) % 60, used, num(e, "metal"), num(e, "metal_inc"), num(e, "metal_pull"),
            num(e, "float_e"), num(e, "stall_m"),
            num(u, "mex"), mex_m, num(u, "energy"), wind_m, nanos, nano_m, cons, con_m, other,
            nano_bp, mob_bp))

    print("\nComposition of metal used (share of total) at checkpoints:")
    for minute in (2, 3, 4, 5, 6, 7, 7.5):
        f = int(minute * 1800)
        e, u = eco.get(f), units.get(f)
        if not e or not u or f > last:
            continue
        used = num(e, "metal_used") or 1.0
        parts = [("mex", num(u, "mex_mv")), ("wind", num(u, "energy_mv")),
                 ("nano", num(u, "nano") * NANO_M), ("con", num(u, "con") * CON_M)]
        parts.append(("other", used - sum(p[1] for p in parts)))
        print("  %4.1f min  used %6.0f : %s" % (minute, used,
              "  ".join("%s %4.0f%% " % (k, 100.0 * v / used) for k, v in parts)))


if __name__ == "__main__":
    main()
