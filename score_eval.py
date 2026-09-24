#!/usr/bin/env python3
"""
score_eval.py - is bot_score's phi any good? Test it against what actually happened.

A state-value estimate is only useful if it (a) predicts who wins and (b) is quiet enough
that a difference means something. This checks both, for phi, for today's adjudicator
formula (`legacy` = army_mv + 60 x metal_inc) as the baseline to beat, and for every
category and signal on its own, so a signal that carries no information shows up as such.

    python score_eval.py knowledge/raid_runs knowledge/threat_logs     # files or folders
    python score_eval.py results/ --frames 7200,10800,14400
    python score_eval.py results/ --fit 14400      # suggest weights (needs ~30 decided games)

1. PREDICTIVE VALIDITY. In each decided game (a commander kill, or the end-of-match score
   verdict; draws, unit-count fallbacks and mirror matches are left out -- a mirror's winner
   is noise), at each checkpoint BEFORE the game
   was decided: does the team with the higher value go on to win? Reported as hits/games.
   With few games this is anecdote, not evidence -- the n is printed for that reason.
   Most "end_score" winners are decided BY the legacy formula, so a score that departs from
   it (e.g. counting energy) looks worse here by construction. Commander kills and long
   games are the outcomes that actually test phi.

2. NOISE. In mirror matches (the same bot in both slots) the two teams should score the
   same; the median max/min ratio between them is the metric's noise floor, in the same
   form as ab_test.NOISE_FLOOR. It includes the slot advantage (see CLAUDE.md).

3. FIT (--fit FRAME). Logistic regression of "team 0 won" on the per-category differences
   at FRAME (scaled). The coefficients are a suggestion for score_config.json weights --
   the "learned value function" without training a policy. Not written automatically.
"""

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

import bot_score
from find_weakness import mmss

DECIDED = {"game_over", "end_score", "end_score_wallclock"}
METRICS_CAT = ("materiel", "economy", "exposure", "spend", "ability", "awareness")


def load_results(paths):
    out = []
    for p in paths:
        p = Path(p)
        files = sorted(p.rglob("*.json")) if p.is_dir() else [p]
        for f in files:
            try:
                r = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(r, dict) and r.get("tracker_timeline"):
                out.append((f, r))
    return out


def metric_values(cp):
    """Every comparable number at one checkpoint: phi, legacy, categories, signal values."""
    v = {"phi": cp["phi"], "legacy": cp["legacy"]}
    for c in METRICS_CAT:
        v["cat:" + c] = cp["categories"].get(c)
    for name, d in cp["components"].items():
        if isinstance(d["value"], (int, float)):
            v["sig:" + name] = d["value"]
    # exposure and value_at_risk are "lower is better"; flip so higher always = better
    if v.get("sig:value_at_risk") is not None:
        v["sig:value_at_risk"] = -v["sig:value_at_risk"]
    for k in ("sig:denial", "sig:waste", "sig:stranded_bp"):
        if v.get(k) is not None:
            v[k] = -v[k]
    return v


def decided_frame(result, scored):
    """First checkpoint frame at which the outcome was already fixed (a commander dead)."""
    fs = [c["frame"] for t in (0, 1) for c in scored[t]["checkpoints"] if c["terminal"]]
    return min(fs) if fs else None


def validity(games, frames):
    """{metric: {frame: [hits, n]}}"""
    tab = {}
    for f, r, sc in games:
        if r.get("winner_method") not in DECIDED or r.get("winner") not in (0, 1):
            continue
        if r.get("bot0_name") == r.get("bot1_name"):
            continue        # a mirror's winner is noise, not something a score should predict
        win = r["winner"]
        dead = decided_frame(r, sc)
        for i, fr in enumerate(frames):
            if dead is not None and fr >= dead:
                continue
            a = metric_values(sc[0]["checkpoints"][i])
            b = metric_values(sc[1]["checkpoints"][i])
            for k in a:
                if a[k] is None or b.get(k) is None or a[k] == b[k]:
                    continue
                cell = tab.setdefault(k, {}).setdefault(fr, [0, 0])
                cell[0] += (0 if a[k] > b[k] else 1) == win
                cell[1] += 1
    return tab


def noise(games, frames):
    """{metric: {frame: [ratios]}} over mirror matches."""
    tab = {}
    for f, r, sc in games:
        if r.get("bot0_name") != r.get("bot1_name"):
            continue
        for i, fr in enumerate(frames):
            a = metric_values(sc[0]["checkpoints"][i])
            b = metric_values(sc[1]["checkpoints"][i])
            for k in a:
                x, y = a[k], b.get(k)
                if x is None or y is None or x <= 0 or y <= 0:
                    continue
                tab.setdefault(k, {}).setdefault(fr, []).append(max(x, y) / min(x, y))
    return tab


def fit(games, frame, cats=("materiel", "economy", "exposure", "ability"), iters=4000, lr=0.1,
        l2=0.01):
    """Plain logistic regression, no numpy: P(team 0 wins) = sigmoid(w . (x0 - x1) / scale)."""
    X, y = [], []
    for f, r, sc in games:
        if r.get("winner_method") not in DECIDED or r.get("winner") not in (0, 1):
            continue
        if r.get("bot0_name") == r.get("bot1_name"):
            continue
        dead = decided_frame(r, sc)
        if dead is not None and frame >= dead:
            continue
        c0 = next((c for c in sc[0]["checkpoints"] if c["frame"] == frame), None)
        c1 = next((c for c in sc[1]["checkpoints"] if c["frame"] == frame), None)
        if not c0 or not c1 or c0["phi"] is None or c1["phi"] is None:
            continue
        row = [(c0["categories"].get(k) or 0) - (c1["categories"].get(k) or 0) for k in cats]
        # add the mirrored sample so the fit cannot learn a slot bias as a weight
        X += [row, [-v for v in row]]
        y += [1.0 if r["winner"] == 0 else 0.0, 0.0 if r["winner"] == 0 else 1.0]
    if not X:
        return None, 0
    scale = [statistics.pstdev([x[j] for x in X]) or 1.0 for j in range(len(cats))]
    Xs = [[x[j] / scale[j] for j in range(len(cats))] for x in X]
    w = [0.0] * len(cats)
    for _ in range(iters):
        g = [l2 * wj for wj in w]
        for x, t in zip(Xs, y):
            z = sum(wj * xj for wj, xj in zip(w, x))
            p = 1 / (1 + math.exp(-max(-30, min(30, z))))
            for j in range(len(w)):
                g[j] += (p - t) * x[j] / len(Xs)
        w = [wj - lr * gj for wj, gj in zip(w, g)]
    return {k: (w[j], w[j] / scale[j]) for j, k in enumerate(cats)}, len(X) // 2


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="result JSON files or folders of them")
    ap.add_argument("--frames", help="comma-separated checkpoints (default: config)")
    ap.add_argument("--all-signals", action="store_true", help="list every signal, not just the headline rows")
    ap.add_argument("--fit", type=int, metavar="FRAME", help="fit category weights at FRAME")
    args = ap.parse_args()

    cfg = bot_score.load_config()
    frames = [int(x) for x in args.frames.split(",")] if args.frames else cfg["checkpoints"]
    games = [(f, r, bot_score.score_result(r, frames, cfg)) for f, r in load_results(args.paths)]
    if not games:
        sys.exit("no result files with tracker data found")

    decided = [g for g in games if g[1].get("winner_method") in DECIDED
               and g[1].get("bot0_name") != g[1].get("bot1_name")]
    mirrors = [g for g in games if g[1].get("bot0_name") == g[1].get("bot1_name")]
    print(f"{len(games)} results with tracker data: {len(decided)} decided, "
          f"{len(mirrors)} mirror matches; config v{cfg['version']}\n")
    for f, r, sc in games:
        print(f"  {f.name}: {r.get('bot0_name')} vs {r.get('bot1_name')} -> "
              f"winner {r.get('winner')} ({r.get('winner_method')})")

    head = ["phi", "legacy"] + ["cat:" + c for c in METRICS_CAT]
    val = validity(games, frames)
    keys = head + (sorted(k for k in val if k.startswith("sig:")) if args.all_signals else [])
    print("\n1. Predictive validity: does the higher value go on to win?  (hits/games)")
    print(f"  {'':<24}" + "".join(f"{mmss(fr):>9}" for fr in frames) + f"{'all':>9}")
    for k in keys:
        cells, h, n = [], 0, 0
        for fr in frames:
            c = val.get(k, {}).get(fr)
            cells.append(f"{c[0]}/{c[1]}" if c else "-")
            if c:
                h, n = h + c[0], n + c[1]
        tot = f"{100 * h / n:.0f}%" if n else "-"
        print(f"  {k:<24}" + "".join(f"{v:>9}" for v in cells) + f"{tot:>9}")
    if len(decided) < 20:
        print(f"  ({len(decided)} decided games: far too few to separate these metrics. "
              "Treat as a smoke test, not a verdict.)")

    nz = noise(games, frames)
    print("\n2. Noise in mirror matches (median max/min between the two teams)")
    if not nz:
        print("  no mirror matches yet: run `ab_test.py --bot-a X --bot-b X` or a few "
              "`bot_testing.py --bot1 X --bot2 X --save-result ...` and include them")
    else:
        print(f"  {'':<24}" + "".join(f"{mmss(fr):>9}" for fr in frames))
        for k in keys:
            cells = [f"{statistics.median(nz[k][fr]):.2f}" if nz.get(k, {}).get(fr) else "-"
                     for fr in frames]
            print(f"  {k:<24}" + "".join(f"{v:>9}" for v in cells))

    if args.fit:
        w, n = fit(games, args.fit)
        print(f"\n3. Logistic fit at {mmss(args.fit)} on {n} decided games")
        if not w:
            print("  no usable games at that frame")
        else:
            if n < 30:
                print(f"  WARNING: {n} games. Coefficients this early are noise; do not copy them "
                      "into score_config.json yet.")
            for k, (ws, wr) in w.items():
                print(f"  {k:<12} scaled {ws:+.3f}   per unit {wr:+.6f}")
            print("  Relative per-unit weights (materiel = 1) are the candidate config weights.")


if __name__ == "__main__":
    main()
