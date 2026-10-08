"""h2h_report.py -- tally a head-to-head series between two bots (results from series.py / bot_testing.py).

    python h2h_report.py NAME_A result1.json result2.json ...

NAME_A is the candidate's player-name prefix (e.g. LINE_CLICK_v3; the folder name). For every match: which slot A
had, the winner and how (commander kill / END_SCORE / tie), and A's END_SCORE / B's. Then A's record and the geometric
mean of the score ratio per slot order, as ab_test.py does for army value (slot bias cancels across the two orders).
A commander kill counts as a win whatever the score; a tie is END_SCORE within 10%.
"""
import json
import math
import statistics
import sys


def main():
    a_name, paths = sys.argv[1], sys.argv[2:]
    wins = losses = ties = 0
    ratios = {0: [], 1: []}
    for p in paths:
        r = json.load(open(p, encoding="utf-8"))
        n0, n1 = r.get("bot0_name", ""), r.get("bot1_name", "")
        a_slot = 0 if n0 == a_name else 1 if n1 == a_name else None
        if a_slot is None:
            print(f"{p}: {a_name} not in ({n0}, {n1})")
            continue
        w, how = r.get("winner"), r.get("winner_method")
        ds = r.get("draw_score") or {}
        sa, sb = ds.get(f"score{a_slot}"), ds.get(f"score{1 - a_slot}")
        kill = None
        for x in r.get("tracker_timeline") or []:
            if x["kind"] == "event" and x.get("name") == "commander_lost" and (not ds or x["frame"] < ds.get("frame0", 1e9) - 60):
                kill = (x["team"], x["frame"])
                break
        if kill:
            res = "WIN" if kill[0] != a_slot else "LOSS"
            detail = f"commander of team {kill[0]} killed at {kill[1] / 1800:.1f} min"
        elif sa and sb:
            ratio = sa / sb
            ratios[a_slot].append(ratio)
            res = "TIE" if 1 / 1.1 < ratio < 1.1 else ("WIN" if ratio > 1 else "LOSS")
            detail = f"END_SCORE {sa:,.0f} vs {sb:,.0f} ({ratio:.2f}x)"
        else:
            res, detail = "?", f"winner={w} by {how} (no score: desync / cut short?)"
        wins += res == "WIN"; losses += res == "LOSS"; ties += res == "TIE"
        print(f"{res:5} A in slot {a_slot}: {detail}   [{p.split(chr(92))[-1]}]")
    print(f"\n{a_name}: {wins} wins, {losses} losses, {ties} ties")
    per = [statistics.geometric_mean(ratios[s]) for s in (0, 1) if ratios[s]]
    if len(per) == 2:
        print(f"END_SCORE ratio, geometric mean over the two slot orders: {math.sqrt(per[0] * per[1]):.3f}"
              f" (slot 0: {per[0]:.3f}, slot 1: {per[1]:.3f}; games ended by a kill are not in it)")


if __name__ == "__main__":
    main()
