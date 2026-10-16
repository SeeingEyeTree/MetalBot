"""check_lua_unbound.py -- a static check for the Lua modules split out of a larger file.

A split module is `function M.Install(X) ... end`; every name it uses that belongs to the parent file or a sibling must be bound at
its top (`local Clock = X.Clock`).  A missing binding is a global read that only fails when that code path runs (a 20-minute game
away).  This lists, for each module, the names of the original file's functions and constants that it uses without binding.

    python tests/check_lua_unbound.py bar_framework/line_transition            # modules of line_transition
    python tests/check_lua_unbound.py <dir> --names NAME,NAME                  # extra names to look for

The universe of names is every `local function` / `local NAME` of the directory's parent file (<dir>.lua) plus the names exported on X
by the modules themselves.  Exit status 1 when anything is unbound.
"""
import glob, os, re, sys

BACKSLASH = chr(92)


def strip_lua(s):
    """Source with comments removed and string contents emptied (long strings and comments handled)."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if s.startswith("--", i):
            m = re.match(r"--\[(=*)\[", s[i:])
            if m:
                e = s.find("]" + m.group(1) + "]", i)
                i = n if e < 0 else e + len(m.group(1)) + 2
            else:
                e = s.find("\n", i)
                i = n if e < 0 else e
        elif c in "\"'":
            q, i = c, i + 1
            while i < n and s[i] != q:
                i += 2 if s[i] == BACKSLASH else 1
            i += 1
            out.append('""')
        else:
            out.append(c)
            i += 1
    return "".join(out)


def declared(code, top=False):
    ind = "" if top else r"\s*"
    own = set(re.findall(r"^" + ind + r"local function (\w+)", code, re.M))
    for m in re.finditer(r"^" + ind + r"local ([\w, ]+?)\s*(?:=|$)", code, re.M):
        own |= {x.strip() for x in m.group(1).split(",")}
    return own


def main():
    ap = sys.argv[1:]
    if not ap:
        print(__doc__)
        return 2
    d = ap[0].rstrip("/\\")
    extra = []
    if "--names" in ap:
        extra = ap[ap.index("--names") + 1].split(",")
    parent = d + ".lua"
    names = set(extra)
    if os.path.exists(parent):
        code = strip_lua(open(parent, encoding="utf-8").read())
        names |= set(re.findall(r"^local function (\w+)", code, re.M))
        names |= declared(code, top=True)
    files = sorted(glob.glob(os.path.join(d, "*.lua")))
    for f in files:
        names |= set(re.findall(r"\bX\.(\w+)\s*=", strip_lua(open(f, encoding="utf-8").read())))
    names.discard("X")      # the Install parameter
    bad = 0
    for f in files:
        code = strip_lua(open(f, encoding="utf-8").read())
        own = declared(code)
        for n in sorted(names - own):
            if re.search(r"(?<![\w.:])" + re.escape(n) + r"\b(?!\s*=[^=])", code):
                print(f"{f}: uses '{n}' without binding it")
                bad += 1
    print(f"{len(files)} modules, {bad} unbound")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
