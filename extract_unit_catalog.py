"""Extract mobile-unit stats from the installed BAR game archive into knowledge/unit_catalog.json.

threat_map_viz.py uses the catalog to stand in for Spring's UnitDefs.  Fields mirror what
bar_framework/unit_query.lua reads (metalCost, speed, canFly, weapons/onlyTargets/canAttackGround),
so the visualiser classifies units exactly as the bot does.

    python extract_unit_catalog.py            # auto-finds the newest archive with unit defs
    python extract_unit_catalog.py --bar-data "D:\\BAR\\data"
"""
import argparse, glob, gzip, json, os, re, sys
from lupa import LuaRuntime

DEFAULT_DATA = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Beyond-All-Reason", "data")
FACTIONS = ("cor", "arm", "leg")


def find_archive(data):
    best = None
    for p in glob.glob(os.path.join(data, "packages", "*.sdp")):
        try:
            raw = gzip.open(p).read()
            i, entries = 0, {}
            while i < len(raw):
                n = raw[i]; i += 1
                name = raw[i:i + n].decode("utf8", "replace"); i += n
                entries[name] = raw[i:i + 16].hex(); i += 24
        except Exception:
            continue
        if any(k.lower().endswith("/corgator.lua") for k in entries):
            m = os.path.getmtime(p)
            if not best or m > best[0]:
                best = (m, entries)
    if not best:
        sys.exit("No BAR archive with unit defs found under %s" % data)
    return best[1]


def read_pool(data, h):
    return gzip.open(os.path.join(data, "pool", h[:2], h[2:] + ".gz")).read().decode("utf8", "replace")


def lua_to_py(v):
    if hasattr(v, "items"):
        return {(k if not isinstance(k, float) else int(k)): lua_to_py(x) for k, x in v.items()}
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bar-data", default=DEFAULT_DATA)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                   "knowledge", "unit_catalog.json"))
    a = ap.parse_args()

    entries = find_archive(a.bar_data)
    lua = LuaRuntime(unpack_returned_tuples=True)
    catalog = []
    for path, h in sorted(entries.items()):
        m = re.fullmatch(r"units/(?:[^/]+/)+([a-z0-9_]+)\.lua", path.lower())
        if not m:
            continue
        name = m.group(1)
        if not name.startswith(FACTIONS) or "_scav" in name:
            continue
        try:
            tbl = lua_to_py(lua.execute(read_pool(a.bar_data, h)))
            d = next(iter(tbl.values()))
        except Exception:
            continue
        speed = d.get("speed") or 0
        if speed <= 0:
            continue
        # Same rule as unit_query.caps(): inspect every weapon.
        wdefs = {str(k).lower(): v for k, v in (d.get("weapondefs") or {}).items()}
        weapons = [w for _, w in sorted((d.get("weapons") or {}).items(), key=lambda kv: str(kv[0]))]
        air = gnd = False
        for w in weapons:
            wd = wdefs.get(str(w.get("def", "")).lower(), {})
            only = set(str(w.get("onlytargets", "")).lower().split())
            ground_ok = wd.get("canattackground") is not False
            if "vtol" in only:
                air = True
            else:
                if "surface" not in only and "notair" not in only:
                    air = True
                if ground_ok:
                    gnd = True
        cp = d.get("customparams") or {}
        catalog.append({
            "name": name,
            "metal": d.get("metalcost", 0),
            "energy": d.get("energycost", 0),
            "buildtime": d.get("buildtime", 0),
            "speed": speed,
            "air": bool(d.get("canfly")),
            "armed": len(weapons) > 0,
            "hitsAir": air, "hitsGround": gnd,
            "builder": bool(d.get("builder")) and not d.get("isfactory"),
            "commander": "iscommander" in cp or "commander" in name,
            "tech": cp.get("techlevel", 1),
            "sub": cp.get("subfolder", ""),
        })
    catalog.sort(key=lambda u: (u["air"], u["name"]))
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(catalog, open(a.out, "w"), indent=0)
    print("wrote %d mobile units -> %s" % (len(catalog), a.out))


if __name__ == "__main__":
    main()
