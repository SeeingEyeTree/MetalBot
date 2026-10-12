"""eco_scaling.py -- economy scaling benchmark (army share 0) and a model of scaling at other army spend rates.

    python eco_scaling.py run [--bot candidates/ECO_BENCH] [--label base] [--end-minutes 17]
    python eco_scaling.py report eco_bench_runs/doubling/eco0.json [--team 0]
    python eco_scaling.py run --schedule 3:0.2                        (candidates/ARMY_BENCH: spine army share follows min:share,...)
    python eco_scaling.py shares result.json --baseline r1.json r2.json    (does army spend follow the schedule? is income what the math says?)
    python eco_scaling.py spread run1.json run2.json ...    (replicate spread: use this, not one number at 15:00)
    python eco_scaling.py model [--t2 1.75] [--from-run eco_bench_runs/doubling/eco0.json]

`run`    plays <bot> vs INACTIVE_BOT (nothing attacks, so only the economy is measured) and reports.
         candidates/ECO_BENCH = LINE_CLICK_v13d's macro with SPINE=false and no-op lab/unit controllers,
         i.e. army share 0: everything the bot earns goes into eco.  Any bot folder can be benched; a
         bot that builds army will simply show a slower curve.
`report` doubling times from a result json: time to reach each metal-income milestone (100, 200, ... m/s),
         log-linear doubling time over 4-10 / 10-15 / 12-17 min, and PASS/FAIL against TARGET (1.6-1.9 min).
`model`  income and banked army value at 5/8/10/12/15 min for army spend shares 0..60%.

THE MODEL (a deliberately simple one -- see the caveats in the printout):
    dI/dt = I * ln2 / T2 * (1 - a)       while t < T_CAP-limited ceiling, a = share of metal spent on army
    I(t0) = I0 at t0 = 4:00 (the end of the opening, where growth becomes exponential)
    army value = a * integral(I dt) from the moment the share is switched on (default 4:00)
It assumes reinvested metal compounds at a fixed rate (a unit of income costs a fixed amount of metal and
pays back in a fixed time), so removing a share `a` of the spend slows the exponent by exactly (1-a).
That is the first-order truth for mex/wind/fusion growth; it ignores that army also protects the eco,
that eco growth stalls against map/unit-cap ceilings, and that the build-power supply is also finite.
"""
import argparse
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ARMY_SPINE_DEFAULTS = ("LAB_GATE_AV = false, MAX_OPENING = 4, NANO_BATCH = 12, NANO_INFLIGHT_MAX = 20, "
                       "EXPAND_FROM = 3600")   # capacity ahead of demand (bench)
TARGET = (1.6, 1.9)               # min per doubling the user expects from a correctly-scaling eco
T0_MIN = 4.0                      # growth is roughly exponential from here (opening is over)
MILESTONES = (100, 200, 400, 800, 1600, 3200)
WINDOWS = ((4, 10), (10, 15), (12, 17))


def curve(path, team=0):
    """-> [(game_minute, metal_inc_avg, metal_used, metal_stored)] from a bot_testing result json."""
    d = json.load(open(path, encoding="utf-8"))
    out = []
    for r in d.get("tracker_timeline", []):
        if r.get("kind") == "eco" and r["team"] == team and int(r["frame"]) % 900 == 0:
            out.append((int(r["frame"]) / 1800.0, float(r.get("metal_inc_avg", 0)),
                        float(r.get("metal_used", 0)), float(r.get("metal", 0))))
    return sorted(out)


def fit_doubling(pts, lo, hi):
    """log-linear least squares of income over [lo, hi] minutes -> (min per doubling, R^2) or None."""
    xs = [(t, math.log(i)) for t, i, _, _ in pts if lo <= t <= hi and i > 1]
    if len(xs) < 4:
        return None
    n = len(xs)
    mx = sum(x for x, _ in xs) / n
    my = sum(y for _, y in xs) / n
    sxx = sum((x - mx) ** 2 for x, _ in xs)
    sxy = sum((x - mx) * (y - my) for x, y in xs)
    syy = sum((y - my) ** 2 for _, y in xs)
    if sxy <= 0:
        return None
    return math.log(2) / (sxy / sxx), (sxy * sxy) / (sxx * syy)


def report(path, team=0):
    pts = curve(path, team)
    if not pts:
        sys.exit("no eco rows for team %d in %s" % (team, path))
    print("\n%s  team %d" % (path, team))
    print("  income (m/s, 30 s average):  " + "  ".join("%g:%d" % (t, i) for t, i, _, _ in pts if t in (4, 6, 8, 10, 12, 15, 17)))
    print("  milestones (first time income >= X):")
    prev = None
    for m in MILESTONES:
        hit = next((t for t, i, _, _ in pts if i >= m), None)
        gap = "" if hit is None or prev is None else "   +%.2f min since previous" % (hit - prev)
        print("    %5d m/s  %s%s" % (m, "not reached" if hit is None else "%5.2f min" % hit, gap))
        prev = hit if hit is not None else prev
    print("  doubling time, log-linear fit (target %.1f-%.1f min):" % TARGET)
    for lo, hi in WINDOWS:
        f = fit_doubling(pts, lo, hi)
        if not f:
            print("    %2d-%2d min: not enough data" % (lo, hi))
            continue
        ok = "PASS" if TARGET[0] <= f[0] <= TARGET[1] else ("faster than target" if f[0] < TARGET[0] else "SLOW")
        print("    %2d-%2d min: %.2f min/doubling  (R^2 %.2f)  %s" % (lo, hi, f[0], f[1], ok))
    floats = [(t, s) for t, _, _, s in pts if s > 5000]
    if floats:
        print("  metal banked > 5000 at: %s min (spend is not keeping up with income)" % ", ".join("%g" % t for t, _ in floats[:12]))
    sanity(json.load(open(path, encoding="utf-8")), team)
    return pts


def spread(paths):
    """Replicates of one bot: when does income reach X (steady) vs what is it at minute M (a fixed-time sample
    through a steep climb: a 30 s shift in the surge reads as 2x at 15:00)."""
    P = [curve(p) for p in paths]
    print("\n%d runs" % len(P))
    for x in (400, 800, 1600, 3200, 5000):
        v = [next((t for t, i, _, _ in p if i >= x), None) for p in P]
        print("  first >= %4d m/s at min: %s%s" % (x, ", ".join("-" if t is None else "%.1f" % t for t in v),
              "   range %.1f min" % (max(v) - min(v)) if all(v) else ""))
    for m in (8, 10, 12, 15, 17):
        v = [next((i for t, i, _, _ in p if t >= m), 0) for p in P]
        print("  income at %2d:00: %s   max/min %.2f" % (m, " ".join("%5.0f" % x for x in v), max(v) / max(min(v), 1)))


def parse_schedule(text):
    """'0:0,5:0.3,8:0.8' -> [(0.0, 0.0), (5.0, 0.3), (8.0, 0.8)] (game minute, share), ascending."""
    out = []
    for part in text.split(","):
        m, _, s = part.partition(":")
        out.append((float(m), float(s)))
    return sorted(out)


def share_at(sched, minute):
    s = 0.0
    for m, v in sched:
        if minute >= m:
            s = v
    return s


def _series(d, team, kind, key):
    return sorted((int(r["frame"]) / 1800.0, float(r.get(key, 0))) for r in d.get("tracker_timeline", [])
                  if r.get("kind") == kind and r["team"] == team)


def _at(series, minute):
    """Value of a cumulative series at `minute` (linear between samples, clamped at the ends)."""
    if not series:
        return 0.0
    if minute <= series[0][0]:
        return series[0][1]
    for (t0, v0), (t1, v1) in zip(series, series[1:]):
        if t0 <= minute <= t1:
            return v0 + (v1 - v0) * (minute - t0) / max(t1 - t0, 1e-9)
    return series[-1][1]


def shares(path, sched, baseline=None, lag=0.0, team=0):
    """Check that army metal spend follows the schedule, and that income follows the math."""
    d = json.load(open(path, encoding="utf-8"))
    spent = _series(d, team, "bench", "army_spent")
    used = _series(d, team, "eco", "metal_used")
    if not spent:
        print("\nno [TRK] bench rows: the bot has no ARMY_BENCH unit controller")
        return
    end = min(spent[-1][0] - lag, used[-1][0])
    marks = sorted(set([0.0] + [m for m, _ in sched] + [end]))
    marks = [m for m in marks if m <= end]
    print("\narmy share adherence  (%s)  target = spine army_share; actual = army metal finished / metal used" % path)
    print("  army spend = finished units + the built share of units in progress (bench unit controller)" + (", shifted %.2f min" % lag if lag else ""))
    print("   window        target   actual (of metal used)   of income   verdict")
    inc = _series(d, team, "eco", "metal_inc_avg")
    bad = 0
    for a, b in zip(marks, marks[1:]):
        if b - a < 0.5:
            continue
        tgt = share_at(sched, a + 1e-6)
        du = _at(used, b) - _at(used, a)
        ds = _at(spent, b + lag) - _at(spent, a + lag)
        di = sum(v * 30 for t, v in inc if a <= t < b)              # samples are 30 s apart
        act = ds / du if du > 0 else float("nan")
        act_i = ds / di if di > 0 else float("nan")
        ok = abs(act - tgt) <= max(0.07, 0.25 * tgt)
        bad += not ok
        print("  %5.1f-%5.1f   %4.0f%%     %5.1f%%                  %5.1f%%     %s" % (a, b, tgt * 100, act * 100, act_i * 100,
              "ok" if ok else ("OVER target" if act > tgt else "UNDER target")))
    print("  => %s" % ("army spend follows the schedule in every window" if not bad else
                      "%d window(s) off target: the share does not control the spend there" % bad))
    if baseline:
        base = [curve(p, team) for p in baseline]
        n = min(len(b) for b in base)
        mean = [(base[0][i][0], sum(b[i][1] for b in base) / len(base)) for i in range(n)]
        meas = {t: i for t, i, _, _ in curve(path, team)}
        t_on = next((m for m, s in sched if s > 0), None)
        if t_on is None:
            return
        pts = [(t, i) for t, i in mean if t >= t_on and i > 1]
        if len(pts) < 2 or t_on not in meas and not any(abs(t - t_on) < 0.26 for t in meas):
            return
        start = min(meas, key=lambda t: abs(t - t_on))
        pts = [(t, i) for t, i in mean if t >= start and i > 1]
        logi, out = math.log(meas[start]), {}
        for (t0, i0), (t1, i1) in zip(pts, pts[1:]):
            logi += (1 - share_at(sched, t0 + 1e-6)) * (math.log(i1) - math.log(i0))
            out[t1] = math.exp(logi)
        print("\nincome against the math: expected = measured income when the army starts (%.1f min), then the 0%% baseline's" % start)
        print("  growth (mean of %d run(s)) slowed by (1 - share) at each moment.  Spine labs/nanos are extra eco-side cost, so" % len(base))
        print("  measured below expected is partly real.")
        print("   minute   measured   expected   measured/expected   (0% baseline)")
        for m in (6, 8, 10, 12, 14, 16):
            t = min(out, key=lambda x: abs(x - m)) if out else None
            if t is None or abs(t - m) > 0.3 or t not in meas:
                continue
            bm = next(i for tt, i in mean if tt == t)
            print("   %5.1f   %8.0f   %8.0f        %5.2f            %8.0f" % (t, meas[t], out[t], meas[t] / out[t], bm))


def sanity(d, team=0):
    """Things a 0%-army bench should satisfy; printed by `report`."""
    tl = d.get("tracker_timeline", [])
    eco = [r for r in tl if r.get("kind") == "eco" and r["team"] == team]
    if not eco:
        return
    last = eco[-1]
    army = [r for r in tl if r.get("kind") == "army" and r["team"] == team]
    cm = [r for r in tl if r.get("kind") == "cmdr" and r["team"] == team]
    prod, used = float(last.get("metal_produced", 0)), float(last.get("metal_used", 0))
    wasted = sum(float(r.get("metal_excess", 0)) * 30 for r in eco if int(r["frame"]) % 900 == 0)
    flags = []
    flags.append(("desync/Lua failure flags clear", not d.get("desync") and not d.get("lua_failure")))
    flags.append(("ran to the end-minutes frame (end_reason frame)", d.get("end_reason") in (None, "frame", "end_score")))
    if army and not any(r.get("kind") == "bench" and r["team"] == team for r in tl):
        flags.append(("army value at the end is %.0f (a 0%% bench should be 0)" % float(army[-1].get("mv", 0)),
                      float(army[-1].get("mv", 0)) == 0))
    if cm:
        flags.append(("commander alive at the end (hp %.0f)" % float(cm[-1].get("hp", 0)), float(cm[-1].get("hp", 0)) > 0))
    print("  sanity:")
    for text, ok in flags:
        print("    [%s] %s" % ("ok" if ok else "!!", text))
    print("    metal: produced %.0f, used %.0f (%.0f%%), banked at end %.0f, wasted at the cap ~%.0f (%.1f%% of produced)" % (
        prod, used, 100 * used / max(prod, 1), float(last.get("metal", 0)), wasted, 100 * wasted / max(prod, 1)))
    print("    units at the end %d of cap %d; energy produced %.0f used %.0f" % (
        float(last.get("units_total", 0)), float(last.get("unit_cap", 0)), float(last.get("energy_produced", 0)), float(last.get("energy_used", 0))))


def model(t2, shares, i0, t_on=T0_MIN, ceiling=None, show=(5, 8, 10, 12, 15)):
    print("\nmodel: I(4:00) = %.0f m/s, %.2f min/doubling at army share 0, army switched on at %.1f min" % (i0, t2, t_on))
    head = "  army share  " + "".join("  %5s min" % ("%g" % m) for m in show)
    print("  income (m/s)\n" + head)
    rows = {}
    for a in shares:
        k = math.log(2) / t2
        i, t, dt, army, cur = i0, T0_MIN, 1 / 60.0, 0.0, {}
        while t < max(show) + 1e-9:
            share = a if t >= t_on else 0.0
            if ceiling:
                i = min(i, ceiling)
            i *= math.exp(k * (1 - share) * dt)
            army += share * i * 60 * dt
            t += dt
            for m in show:
                if abs(t - m) < dt / 2:
                    cur[m] = (i, army)
        rows[a] = cur
        print("  %9d%%  " % round(a * 100) + "".join("  %9.0f" % cur[m][0] for m in show))
    print("  army metal banked (cumulative, m)\n" + head)
    for a in shares:
        print("  %9d%%  " % round(a * 100) + "".join("  %9.0f" % rows[a][m][1] for m in show))
    print("  equal-value check: at 15 min, income x 60 s = what one more minute of eco buys; a share is worth it only if")
    print("  the army it buys is needed to hold the eco.  Doubling time at share a is T2/(1-a):  " +
          ", ".join("%d%%: %.2f" % (round(a * 100), t2 / (1 - a)) for a in shares))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--bot", default="candidates/ECO_BENCH")
    r.add_argument("--label", default="base")
    r.add_argument("--end-minutes", type=float, default=17)
    r.add_argument("--duration", type=int, default=900)
    r.add_argument("--lt", action="append", default=[], metavar="KEY=VAL", help="override line_transition CFG entries (copy of the bot)")
    r.add_argument("--server", default="spectator")
    r.add_argument("--schedule", help="army share schedule (candidates/ARMY_BENCH): min:share,... e.g. 3:0.2 or 0:0,5:0.3,8:0.8,10:1,12:0,14:0.3")
    r.add_argument("--spine", action="append", default=[], metavar="KEY=VAL", help="extra SPINE_CFG entries (ARMY_BENCH)")
    sh = sub.add_parser("shares", help="does the army spend follow the schedule, and is income what the math says?")
    sh.add_argument("result")
    sh.add_argument("--schedule", help="min:share,... (default: schedule.json next to the result)")
    sh.add_argument("--baseline", nargs="*", help="0%% army result json(s): expected income = baseline curve slowed by (1-share)")
    sh.add_argument("--lag", type=float, default=0.0, help="minutes between spend and finish; the bench now counts in-progress spend, so 0")
    p = sub.add_parser("report")
    p.add_argument("result")
    p.add_argument("--team", type=int, default=0)
    s = sub.add_parser("spread", help="compare replicate results: time-to-milestone ranges (stable) and income at fixed minutes (noisy)")
    s.add_argument("results", nargs="+")
    m = sub.add_parser("model")
    m.add_argument("--t2", type=float, default=sum(TARGET) / 2, help="min/doubling at army share 0")
    m.add_argument("--i0", type=float, default=60.0, help="metal income at 4:00")
    m.add_argument("--from-run", help="result json: take I(4:00) and the 4-10 min doubling time from it")
    m.add_argument("--t-on", type=float, default=T0_MIN, help="game minute the army share starts")
    m.add_argument("--shares", default="0,0.1,0.2,0.3,0.5")
    a = ap.parse_args()
    if a.cmd == "run":
        folder = os.path.join(HERE, "eco_bench_runs", a.label)
        os.makedirs(folder, exist_ok=True)
        out = os.path.join(folder, "eco.json")
        bot = a.bot
        if a.schedule and bot == "candidates/ECO_BENCH":
            bot = "candidates/ARMY_BENCH"                  # a schedule needs the bot with a spine
        if a.lt or a.schedule or a.spine:
            import re
            import shutil
            src = bot
            bot = os.path.join("candidates", "_variant_" + a.label)
            shutil.rmtree(os.path.join(HERE, bot), ignore_errors=True)
            shutil.copytree(os.path.join(HERE, src), os.path.join(HERE, bot))
            mp = os.path.join(HERE, bot, "macro_controller.lua")
            txt = open(mp, encoding="utf-8").read()
            if a.lt:
                add = ", ".join(x.replace("=", " = ", 1) for x in a.lt)
                m = re.search(r"(\n\s*LT\s*=\s*\{[^}]*?)(\s*\})", txt)
                if not m:
                    sys.exit("no `LT = { ... }` table found in macro_controller.lua")
                txt = txt[:m.end(1)] + ", " + add + txt[m.start(2):]
            if a.schedule or a.spine:
                sched = parse_schedule(a.schedule) if a.schedule else None
                extra = "".join(", " + x.replace("=", " = ", 1) for x in a.spine)
                lua = "{ " + ", ".join("{ %d, %g }" % (round(mn * 1800), s) for mn, s in (sched or [])) + " }"
                head = "STRICT = true, SCHEDULE = %s, %s" % (lua, ARMY_SPINE_DEFAULTS) if sched else "STRICT = true, " + ARMY_SPINE_DEFAULTS
                txt, n = re.subn(r"SPINE_CFG\s*=\s*\{[^\n]*\},", lambda mm: "SPINE_CFG = { %s%s }," % (head, extra), txt, count=1)
                if n != 1:
                    sys.exit("no SPINE_CFG line in %s (use candidates/ARMY_BENCH)" % mp)
                if sched:
                    json.dump(sched, open(os.path.join(folder, "schedule.json"), "w"))
            open(mp, "w", encoding="utf-8", newline="").write(txt)
        subprocess.run([sys.executable, os.path.join(HERE, "bot_testing.py"), "--bot1", bot, "--bot2", "INACTIVE_BOT",
                        "--server", a.server, "--end-minutes", str(a.end_minutes), "--duration", str(a.duration),
                        "--save-result", out], cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        report(out)
        if a.schedule:
            shares(out, parse_schedule(a.schedule))
    elif a.cmd == "shares":
        sched = parse_schedule(a.schedule) if a.schedule else json.load(open(os.path.join(os.path.dirname(a.result), "schedule.json")))
        shares(a.result, [tuple(x) for x in sched], a.baseline, a.lag)
    elif a.cmd == "spread":
        spread(a.results)
    elif a.cmd == "report":
        report(a.result, a.team)
    else:
        t2, i0 = a.t2, a.i0
        if a.from_run:
            pts = curve(a.from_run)
            i0 = next(i for t, i, _, _ in pts if t >= T0_MIN)
            f = fit_doubling(pts, 4, 10)
            t2 = f[0] if f else t2
        model(t2, [float(x) for x in a.shares.split(",")], i0, a.t_on)


if __name__ == "__main__":
    main()
