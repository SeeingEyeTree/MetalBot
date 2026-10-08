"""match_summary.py -- one screen per saved match result (bot_testing.py --save-result).

    python match_summary.py result.json [more.json ...]

Per match: winner and how it was decided, the frame each commander died (a real kill, or the end-of-match
self-destruct), END_SCORE of both sides, and per team at fixed checkpoints: army value, metal income, and what
it has LOST to the enemy (all / eco: the tracker's `combat` rows lost_enemy_*, i.e. losses the enemy caused --
so team 1's lost_eco is the eco team 0 destroyed).  The last block is the user's preferred judgement (knowledge/game_mechanics.md 10): enemy eco destroyed, metal wasted, stall.
"""
import json
import sys

CHECKS = (9000, 14400, 18000, 27000, 36000, 54000)


def at(rows, team, frame, key):
    best = None
    for r in rows:
        if r.get("team") == team and r.get("frame", 0) <= frame and key in r:
            if best is None or r["frame"] > best["frame"]:
                best = r
    return best[key] if best and best["frame"] >= frame - 900 else None


def fmt(v, w=8):
    if v is None:
        return f"{'-':>{w}}"
    if isinstance(v, float) and v < 100:
        return f"{v:>{w}.1f}"
    return f"{v:>{w},.0f}"


def summary(path):
    r = json.load(open(path, encoding="utf-8"))
    tl = r.get("tracker_timeline") or []
    names = {0: r.get("bot0_name", "?"), 1: r.get("bot1_name", "?")}
    last = max((x["frame"] for x in tl), default=0)
    print(f"== {path}")
    ds = r.get("draw_score") or {}
    print(f"   winner: team {r.get('winner')} ({names.get(r.get('winner'), '-')}) by {r.get('winner_method')}"
          f"  | end_reason={r.get('end_reason')} last tracker frame={last} ({last / 1800:.1f} min)"
          f"  | wall {r.get('duration_secs', 0):.0f}s")
    if r.get("desync"):
        print(f"   ** DESYNC: {r['desync']['player']} out of sync from frame {r['desync']['frame']}"
              f" ({r['desync']['frame'] / 1800:.1f} min) -- later numbers come from diverged games **")
    if ds:
        print(f"   END_SCORE {names[0]}={ds.get('score0', 0):,.0f}  {names[1]}={ds.get('score1', 0):,.0f}"
              f"  (army {ds.get('mv0', 0):,.0f} / {ds.get('mv1', 0):,.0f}, income {ds.get('metal_inc0', 0):.0f}"
              f" / {ds.get('metal_inc1', 0):.0f})")
    for x in tl:
        if x["kind"] == "event" and x.get("name") == "commander_lost":
            print(f"   commander of team {x['team']} ({names[x['team']]}) died at frame {x['frame']}"
                  f" ({x['frame'] / 1800:.1f} min), killer={x.get('killer')}")
    eco = [x for x in tl if x["kind"] == "eco"]
    army = [x for x in tl if x["kind"] == "army"]
    combat = [x for x in tl if x["kind"] == "combat"]
    print(f"   {'frame':>7} {'min':>5} | " + " | ".join(
        f"{names[t][:12]:>12}: {'army':>8} {'m/s':>6} {'lost_mv':>8} {'lost_eco':>8}" for t in (0, 1)))
    for f in CHECKS:
        if f > last + 900:
            break
        parts = []
        for t in (0, 1):
            parts.append(f"{'':>12}  {fmt(at(army, t, f, 'mv'))} {fmt(at(eco, t, f, 'metal_inc'), 6)}"
                         f" {fmt(at(combat, t, f, 'lost_enemy_mv'))} {fmt(at(combat, t, f, 'lost_enemy_eco_mv'))}")
        print(f"   {f:>7} {f / 1800:>5.1f} | " + " | ".join(parts))
    for t in (0, 1):
        e = [x for x in eco if x["team"] == t]
        if e:
            x = e[-1]
            print(f"   {names[t]}: metal wasted (excess) {x.get('metal_excess', 0):,.0f}, "
                  f"stall_m {x.get('stall_m', '-')}, stall_e {x.get('stall_e', '-')}, float_m {x.get('float_m', '-')}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        summary(p)
