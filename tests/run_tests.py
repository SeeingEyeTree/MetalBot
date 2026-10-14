"""Run every test in tests/ in parallel and print one line per suite.

    python tests/run_tests.py            all suites, 4 at a time
    python tests/run_tests.py -k raid    only suites whose name contains "raid"
    python tests/run_tests.py -j 8 -v    8 at a time, print the output of every suite that fails
    python tests/run_tests.py --list     what would run, and what is skipped or known to fail

Lua suites (tests/test_*.lua) run through lupa's Lua 5.1 (tests/run_lua.py); Python suites (tests/test_*.py) run as scripts.
A suite passes when it exits 0 (run_lua.py maps a Lua test's os.exit(0) to 0) and prints no "FAIL:" line.  Exit status is 1 when any
suite fails that is not listed in KNOWN_FAILING.

Two lists below keep the output honest: SKIP (not tests this runner can run) and KNOWN_FAILING (fail on a clean checkout; the run
says so instead of showing a red line, and says so when one starts passing, so the entry can go).
"""
import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(ROOT, "tests")

# in-game widgets (they define widget:GetInfo and need the engine), not standalone tests
SKIP = {
    "test_blueprint_placer": "in-game widget: needs the engine (deploy it and run a match)",
    "test_com_starter": "in-game widget: needs the engine (deploy it and run a match)",
}
# fail on a clean checkout
KNOWN_FAILING = {
    "test_scout_rings_bot": "2 checks fail (ring radar units on the rings, trickle cap); failed before the 2026-10-14 cleanup too",
}

SUMMARY = re.compile(r"(\d+) checks?, (\d+) (?:failed|failures)")


def discover(pattern):
    names = sorted(f for f in os.listdir(TESTS) if f.startswith("test_") and f.endswith((".lua", ".py")))
    return [n for n in names if pattern in n]


def run_one(name, timeout):
    path = os.path.join("tests", name)
    cmd = [sys.executable, os.path.join("tests", "run_lua.py"), path] if name.endswith(".lua") else [sys.executable, path]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        out, code = (p.stdout or "") + (p.stderr or ""), p.returncode
    except subprocess.TimeoutExpired as e:
        out, code = ((e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")), -999
        out += "\nTIMEOUT after %ds" % timeout
    secs = time.time() - t0
    fails = [l for l in out.splitlines() if l.startswith("FAIL:")]
    m = SUMMARY.findall(out)
    checks = sum(int(a) for a, _ in m) if m else None
    failed = sum(int(b) for _, b in m) if m else None
    ok = code == 0 and not fails and not (failed or 0)
    return {"name": name, "ok": ok, "checks": checks, "failed": failed, "secs": secs, "out": out, "fails": fails}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-k", default="", help="only suites whose file name contains this")
    ap.add_argument("-j", type=int, default=4, help="suites at a time (default 4)")
    ap.add_argument("-v", action="store_true", help="print the output of failing suites")
    ap.add_argument("--timeout", type=int, default=1500, help="seconds per suite (default 1500)")
    ap.add_argument("--list", action="store_true", help="list suites and exit")
    a = ap.parse_args()

    names = discover(a.k)
    run = [n for n in names if os.path.splitext(n)[0] not in SKIP]
    if a.list:
        for n in names:
            stem = os.path.splitext(n)[0]
            tag = "skip: " + SKIP[stem] if stem in SKIP else ("known failing: " + KNOWN_FAILING[stem] if stem in KNOWN_FAILING else "")
            print("%-34s %s" % (n, tag))
        return 0

    t0 = time.time()
    results = []
    with cf.ThreadPoolExecutor(max_workers=max(1, a.j)) as ex:
        futs = {ex.submit(run_one, n, a.timeout): n for n in run}
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            stem = os.path.splitext(r["name"])[0]
            known = stem in KNOWN_FAILING
            tag = "PASS" if r["ok"] else ("KNOWN" if known else "FAIL")
            if r["ok"] and known:
                tag = "PASS*"
            detail = "" if r["checks"] is None else "%d checks" % r["checks"]
            if not r["ok"] and r["failed"]:
                detail += ", %d failed" % r["failed"]
            print("%-6s %-30s %7.1fs  %s" % (tag, r["name"], r["secs"], detail), flush=True)

    bad = [r for r in results if not r["ok"] and os.path.splitext(r["name"])[0] not in KNOWN_FAILING]
    fixed = [r for r in results if r["ok"] and os.path.splitext(r["name"])[0] in KNOWN_FAILING]
    print()
    if a.v:
        for r in sorted(bad, key=lambda r: r["name"]):
            print("---- %s ----" % r["name"])
            print("\n".join(r["out"].strip().splitlines()[-40:]))
            print()
    for r in fixed:
        print("note: %s passes now -- remove it from KNOWN_FAILING in tests/run_tests.py" % r["name"])
    for stem, why in KNOWN_FAILING.items():
        if any(os.path.splitext(r["name"])[0] == stem and not r["ok"] for r in results):
            print("known failing: %s -- %s" % (stem, why))
    for stem, why in SKIP.items():
        if any(os.path.splitext(n)[0] == stem for n in names):
            print("skipped: %s -- %s" % (stem, why))
    print("%d suites, %d passed, %d failed (%.0fs)" % (len(results), sum(r["ok"] for r in results), len(bad), time.time() - t0))
    if bad:
        print("FAILED: " + ", ".join(r["name"] for r in sorted(bad, key=lambda r: r["name"])))
        if not a.v:
            print("(re-run with -v to see their output, or -k <name> to run one)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
