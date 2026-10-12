"""Paired batch: python runs_stance/batch.py TAG BOT_A BOT_B PAIRS END_MIN [PARALLEL]
Runs PAIRS x (A slot0 / A slot1) single-mode matches, PARALLEL at a time, results in runs_stance/TAG_<i>_<slot>.json,
then prints the paired comparison (A vs B end score = army value + 60 x income, and commander kills)."""
import json, math, os, subprocess, sys, time

tag, A, B, pairs, end = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
par = int(sys.argv[6]) if len(sys.argv) > 6 else 4
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
jobs = []
for i in range(pairs):
    jobs.append((i, "s0", A, B))
    jobs.append((i, "s1", B, A))

def cmd(i, slot, b1, b2):
    out = f"runs_stance/{tag}_{i}_{slot}"
    return ["python", "bot_testing.py", "--bot1", b1, "--bot2", b2, "--server", "single", "--end-minutes", str(end),
            "--duration", str(end * 120 + 600), "--save-result", out + ".json"], out + ".log"

running, queue = [], list(jobs)
while queue or running:
    running = [(p, j) for p, j in running if p.poll() is None]
    while queue and len(running) < par:
        j = queue.pop(0)
        c, log = cmd(*j)
        p = subprocess.Popen(c, cwd=root, stdout=open(os.path.join(root, log), "w"), stderr=subprocess.STDOUT)
        running.append((p, j))
        time.sleep(20)          # stagger the loads
    time.sleep(5)

logs = []
for i in range(pairs):
    row = []
    for slot in ("s0", "s1"):
        path = os.path.join(root, f"runs_stance/{tag}_{i}_{slot}.json")
        try:
            r = json.load(open(path))
        except Exception:
            row.append(None); continue
        a = 0 if slot == "s0" else 1
        d = r.get("draw_score") or {}
        ev = [x for x in r["tracker_timeline"] if x.get("name") == "commander_lost"]
        lost = {e["team"]: e["frame"] for e in ev if e["frame"] < end * 1800 - 60}
        if "score0" in d:
            ratio = d[f"score{a}"] / max(d[f"score{1 - a}"], 1)
        else:
            ratio = None
        row.append({"ratio": ratio, "a_cmdr_lost": a in lost, "b_cmdr_lost": (1 - a) in lost,
                    "desync": r.get("desync"), "luafail": r.get("lua_failure")})
    logs.append(row)
    print(i, row)
ratios = [x["ratio"] for row in logs for x in row if x and x["ratio"]]
wins = sum(1 for row in logs for x in row if x and ((x["b_cmdr_lost"]) or (x["ratio"] and x["ratio"] > 1.1 and not x["a_cmdr_lost"])))
loss = sum(1 for row in logs for x in row if x and ((x["a_cmdr_lost"]) or (x["ratio"] and x["ratio"] < 1 / 1.1 and not x["b_cmdr_lost"])))
if ratios:
    gm = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
    print(f"A={A} vs B={B}: games {len(ratios)}, A wins {wins}, B wins {loss}, geo-mean score ratio A/B {gm:.2f}")
