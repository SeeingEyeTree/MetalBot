"""series.py -- run a list of matches one after another (for overnight batches).

    python series.py OUTDIR END_MINUTES label=BOT1|BOT2 [label=BOT1|BOT2 ...]

Each match saves OUTDIR/<label>.json (+ .log with bot_testing's output). A label whose json already exists is
skipped, so a batch can be resumed. BOT2 may be AI:BARb. Read the results with match_summary.py / h2h_report.py.
Extra bot_testing.py arguments for every match go in the SERIES_EXTRA environment variable (e.g. "--no-pin-cores").
"""
import os
import subprocess
import sys
import time

out, endm, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
extra = os.environ.get("SERIES_EXTRA", "").split()
os.makedirs(out, exist_ok=True)
for s in specs:
    label, pair = s.split("=", 1)
    b1, b2 = pair.split("|", 1)
    dst = os.path.join(out, label + ".json")
    if os.path.exists(dst):
        continue
    t = time.time()
    with open(os.path.join(out, label + ".log"), "w") as fh:
        subprocess.run([sys.executable, "bot_testing.py", "--bot1", b1, "--bot2", b2, "--end-minutes", endm,
                        "--save-result", dst] + extra, stdout=fh, stderr=subprocess.STDOUT)
    print(f"{label} done in {time.time() - t:.0f}s", flush=True)
