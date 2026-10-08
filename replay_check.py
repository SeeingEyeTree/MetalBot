"""Does this machine play a recorded game the same way as another one?

Plays a .sdfz with spring-headless in an ISOLATED write dir (nothing in the real BAR install is touched, and a
running game's infolog is not clobbered).  Every stock and user widget is shadowed except one probe widget that,
every --every frames, prints an order-independent hash of all units' positions and health plus per-team counts:

    [RP] f=9000 n=412 h=1830041223 hp=912345 t0=190 t1=222

Run it on two machines with the SAME .sdfz and compare the [RP] lines (--compare a.json b.json): the first frame
whose hash differs is where the two simulations split.  A replay is a fixed command stream, so any difference
comes from the machine / engine settings, not from the players.

  python replay_check.py demo.sdfz --label mainpc --out mainpc.json
  python replay_check.py demo.sdfz --label treeserver --out treeserver.json --threads 4
  python replay_check.py --compare mainpc.json treeserver.json

--threads N pins the engine's WorkerThreadCount (pathfinding etc.) in the isolated springsettings.cfg.
"""
import argparse, json, os, re, subprocess, sys, tempfile, time
from pathlib import Path

BAR_DATA_DIR = Path(os.environ.get(
    "BAR_DATA_DIR", str(Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Beyond-All-Reason" / "data")))

PROBE = r'''
function widget:GetInfo()
    return { name = "Replay Probe", desc = "state hash every N frames", author = "MetalBot",
             layer = 0, enabled = true }
end
local EVERY, ENDF, SPEED, NOREQ = __EVERY__, __END__, __SPEED__, __NOREQ__
local done = false
local function Speed()
    Spring.SendCommands("setmaxspeed " .. SPEED, "setminspeed " .. SPEED)
end
local function Probe(f)
    local units = Spring.GetAllUnits() or {}
    local n, hsum, hpsum = 0, 0, 0
    local team = {}
    for i = 1, #units do
        local u = units[i]
        local x, _, z = Spring.GetUnitPosition(u)
        if x then
            local hp = Spring.GetUnitHealth(u) or 0
            local k = math.floor(x * 100 + 0.5) + math.floor(z * 100 + 0.5) * 131 + math.floor(hp) * 7
            hsum = (hsum + (u * 2654435 + k) % 2147483629) % 2147483629
            hpsum = hpsum + math.floor(hp)
            n = n + 1
            local t = Spring.GetUnitTeam(u) or -1
            team[t] = (team[t] or 0) + 1
        end
    end
    local ts = {}
    for t = 0, 3 do ts[#ts + 1] = "t" .. t .. "=" .. (team[t] or 0) end
    Spring.Echo(string.format("[RP] f=%d n=%d h=%d hp=%d %s", f, n, hsum, hpsum, table.concat(ts, " ")))
end
function widget:Initialize()
    local spec, full = Spring.GetSpectatingState()
    Spring.Echo(string.format("[RP] start spec=%s fullview=%s norequest=%s", tostring(spec), tostring(full), tostring(NOREQ)))
    if NOREQ then Spring.RequestPath = nil end
    Speed()
end
function widget:GameStart() Speed() end
function widget:GameFrame(f)
    if f % EVERY == 0 then Probe(f) end
    if f >= ENDF and not done then
        done = true
        Probe(f)
        Spring.Echo("[RP] end f=" .. f)
        Spring.SendCommands("quit")
    end
end
function widget:GameOver()
    Spring.Echo("[RP] gameover")
    if not done then done = true; Spring.SendCommands("quit") end
end
'''


def find_engine():
    d = BAR_DATA_DIR / "engine"
    c = sorted(d.rglob("spring-headless.exe"), key=lambda p: str(p.parent), reverse=True)
    if not c:
        raise FileNotFoundError(f"spring-headless.exe not found under {d}")
    return c[0]


BLOCK = ("do local S, f = Spring, function() return false end; S.GiveOrderToUnit = f; S.GiveOrderToUnitArray = f; "
         "S.GiveOrderToUnitMap = f; S.GiveOrderArrayToUnit = f; S.GiveOrderArrayToUnitArray = f; S.GiveOrder = f; "
         "S.SendCommands = function() end end\n")


def setup(write_dir, every, end, speed, threads, extra=(), norequest=False, block_orders=False):
    wd = write_dir / "LuaUI" / "Widgets"
    wd.mkdir(parents=True, exist_ok=True)
    (wd / "replay_probe.lua").write_text(
        PROBE.replace("__EVERY__", str(every)).replace("__END__", str(end)).replace("__SPEED__", str(speed))
             .replace("__NOREQ__", "true" if norequest else "false"),
        encoding="utf-8")
    order = ["Replay Probe"]
    for ex in extra:                       # widgets under test, copied BEFORE the shadowing below
        src = Path(ex)
        txt = src.read_text(encoding="utf-8", errors="replace")
        if block_orders:                    # the widgets can still READ the game, but cannot give a single order
            txt = BLOCK + txt
        (wd / src.name).write_text(txt, encoding="utf-8")
        m = re.search(r"GetInfo.*?name\s*=\s*[\"']([^\"']+)[\"']", txt, re.S)
        order.append(m.group(1) if m else src.stem)
    # shadow every stock / user widget so nothing but the probe (and --with widgets) runs
    for wf in (BAR_DATA_DIR / "LuaUI" / "Widgets").glob("*.lua"):
        dest = wd / wf.name
        if not dest.exists():
            dest.write_text("function widget:GetInfo()\n    return { name='stub_%s', enabled=false }\nend\n" % wf.stem,
                            encoding="utf-8")
    cfg = write_dir / "LuaUI" / "Config"
    cfg.mkdir(parents=True, exist_ok=True)
    names = "\n".join('        ["%s"] = %d,' % (n, i + 1) for i, n in enumerate(order))
    (cfg / "BYAR.lua").write_text('return {\n    allowUserWidgets = true,\n    data = {},\n    order = {\n' + names
                                  + '\n    },\n}\n', encoding="utf-8")
    lines = [f"SpringData = {BAR_DATA_DIR}", "LuaSocketEnabled = 0", "LogFlushLevel = 0", "HangTimeout = 300"]
    if threads:
        lines.append(f"WorkerThreadCount = {threads}")
    (write_dir / "springsettings.cfg").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run(demo, label, every, end, speed, threads, timeout, out, extra=(), norequest=False, block_orders=False):
    demo = Path(demo).resolve()
    write_dir = Path(tempfile.mkdtemp(prefix="replaychk_"))
    setup(write_dir, every, end, speed, threads, extra, norequest, block_orders)
    exe = find_engine()
    env = {**os.environ, "SPRING_DATADIR": str(BAR_DATA_DIR)}
    log = write_dir / "headless.log"
    print(f"[{label}] engine {exe}\n[{label}] write dir {write_dir}\n[{label}] demo {demo.name}")
    t0 = time.monotonic()
    with open(log, "wb") as fh:
        p = subprocess.Popen([str(exe), "--isolation", "--write-dir", str(write_dir), str(demo)],
                             cwd=str(write_dir), stdout=fh, stderr=subprocess.STDOUT, env=env,
                             creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
        last = 0
        while p.poll() is None and time.monotonic() - t0 < timeout:
            time.sleep(5)
            try:
                txt = (write_dir / "infolog.txt").read_text(encoding="utf-8", errors="replace")
                m = re.findall(r"\[RP\] f=(\d+)", txt)
                if m and int(m[-1]) != last:
                    last = int(m[-1])
                    print(f"[{label}] frame {last} after {time.monotonic() - t0:.0f}s")
                if "[RP] end" in txt:        # the in-game quit does not stop a demo run: stop it from here
                    time.sleep(2)
                    break
            except OSError:
                pass
        if p.poll() is None:
            if time.monotonic() - t0 >= timeout:
                print(f"[{label}] timeout, killing")
            p.kill()
    info = (write_dir / "infolog.txt").read_text(encoding="utf-8", errors="replace") if (write_dir / "infolog.txt").exists() else ""
    rows = []
    for m in re.finditer(r"\[RP\] f=(\d+) n=(\d+) h=(\d+) hp=(\d+) t0=(\d+) t1=(\d+) t2=(\d+) t3=(\d+)", info):
        f, n, h, hp, t0_, t1, t2, t3 = map(int, m.groups())
        rows.append({"f": f, "n": n, "h": h, "hp": hp, "t": [t0_, t1, t2, t3]})
    start = re.search(r"\[RP\] start .*", info)
    errs = [l for l in info.splitlines() if "Error" in l and "RP" not in l][:5]
    res = {"label": label, "demo": demo.name, "threads": threads, "with": [Path(x).name for x in extra],
           "norequest": norequest, "rows": rows, "start": start.group(0) if start else None,
           "wall_s": round(time.monotonic() - t0), "write_dir": str(write_dir), "errors": errs}
    Path(out).write_text(json.dumps(res, indent=1), encoding="utf-8")
    print(f"[{label}] {len(rows)} probe rows, {res['wall_s']}s wall; {res['start']}; saved {out}")
    return res


def compare(a_path, b_path):
    a, b = (json.loads(Path(p).read_text(encoding="utf-8")) for p in (a_path, b_path))
    ra, rb = {r["f"]: r for r in a["rows"]}, {r["f"]: r for r in b["rows"]}
    common = sorted(set(ra) & set(rb))
    print(f"A = {a['label']} (threads {a['threads']}), B = {b['label']} (threads {b['threads']}); "
          f"{len(common)} common probe frames")
    first = None
    for f in common:
        same = ra[f]["h"] == rb[f]["h"] and ra[f]["n"] == rb[f]["n"]
        if not same and first is None:
            first = f
        print(f"  f={f:6d} ({f // 1800}:{(f // 30) % 60:02d}) n {ra[f]['n']:4d} / {rb[f]['n']:4d}  "
              f"teams {ra[f]['t'][:2]} / {rb[f]['t'][:2]}  {'same' if same else 'DIFFERENT'}")
    print("first differing probe frame:", first)
    return first


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("demo", nargs="?")
    ap.add_argument("--label", default=os.environ.get("COMPUTERNAME", "machine"))
    ap.add_argument("--every", type=int, default=300)
    ap.add_argument("--end", type=int, default=19200, help="quit at this game frame")
    ap.add_argument("--speed", type=float, default=40)
    ap.add_argument("--threads", type=int, default=0, help="pin WorkerThreadCount (0 = engine default)")
    ap.add_argument("--timeout", type=int, default=1500)
    ap.add_argument("--out", default="replay_check.json")
    ap.add_argument("--with", dest="extra", action="append", default=[], metavar="WIDGET.lua",
                    help="also load this widget (repeatable), e.g. metalbot_stats_tracker.lua")
    ap.add_argument("--no-requestpath", action="store_true", help="make Spring.RequestPath unavailable to widgets")
    ap.add_argument("--block-orders", action="store_true",
                    help="stub out every GiveOrder* / SendCommands the --with widgets could call (read-only widgets)")
    ap.add_argument("--compare", nargs=2, metavar=("A", "B"))
    a = ap.parse_args()
    if a.compare:
        compare(*a.compare)
    else:
        if not a.demo:
            ap.error("a demo path is required")
        run(a.demo, a.label, a.every, a.end, a.speed, a.threads, a.timeout, a.out, a.extra, a.no_requestpath,
            a.block_orders)
