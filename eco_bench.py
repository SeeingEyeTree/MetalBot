"""eco_bench.py -- opening-economy benchmark: metal used at 5:00 / 6:00 / 7:30 over N mirror matches.

    python eco_bench.py candidates/TILE_V2 --n 8 --label baseline
    python eco_bench.py candidates/TILE_V2 --n 4 --label only_bal --set BALANCE=true \
        --set TILE_BLUEPRINT='"con_bot_grid"' --set AIR_CON_CAP=false      (CFG overrides)
    python eco_bench.py --summarize eco_bench_runs/baseline          (re-read saved results)

`--set KEY=LUA_LITERAL` rewrites a `KEY = value,` entry of the bot's macro_controller.lua CFG table
in a temporary copy of the bot folder (candidates/_variant_<label>, deleted afterwards), so one
bot folder can be tested with single flags flipped.  Strings need their quotes.

Each sample is one `bot_testing.py --bot1 X --bot2 X --end-minutes 8` match; both teams are
measured (the harness scores each team from its own process).  Slot 0 has a large advantage,
so team 0 and team 1 are reported SEPARATELY and the A/B comparison should use the same slot.
Metrics: `metal_used` (tracker eco row, cumulative) at frames 9000 / 10800 / 13500, and metal
income at 9000.  Earlier TILE_BOT mirror runs: sd 0.76k at 7:30 (n=8), so ~1.5k is detectable.

Results go to eco_bench_runs/<label>/run<i>.json (the bot_testing result), so a summary can be
re-run or compared later without replaying the games.  `--runner` replaces how one match is
run (default: this machine); it receives (bot, out_json, end_minutes) and must write out_json.
"""
import argparse
import json
import math
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKPOINTS = (("5:00", 9000), ("6:00", 10800), ("7:30", 13500))


def run_local(bot, out_json, end_minutes, duration):
    cmd = [sys.executable, os.path.join(HERE, "bot_testing.py"), "--bot1", bot, "--bot2", bot,
           "--end-minutes", str(end_minutes), "--duration", str(duration), "--save-result", out_json]
    subprocess.run(cmd, cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_variant(bot, label, settings):
    """Copy `bot` to candidates/_variant_<label> with CFG entries rewritten.  -> folder (relative)."""
    import re
    import shutil
    src = bot if os.path.isabs(bot) else os.path.join(HERE, bot)
    rel = os.path.join("candidates", "_variant_" + label)
    dst = os.path.join(HERE, rel)
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    path = os.path.join(dst, "macro_controller.lua")
    text = open(path, encoding="utf-8").read()
    for item in settings:
        key, _, val = item.partition("=")
        # bare words that are not Lua literals become strings: --set TILE_BLUEPRINT=con_bot_grid
        if not re.match(r'^(true|false|nil|-?[\d.]+|".*"|\'.*\'|\{.*\})$', val):
            val = '"%s"' % val
        pat = re.compile(r"(^[ \t]*%s[ \t]*=[ \t]*)(\{[^}\n]*\}|[^,\n]+)(,)" % re.escape(key.strip()), re.M)
        text, n = pat.subn(lambda m: m.group(1) + val + m.group(3), text, count=1)
        if n != 1:
            sys.exit("--set %s: no `%s = ...,` entry found in macro_controller.lua" % (item, key))
    open(path, "w", encoding="utf-8", newline="").write(text)
    return rel


def sample(path):
    """-> {team: {"used5": .., "used6": .., "used730": .., "inc5": ..}} from one result json."""
    d = json.load(open(path, encoding="utf-8"))
    out = {}
    for r in d.get("tracker_timeline", []):
        if r.get("kind") != "eco":
            continue
        t = r["team"]
        f = int(r["frame"])
        for name, frame in CHECKPOINTS:
            if f == frame:
                out.setdefault(t, {})["used" + name] = float(r.get("metal_used", 0))
        if f == 9000:
            out.setdefault(t, {})["inc5"] = float(r.get("metal_inc", 0))
    for r in d.get("tracker_timeline", []):
        if r.get("kind") == "units" and int(r["frame"]) in (7200, 9000):
            out.setdefault(r["team"], {})["mex%d" % (int(r["frame"]) // 1800)] = float(r.get("mex", 0))
    return out


def summarize(folder):
    files = sorted(f for f in os.listdir(folder) if f.endswith(".json"))
    per_team = {}
    for fn in files:
        try:
            s = sample(os.path.join(folder, fn))
        except Exception as e:                      # a broken/cut-short run is skipped, not fatal
            print("skip %s: %s" % (fn, e))
            continue
        for team, vals in s.items():
            for k, v in vals.items():
                per_team.setdefault(team, {}).setdefault(k, []).append(v)
    print("\n%s  (%d result files)" % (folder, len(files)))
    for team in sorted(per_team):
        print("  team %d (slot %d):" % (team, team))
        for k in ("used5:00", "used6:00", "used7:30", "inc5", "mex4", "mex5"):
            xs = per_team[team].get(k, [])
            if not xs:
                continue
            sd = statistics.stdev(xs) if len(xs) > 1 else 0.0
            print("    %-9s n=%d  mean %8.0f  sd %6.0f  [%.0f - %.0f]" % (k, len(xs), statistics.mean(xs), sd,
                                                                      min(xs), max(xs)))
    return per_team


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bot", nargs="?")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--label", default="run")
    ap.add_argument("--end-minutes", type=float, default=8)
    ap.add_argument("--duration", type=int, default=900, help="real-seconds backstop per match")
    ap.add_argument("--summarize", metavar="FOLDER")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=LUA_LITERAL")
    a = ap.parse_args()
    if a.summarize:
        summarize(a.summarize)
        return
    if not a.bot:
        ap.error("bot folder required")
    bot = a.bot
    variant = None
    if a.set:
        bot = variant = make_variant(a.bot, a.label, a.set)
    folder = os.path.join(HERE, "eco_bench_runs", a.label)
    os.makedirs(folder, exist_ok=True)
    try:
        for i in range(a.n):
            out = os.path.join(folder, "run%02d.json" % i)
            if os.path.exists(out):
                continue                                  # resume
            print("match %d/%d ..." % (i + 1, a.n), flush=True)
            run_local(bot, out, a.end_minutes, a.duration)
    finally:
        if variant:
            import shutil
            shutil.rmtree(os.path.join(HERE, variant), ignore_errors=True)
    summarize(folder)


if __name__ == "__main__":
    main()
