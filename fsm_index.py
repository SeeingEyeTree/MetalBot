"""Write stance_editor/machine_index.json for machine_editor.html: the stances (name, intent, share, plan, units), the signals
(bar_framework/signals.lua) and the built-in rules (machines/builtin_rules.lua).  Re-run it when a stance, signal or built-in rule
changes.  Also checks machine files:  python fsm_index.py --check [machines/core_default.lua ...]  (no args = every machines/*.lua).

Everything is read by running the Lua files in lupa (these files are plain data with no engine calls)."""
import glob
import json
import os
import sys

import lupa.lua51 as L

ROOT = os.path.dirname(os.path.abspath(__file__))


def lua():
    rt = L.LuaRuntime(unpack_returned_tuples=True)
    return rt


def to_py(v):
    """Lua table -> dict / list / scalar (a table with keys 1..n only becomes a list)."""
    if L.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(v[k]) for k in sorted(keys)]
        return {str(k): to_py(v[k]) for k in keys}
    return v


def run_file(rt, path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    # files start with `local M = {} ... return M` or `return {...}`
    fn = rt.eval("function(src, name) local f, e = loadstring(src, name); if not f then error(e) end return f() end")
    return fn(src, path)


GROUND_AA = {"coraak", "corsent", "corcrash", "cormist"}      # unit_runtime GROUND_AA.NAMES: an AA post, not an army unit
SLOW_SPEED = 50                                               # click_army slow group (plan.slow_group): units slower than this


def driver(u, plan, speed):
    """Who gives orders to a stance unit (user 2026-10-28: 'only a few units show a behaviour in the machine' -- the rest are driven by
    the army controllers implicitly; this names that owner so the editor can show it)."""
    n, army = u.get("n"), (plan or {}).get("army")
    if n in GROUND_AA:
        return "AA post (ring round the base, escort behind the biggest group)"
    if army in ("hold", "defend", "maneuver"):
        if "raid_sections" in (plan or {}) :
            return "maneuver blob (a quiet blob is released as a raid group: raid_sections)"
        return "maneuver blob on the perimeter ring"
    if army == "raid":
        if (plan or {}).get("slow_group") and speed is not None and speed < SLOW_SPEED:
            return "click_army slow group"
        return "click_army raid group" + (" (survive: steers round enemy force)" if (plan or {}).get("survive") else "")
    return "unit controller"


def behavior_catalog():
    """name -> one-line description for every file in bar_framework/behaviors/ (the `describes` / first comment line)."""
    out = {}
    for p in sorted(glob.glob(os.path.join(ROOT, "bar_framework", "behaviors", "*.lua"))):
        name = os.path.splitext(os.path.basename(p))[0]
        try:
            m = run_file(lua(), p)
            d = to_py(m).get("describes") if L.lua_type(m) == "table" else None
        except Exception:  # noqa: BLE001  (behaviours need engine globals to load; fall back to the header comment)
            d = None
        if not d:
            with open(p, encoding="utf-8") as f:
                lines = [ln[2:].strip() for ln in f.read().splitlines() if ln.startswith("--")]
            d = next((ln for ln in lines[1:] if ln and not ln.startswith("bar_framework/")), "")
        out[name] = d
    return out


def stances():
    speeds = {}
    up = os.path.join(ROOT, "stance_editor", "units.json")
    if os.path.exists(up):
        with open(up, encoding="utf-8") as f:
            data = json.load(f)
        speeds = {u["name"]: u.get("speed") for u in (data if isinstance(data, list) else data.get("units", [])) if isinstance(u, dict) and "name" in u}
    out = []
    for p in sorted(glob.glob(os.path.join(ROOT, "stances", "*.lua"))):
        rt = lua()
        try:
            m = to_py(run_file(rt, p))
        except Exception as e:  # noqa: BLE001
            print(f"  skip {os.path.basename(p)}: {e}")
            continue
        if not isinstance(m, dict) or "units" not in m:
            continue
        plan = m.get("plan") or {}
        units = [{"n": u.get("n"), "share": u.get("share", 0), "tag": u.get("tag"), "behaviors": u.get("behaviors"),
                  "cfg": u.get("cfg"), "driver": driver(u, plan, speeds.get(u.get("n")))}
                 for u in (m.get("units") or [])]
        out.append({
            "name": os.path.splitext(os.path.basename(p))[0],
            "intent": (m.get("intent") or "").strip(),
            "control": (m.get("control") or "").strip(),
            "share": str(m.get("suggestedShare") or "").strip(),
            "plan": plan,
            "units": units,
            "extras": [e.get("n") for e in (m.get("extras") or [])],
            "extra_units": [{"n": e.get("n"), "behaviors": e.get("behaviors"), "cfg": e.get("cfg"), "note": e.get("note")}
                            for e in (m.get("extras") or [])],
        })
    return out


SIG_SRC = """
local S = dofile(...)
local out = {}
for _, r in ipairs(S.list) do out[#out+1] = {name=r[1], type=r[2], doc=r[3], unit=r[4]} end
for _, r in ipairs(S.CROSS) do out[#out+1] = {name=r[1], type=r[2], doc=r[3], unit=r[4], cross=true} end
return out
"""


def signals():
    rt = lua()
    fn = rt.eval("function(path) " + SIG_SRC.replace("...", "path") + " end")
    return to_py(fn(os.path.join(ROOT, "bar_framework", "signals.lua")))


def builtin_rules():
    return to_py(run_file(lua(), os.path.join(ROOT, "machines", "builtin_rules.lua")))


def unit_names():
    p = os.path.join(ROOT, "stance_editor", "units.json")
    if not os.path.exists(p):
        return {}
    with open(p, encoding="utf-8") as f:
        data = json.load(f)
    items = data if isinstance(data, list) else data.get("units", [])
    return {u["name"]: u.get("display") or u["name"] for u in items if isinstance(u, dict) and "name" in u}


def build():
    idx = {"stances": stances(), "signals": signals(), "builtin_rules": builtin_rules(), "units": unit_names(),
           "behaviors": behavior_catalog()}
    out = os.path.join(ROOT, "stance_editor", "machine_index.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(idx, f, indent=1)
    with open(os.path.join(ROOT, "stance_editor", "machine_index.js"), "w", encoding="utf-8") as f:
        f.write("window.MACHINE_INDEX = " + json.dumps(idx) + ";\n")      # a <script> works from file://, fetch() does not
    print(f"wrote {out}: {len(idx['stances'])} stances, {len(idx['signals'])} signals, {len(idx['builtin_rules'])} built-in rules")
    return idx


def check(paths):
    idx = build()
    sig = {s["name"] for s in idx["signals"]}
    stance = {s["name"] for s in idx["stances"]}
    hooks = {"match_enemy", "v16_share"}
    ops = {">", ">=", "<", "<=", "==", "!="}
    bad = 0
    for p in paths:
        spec = to_py(run_file(lua(), p))
        probs = []

        def walk(c, where):
            if "all" in c or "any" in c:
                for k in c.get("all") or c.get("any"):
                    walk(k, where)
            elif "not" in c:
                walk(c["not"], where)
            elif "sig" in c:
                if c["sig"] not in sig:
                    probs.append(f"{where}: unknown signal {c['sig']}")
                if c.get("op") and c["op"] not in ops:
                    probs.append(f"{where}: bad operator {c['op']}")

        for key in ("stance_machine", "share_machine"):
            m = spec.get(key)
            if not m:
                continue
            nodes = m.get("nodes", {})
            if m.get("initial") not in nodes:
                probs.append(f"{key}: initial {m.get('initial')} missing")
            for n, nd in nodes.items():
                if key == "stance_machine" and nd.get("stance") not in stance:
                    probs.append(f"{key}: node {n}: stance {nd.get('stance')} not found")
                if key == "share_machine" and nd.get("hook") and nd["hook"] not in hooks:
                    probs.append(f"{key}: node {n}: unknown hook {nd['hook']}")
            for tag in ("edges", "any_edges"):
                for i, e in enumerate(m.get(tag) or []):
                    if e.get("to") not in nodes or (tag == "edges" and e.get("from") not in nodes):
                        probs.append(f"{key} {tag}[{i + 1}]: from/to not a node")
                    if e.get("when"):
                        walk(e["when"], f"{key} {tag}[{i + 1}]")
        print(os.path.relpath(p, ROOT), "OK" if not probs else "")
        for pr in probs:
            print("  " + pr)
        bad += len(probs)
    return bad


if __name__ == "__main__":
    if "--check" in sys.argv:
        files = [a for a in sys.argv[1:] if not a.startswith("--")]
        if not files:
            files = [p for p in sorted(glob.glob(os.path.join(ROOT, "machines", "*.lua"))) if "builtin" not in p]
        sys.exit(1 if check(files) else 0)
    build()
