"""Which bot uses which behaviour (bar_framework/behaviors/<name>.lua).

Scans every bot folder's controllers for an `ARMY_BEHAVIORS = { "a", "b" }` list, and every stances/*.lua for
`behaviors = { "kite" }`, then prints a behaviour x user table (and flags behaviours nobody uses).
    python behavior_usage.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).parent
BEH = sorted(p.stem for p in (ROOT / "bar_framework" / "behaviors").glob("*.lua"))
STR = re.compile(r'"([a-z_]+)"')
uses = {b: [] for b in BEH}

def add(name, user):
    if name in uses and user not in uses[name]:
        uses[name].append(user)

bot_dirs = [d for base in ("candidates", ".") for d in (ROOT / base).iterdir()
            if d.is_dir() and (d / "unit_controller.lua").exists()]
stances = {}
for st in (ROOT / "stances").glob("*.lua"):
    stances[st.stem] = set(m for blk in re.findall(r'behaviors\s*=\s*\{([^}]*)\}', st.read_text(encoding="utf-8", errors="ignore"))
                           for m in STR.findall(blk))
for d in sorted(set(bot_dirs)):
    for f in d.glob("*.lua"):
        txt = f.read_text(encoding="utf-8", errors="ignore")
        for blk in re.findall(r'(?:ARMY|BOMBER)_BEHAVIORS\s*=\s*\{([^}]*)\}', txt):
            for m in STR.findall(blk):
                add(m, f"{d.name} (army stack)")
        m = re.search(r'STANCE\s*=\s*"([^"]+)"', txt)
        if m and m.group(1) in stances:
            for b in stances[m.group(1)]:
                add(b, f"{d.name} (stance {m.group(1)})")

w = max(len(b) for b in BEH)
for b in BEH:
    mod = (ROOT / "bar_framework" / "behaviors" / f"{b}.lua").read_text(encoding="utf-8", errors="ignore").splitlines()
    kind = "ARMY" if any("ARMY behaviour" in l for l in mod[:6]) else "BOMBER" if any("BOMBER behaviour" in l for l in mod[:6]) else "unit"
    print(f"{b:<{w}}  [{kind}]  " + (", ".join(uses[b]) if uses[b] else "(unused)"))
