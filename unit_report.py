"""Per-unit-type report of a match: built, lost, and what each type killed (2026-10-25).

    python unit_report.py <infolog.txt | run game.log>          # both teams
    python unit_report.py <log> --team 0 --min-built 3 --until 45000

Reads the harness's [STATS] rows: "built" (a unit started) and "destroyed ... attacker_team=N attacker_def=NAME" (attacker_def
since 2026-10-25; older logs have no killer type, so the kill columns stay empty).  A run's game.log is followed to its
"Write dir" (single mode: <dir>/solo/infolog.txt).  In single mode every event is logged by both teams' widgets (<T0>/<T1>);
each event is counted once, from the log of the team whose unit it was.

Columns per type: built, lost (to the enemy), value lost, kills (enemy units it killed), value killed, kill/cost
(value killed / value built).  Values are metal cost (the row's mv).  Rows after --until (default 45000 = 25:00, before the
end-of-match self-destructs) are ignored; self-destructs have attacker_team -1 and never count as losses.
"""
import argparse
import os
import re
import sys
from collections import defaultdict

ROW = re.compile(r"\[STATS\] (built|factory|destroyed) frame=(\d+) team=(\d+) def=(\S+) mv=(\d+)"
                 r"(?: nc\[0\]=\d+ nc\[1\]=\d+)?(?: attacker_team=(-?\d+))?(?: attacker_def=(\S+))?")
TAG = re.compile(r"<T(\d)>")


def find_log(path):
    if os.path.isdir(path):
        for cand in (os.path.join(path, "solo", "infolog.txt"), os.path.join(path, "infolog.txt")):
            if os.path.exists(cand):
                return cand
    if path.endswith("game.log"):
        for line in open(path, encoding="utf-8", errors="ignore"):
            m = re.match(r"Write dir\s*:\s*(.+?)\s+\(", line)
            if m:
                return find_log(m.group(1).strip())
    return path


def parse(path, until):
    """Returns {team: {def: stats}} with stats = built, mv, lost, lostV, kills, killV."""
    stats = defaultdict(lambda: defaultdict(lambda: {"built": 0, "mv": 0, "lost": 0, "lostV": 0, "kills": 0, "killV": 0}))
    tagged = None
    for line in open(path, encoding="utf-8", errors="ignore"):
        m = ROW.search(line)
        if not m:
            continue
        kind, frame, team, name, mv, ateam, adef = m.groups()
        frame, team, mv = int(frame), int(team), int(mv)
        if frame > until:
            continue
        t = TAG.search(line)
        if tagged is None:
            tagged = t is not None
        if tagged and (not t or int(t.group(1)) != team):
            continue                       # single mode: the event once, from its own team's log
        s = stats[team][name]
        if kind in ("built", "factory"):
            s["built"] += 1
            s["mv"] = mv
        else:
            ateam = int(ateam) if ateam is not None else -1
            if ateam < 0 or ateam == team:
                continue                   # self-destruct / reclaim / own fire: not a loss to the enemy
            s["lost"] += 1
            s["lostV"] += mv
            s["mv"] = s["mv"] or mv
            if adef and adef != "-":
                k = stats[ateam][adef]
                k["kills"] += 1
                k["killV"] += mv
    return stats


def report(stats, teams, min_built, out=sys.stdout):
    for team in teams:
        rows = []
        for name, s in stats.get(team, {}).items():
            if s["built"] < min_built and s["kills"] == 0:
                continue
            spent = s["built"] * s["mv"]
            ratio = (s["killV"] / spent) if spent > 0 else None
            rows.append((s["killV"], name, s, spent, ratio))
        rows.sort(key=lambda r: (-r[0], -r[3]))
        print(f"== team {team}", file=out)
        print(f"{'type':<12}{'built':>7}{'lost':>7}{'value lost':>12}{'kills':>7}{'value killed':>14}{'kill/cost':>11}", file=out)
        for killV, name, s, spent, ratio in rows:
            r = f"{ratio:.2f}" if ratio is not None else "-"
            print(f"{name:<12}{s['built']:>7}{s['lost']:>7}{s['lostV']:>12}{s['kills']:>7}{killV:>14}{r:>11}", file=out)
        print(file=out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--team", type=int, action="append")
    ap.add_argument("--min-built", type=int, default=3)
    ap.add_argument("--until", type=int, default=45000)
    a = ap.parse_args()
    path = find_log(a.log)
    stats = parse(path, a.until)
    report(stats, a.team or sorted(stats), a.min_built)


if __name__ == "__main__":
    main()
