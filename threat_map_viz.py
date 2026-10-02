"""Build threat_map_viz.html: an interactive lab for bar_framework/threat_map.lua.

The page embeds the CURRENT threat_map.lua and unit_query.lua and runs them unmodified in the
browser (fengari, a Lua VM in JS), so what it shows is what the bot computes.  Re-run this after
editing threat_map.lua:

    python threat_map_viz.py

    python threat_map_viz.py --log knowledge/threat_logs/dragon_vs_raider.json   # embed a recorded game

Unit stats come from knowledge/unit_catalog.json (python extract_unit_catalog.py refreshes it
from the installed BAR).  Fengari is inlined from node_modules when present (fully offline),
otherwise loaded from a CDN.
"""
import argparse, json, os, time

ROOT = os.path.dirname(os.path.abspath(__file__))
FENGARI = os.path.join(ROOT, "node_modules", "fengari-web", "dist", "fengari-web.js")
CDN = "https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.js"


def read(*p):
    with open(os.path.join(ROOT, *p), encoding="utf-8") as f:
        return f.read()


def safe_json(obj):
    return json.dumps(obj, separators=(",", ":")).replace("</", "<\\/")


def load_log(path):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    lines = d.get("threat_log", []) if isinstance(d, dict) else d
    return {"name": os.path.splitext(os.path.basename(path))[0], "lines": lines}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", action="append", default=[], metavar="RESULT.json",
                    help="embed a match result's threat_log so the page opens with it ready (repeatable)")
    args = ap.parse_args()
    payload = {
        "logs": [load_log(p) for p in args.log],
        "tm": read("bar_framework", "threat_map.lua"),
        "uq": read("bar_framework", "unit_query.lua"),
        "glue": read("threat_map_viz", "glue.lua"),
        "catalog": json.loads(read("knowledge", "unit_catalog.json")),
        "generated": time.strftime("%Y-%m-%d %H:%M"),
    }
    html = read("threat_map_viz", "template.html")
    if os.path.exists(FENGARI):
        fengari_tag = "<script>" + read("node_modules", "fengari-web", "dist", "fengari-web.js").replace("</script", "<\\/script") + "</script>"
    else:
        fengari_tag = '<script src="%s"></script>' % CDN
    html = html.replace("<!--FENGARI-->", fengari_tag).replace("__PAYLOAD__", safe_json(payload))
    out = os.path.join(ROOT, "threat_map_viz.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)
    print("wrote %s (%d KB, fengari %s)" % (out, len(html) // 1024, "inlined" if os.path.exists(FENGARI) else "from CDN"))


if __name__ == "__main__":
    main()
