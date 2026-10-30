"""order_check.py -- prove a refactor changed no orders (CLAUDE.md "Checking a refactor").

    python order_check.py save              # run the scenarios on the current code, store the order streams as the baseline
    python order_check.py check             # run them again and diff against the baseline (exit 1 on any difference)
    python order_check.py check --only STANCE_ECO2

Each scenario is one eco_sim.py vacuum game (ECOSIM_ORDER_DUMP makes the sim write every accepted order and use a fixed `pairs`
order, so two runs of identical code give identical streams).  Baselines live in ecosim/_dump/ (not committed).
"""
import argparse, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(ROOT, "ecosim", "_dump")
SCENARIOS = {                       # name -> eco_sim.py run args
    "STANCE_ECO2": ["--bot", "candidates/STANCE_ECO2", "--seed", "1", "--no-vacuum"],
    "RAID_BOT":    ["--bot", "candidates/RAID_BOT", "--seed", "2", "--no-vacuum"],
    "DRAGON_ECO":  ["--bot", "candidates/DRAGON_ECO", "--seed", "3", "--no-vacuum"],
    "STANCE_ECO2_vac": ["--bot", "candidates/STANCE_ECO2", "--seed", "4"],
    "CORE":        ["--bot", "candidates/CORE", "--seed", "2", "--no-vacuum"],
    "CORE_ROWS_ECO": ["--bot", "candidates/CORE_ROWS_ECO", "--seed", "1", "--no-vacuum"],   # the main CORE (2026-10-28)
}
# A scenario with no baseline of its own is compared with another scenario's baseline: CORE (the config-driven bot) must play
# exactly like RAID_BOT, so it runs RAID_BOT's seed and is diffed against RAID_BOT.base.txt.  `save` skips these.
SAME_AS = {"CORE": "RAID_BOT"}

def run(name, out):
    env = dict(os.environ, ECOSIM_ORDER_DUMP=out)
    cmd = [sys.executable, "eco_sim.py", "run", *SCENARIOS[name], "--tag", "oc_" + name]
    r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    last = [l for l in r.stdout.splitlines() if "orders" in l]
    info = last[-1] if last else r.stdout[-300:] + r.stderr[-300:]
    # a widget error that a bot's own pcall swallowed (printed as "<tag>] error: ...") is not counted in "Lua errors"
    logf = os.path.join(ROOT, "ecosim", "runs", "oc_" + name, "log.txt")
    swallowed = 0
    if os.path.exists(logf):
        swallowed = sum(1 for l in open(logf, encoding="utf-8", errors="replace") if re.search(r"\] (error|ERROR)[: ]", l))
    if swallowed:
        info += f"  SWALLOWED ERRORS: {swallowed}"
        return name, 1, info
    return name, r.returncode, info

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["save", "check"])
    ap.add_argument("--only", action="append")
    a = ap.parse_args()
    names = a.only or list(SCENARIOS)
    if a.mode == "save":
        names = [n for n in names if n not in SAME_AS]
    os.makedirs(DUMP, exist_ok=True)
    suffix = "base" if a.mode == "save" else "new"
    with ThreadPoolExecutor(max_workers=len(names)) as ex:
        results = list(ex.map(lambda n: run(n, os.path.join(DUMP, f"{n}.{suffix}.txt")), names))
    bad = 0
    for name, rc, info in results:
        status = "ok" if rc == 0 else "RUN FAILED"
        if rc != 0: bad += 1
        elif a.mode == "check":
            b, n = (os.path.join(DUMP, f"{SAME_AS.get(name, name) if s == 'base' else name}.{s}.txt") for s in ("base", "new"))
            if not os.path.exists(b): status = "no baseline (run save)"; bad += 1
            else:
                la, lb = open(b).read().splitlines(), open(n).read().splitlines()
                if la == lb: status = f"IDENTICAL ({len(la)} orders)"
                else:
                    i = next((k for k in range(min(len(la), len(lb))) if la[k] != lb[k]), min(len(la), len(lb)))
                    status = f"DIFFERENT: {len(la)} vs {len(lb)} orders, first change at line {i+1}: {la[i] if i < len(la) else '-'} | {lb[i] if i < len(lb) else '-'}"
                    bad += 1
        print(f"{name:18s} {status}   [{info.strip()[:90]}]")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
