"""Extract every arm/cor/leg unit (mobile AND structures) from the installed BAR archive for stance_editor.html.

Writes stance_editor/units.json (display names, costs, role flags) and stance_editor/pics/<name>.png
(unitpics converted from DDS).  Reuses the archive helpers from extract_unit_catalog.py.

    python extract_unit_data.py
    python extract_unit_data.py --bar-data "D:\\BAR\\data" --no-pics
"""
import argparse, io, json, os, re
from lupa import LuaRuntime
from extract_unit_catalog import DEFAULT_DATA, FACTIONS, find_archive, read_pool, lua_to_py

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "stance_editor")


def weapon_caps(d):
    """(hitsAir, hitsGround), same rule as unit_query.caps()."""
    wdefs = {str(k).lower(): v for k, v in (d.get("weapondefs") or {}).items()}
    weapons = [w for _, w in sorted((d.get("weapons") or {}).items(), key=lambda kv: str(kv[0]))]
    air = gnd = False
    for w in weapons:
        wd = wdefs.get(str(w.get("def", "")).lower(), {})
        only = set(str(w.get("onlytargets", "")).lower().split())
        if "vtol" in only:
            air = True
        else:
            if "surface" not in only and "notair" not in only:
                air = True
            if wd.get("canattackground") is not False:
                gnd = True
    return len(weapons) > 0, air, gnd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bar-data", default=DEFAULT_DATA)
    ap.add_argument("--no-pics", action="store_true")
    a = ap.parse_args()

    entries = find_archive(a.bar_data)
    lower = {k.lower(): v for k, v in entries.items()}

    names = {}
    h = lower.get("language/en/units.json")
    if h:
        j = json.loads(read_pool(a.bar_data, h))
        names = (j.get("units") or {}).get("names") or {}
    descs = ((j.get("units") or {}).get("descriptions") or {}) if h else {}

    lua = LuaRuntime(unpack_returned_tuples=True)
    units = []
    for path, h in sorted(lower.items()):
        m = re.fullmatch(r"units/(?:[^/]+/)+([a-z0-9_]+)\.lua", path)
        if not m:
            continue
        name = m.group(1)
        if not name.startswith(FACTIONS) or "_scav" in name:
            continue
        try:
            d = next(iter(lua_to_py(lua.execute(read_pool(a.bar_data, h))).values()))
        except Exception:
            continue
        if not isinstance(d, dict) or "metalcost" not in d:
            continue
        cp = d.get("customparams") or {}
        armed, hits_air, hits_gnd = weapon_caps(d)
        speed = d.get("speed") or d.get("maxvelocity") or 0
        movetype = str(d.get("movementclass", "")).lower()
        naval = any(s in movetype for s in ("boat", "ship", "sub")) or bool(d.get("floater") or d.get("waterline"))
        tech = cp.get("techlevel", 1)
        units.append({
            "name": name,
            "display": names.get(name, name),
            "desc": descs.get(name, ""),
            "faction": name[:3],
            "tech": int(tech) if isinstance(tech, (int, float)) else 1,
            "sub": cp.get("subfolder", ""),
            "mobile": speed > 0,
            "air": bool(d.get("canfly")),
            "naval": naval,
            "builder": bool(d.get("builder")),
            "factory": bool(d.get("isfactory")) or (speed == 0 and bool(d.get("builder")) and bool(d.get("buildoptions"))),
            "commander": "iscommander" in cp or "commander" in name,
            "armed": armed, "hitsAir": hits_air, "hitsGround": hits_gnd,
            "metal": d.get("metalcost", 0),
            "energy": d.get("energycost", 0),
            "buildtime": d.get("buildtime", 0),
            "speed": speed,
            "health": d.get("health") or d.get("maxdamage") or 0,
            "pic": str(d.get("buildpic", name + ".dds")).lower().rsplit(".", 1)[0],
        })
    units.sort(key=lambda u: (u["faction"], u["tech"], u["name"]))
    os.makedirs(os.path.join(OUT, "pics"), exist_ok=True)
    json.dump(units, open(os.path.join(OUT, "units.json"), "w"), separators=(",", ":"))
    print("wrote %d units -> %s" % (len(units), os.path.join(OUT, "units.json")))

    if a.no_pics:
        return
    from PIL import Image
    ok = miss = bad = 0
    for u in units:
        h = lower.get("unitpics/%s.dds" % u["pic"]) or lower.get("unitpics/%s.dds" % u["name"])
        if not h:
            miss += 1
            continue
        try:
            raw = gzip_read(a.bar_data, h)
            Image.open(io.BytesIO(raw)).convert("RGBA").save(os.path.join(OUT, "pics", u["name"] + ".png"))
            ok += 1
        except Exception as e:
            bad += 1
            if bad <= 3:
                print("  pic failed for %s: %s" % (u["name"], e))
    print("pics: %d written, %d missing, %d failed" % (ok, miss, bad))


def gzip_read(data, h):
    import gzip
    return gzip.open(os.path.join(data, "pool", h[:2], h[2:] + ".gz")).read()


if __name__ == "__main__":
    main()
