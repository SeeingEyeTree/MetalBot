#!/usr/bin/env python3
"""checkpoint_map.py -- find which game frame actually discriminates between two bots.

This project has a structural measurement problem. Run-to-run noise between byte-identical
bots GROWS over a match, while the signal from a change only appears once the bots diverge
from their scripted opening. Measure too early and both bots are still doing the same thing;
measure too late and the noise swamps the difference. The usable window, if there is one, has
to be found rather than assumed.

Point this at the result files ab_test.py leaves in its temp directory and it prints, per
sampled frame: the within-condition spread (noise) and the between-condition gap (signal),
so you can see where -- or whether -- signal ever exceeds noise.

    python checkpoint_map.py <dir-of-abtest-jsons>

A frame is only worth using as a checkpoint when signal/noise is comfortably above 1.
"""
import json, statistics, sys
from pathlib import Path


def collect(files: list, metric: str):
    """-> {frame: {"A":{0:[..],1:[..]}, "B":{...}}} for the chosen metric."""
    key, field = (("resource_timeline", "metal_inc") if metric == "income"
                  else ("army_timeline", "mv"))
    out: dict = {}
    for f in files:
        who = "A" if f.name.startswith("A") else "B"
        data = json.loads(f.read_text(encoding="utf-8"))
        # The opposing bot occupies the other slot in each file, so a file named A* holds
        # A in slot 0 and B in slot 1.
        for row in data.get(key) or []:
            fr, team = row.get("frame"), row.get("team")
            if fr is None or team not in (0, 1):
                continue
            owner = who if team == 0 else ("B" if who == "A" else "A")
            val = float(row[field])
            if val <= 0:
                continue  # post-game rows read as zero
            out.setdefault(fr, {"A": {0: [], 1: []}, "B": {0: [], 1: []}})
            out[fr][owner][team].append(val)
    return out


def spread(vals: list) -> "float | None":
    vals = [v for v in vals if v > 0]
    if len(vals) < 2:
        return None
    return max(vals) / min(vals)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    d = Path(sys.argv[1])
    files = sorted(d.glob("*.json"))
    if not files:
        print(f"no result files in {d}")
        return 2
    print(f"{len(files)} result files from {d}\n")

    for metric in ("income", "army"):
        data = collect(files, metric)
        if not data:
            continue
        print(f"=== {metric} ===")
        print(f"  {'frame':>7}{'game_min':>10}{'noise':>9}{'signal':>9}{'s/n':>7}   verdict")
        for fr in sorted(data):
            d0, d1 = data[fr]["A"], data[fr]["B"]
            # Noise: worst within-condition spread across the four bot/slot cells.
            noises = [s for s in (spread(d0[0]), spread(d0[1]),
                                  spread(d1[0]), spread(d1[1])) if s]
            if not noises:
                continue
            noise = max(noises)
            # Signal: larger of the two per-slot gaps between the bots' means.
            sigs = []
            for slot in (0, 1):
                if d0[slot] and d1[slot]:
                    a, b = statistics.mean(d0[slot]), statistics.mean(d1[slot])
                    if min(a, b) > 0:
                        sigs.append(max(a, b) / min(a, b))
            if not sigs:
                continue
            signal = max(sigs)
            sn = signal / noise
            note = ("USABLE" if sn > 1.5 else
                    "marginal" if sn > 1.0 else "noise dominates")
            print(f"  {fr:>7}{fr / 1800:>10.1f}{noise:>9.2f}{signal:>9.2f}{sn:>7.2f}   {note}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
