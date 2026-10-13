"""Repeated vacuum games for several STANCE_BOT config variants.

    python runs_stance/ab_variants.py TAG GAMES PARALLEL [variant ...]

Each variant is candidates/STANCE_BOT with a few cfg changes (VARIANTS below) plus the vacuum self-destruct snippet
(runs_stance/vac_snippet.lua), played against INACTIVE_BOT for 20 game-minutes in --server single mode.  Games are spread
over PARALLEL workers (each match pins its own core, ~4 GB RAM).  Results land in runs_stance/<TAG>_<variant>_<i>.json / .log and
a summary (mean, sd and range over the games of each variant) is printed and saved to runs_stance/<TAG>_summary.txt.

Judge on the interval averages (metal_inc_avg etc.) and on metal_used (everything the bot actually spent), not on the minute-mark
samples.  The sd across games of one variant is the run-to-run drift: see knowledge/variance_notes_2026-10-12.md.
"""
import json, math, os, re, shutil, statistics, subprocess, sys, time

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(root, "candidates", "STANCE_BOT")

# name -> list of (regex pattern, replacement) applied to the cfg line of macro_controller.lua; "" = the bot as it is now
OLD_FUSION = [(r"FUSION_HELPERS = true, ENERGY_PRIORITY = true,", "FUSION_HELPERS = false, ENERGY_PRIORITY = false,"),
              (r"EP_INFLIGHT = 6", "EP_INFLIGHT = 2"), (r"ECELL_MAX_ACTIVE = 4", "ECELL_MAX_ACTIVE = 3"),
              (r"EP_CON_BATCH = 4, EP_CON_EVERY = 450", "EP_CON_BATCH = 2, EP_CON_EVERY = 900")]
OLD_RETRO = [(r"RETROFIT_MEX_DONE = true, UPGRADE_CONS_PER_LAB = 4, RETROFIT_FLOAT_CONS = true, RETROFIT_FLOAT_FRAC = 0, RETROFIT_FLOAT_BATCH = 6,", "")]
NO_FULL_CREW = [(r"NANO_CREW_FULL = 12, NANO_CREW_SIZE_FULL = 16,", "")]
NO_HELP = [(r"GRID_HELPERS = true, HELP_ANY = true, HELP_MAX = 3,", "")]
VARIANTS = {
    "full": [],                                   # everything this session added
    "nofullcrew": NO_FULL_CREW,                   # ... without the 16-con nano crew (fixed crew of 4)
    "noretro": NO_FULL_CREW + OLD_RETRO,          # ... and without the earlier-retrofit / more-T2-con changes
    "oldfusion": NO_FULL_CREW + OLD_RETRO + NO_HELP + OLD_FUSION,   # ... and the old fusion rules (jobs 2, no helpers, no energy priority)
}

args = sys.argv[1:]
tag, games, par = args[0], int(args[1]), int(args[2])
names = args[3:] or list(VARIANTS)
snippet = open(os.path.join(root, "runs_stance", "vac_snippet.lua"), encoding="utf-8").read()


def build(name):
    dst = os.path.join(root, "candidates", "_T_" + name)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(SRC, dst)
    mc = os.path.join(dst, "macro_controller.lua")
    s = open(mc, encoding="utf-8", newline="").read()
    for pat, rep in VARIANTS[name]:
        s2 = re.sub(pat, rep, s, count=1)
        if s2 == s and rep != "" or (s2 == s and pat not in s):
            raise SystemExit(f"variant {name}: pattern not found: {pat}")
        s = s2
    open(mc, "w", encoding="utf-8", newline="").write(s)
    with open(os.path.join(dst, "lab_controller.lua"), "a", encoding="utf-8", newline="") as f:
        f.write("\n" + snippet)
    return dst


for n in names:
    build(n)
jobs = [(n, i) for i in range(games) for n in names]       # round-robin so every variant gets games early
running, queue = [], list(jobs)
while queue or running:
    running = [(p, j) for p, j in running if p.poll() is None]
    while queue and len(running) < par:
        n, i = queue.pop(0)
        out = f"runs_stance/{tag}_{n}_{i}"
        c = ["python", "bot_testing.py", "--bot1", f"candidates/_T_{n}", "--bot2", "INACTIVE_BOT", "--server", "single",
             "--end-minutes", "20", "--duration", "3000", "--save-result", out + ".json"]
        p = subprocess.Popen(c, cwd=root, stdout=open(os.path.join(root, out + ".log"), "w"), stderr=subprocess.STDOUT)
        running.append((p, (n, i)))
        time.sleep(25)                                      # stagger the loads
    time.sleep(5)

for n in names:
    shutil.rmtree(os.path.join(root, "candidates", "_T_" + n), ignore_errors=True)


def stats(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "-"
    sd = statistics.pstdev(vals) if len(vals) > 1 else 0
    return f"{statistics.mean(vals):7.0f} ±{sd:5.0f} [{min(vals):.0f}-{max(vals):.0f}]"


def metrics(path):
    r = json.load(open(path))
    eco = {x["frame"]: x for x in r["tracker_timeline"] if x.get("kind") == "eco" and x.get("team") == 0}
    units = {x["frame"]: x for x in r["tracker_timeline"] if x.get("kind") == "units" and x.get("team") == 0}
    m = {"desync": r.get("desync"), "luafail": r.get("lua_failure")}
    for mn in (12, 14, 16, 18, 20):
        e = eco.get(mn * 1800)
        m[f"inc{mn}"] = e["metal_inc_avg"] if e else None
        m[f"pull{mn}"] = e["metal_pull_avg"] if e else None
        m[f"einc{mn}"] = e["energy_inc_avg"] if e else None
    last = max(eco) if eco else None
    m["spent"] = eco[last]["metal_used"] if last else None
    u = units.get(20 * 1800)
    m["army20"] = u.get("army_mv") if u else None
    m["mex20"] = u.get("mex") if u else None
    return m


lines = [f"{tag}: {games} game(s) per variant, vacuum 20 min vs INACTIVE_BOT; mean ±sd [min-max]"]
rows = {}
for n in names:
    rows[n] = []
    for i in range(games):
        p = os.path.join(root, f"runs_stance/{tag}_{n}_{i}.json")
        if os.path.exists(p):
            try:
                rows[n].append(metrics(p))
            except Exception as ex:
                lines.append(f"  {n} game {i}: unreadable ({ex})")
        else:
            lines.append(f"  {n} game {i}: no result")
cols = [("metal income 14m", "inc14"), ("16m", "inc16"), ("18m", "inc18"), ("20m", "inc20"), ("metal pull 20m", "pull20"),
        ("energy income 20m", "einc20"), ("total metal spent", "spent"), ("army value 20m", "army20"), ("mexes 20m", "mex20")]
for label, key in cols:
    lines.append(f"\n{label}")
    for n in names:
        lines.append(f"  {n:11s} {stats([r[key] for r in rows[n]])}")
bad = [(n, i) for n in names for i, r in enumerate(rows[n]) if r["desync"] or r["luafail"]]
lines.append(f"\ndesync / lua failures: {bad or 'none'}")
text = "\n".join(lines)
print(text)
open(os.path.join(root, f"runs_stance/{tag}_summary.txt"), "w").write(text)
