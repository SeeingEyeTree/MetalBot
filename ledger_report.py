"""ledger_report.py -- read the [LED] rows of ledger_logger.lua and say where a bot (or a person) loses value.

    python ledger_report.py                       newest LuaUI/Config/metalbot_ledger_*.log in the BAR data folder
    python ledger_report.py game.log infolog.txt  any text files with [LED] rows (an infolog, a harness log, a ledger log)
    python ledger_report.py a.log --vs b.log      two games side by side (spend and fight totals)
    python ledger_report.py a.log --json          the summary as JSON
    python ledger_report.py a.log --team 0        single-client logs tag every line <T0>/<T1>: pick one

Three ledgers (what each row means: the header of ledger_logger.lua; what a unit is worth: bar_framework/value_weights.lua):
  SPEND  where the income went (army / bp / eco / defence ...) and, when it did not go, why (unit cap, idle labs, energy, build power ...).
         Unspent metal = sum of (income - pull) x 30 s over the rows where the bank is filling.
  FIGHT  what each side lost, value-weighted (eco = cost + 60 s of income, build power the most): killed / lost per category, the biggest
         fights, what died most.  "Damage to the enemy's future" is killed_eco + killed_bp.
  SCOUT  the lead: seconds between an enemy being first seen and reaching 1800 elmos from home, per arrival wave; the surprise rate.
Ends with GAPS: the three largest, each in metal-equivalent where it can be.
"""
import argparse
import glob
import json
import os
import re
import statistics
import sys

LED = re.compile(r"\[LED\]\s+(\w+)\s*(.*)$")
KV = re.compile(r"(\w+)=(\S+)")
TEAM = re.compile(r"<T(\d)>")
CATS = ["army", "eco", "bp", "defence", "commander", "other"]
SPEND_KINDS = ["army_ground", "army_air", "bp", "eco", "defence", "commander", "other"]
SPEND_SECONDS = 30            # the spend row's interval (ledger_logger SPEND_EVERY / 30)


def _num(v):
    try:
        return float(v)
    except ValueError:
        return v


def parse_lines(lines, team=None):
    """-> {'spend': [...], 'fight': [...], 'value': [...], 'scout': [...], 'init': [...]} of dicts (key=value fields, numbers parsed)."""
    out = {"spend": [], "fight": [], "value": [], "scout": [], "init": [], "error": []}
    for line in lines:
        m = LED.search(line)
        if not m:
            continue
        t = TEAM.search(line)
        if team is not None and (not t or int(t.group(1)) != team):
            continue
        kind, rest = m.group(1), m.group(2)
        row = {k: _num(v) for k, v in KV.findall(rest)}
        tm = re.search(r"f=(\d+)\s+t=(\d+):(\d+)", rest)
        if tm:
            row["f"] = int(tm.group(1))
            row["t"] = int(tm.group(2)) * 60 + int(tm.group(3))
        if kind in out:
            out[kind].append(row)
        elif kind == "error" or kind.startswith("error"):
            out["error"].append(row)
    return out


def read_files(paths, team=None):
    lines = []
    for p in paths:
        with open(p, encoding="utf-8", errors="replace") as f:
            lines.extend(f)
    return parse_lines(lines, team)


def newest_log():
    cands = []
    for base in (os.path.expandvars(r"%LOCALAPPDATA%\Programs\Beyond-All-Reason\data"), os.path.expandvars(r"%ProgramFiles%\Beyond-All-Reason\data")):
        cands += glob.glob(os.path.join(base, "LuaUI", "Config", "metalbot_ledger_*.log"))
    return max(cands, key=os.path.getmtime) if cands else None


# ── summaries ─────────────────────────────────────────────────────────────────

def summarize_spend(rows):
    if not rows:
        return None
    n = len(rows)
    inc = sum(r.get("m_inc", 0) for r in rows) * SPEND_SECONDS
    pull = sum(r.get("m_pull", 0) for r in rows) * SPEND_SECONDS
    kinds = {k: sum(r.get("to_" + k, 0) for r in rows) * SPEND_SECONDS for k in SPEND_KINDS}
    why = {}
    unspent_by = {}
    for r in rows:
        w = r.get("why", "?")
        why[w] = why.get(w, 0) + 1
        if w != "spending":
            gap = max(0.0, r.get("m_inc", 0) - r.get("m_pull", 0)) * SPEND_SECONDS
            unspent_by[w] = unspent_by.get(w, 0) + gap
    return {
        "rows": n, "income": inc, "pulled": pull, "unspent": sum(unspent_by.values()), "unspent_by_reason": unspent_by,
        "by_kind": kinds, "why_rows": why,
        "peak_bank": max(r.get("m_bank", 0) for r in rows),
        "unexplained": sum(r.get("unexplained", 0) for r in rows) * SPEND_SECONDS,
        "idle_lab_rows": sum(1 for r in rows if r.get("labs_idle", 0) > 0),
        "last_t": rows[-1].get("t", 0),
    }


def summarize_fight(rows, value_rows=None):
    lost = {c: 0.0 for c in CATS}
    killed = {c: 0.0 for c in CATS}
    for r in rows:
        for c in CATS:
            lost[c] += r.get("lost_" + c, 0)
            killed[c] += r.get("killed_" + c, 0)
    if not rows and value_rows:          # no fight rows: fall back to the last cumulative value row
        last = value_rows[-1]
        for c in CATS:
            lost[c], killed[c] = last.get("lost_" + c, 0), last.get("killed_" + c, 0)
    tl, tk = sum(lost.values()), sum(killed.values())
    top = sorted(rows, key=lambda r: -(r.get("lost", 0) + r.get("killed", 0)))[:5]
    names = {}
    for r in rows:
        for fld in ("top_killed",):
            if isinstance(r.get(fld), str) and r[fld] != "-":
                for part in r[fld].split(","):
                    nm, _, cnt = part.rpartition(":")
                    names[nm] = names.get(nm, 0) + int(cnt or 0)
    return {
        "fights": len(rows), "lost": lost, "killed": killed, "lost_total": tl, "killed_total": tk,
        "ratio": (tk / tl) if tl else None,
        "future_killed": killed["eco"] + killed["bp"],       # enemy economy and build power destroyed: their future value
        "future_lost": lost["eco"] + lost["bp"],
        "biggest": [{"t": r.get("t"), "lost": r.get("lost"), "killed": r.get("killed"), "ratio": r.get("ratio"), "x": r.get("x"), "z": r.get("z")} for r in top],
        "most_killed": sorted(names.items(), key=lambda kv: -kv[1])[:8],
    }


def summarize_scout(rows):
    if not rows:
        return None
    leads = [r.get("lead_s", 0) for r in rows]
    return {
        "waves": len(rows), "median_lead_s": statistics.median(leads), "min_lead_s": min(leads),
        "surprises": sum(1 for r in rows if r.get("surprise") == 1),
        "surprise_rate": sum(1 for r in rows if r.get("surprise") == 1) / len(rows),
        "first_wave_t": rows[0].get("t"), "first_wave_lead_s": rows[0].get("lead_s"),
        "by_unit": _count(r.get("unit", "?") for r in rows),
        "by_seen": _count(r.get("seen_by", "?") for r in rows),
        "median_seen_d": statistics.median([r.get("seen_d", 0) for r in rows]),
    }


def _count(it):
    d = {}
    for x in it:
        d[x] = d.get(x, 0) + 1
    return d


def gaps(spend, fight, scout):
    """The three largest gaps, in metal-equivalent where possible, biggest first."""
    g = []
    if spend and spend["unspent"] > 0:
        why = max(spend["unspent_by_reason"].items(), key=lambda kv: kv[1])
        g.append((spend["unspent"], "unspent income: %.0fk metal (mostly why=%s, %.0fk)" % (spend["unspent"] / 1000, why[0], why[1] / 1000)))
    if fight and fight["lost_total"]:
        net = fight["lost_total"] - fight["killed_total"]
        if net > 0:
            g.append((net, "lost %.0fk more value than killed (ratio %.2f); %.0fk of our eco+bp died vs %.0fk of theirs" % (
                net / 1000, fight["ratio"] or 0, fight["future_lost"] / 1000, fight["future_killed"] / 1000)))
        elif fight["future_killed"] < fight["future_lost"]:
            g.append((fight["future_lost"] - fight["future_killed"], "won the army trade but lost more eco+bp (%.0fk) than we killed (%.0fk)" % (
                fight["future_lost"] / 1000, fight["future_killed"] / 1000)))
    if scout and scout["surprises"]:
        g.append((scout["surprise_rate"] * 1000, "%d of %d arrival waves were surprises (lead < 5 s); median lead %.0f s, seen at %.0f elmos" % (
            scout["surprises"], scout["waves"], scout["median_lead_s"], scout["median_seen_d"])))
    g.sort(key=lambda x: -x[0])
    return [t for _, t in g[:3]]


def summarize(data):
    sp, fi, sc = summarize_spend(data["spend"]), summarize_fight(data["fight"], data["value"]), summarize_scout(data["scout"])
    return {"spend": sp, "fight": fi if (data["fight"] or data["value"]) else None, "scout": sc, "gaps": gaps(sp, fi if (data["fight"] or data["value"]) else None, sc),
            "errors": len(data["error"])}


# ── text ──────────────────────────────────────────────────────────────────────

def k(x):
    return "%.0fk" % (x / 1000.0) if abs(x) >= 1000 else "%.0f" % x


def text_report(name, data, s):
    out = ["=== %s ===" % name]
    sp = s["spend"]
    if sp:
        out.append("SPEND  %d rows, to %d:%02d.  income %s, pulled %s (%.0f%%), unspent %s, unexplained %s, peak bank %.0f%%" % (
            sp["rows"], sp["last_t"] // 60, sp["last_t"] % 60, k(sp["income"]), k(sp["pulled"]), 100 * sp["pulled"] / max(1, sp["income"]),
            k(sp["unspent"]), k(sp["unexplained"]), 100 * sp["peak_bank"]))
        tot = max(1.0, sum(sp["by_kind"].values()))
        out.append("  metal went into: " + ", ".join("%s %.0f%%" % (kk, 100 * v / tot) for kk, v in sorted(sp["by_kind"].items(), key=lambda kv: -kv[1]) if v > 0))
        out.append("  not spending, by reason: " + (", ".join("%s %s (%d rows)" % (w, k(v), sp["why_rows"].get(w, 0))
                   for w, v in sorted(sp["unspent_by_reason"].items(), key=lambda kv: -kv[1])) or "none"))
        # a coarse timeline: every 5th row
        out.append("  timeline (t, income, pull, bank, labs idle, why):")
        for r in data["spend"][::max(1, len(data["spend"]) // 10)]:
            out.append("    %2d:%02d  %6.0f %6.0f  %3.0f%%  idle %d  %s" % (r.get("t", 0) // 60, r.get("t", 0) % 60, r.get("m_inc", 0), r.get("m_pull", 0),
                       100 * r.get("m_bank", 0), r.get("labs_idle", 0), r.get("why", "?")))
    else:
        out.append("SPEND  no rows")
    fi = s["fight"]
    if fi:
        out.append("FIGHT  %d fights.  we lost %s, killed %s (value ratio %s)" % (fi["fights"], k(fi["lost_total"]), k(fi["killed_total"]),
                   "%.2f" % fi["ratio"] if fi["ratio"] is not None else "-"))
        out.append("  by category (lost / killed): " + ", ".join("%s %s/%s" % (c, k(fi["lost"][c]), k(fi["killed"][c])) for c in CATS))
        out.append("  enemy future destroyed (eco + build power): %s;  ours: %s" % (k(fi["future_killed"]), k(fi["future_lost"])))
        for b in fi["biggest"]:
            out.append("    biggest: %s  lost %s killed %s ratio %s at (%s, %s)" % ("%d:%02d" % (b["t"] // 60, b["t"] % 60) if b["t"] is not None else "?",
                       k(b["lost"] or 0), k(b["killed"] or 0), b["ratio"], b["x"], b["z"]))
        if fi["most_killed"]:
            out.append("  we killed most: " + ", ".join("%s x%d" % kv for kv in fi["most_killed"]))
    else:
        out.append("FIGHT  no rows")
    sc = s["scout"]
    if sc:
        out.append("SCOUT  %d arrival waves.  median lead %.0f s (min %.0f), first seen at median %.0f elmos, surprises %d (%.0f%%)" % (
            sc["waves"], sc["median_lead_s"], sc["min_lead_s"], sc["median_seen_d"], sc["surprises"], 100 * sc["surprise_rate"]))
        out.append("  first wave %d:%02d lead %.0f s;  by unit %s;  seen by %s" % ((sc["first_wave_t"] or 0) // 60, (sc["first_wave_t"] or 0) % 60,
                   sc["first_wave_lead_s"] or 0, sc["by_unit"], sc["by_seen"]))
    else:
        out.append("SCOUT  no waves")
    out.append("GAPS")
    for i, g in enumerate(s["gaps"], 1):
        out.append("  %d. %s" % (i, g))
    if not s["gaps"]:
        out.append("  none found")
    if s["errors"]:
        out.append("  (%d [LED] error rows in the log)" % s["errors"])
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="log files with [LED] rows (default: the newest metalbot_ledger_*.log)")
    ap.add_argument("--vs", nargs="+", help="a second game's files, printed after the first")
    ap.add_argument("--team", type=int, default=None, help="only rows tagged <T0>/<T1> (single-client logs)")
    ap.add_argument("--json", action="store_true", help="print the summary as JSON")
    a = ap.parse_args(argv)
    files = a.files or ([newest_log()] if newest_log() else [])
    if not files:
        print("no ledger log found; pass a file", file=sys.stderr)
        return 2
    games = [(", ".join(os.path.basename(f) for f in files), files)]
    if a.vs:
        games.append((", ".join(os.path.basename(f) for f in a.vs), a.vs))
    results = []
    for name, fl in games:
        data = read_files(fl, a.team)
        results.append((name, data, summarize(data)))
    if a.json:
        print(json.dumps({n: s for n, _, s in results}, indent=1, default=str))
    else:
        print("\n\n".join(text_report(n, d, s) for n, d, s in results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
