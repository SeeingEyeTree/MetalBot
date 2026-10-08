"""Summarise how a human controlled units, from human_control_logger.lua output.

    python human_control_report.py                 # newest metalbot_human_*.log in BAR's LuaUI/Config
    python human_control_report.py FILE [--json]   # a log file, or an infolog.txt containing [HCL] lines

Prints the things a unit controller would need to copy: how often and how big the orders are, move vs
fight vs attack, whether the army is kept as one blob, when and how far it is sent out, whether it
pulls back hurt, what is queued, how selections/groups are used, and where the camera goes.
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict
from statistics import mean, median

KV = re.compile(r"(\w+)=(\S+)")


def find_log():
    roots = [os.path.expandvars(r"%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\LuaUI\Config"),
             os.path.expandvars(r"%ProgramFiles%\Beyond-All-Reason\data\LuaUI\Config")]
    files = []
    for r in roots:
        files += glob.glob(os.path.join(r, "metalbot_human_*.log"))
    return max(files, key=os.path.getmtime) if files else None


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            i = line.find("[HCL] ")
            if i < 0:
                continue
            parts = line[i + 6:].rstrip("\n").split(" ", 1)
            kind, rest = parts[0], parts[1] if len(parts) > 1 else ""
            d = {k: v for k, v in KV.findall(rest)}
            d["kind"] = kind
            d["f"] = int(num(d.get("f")) or 0)
            rows.append(d)
    return rows


def comp_counts(s):
    out = Counter()
    for item in (s or "").split(","):
        if ":" in item:
            n, c = item.rsplit(":", 1)
            out[n] += int(c)
    return out


def pct(a, b):
    return f"{100 * a / b:.0f}%" if b else "-"


def mm(f):
    s = int(f / 30)
    return f"{s // 60}:{s % 60:02d}"


def analyse(rows):
    r = {}
    # Engine-issued noise (nano auto-repair, state toggles, unknown cmdNNN) and orders to non-army units are
    # not army control; keep them out of the stats and count them separately.
    NOISE = {"repair", "move_state", "fire_state", "onoff", "repeat", "build"}
    BUILDERS = ("corck", "corcv", "cornecro", "coraca", "corack", "coracv", "corca", "corcom", "corfink",
                "cormls", "corwin", "cormex")

    def army_comp(c):
        return any(not n.startswith(BUILDERS) and not n.endswith("nanotc") for n in comp_counts(c.get("comp")))
    allcmds = [x for x in rows if x["kind"] == "cmd"]
    cmds = [x for x in allcmds if x.get("cmd") not in NOISE and not x.get("cmd", "").startswith("cmd")
            and army_comp(x)]
    r["ignored_orders"] = Counter(x["cmd"] for x in allcmds if x not in cmds)
    ctx = [x for x in rows if x["kind"] == "ctx"]
    fights = [x for x in rows if x["kind"] == "fight"]
    queues = [x for x in rows if x["kind"] == "queue"]
    sels = [x for x in rows if x["kind"] == "sel"]
    groups = [x for x in rows if x["kind"] == "group"]
    cams = [x for x in rows if x["kind"] == "cam"]
    last_f = max((x["f"] for x in rows), default=0)
    r["duration_f"] = last_f
    mins = max(last_f / 1800.0, 1e-9)

    # Orders to army (armed mobile) vs everything else is not distinguishable per row, so use the type mix.
    by_cmd = Counter()
    units_by_cmd = Counter()
    for c in cmds:
        by_cmd[c["cmd"]] += 1
        units_by_cmd[c["cmd"]] += int(num(c.get("n")) or 0)
    r["orders"] = {"total": len(cmds), "per_min": len(cmds) / mins, "by_cmd": dict(by_cmd),
                   "units_by_cmd": dict(units_by_cmd),
                   "shift_frac": mean([num(c["shift"]) or 0 for c in cmds]) if cmds else 0}
    sizes = [int(num(c["n"])) for c in cmds]
    r["order_size"] = {"median": median(sizes), "mean": mean(sizes), "max": max(sizes)} if sizes else {}
    r["whole_selection_frac"] = mean([num(c.get("sel")) or 0 for c in cmds]) if cmds else 0

    # Streams: orders on similar units within 1.5 s of each other are one drag / steering gesture.
    cur, gestures = None, []
    for c in sorted([c for c in cmds if c["cmd"] in ("move", "fight", "attack", "patrol")], key=lambda c: c["f"]):
        n = int(num(c["n"]))
        if cur and c["f"] - cur["last"] <= 45 and (cur["key"] == c["comp"] or n >= 0.6 * cur["n"]):
            cur["last"] = c["f"]; cur["k"] += 1; cur["end"] = c
        else:
            cur = {"first": c["f"], "last": c["f"], "key": c["comp"], "n": n, "k": 1, "start": c, "end": c}
            gestures.append(cur)
    glist = [{"t": mm(g["first"]), "dur_s": round((g["last"] - g["first"]) / 30, 1), "orders": g["k"], "n": g["n"],
              "cmd": g["start"]["cmd"], "comp": g["start"]["comp"], "enemy_near": g["start"]["enemy_near"],
              "out_first": g["start"]["out"], "out_last": g["end"]["out"], "hp": g["start"]["hp"],
              "enemy_d": g["start"]["enemy_d"]} for g in gestures]
    r["gestures"] = {"count": len(glist), "per_min": len(glist) / mins,
                     "single": sum(1 for g in glist if g["orders"] == 1),
                     "steered": sum(1 for g in glist if g["orders"] >= 4),
                     "steered_enemy_near": sum(1 for g in glist if g["orders"] >= 4 and num(g["enemy_near"]) > 0),
                     "median_orders": median([g["orders"] for g in glist]) if glist else None,
                     "median_dur_s": median([g["dur_s"] for g in glist]) if glist else None, "list": glist}

    # Direction and distance of army moves (move/fight/attack/patrol only).
    mv = [c for c in cmds if c["cmd"] in ("move", "fight", "attack", "patrol") and num(c.get("tx")) is not None
          and int(num(c["n"])) >= 3]
    r["army_orders"] = {
        "n": len(mv),
        "out_median": median([num(c["out"]) for c in mv]) if mv else None,
        "dist_median": median([num(c["dist"]) for c in mv]) if mv else None,
        "to_base_median": median([num(c["to_base"]) for c in mv]) if mv else None,
        "outward_frac": mean([1.0 if num(c["out"]) > 0 else 0.0 for c in mv]) if mv else None,
        "at_enemy_frac": mean([1.0 if 0 <= num(c["enemy_d"]) < 600 else 0.0 for c in mv]) if mv else None,
        "with_enemy_near_frac": mean([1.0 if num(c["enemy_near"]) > 0 else 0.0 for c in mv]) if mv else None,
    }

    # Retreats: a pull-back (out < -300) of units that are hurt or have enemies near.
    retreats = [c for c in mv if num(c["out"]) < -300 and (num(c["enemy_near"]) > 0 or 0 <= num(c["hp"]) < 0.6)]
    r["retreats"] = [{"t": mm(c["f"]), "n": c["n"], "hp": c["hp"], "enemy_near": c["enemy_near"],
                      "out": c["out"], "comp": c["comp"]} for c in retreats][:15]

    # Attack-move vs plain move when enemies are near / far.
    near = Counter(); far = Counter()
    for c in mv:
        (near if num(c["enemy_near"]) > 0 else far)[c["cmd"]] += 1
    r["cmd_when_enemy_near"] = dict(near)
    r["cmd_when_no_enemy_near"] = dict(far)

    # Targeted attacks: what units it picks out.
    tdefs = Counter(c["tdef"] for c in cmds if c["cmd"] in ("attack", "guard", "reclaim", "repair") and c.get("tdef") not in (None, "-"))
    r["targeted"] = dict(tdefs.most_common(10))
    r["other_cmds"] = {k: v for k, v in by_cmd.items() if k not in ("move", "fight", "attack", "patrol")}

    # Context: army cohesion, idleness, size over time, first enemy contact and reaction.
    if ctx:
        spread = [num(x["spread"]) for x in ctx if int(num(x["army_n"])) >= 5]
        idle = [num(x["idle"]) / max(num(x["army_n"]), 1) for x in ctx if int(num(x["army_n"])) >= 5]
        r["army"] = {
            "peak_n": max(int(num(x["army_n"])) for x in ctx),
            "peak_mv": max(int(num(x["army_mv"])) for x in ctx),
            "spread_median": median(spread) if spread else None,
            "idle_frac_mean": mean(idle) if idle else None,
            "from_base_median": median([num(x["from_base"]) for x in ctx if int(num(x["army_n"])) >= 5] or [0]),
            "from_base_max": max(num(x["from_base"]) for x in ctx),
        }
        first_enemy = next((x for x in ctx if int(num(x["enemies"])) > 0), None)
        r["first_enemy_seen"] = mm(first_enemy["f"]) if first_enemy else None
        # timeline: one row per minute
        tl = {}
        for x in ctx:
            tl[x["f"] // 1800] = x
        r["timeline"] = [{"min": m, "army_n": x["army_n"], "army_mv": x["army_mv"], "from_base": x["from_base"],
                          "spread": x["spread"], "idle": x["idle"], "enemies": x["enemies"],
                          "comp": x["comp"]} for m, x in sorted(tl.items())]
        # Army composition at peak
        peak = max(ctx, key=lambda x: int(num(x["army_mv"])))
        r["peak_comp"] = peak["comp"]

    # Reaction time: first order after an enemy first comes within 900 of the army.
    if ctx and cmds:
        contact = next((x for x in ctx if 0 <= num(x["enemy_nearest"]) < 900 and int(num(x["army_n"])) >= 3), None)
        if contact:
            nxt = next((c for c in mv if c["f"] >= contact["f"]), None)
            r["first_contact"] = {"t": mm(contact["f"]), "enemy_nearest": contact["enemy_nearest"],
                                  "reaction_s": round((nxt["f"] - contact["f"]) / 30.0, 1) if nxt else None}

    r["fights"] = {"n": len(fights),
                   "dmg_taken": sum(int(num(f["dmg_taken"])) for f in fights),
                   "losses": sum(int(num(f["losses"])) for f in fights),
                   "kills": sum(int(num(f["kills"])) for f in fights),
                   "from_base_median": median([num(f["from_base"]) for f in fights]) if fights else None,
                   "list": [{"t": mm(f["f"]), "dur_s": round(int(num(f["dur"])) / 30), "dmg": f["dmg_taken"],
                             "lost": f["losses"], "killed": f["kills"], "from_base": f["from_base"],
                             "lost_comp": f["lost"], "killed_comp": f["killed"]} for f in fights][:25]}

    q = Counter()
    for x in queues:
        q[x["unit"]] += int(num(x["n"]) or 1)
    first_q = defaultdict(lambda: None)
    for x in queues:
        first_q[x["unit"]] = first_q[x["unit"]] if first_q[x["unit"]] is not None else mm(x["f"])
    r["queued"] = {u: {"count": c, "first": first_q[u]} for u, c in q.most_common()}
    r["queue_front_frac"] = mean([num(x.get("front")) or 0 for x in queues]) if queues else None

    sel_sizes = [int(num(s["n"])) for s in sels]
    r["selections"] = {"n": len(sels), "per_min": len(sels) / mins,
                       "median_size": median(sel_sizes) if sel_sizes else None,
                       "big_selections": sum(1 for n in sel_sizes if n >= 10)}
    g_final = {}
    for g in groups:
        g_final[g["g"]] = g
    r["groups_used"] = sorted(int(g) for g, v in g_final.items() if int(num(v["n"])) > 0 or True)
    r["group_changes"] = len(groups)
    r["group_final"] = {g: {"n": v["n"], "comp": v["comp"]} for g, v in g_final.items()}

    if cams:
        xs = [(num(c["x"]), num(c["z"]), num(c["h"])) for c in cams if num(c.get("x")) is not None]
        r["camera"] = {"samples": len(xs), "height_median": median([h for _, _, h in xs]),
                       "jumps": sum(1 for a, b in zip(xs, xs[1:]) if ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5 > 2500)}
    return r


def show(r):
    o = r["orders"]
    print(f"Game length logged: {mm(r['duration_f'])}")
    print(f"\nOrders (non-build): {o['total']}  ({o['per_min']:.1f}/min), shift-queued {o['shift_frac']:.0%}, "
          f"whole selection {r['whole_selection_frac']:.0%}")
    for k, v in sorted(o["by_cmd"].items(), key=lambda kv: -kv[1]):
        print(f"  {k:<12} {v:>4} orders  {o['units_by_cmd'][k]:>5} unit-orders")
    print(f"  ignored (engine/builder noise): {dict(r['ignored_orders'])}")
    g = r["gestures"]
    print(f"\nGestures (orders <1.5 s apart merged): {g['count']} ({g['per_min']:.1f}/min); single clicks {g['single']}, "
          f"steered (4+ orders) {g['steered']}, of which enemies near {g['steered_enemy_near']}; "
          f"median {g['median_orders']} orders / {g['median_dur_s']}s")
    if r["order_size"]:
        s = r["order_size"]
        print(f"  units per order: median {s['median']:.0f}, mean {s['mean']:.1f}, max {s['max']}")
    a = r["army_orders"]
    if a["n"]:
        print(f"\nArmy movement orders (>=3 units, with a ground target): {a['n']}")
        print(f"  sent outward from base {a['outward_frac']:.0%}; median push {a['out_median']:.0f} elmos; "
              f"median leg length {a['dist_median']:.0f}; median target distance from base {a['to_base_median']:.0f}")
        print(f"  target within 600 of a visible enemy {a['at_enemy_frac']:.0%}; "
              f"ordered with enemies near the army {a['with_enemy_near_frac']:.0%}")
        print(f"  command when enemy near: {r['cmd_when_enemy_near']}   when none near: {r['cmd_when_no_enemy_near']}")
    if r["retreats"]:
        print("\nRetreats (pull-back >300 elmos while hurt or enemies near):")
        for c in r["retreats"]:
            print(f"  {c['t']} n={c['n']} hp={c['hp']} enemy_near={c['enemy_near']} out={c['out']} {c['comp']}")
    if r["targeted"]:
        print(f"\nFocus targets (attack/guard/reclaim/repair on a unit): {r['targeted']}")
    if r["other_cmds"]:
        print(f"Other commands: {r['other_cmds']}")
    if "army" in r:
        ar = r["army"]
        print(f"\nArmy: peak {ar['peak_n']} units / {ar['peak_mv']} metal; median spread "
              f"{ar['spread_median'] or 0:.0f}; idle {ar['idle_frac_mean'] or 0:.0%}; median distance from base "
              f"{ar['from_base_median']:.0f} (max {ar['from_base_max']:.0f}); peak comp: {r.get('peak_comp')}")
        print(f"  first enemy seen {r.get('first_enemy_seen')}", end="")
        if "first_contact" in r:
            fc = r["first_contact"]
            print(f"; first contact {fc['t']} (nearest {fc['enemy_nearest']}), first order reaction {fc['reaction_s']}s")
        else:
            print()
        print("  per minute: min | army n | mv | from_base | spread | idle | enemies")
        for t in r["timeline"]:
            print(f"    {t['min']:>3} | {t['army_n']:>5} | {t['army_mv']:>6} | {t['from_base']:>5} | {t['spread']:>5} "
                  f"| {t['idle']:>4} | {t['enemies']:>3}")
    f = r["fights"]
    print(f"\nFights: {f['n']} bursts, dmg taken {f['dmg_taken']}, units lost {f['losses']}, kills {f['kills']}")
    for x in f["list"][:12]:
        print(f"  {x['t']} {x['dur_s']}s dmg={x['dmg']} lost={x['lost']} killed={x['killed']} "
              f"base_dist={x['from_base']} lost:{x['lost_comp']} killed:{x['killed_comp']}")
    if r["queued"]:
        print("\nLab queue (what you built, first queued at):")
        for u, v in r["queued"].items():
            print(f"  {u:<18} x{v['count']:<4} from {v['first']}")
    s = r["selections"]
    print(f"\nSelections: {s['n']} ({s['per_min']:.1f}/min), median size {s['median_size']}, "
          f"{s['big_selections']} of 10+ units")
    print(f"Control groups: {r['group_changes']} changes; final: {r['group_final'] or 'none used'}")
    if "camera" in r:
        c = r["camera"]
        print(f"Camera: median height {c['height_median']:.0f}, {c['jumps']} large jumps (>2500 elmos)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    path = args.path or find_log()
    if not path or not os.path.exists(path):
        sys.exit("No log found. Play with candidates/LINE_HUMAN deployed, or pass a file.")
    rows = parse(path)
    if not rows:
        sys.exit(f"No [HCL] rows in {path}")
    r = analyse(rows)
    if args.json:
        print(json.dumps(r, indent=1, default=str))
    else:
        print(f"Log: {path}\n")
        show(r)


if __name__ == "__main__":
    main()
