#!/usr/bin/env python3
"""
replay_analysis.py — extract economy/combat telemetry from a BAR (.sdfz) replay
and append it to a growing history file so bot performance can be tracked
across every game that gets played, not just judged by "units built."

WHY THIS APPROACH
------------------
A .sdfz replay already contains, every `teamStatPeriod` seconds (usually 15),
a recorded snapshot per team of cumulative metal/energy produced/used/excess,
damage dealt/received, and units produced/died/killed (this is the engine's
own TeamStatistics struct, written into the demo file as the game is played).
That means we do NOT need to re-simulate the game headlessly to get this
data — it's already sitting in the file. We just need to decode it.

The .sdfz binary format has changed subtly across engine versions, and
hand-parsing the byte layout is error-prone (ask me how I know). Rather than
maintain a fragile hand-rolled binary parser, this script shells out to the
`sdfz-demo-parser` CLI — the parser actively maintained by the Beyond All
Reason project itself (https://github.com/beyond-all-reason/demo-parser) —
and does all the BAR-specific analysis in Python on top of its JSON output.

SETUP (one-time, on any machine this runs on — needs Node.js)
----------------------------------------------------------------
    cd <this directory>
    npm install sdfz-demo-parser

USAGE
-----
    python replay_analysis.py path/to/replay.sdfz
    python replay_analysis.py path/to/replay.sdfz --history some/other/file.jsonl
    python replay_analysis.py path/to/replay.sdfz --no-history --json

By default, every run both prints a report AND appends a compact record to
knowledge/replay_history.jsonl (one line per game) — this is the growing,
cross-game dataset: run it after every test/ladder game and the history
accumulates automatically. Use --history to point at a different file, or
--no-history to just print without recording. Re-running on the same replay
appends another record rather than deduping (dedupe on gameId downstream if
that ever matters).
"""

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


PARSER_SCRIPT = Path(__file__).with_name("replay_parser.mjs")


def parse_replay(path: Path) -> dict:
    """Parse a .sdfz replay via replay_parser.mjs, a thin wrapper around the
    `sdfz-demo-parser` library (see that file for why we call the library
    directly instead of the package's own CLI binary).

    One-time setup, in this directory:
        npm install sdfz-demo-parser
    """
    if not shutil.which("node"):
        raise RuntimeError("Node.js is required to parse replays but wasn't found on PATH.")
    if not (PARSER_SCRIPT.parent / "node_modules" / "sdfz-demo-parser").exists():
        raise RuntimeError(
            f"sdfz-demo-parser isn't installed next to {PARSER_SCRIPT}.\n"
            f"Run this once:\n    cd {PARSER_SCRIPT.parent} && npm install sdfz-demo-parser"
        )
    proc = subprocess.run(
        ["node", str(PARSER_SCRIPT), str(path)], capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise RuntimeError(f"replay_parser.mjs failed on {path}:\n{proc.stderr}")
    return json.loads(proc.stdout)


# --------------------------------------------------------------------------
# Derived metrics
# --------------------------------------------------------------------------

def team_id_for_player(players, name=None, player_id=None):
    for p in players:
        if name is not None and p["name"] == name:
            return p["teamId"]
        if player_id is not None and p["playerId"] == player_id:
            return p["teamId"]
    return None


def rate_series(records, field):
    """Per-interval rate of change of a cumulative field, keyed by time (s)."""
    out = []
    for i in range(1, len(records)):
        dt = (records[i]["frame"] - records[i - 1]["frame"]) / 30.0
        if dt <= 0:
            continue
        dv = records[i][field] - records[i - 1][field]
        out.append((records[i]["frame"] / 30.0, dv / dt))
    return out


def first_contact_time(team_stats: dict) -> float | None:
    """First game-time (s) at which any team's recorded damageDealt/Received
    becomes nonzero — i.e. when armies actually met."""
    times = []
    for recs in team_stats.values():
        for r in recs:
            if r["damageDealt"] > 0 or r["damageReceived"] > 0:
                times.append(r["frame"] / 30.0)
                break
    return min(times) if times else None


def snapshot_at_or_before(records, t_seconds):
    best = None
    for r in records:
        if r["frame"] / 30.0 <= t_seconds:
            best = r
        else:
            break
    return best or (records[0] if records else None)


def energy_waste_pct(rec) -> float:
    if not rec or rec["energyProduced"] <= 0:
        return 0.0
    return 100.0 * rec["energyExcess"] / rec["energyProduced"]


def metal_energy_ratio(rec) -> float:
    if not rec or rec["energyProduced"] <= 0:
        return 0.0
    return rec["metalProduced"] / rec["energyProduced"]


def combat_value_ratio(rec) -> float:
    """dealt / received damage, as a quick combat-efficiency proxy."""
    if not rec or rec["damageReceived"] <= 0:
        return float("inf") if rec and rec["damageDealt"] > 0 else 0.0
    return rec["damageDealt"] / rec["damageReceived"]


def build_team_summary(team_id, players, team_stats, checkpoints_s):
    recs = team_stats.get(str(team_id), team_stats.get(team_id, []))
    player = next((p for p in players if p["teamId"] == team_id), {})
    last = recs[-1] if recs else {}

    checkpoints = {}
    for t in checkpoints_s:
        snap = snapshot_at_or_before(recs, t)
        if snap:
            checkpoints[f"t{t}s"] = {
                "metalProduced": round(snap["metalProduced"], 1),
                "energyProduced": round(snap["energyProduced"], 1),
                "energyWastePct": round(energy_waste_pct(snap), 2),
                "metalEnergyRatio": round(metal_energy_ratio(snap), 4),
                "unitsProduced": snap["unitsProduced"],
                "unitsDied": snap["unitsDied"],
            }

    metal_rate = rate_series(recs, "metalProduced")
    peak_metal_rate = max((v for _, v in metal_rate), default=0.0)

    return {
        "teamId": team_id,
        "playerName": player.get("name"),
        "faction": player.get("faction"),
        "rank": player.get("rank"),
        "skill": player.get("skill"),
        "final": {
            "metalProduced": round(last.get("metalProduced", 0), 1),
            "energyProduced": round(last.get("energyProduced", 0), 1),
            "energyWastePct": round(energy_waste_pct(last), 2),
            "metalEnergyRatio": round(metal_energy_ratio(last), 4),
            "damageDealt": round(last.get("damageDealt", 0), 1),
            "damageReceived": round(last.get("damageReceived", 0), 1),
            "combatValueRatio": round(combat_value_ratio(last), 3)
            if last.get("damageReceived", 0) > 0
            else None,
            "unitsProduced": last.get("unitsProduced", 0),
            "unitsDied": last.get("unitsDied", 0),
            "unitsKilled": last.get("unitsKilled", 0),
        },
        "peakMetalIncomeRate": round(peak_metal_rate, 2),
        "checkpoints": checkpoints,
    }


def analyze(demo_json: dict, checkpoints_s=(120, 240, 450, 600)) -> dict:
    info = demo_json["info"]
    players = info["players"]
    team_stats = demo_json["statistics"]["teamStats"]
    winning_ally_teams = info["meta"].get("winningAllyTeamIds", [])

    team_ids = sorted({p["teamId"] for p in players})
    teams = [build_team_summary(tid, players, team_stats, checkpoints_s) for tid in team_ids]

    fc_time = first_contact_time(team_stats)
    pre_contact_econ = None
    if fc_time is not None:
        pre = {}
        for tid in team_ids:
            recs = team_stats.get(str(tid), team_stats.get(tid, []))
            snap = snapshot_at_or_before(recs, max(fc_time - 15, 0))
            pre[tid] = round(snap["metalProduced"], 1) if snap else 0.0
        pre_contact_econ = pre

    winners = [
        p["name"] for p in players if p.get("allyTeamId") in winning_ally_teams
    ]

    return {
        "gameId": info["meta"]["gameId"],
        "engine": info["meta"]["engine"],
        "map": info["meta"]["map"],
        "startTime": info["meta"]["startTime"],
        "durationSeconds": info["meta"]["fullDurationMs"] / 1000.0,
        "winningAllyTeamIds": winning_ally_teams,
        "winners": winners,
        "firstContactSeconds": fc_time,
        "preContactMetalProducedByTeam": pre_contact_econ,
        "teams": teams,
    }


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def print_report(result: dict, replay_path: Path):
    print(f"=== Replay: {replay_path.name} ===")
    print(f"Map: {result['map']}   Engine: {result['engine']}")
    print(f"Duration: {result['durationSeconds']:.0f}s   Winner(s): {', '.join(result['winners']) or 'unknown'}")
    if result["firstContactSeconds"] is not None:
        print(f"First combat contact: {result['firstContactSeconds']:.0f}s")
        pre = result["preContactMetalProducedByTeam"] or {}
        for team in result["teams"]:
            tid = team["teamId"]
            print(f"  team {tid} ({team['playerName']}, {team['faction']}): "
                  f"{pre.get(tid, pre.get(str(tid), 0)):.0f} cumulative metal produced just before contact")
    else:
        print("No combat detected in the recorded stat history.")

    print()
    for team in result["teams"]:
        f = team["final"]
        print(f"--- {team['playerName']} (team {team['teamId']}, {team['faction']}, "
              f"rank {team['rank']}, skill {team['skill']}) ---")
        print(f"  Final metal produced:   {f['metalProduced']:.0f}")
        print(f"  Final energy produced:  {f['energyProduced']:.0f}   (wasted: {f['energyWastePct']:.1f}%)")
        print(f"  Metal:Energy production ratio: {f['metalEnergyRatio']:.4f}")
        print(f"  Peak metal income rate: {team['peakMetalIncomeRate']:.1f} M/s")
        print(f"  Units produced: {f['unitsProduced']}   Units lost: {f['unitsDied']}   Units killed: {f['unitsKilled']}")
        print(f"  Damage dealt: {f['damageDealt']:.0f}   Damage received: {f['damageReceived']:.0f}"
              + (f"   (ratio {f['combatValueRatio']:.2f})" if f['combatValueRatio'] else ""))
        print("  Checkpoints:")
        for label, cp in team["checkpoints"].items():
            print(f"    {label:>6}: metal={cp['metalProduced']:.0f} energy={cp['energyProduced']:.0f} "
                  f"e-waste={cp['energyWastePct']:.1f}% M:E={cp['metalEnergyRatio']:.4f} "
                  f"unitsBuilt={cp['unitsProduced']} unitsLost={cp['unitsDied']}")
        print()


def append_history(result: dict, history_path: Path, source_file: str):
    history_path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "sourceFile": source_file,
        **result,
    }
    with open(history_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("replay", type=Path, help="Path to a .sdfz replay file")
    default_history = Path(__file__).with_name("knowledge") / "replay_history.jsonl"
    ap.add_argument("--history", type=Path, default=default_history,
                     help=f"JSONL file to append this game's summary to, creating it if missing "
                          f"(default: {default_history})")
    ap.add_argument("--no-history", action="store_true", help="Don't write to the history file at all")
    ap.add_argument("--json", action="store_true", help="Print the full analysis as JSON instead of a text report")
    args = ap.parse_args()

    if not args.replay.exists():
        sys.exit(f"No such file: {args.replay}")

    demo_json = parse_replay(args.replay)
    result = analyze(demo_json)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_report(result, args.replay)

    if not args.no_history:
        append_history(result, args.history, str(args.replay))
        print(f"Appended to {args.history}")


if __name__ == "__main__":
    main()
