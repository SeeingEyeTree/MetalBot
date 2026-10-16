"""Fail when bar_framework/ gains a quoted unit name it did not have (C4: use bar_framework/roles.lua for a role).

  python tests/check_role_names.py            check against tests/role_name_baseline.json
  python tests/check_role_names.py --save     rewrite the baseline (after a deliberate change: a new blueprint literal, a new role)

A quoted Cortex / Armada unit name ("cordecom", 'armawac') counts once per (file, name).  The baseline lists what exists today -- build-order and
blueprint items (cormex, corwin ...), army pick tables, test-only helpers -- so only NEW literals fail.  A new role literal belongs in roles.lua.
roles.lua and presets/ are exempt.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "tests", "role_name_baseline.json")
PAT = re.compile(r"""["']((?:cor|arm)[a-z0-9_]{2,})["']""")
EXEMPT = ("roles.lua",)


def scan():
    found = {}
    top = os.path.join(ROOT, "bar_framework")
    for dp, dn, fn in os.walk(top):
        if os.sep + "presets" in dp:
            continue
        for f in fn:
            if not f.endswith(".lua") or f in EXEMPT:
                continue
            path = os.path.join(dp, f)
            names = set()
            for line in open(path, encoding="utf-8", errors="ignore"):
                code = line.split("--", 1)[0]
                names.update(PAT.findall(code))
            if names:
                found[os.path.relpath(path, top).replace(os.sep, "/")] = sorted(names)
    return found


def main():
    cur = scan()
    if "--save" in sys.argv:
        json.dump(cur, open(BASE, "w"), indent=1, sort_keys=True)
        print("saved %d files, %d literals" % (len(cur), sum(len(v) for v in cur.values())))
        return 0
    base = json.load(open(BASE)) if os.path.exists(BASE) else {}
    bad = []
    for f, names in cur.items():
        new = sorted(set(names) - set(base.get(f, [])))
        if new:
            bad.append("%s: new unit-name literal(s) %s -- use a role from bar_framework/roles.lua (or --save if it is a blueprint item)" % (f, ", ".join(new)))
    print("\n".join(bad) if bad else "role names ok (%d files)" % len(cur))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
