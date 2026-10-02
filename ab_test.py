#!/usr/bin/env python3
"""ab_test.py -- compare two bots without fooling yourself.

Two things make a naive comparison worthless in this project, both measured, not assumed:

  1. SLOT BIAS. Whichever bot is passed as --bot1 (slot 0) has a large advantage. A bot
     beats *itself* from slot 0. So every comparison runs both slot orders.

  2. RUN-TO-RUN NOISE. Even with identical bots in the same slot, army value at the
     10-game-minute checkpoint varies by 12% or more between runs. A single match per
     slot order is therefore not enough: baseline_001 vs baseline_001 was once reported
     as "B is better, leads in BOTH slots" (1.12x and 1.07x). Leading in both slots is
     NOT sufficient evidence.

The verdict compares the two bots INSIDE each match (paired), not across matches. Most of
the run-to-run noise is shared by both teams of a match (game speed, lag, how the map
plays out): in one A/B, one match was ~15% richer than the next for BOTH bots. The ratio
A/B within a match cancels that, and taking the geometric mean over both slot orders
cancels the slot bias (A's slot-0 match is inflated by it exactly as much as its slot-1
match is deflated). The within-match ratio is NOT noise-free, though: over 8 matches of
two A/Bs with no real effect it still varied with a log standard deviation of ~0.10
(0.877-1.208 for the same condition), so the bar is ~2 sigma of the paired mean and
shrinks with more matches: ~1.15 at one match per slot, ~1.08 at three.

A bot is called better only when it is ahead in EVERY match and the paired geometric mean
clears that bar. Default --repeat is 1 (one match per slot order): enough to catch an
effect of ~15% or a breakage while there is only one bot to test against. Raise it when
effects get small or there are several bots to rank. The per-slot table and the old
"no overlap between runs" check are still printed when --repeat >= 2.

Scoring uses army metal value at frame 18000 rather than the end state, because slot 0
saturates the ~2000 unit cap in a 300s match and end-of-match numbers cannot tell two
competent bots apart. Metal income at the same frame is reported as a cross-check: it is
a pure economy signal, whereas army value also absorbs chaotic combat losses.

Each match takes about 6 minutes, so a run costs roughly 12*REPEAT minutes.
"""
import argparse, json, math, statistics, subprocess, sys, tempfile
from pathlib import Path

# WHERE to measure was determined empirically with checkpoint_map.py, not guessed.
# Measured run-to-run spread between effectively-identical bots, by frame:
#
#   frame (game-min)     army value      metal income
#    3600  (2)              1.09             1.00
#    7200  (4)              1.07             1.18
#   10800  (6)              1.10             1.22
#   14400  (8)              1.14             1.30
#   18000 (10)           1.20-1.50           1.28-1.44
#   27000 (15)              1.40             1.60
#   36000 (20)              2.00             4.50
#
# Two things follow. Noise grows steeply with match length, so a LONGER match is a WORSE
# measurement. And army value is quieter than metal income in the early-to-mid window,
# which is the opposite of the intuition that combat noise makes it dirtier -- income is
# spiky because it tracks instantaneous build-power draw.
#
# The default is therefore army value at frame 14400 (8 game-minutes): about the latest
# point still under ~1.15x noise, so the bots have had time to diverge from their shared
# scripted opening while the measurement is still trustworthy. Detectable effect size
# there is roughly 15-20%. Anything smaller is not measurable on this harness at any
# frame -- see the NOTE in lessons_learned.md before trying to chase it.
#
# These floors come from n=3 samples, so they are themselves uncertain (frame 18000 has
# measured both 1.20x and 1.50x on different runs). Treat them as indicative.
DEFAULT_FRAME = {"income": 9000, "army": 14400, "phi": 14400}
# Log standard deviation of the within-match A/B ratio when there is no real effect,
# from 8 matches (energy look-ahead x6, air-con reserve x2, 2026-09-23). The verdict bar
# is exp(2 * PAIR_LOG_SD / sqrt(matches)). Re-measure as A/Bs accumulate.
PAIR_LOG_SD = 0.098
NOISE_FLOOR = {("army", 3600): 1.09, ("army", 7200): 1.07, ("army", 10800): 1.10,
               ("army", 14400): 1.14, ("army", 18000): 1.35, ("army", 27000): 1.40,
               ("army", 36000): 2.00,
               ("income", 9000): 1.06, ("income", 18000): 1.44,
               ("income", 27000): 1.60, ("income", 36000): 4.50}


def run_match(bot1: str, bot2: str, duration: int, out: Path) -> dict:
    subprocess.run(
        [sys.executable, "bot_testing.py", "--bot1", bot1, "--bot2", bot2,
         "--duration", str(duration), "--save-result", str(out)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return json.loads(out.read_text(encoding="utf-8"))


def sample(result: dict, metric: str, team: int, frame: int) -> "float | None":
    if metric == "phi":
        # Recomputed from the tracker rows, so any checkpoint works (not only the ones
        # stored in result["phi"]). Its noise floor is not measured yet: see scoring.md.
        import bot_score
        cp = bot_score.score_result(result, [frame])[team]["checkpoints"][0]
        return cp["phi"] if not cp["terminal"] else None
    key, field = (("resource_timeline", "metal_inc") if metric == "income"
                  else ("army_timeline", "mv"))
    for row in result.get(key) or []:
        if row.get("team") == team and row.get("frame") == frame:
            return float(row[field])
    return None


def fmt(vals: list) -> str:
    if not vals:
        return "n/a"
    if len(vals) == 1:
        return f"{vals[0]:,.0f}"
    return f"{statistics.mean(vals):,.0f} [{min(vals):,.0f}-{max(vals):,.0f}]"


def separated(x: list, y: list) -> "int | None":
    """1 if every x beats every y, -1 if every y beats every x, else None (overlap)."""
    if not x or not y:
        return None
    if min(x) > max(y):
        return 1
    if max(x) < min(y):
        return -1
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bot-a", required=True, help="bot folder (the candidate)")
    ap.add_argument("--bot-b", required=True, help="bot folder (the opponent)")
    ap.add_argument("--duration", type=int, default=300, help="real seconds per match")
    ap.add_argument("--repeat", type=int, default=1,
                    help="matches per slot order (default 1; the verdict is paired within "
                         "each match, see the docstring)")
    ap.add_argument("--metric", choices=("army", "income", "phi"), default="army",
                    help="army = army metal value at frame 14400 (default, quietest);"
                         " income = metal income; phi = bot_score.py state value (noise"
                         " floor not yet measured)")
    ap.add_argument("--checkpoint", type=int, default=None,
                    help="game frame to score at (default 9000 for income, 18000 for army)")
    args = ap.parse_args()

    frame = args.checkpoint or DEFAULT_FRAME[args.metric]
    floor = NOISE_FLOOR.get((args.metric, frame))
    # Report the other metric alongside, as an independent cross-check.
    ctx_metric = "income" if args.metric == "army" else "army"
    if args.metric == "phi" and floor is None:
        print("NOTE: phi has no measured noise floor yet. Run A vs A first and record it in "
              "knowledge/scoring.md before trusting a phi verdict.")
    ctx_frame = DEFAULT_FRAME[ctx_metric]

    tmp = Path(tempfile.mkdtemp(prefix="abtest_"))
    score = {("A", 0): [], ("A", 1): [], ("B", 0): [], ("B", 1): []}
    pairs = []    # (A's slot, A value / B value) for each match
    ctx = {("A", 0): [], ("A", 1): [], ("B", 0): [], ("B", 1): []}

    print(f"A = {args.bot_a}\nB = {args.bot_b}")
    print(f"metric = {args.metric} at frame {frame}"
          + (f" (noise floor {floor:.2f}x between identical bots)" if floor else ""))
    print(f"repeat = {args.repeat} ({2 * args.repeat} matches, ~{12 * args.repeat} min total)\n",
          flush=True)

    total, n = 2 * args.repeat, 0
    for i in range(args.repeat):
        for first in ("A", "B"):
            n += 1
            print(f"[{n}/{total}] {first} in slot 0 ...", flush=True)
            b1, b2 = (args.bot_a, args.bot_b) if first == "A" else (args.bot_b, args.bot_a)
            r = run_match(b1, b2, args.duration, tmp / f"{first}{i}.json")
            other = "B" if first == "A" else "A"
            got = {}
            for who, team in ((first, 0), (other, 1)):
                v = sample(r, args.metric, team, frame)
                if v is not None:
                    score[(who, team)].append(v)
                    got[who] = v
                v = sample(r, ctx_metric, team, ctx_frame)
                if v is not None:
                    ctx[(who, team)].append(v)
            if got.get("A") and got.get("B"):
                pairs.append((0 if first == "A" else 1, got["A"] / got["B"]))
                print(f"      A/B in this match: {got['A'] / got['B']:.3f}", flush=True)

    print(f"\n{args.metric} at frame {frame}  (mean [min-max])\n")
    print(f"  {'':<6}{'slot 0':>26}{'slot 1':>26}")
    for who in ("A", "B"):
        print(f"  {who:<6}{fmt(score[(who, 0)]):>26}{fmt(score[(who, 1)]):>26}")

    if any(ctx[k] for k in ctx):
        cf = NOISE_FLOOR.get((ctx_metric, ctx_frame))
        print(f"\n{ctx_metric} at frame {ctx_frame}  (cross-check"
              + (f", ~{cf:.2f}x noise" if cf else "") + ")\n")
        print(f"  {'':<6}{'slot 0':>26}{'slot 1':>26}")
        for who in ("A", "B"):
            print(f"  {who:<6}{fmt(ctx[(who, 0)]):>26}{fmt(ctx[(who, 1)]):>26}")

    if args.repeat >= 2:
        s0 = separated(score[("A", 0)], score[("B", 0)])
        s1 = separated(score[("A", 1)], score[("B", 1)])
        label = {1: "A clearly ahead", -1: "B clearly ahead", None: "overlapping (no call)"}
        print(f"\nacross matches, slot 0: {label[s0]}")
        print(f"  across matches, slot 1: {label[s1]}")
        spreads = [max(v) / min(v) for v in score.values() if len(v) > 1 and min(v) > 0]
        if spreads:
            note = f" (expected ~{floor:.2f}x)" if floor else ""
            print(f"  worst within-condition spread this run: {max(spreads):.2f}x{note}")

    print("\nPaired, within each match (A value / B value):")
    for slot, rt in pairs:
        print(f"  A in slot {slot}: {rt:.3f}")
    has_both = {k for k, _ in pairs} == {0, 1}
    if not pairs or not has_both:
        print("\nVERDICT: NO VERDICT -- need at least one finished match in each slot order.")
        return 2
    # Equal weight per slot order, so a slot's bias cannot dominate with uneven repeats.
    per_slot = [statistics.geometric_mean([rt for k, rt in pairs if k == j]) for j in (0, 1)]
    gm = statistics.geometric_mean(per_slot)
    bar = math.exp(2 * PAIR_LOG_SD / math.sqrt(len(pairs)))
    print(f"  geometric mean over both slot orders: {gm:.3f}  "
          f"(bar {bar:.2f}: ~2 sigma of the paired noise for {len(pairs)} matches)")

    print()
    if all(rt > 1 for _, rt in pairs) and gm >= bar:
        print("VERDICT: A is better -- ahead in every match, by more than identical bots differ.")
        return 0
    if all(rt < 1 for _, rt in pairs) and gm <= 1 / bar:
        print("VERDICT: B is better -- ahead in every match, by more than identical bots differ.")
        return 1
    print("VERDICT: NO DIFFERENCE DEMONSTRATED.")
    print("The within-match gap is inside what identical bots show, or the matches disagree.")
    print("Do NOT record this as a win or a regression. Check the mechanism directly, or raise")
    print("--repeat if the effect you expect is small.")
    return 2


if __name__ == "__main__":
    sys.exit(main())
