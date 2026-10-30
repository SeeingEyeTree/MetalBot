"""Engine test for bar_framework/air_transport.lua: a Valkyrie (corvalk) moves a nano (cornanotc) and a con (corck); it cannot lift an HLLT
(corhllt, mass 10200 > its transportmass 750), which AT.CanCarry and the engine both refuse; the T2 transport (corseah) moves the HLLT.

Runs one short single-client game (single_client.py: one spring-headless, cheats on) with tests/engine/transport_fixture/transport_test.lua
as the "bot" of both teams (only team 0 acts).  The widget spawns the units with /give, calls AT.Move for each load and logs [TT] rows;
this script prints them and exits 0 only when every case came out as expected (4 cases).  Takes about 2-3 minutes.

    python tests/engine/transport_test.py
"""
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
os.chdir(ROOT)

import bot_testing as bt          # noqa: E402
import single_client as sc        # noqa: E402

FIXTURE = Path(__file__).parent / "transport_fixture"


def main():
    t0 = time.time()
    sc.run_match_single(FIXTURE, FIXTURE, duration=420, map_name=bt.MAP_NAME, save_replay=False, verbose=True,
                        end_frame=4 * 60 * 30, eco_weight=60, max_speed=20)
    tmp = Path(os.environ.get("LOCALAPPDATA", "")) / "Temp"
    runs = [d for d in tmp.glob("bottest_*") if d.stat().st_mtime >= t0 - 5]
    if not runs:
        print("no run directory found")
        return 2
    log = max(runs, key=lambda d: d.stat().st_mtime) / "solo" / "infolog.txt"
    text = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
    rows = [l for l in text.splitlines() if "[TT]" in l]
    print("\n".join(rows) if rows else f"no [TT] rows in {log}")
    errs = [l for l in text.splitlines() if "Transport Test" in l and ("rror" in l or "Removed widget" in l)]
    for l in errs[:10]:
        print("ERROR:", l)
    m = re.findall(r"\[TT\] RESULT pass=(\d+) fail=(\d+)", text)
    if not m:
        print("FAIL: no RESULT row")
        return 1
    p, f = map(int, m[-1])
    print(f"{'PASS' if p == 4 and f == 0 else 'FAIL'}: {p} cases as expected, {f} not  (log: {log})")
    return 0 if p == 4 and f == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
