"""Rebuild a game's logs from its replay: play the .sdfz with a bot's widgets (and the logging widgets) loaded.

A real game's infolog is overwritten by the next launch.  The replay keeps every order, so playing it back with the same
widget code loaded gives the bot's log rows again ([CFG] [FSM] [SHARE] [LB] [LT] [CK] ...) plus logging the game never ran:
the stats tracker, ledger logger and state dump for BOTH teams (each fogged to its own allyteam, as in single_client.py).

  python replay_logs.py <demo.sdfz> --bot-team 1 --out knowledge/sessions/<game>/
  python replay_logs.py <demo.sdfz> --bot-team 1 --bot-dir <snapshot of LuaUI/Widgets at the time of the game>

How: replay_check.py's isolated playback (own write dir, the real install untouched) + single_client.wrap() per team.
The bot's orders are no-ops (GiveOrder* / SendCommands are stubbed on the team's shimmed Spring table): the units follow
the recorded orders, so the bot sees the queues and states it saw live.
  - Rows that only READ the game ([TRK] [LED] [SNAP]) are exact.
  - Decision rows are a reconstruction: they match the live game only while the bot code is the code that played
    (use --bot-dir with a snapshot taken before any later deploy), and drift a little with math.random / timing.

Output (--out): infolog.txt, team0.log, team1.log, result.json (bot_testing's MatchResult: find_weakness.py, bot_score.py,
match_summary.py read it; ledger_report.py reads team<N>.log).
"""
import argparse, json, os, re, shutil, subprocess, tempfile, time
from pathlib import Path

import bot_testing as bt
import replay_check as rc
import single_client as sc

BOT_FILES = ("macro_controller.lua", "lab_controller.lua", "unit_controller.lua")
LOG_FILES = ("metalbot_stats_tracker.lua", "ledger_logger.lua", "metalbot_state_dump.lua")   # both teams, from the repo

# After SHIM_HEAD `Spring` is the team's shimmed table, so this does not touch the global one the probe uses.
NO_ORDERS = r"""
do
    local f = function() return false end
    for _, k in ipairs({ "GiveOrderToUnit", "GiveOrderToUnitArray", "GiveOrderToUnitMap", "GiveOrderArrayToUnit",
                         "GiveOrderArrayToUnitArray", "GiveOrder" }) do Spring[k] = f end
    Spring.SendCommands = function() end
end
"""


def wrap(content: str, team: int, bot: bool) -> str:
    w = sc.wrap(content, team, f"T{team}", bot=bot)
    head = sc.SHIM_HEAD.replace("__T__", str(team)).replace("__PROF__", "false")
    assert w.startswith(head)
    return head + NO_ORDERS + w[len(head):]                # right after the shim head, before the widget's code


def setup(write_dir: Path, bot_dir: Path, bot_team: int, log_teams, speed: float, every: int, end: int):
    wd = write_dir / "LuaUI" / "Widgets"
    wd.mkdir(parents=True, exist_ok=True)
    active, skip = [], set()

    def put(fname, text, wname):
        (wd / fname).write_text(text, encoding="utf-8")
        skip.add(fname)
        active.append(wname)

    probe = (rc.PROBE.replace("__EVERY__", str(every)).replace("__END__", str(end)).replace("__SPEED__", str(speed))
             .replace("__NOREQ__", "false"))
    put("replay_probe.lua", probe, "Replay Probe")
    put("single_gc.lua", sc.GC_WIDGET, "Single GC")
    # the bot's modules (bar_framework, stances, machines, blueprints) as they were: copy the snapshot's sub-folders
    for sub in bot_dir.iterdir():
        if sub.is_dir():
            shutil.copytree(sub, wd / sub.name, dirs_exist_ok=True)
    for f in ("blueprint_placer.lua", "blueprints_data.lua"):
        if (bot_dir / f).exists():
            shutil.copy2(bot_dir / f, wd / f)
            skip.add(f)
    for team in log_teams:
        for f in LOG_FILES:
            src = (bt.REPO_DIR / f).read_text(encoding="utf-8")
            put(f"log_t{team}_{f}", wrap(src, team, bot=False), f"{sc.info_name(src, f)} T{team}")
    if bot_team is not None:
        for f in BOT_FILES:
            src = (bot_dir / f).read_text(encoding="utf-8")
            wname = f"{bt.extract_widget_name(src, f)} T{bot_team}"
            put(f"bot_t{bot_team}_{f}", wrap(src, bot_team, bot=True), wname)
            print(f"  [T{bot_team}] {f} -> {wname}")
    bt.shadow_bar_widgets(bt.BAR_DATA_DIR / "LuaUI" / "Widgets", wd, skip)
    disabled = [n for n in sc.ui_widget_names() if n not in active]
    sc.write_byar_config(write_dir / "LuaUI" / "Config", active, disabled)
    (write_dir / "springsettings.cfg").write_text(
        f"SpringData = {bt.BAR_DATA_DIR}\nLuaSocketEnabled = 0\nLogFlushLevel = 0\nHangTimeout = 300\n", encoding="utf-8")
    return active


def run(demo: Path, out: Path, bot_dir: Path, bot_team, log_teams, speed, every, end, timeout, names):
    write_dir = Path(tempfile.mkdtemp(prefix="replaylogs_"))
    active = setup(write_dir, bot_dir, bot_team, log_teams, speed, every, end)
    exe = rc.find_engine()
    print(f"engine {exe}\nwrite dir {write_dir}\nwidgets {len(active)}: {', '.join(active)}")
    env = {**os.environ, "SPRING_DATADIR": str(bt.BAR_DATA_DIR)}
    t0 = time.monotonic()
    info_path = write_dir / "infolog.txt"
    with open(write_dir / "headless.log", "wb") as fh:
        p = subprocess.Popen([str(exe), "--isolation", "--write-dir", str(write_dir), str(demo)], cwd=str(write_dir),
                             stdout=fh, stderr=subprocess.STDOUT, env=env,
                             creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
        last = 0
        while p.poll() is None and time.monotonic() - t0 < timeout:
            time.sleep(10)
            try:
                txt = info_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            m = re.findall(r"\[RP\] f=(\d+)", txt)
            if m and int(m[-1]) != last:
                last = int(m[-1])
                print(f"  frame {last} ({last // 1800}:{(last // 30) % 60:02d}) after {time.monotonic() - t0:.0f}s")
            if "[RP] end" in txt or "[RP] gameover" in txt:   # the in-game quit does not end a demo run
                time.sleep(3)
                break
        if p.poll() is None:
            p.kill()                                        # our own process handle only (never by name)
    wall = time.monotonic() - t0
    text = info_path.read_text(encoding="utf-8", errors="replace") if info_path.exists() else ""
    out.mkdir(parents=True, exist_ok=True)
    (out / "infolog.txt").write_text(text, encoding="utf-8")
    t0_text, t1_text = sc.split_log(text)
    (out / "team0.log").write_text(t0_text, encoding="utf-8")
    (out / "team1.log").write_text(t1_text, encoding="utf-8")
    result = bt._parse_logs(t0_text, t1_text, names[0], names[1], wall)
    (out / "result.json").write_text(json.dumps(result.to_dict(), indent=2), encoding="utf-8")
    removed = re.findall(r"Removed widget: .*", text)
    errs = [l for l in text.splitlines() if ("Error" in l or "error" in l) and "gui_pip" not in l and "CreateShader" not in l]
    print(f"done in {wall:.0f}s, last probe frame {last}; saved to {out}")
    print(f"removed widgets: {removed or 'none'}; error lines: {len(errs)}")
    for l in errs[:12]:
        print("  ", l[:240])
    return result


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("demo", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--bot-team", type=int, default=None, help="team the bot played (omit: logging widgets only)")
    ap.add_argument("--bot-dir", type=Path, default=bt.BAR_DATA_DIR / "LuaUI" / "Widgets",
                    help="widget tree that holds the bot's controllers + bar_framework/stances/machines (default: deployed)")
    ap.add_argument("--log-teams", default="0,1", help="teams that get the tracker / ledger / state dump")
    ap.add_argument("--names", default="team0,team1")
    ap.add_argument("--speed", type=float, default=40)
    ap.add_argument("--every", type=int, default=1800, help="[RP] probe row every N frames")
    ap.add_argument("--end", type=int, default=10 ** 7, help="stop at this frame (default: the game's end)")
    ap.add_argument("--timeout", type=int, default=5400)
    a = ap.parse_args()
    run(a.demo.resolve(), a.out, a.bot_dir, a.bot_team, [int(t) for t in a.log_teams.split(",") if t != ""],
        a.speed, a.every, a.end, a.timeout, a.names.split(","))
