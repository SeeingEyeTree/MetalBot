"""line_sweep.py -- tune LINE_BOT's CFG for economy at 3-4 minutes.

    python line_sweep.py                       run every config below, n mirror matches each (resumable)
    python line_sweep.py --n 3 --only base nano_u12
    python line_sweep.py --summarize           re-read eco_bench_runs/line_*

Each match is LINE_BOT vs LINE_BOT ended at 4.5 game-minutes (both teams measured from their own process, so one
match = two samples; slot 0 and slot 1 are reported together here because the line is far from the other base
by then).  Metrics from the tracker's eco rows: metal_used (cumulative), metal_inc and the bank at 3:00 / 3:30 / 4:00.
The objective is metal_used at 4:00: money actually turned into economy; the income at 4:00 and the bank say whether
it is still floating.  Detectable effect is about 2 sd of the base row; read the table, do not trust one run.
"""
import argparse
import json
import os
import statistics
import sys

import eco_bench

HERE = os.path.dirname(os.path.abspath(__file__))
BOT = "LINE_BOT"
FR = {"3:00": 5400, "3:30": 6300, "4:00": 7200}

# label -> CFG overrides (eco_bench.make_variant syntax).  One change per row from `base`.
CONFIGS = {
    "base":      [],
    "gap0":      ["CON_GAP={ [2] = 0, [3] = 0 }"],
    "gap40":     ["CON_GAP={ [2] = 40 * 30, [3] = 40 * 30 }"],
    "gap60":     ["CON_GAP={ [2] = 60 * 30, [3] = 60 * 30 }"],
    "bank300":   ["CON_BANK_TRIGGER=300", "CON_GAP={ [2] = 30 * 30, [3] = 30 * 30 }"],
    "inc15_25":  ["CON_INCOME={ [2] = 15, [3] = 25 }"],
    "inc30_45":  ["CON_INCOME={ [2] = 30, [3] = 45 }"],
    "cons2":     ["MAX_CONS=2"],
    "nano_u05":  ["NANO_U=0.5"],
    "nano_u12":  ["NANO_U=1.2"],
    "nano_u20":  ["NANO_U=2.0"],
    "wind_u08":  ["WIND_U=0.8"],
    "wind_u13":  ["WIND_U=1.3"],
}
# Round 2: everything on top of gap0 (round 1: no minimum gap between cons was the one clear win, x1.24).
G0 = ["CON_GAP={ [2] = 0, [3] = 0 }"]
CONFIGS.update({
    "g0_nano_u05": G0 + ["NANO_U=0.5"],
    "g0_nano_u12": G0 + ["NANO_U=1.2"],
    "g0_wind_u08": G0 + ["WIND_U=0.8"],
    "g0_wind_u13": G0 + ["WIND_U=1.3"],
    "g0_cons2":    G0 + ["MAX_CONS=2"],
    "g0_help0":    G0 + ["NANOS_HELPED=0"],
    "g0_help4":    G0 + ["NANOS_HELPED=4"],
    "g0_release5": G0 + ["CON1_RELEASE_WAIT=5 * 30"],
})


def samples(folder):
    out = {k: [] for k in ("used", "inc", "bank")}
    rows = {}
    for fn in sorted(os.listdir(folder)):
        if not fn.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(folder, fn), encoding="utf-8"))
        except Exception:
            continue
        for r in d.get("tracker_timeline", []):
            if r.get("kind") == "eco" and int(r["frame"]) in FR.values():
                rows.setdefault((fn, r["team"]), {})[int(r["frame"])] = r
    res = {name: {"used": [], "inc": [], "bank": []} for name in FR}
    for per in rows.values():
        for name, f in FR.items():
            if f in per:
                res[name]["used"].append(float(per[f].get("metal_used", 0)))
                res[name]["inc"].append(float(per[f].get("metal_inc", 0)))
                res[name]["bank"].append(float(per[f].get("metal", 0)))
    return res


def mean_sd(xs):
    if not xs:
        return 0.0, 0.0
    return statistics.mean(xs), (statistics.stdev(xs) if len(xs) > 1 else 0.0)


def summarize(labels):
    print("\n%-10s %3s | %-22s | %-22s | %-22s" % ("config", "n", "used@3:00", "used@4:00", "inc / bank @4:00"))
    base = None
    for label in labels:
        folder = os.path.join(HERE, "eco_bench_runs", "line_" + label)
        if not os.path.isdir(folder):
            continue
        r = samples(folder)
        u3, s3 = mean_sd(r["3:00"]["used"])
        u4, s4 = mean_sd(r["4:00"]["used"])
        i4, _ = mean_sd(r["4:00"]["inc"])
        b4, _ = mean_sd(r["4:00"]["bank"])
        n = len(r["4:00"]["used"])
        if label == "base":
            base = u4
        rel = ("  x%.2f" % (u4 / base)) if base and label != "base" and u4 else ""
        print("%-10s %3d | %7.0f sd %5.0f      | %7.0f sd %5.0f%s | inc %5.1f bank %5.0f" % (label, n, u3, s3, u4, s4, rel, i4, b4))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=3, help="matches per config (two samples each)")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--end-minutes", type=float, default=4.5)
    ap.add_argument("--summarize", action="store_true")
    a = ap.parse_args()
    labels = a.only or list(CONFIGS)
    if not a.summarize:
        for label in labels:
            folder = os.path.join(HERE, "eco_bench_runs", "line_" + label)
            os.makedirs(folder, exist_ok=True)
            bot, variant = BOT, None
            if CONFIGS[label]:
                bot = variant = eco_bench.make_variant(BOT, "line_%s_%d" % (label, os.getpid()), CONFIGS[label])   # unique: OneDrive can lock an old copy
            try:
                for i in range(a.n):
                    out = os.path.join(folder, "run%02d.json" % i)
                    if os.path.exists(out):
                        continue
                    print("%s: match %d/%d" % (label, i + 1, a.n), flush=True)
                    eco_bench.run_local(bot, out, a.end_minutes, 600)
            finally:
                if variant:
                    import shutil
                    shutil.rmtree(os.path.join(HERE, variant), ignore_errors=True)
            summarize(labels)
    else:
        summarize(labels)


if __name__ == "__main__":
    main()
