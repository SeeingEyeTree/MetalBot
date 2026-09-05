#!/usr/bin/env python3
"""
bot_testing.py  -  Bot-vs-bot headless tester for Beyond All Reason.

Architecture (mirroring how BAR real servers work):
  1. spring-dedicated.exe  — lightweight server; coordinates game start,
                             waits for ALL players before beginning.
  2. spring-headless.exe   — BotCtrl (team 0) — runs bot1 widgets
  3. spring-headless.exe   — BotB    (team 1) — runs bot2 widgets

Both headless processes load independently (no timing race) and connect to
the dedicated server when ready.  The dedicated server holds the game open
until both send their loadfinished signal.

Usage:
    python bot_testing.py --bot1 PATH --bot2 PATH [options]

Arguments:
    --bot1 PATH      Folder with team-0 bot .lua widgets
    --bot2 PATH      Folder with team-1 bot .lua widgets

Options:
    --duration SECS  Run for this many real seconds then kill (default: 240)
    --save-replay    Keep the .sdfz replay file
    --map NAME       Map name (default: Full Metal Plate 1.7)
"""

import argparse
import gzip
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO_DIR     = Path(__file__).parent
BAR_DATA_DIR = Path(r"C:\Users\malco\AppData\Local\Programs\Beyond-All-Reason\data")
MAP_NAME     = "Full Metal Plate 1.7"
DEFAULT_DURATION = 300

# ── Utility widgets ───────────────────────────────────────────────────────────

# Logs unit creation events and periodic unit-count summaries.
STATS_WIDGET = r"""
local nonComUnits = {[0]=0, [1]=0}

local function isCommander(uDefID)
    local d = uDefID and UnitDefs[uDefID]
    if not d then return false end
    return (d.customParams and
            (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil))
        or (d.name and string.find(string.lower(d.name), "commander") ~= nil)
end

function widget:GetInfo()
    return { name="Headless Stats", desc="Unit count logger", layer=0, enabled=true }
end

function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if (teamID == 0 or teamID == 1) and not isCommander(unitDefID) then
        nonComUnits[teamID] = nonComUnits[teamID] + 1
        local d = UnitDefs[unitDefID]
        Spring.Echo(string.format(
            "[STATS] built team=%d def=%s nc[0]=%d nc[1]=%d",
            teamID, (d and d.name or "?"), nonComUnits[0], nonComUnits[1]))
    end
end

-- Every 9000 frames (~5 min game-time; ~3 real-sec at 100x speed).
function widget:GameFrame(n)
    if n > 0 and n % 9000 == 0 then
        Spring.Echo(string.format("[STATS] frame=%d nc[0]=%d nc[1]=%d", n, nonComUnits[0], nonComUnits[1]))
    end
end
"""


def make_game_end_widget(target_secs: int, do_selfd: bool) -> str:
    """Widget that sets max speed, optionally self-ds the commander, and quits on game over."""
    selfd = ""
    if do_selfd:
        selfd = (
            "\nfunction widget:GameFrame(n)\n"
            "    if done or not startTime or os.clock() - startTime < TARGET_SECS then return end\n"
            "    done = true\n"
            "    local myTeam = Spring.GetMyTeamID()\n"
            "    for _, uid in ipairs(Spring.GetTeamUnits(myTeam) or {}) do\n"
            "        local def = UnitDefs[Spring.GetUnitDefID(uid)]\n"
            "        if def and def.customParams and\n"
            "           (def.customParams.iscommander or def.customParams.is_commander) then\n"
            "            Spring.GiveOrderToUnit(uid, CMD.SELFD, {}, {})\n"
            "            Spring.Echo('[GameEnder] self-d team ' .. myTeam .. ' commander ' .. uid)\n"
            "            return\n"
            "        end\n"
            "    end\n"
            "end\n"
        )
    return (
        f"local TARGET_SECS = {target_secs}\n"
        "local startTime, done = nil, false\n"
        "\n"
        "function widget:GetInfo()\n"
        "    return { name='Game Ender', desc='End helper', layer=0, enabled=true }\n"
        "end\n"
        "\n"
        "function widget:GameStart()\n"
        "    startTime = os.clock()\n"
        "    Spring.SendCommands('setminspeed 100', 'setmaxspeed 100', 'speed 100')\n"
        "end\n"
        + selfd +
        "\nfunction widget:GameOver(winners)\n"
        "    Spring.Echo('[GameEnder] GameOver, quitting')\n"
        "    Spring.SendCommands('quit')\n"
        "end\n"
    )


# ── Helpers ───────────────────────────────────────────────────────────────────

def find_engine(exe_name: str = "spring-headless.exe") -> Path:
    d = BAR_DATA_DIR / "engine"
    candidates = list(d.rglob(exe_name)) if d.is_dir() else []
    if not candidates:
        raise FileNotFoundError(f"{exe_name} not found under {d}")
    candidates.sort(key=lambda p: str(p.parent), reverse=True)
    return candidates[0]


def get_game_type() -> str:
    gz = BAR_DATA_DIR / "rapid/repos-cdn.beyondallreason.dev/byar/versions.gz"
    if gz.exists():
        try:
            with gzip.open(gz, "rt", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.rstrip("\r\n").split(",")
                    if len(parts) >= 4 and parts[0] == "byar:test":
                        return parts[3].strip()
        except Exception:
            pass
    return "byar:test"


def patch_team(content: str, team_id: int, suffix: str) -> str:
    """
    Patch a widget file so it controls the given team.

    Renames the widget (appends suffix), replaces all local alias captures of
    Spring.GetMyTeamID / Spring.GetMyAllyTeamID with hardcoded functions, and
    patches direct Spring.GetMyAllyTeamID() call sites.
    """
    content = re.sub(
        r'(name\s*=\s*)"([^"]*)"',
        lambda m: f'{m.group(1)}"{m.group(2)} {suffix}"',
        content, count=1,
    )
    content = re.sub(r'local\s+DEBUG\s*=\s*false', 'local DEBUG = true', content)
    content = re.sub(
        r'local\s+spGetMyTeamID\s*=\s*Spring\.GetMyTeamID',
        f'local spGetMyTeamID = function() return {team_id} end',
        content,
    )
    content = re.sub(
        r'local\s+spGetMyAllyTeamID\s*=\s*Spring\.GetMyAllyTeamID',
        f'local spGetMyAllyTeamID = function() return {team_id} end',
        content,
    )
    content = re.sub(
        r'Spring\.GetMyAllyTeamID\s+and\s+Spring\.GetMyAllyTeamID\(\)',
        str(team_id),
        content,
    )
    content = re.sub(r'Spring\.GetMyAllyTeamID\(\)', str(team_id), content)
    content = re.sub(r'Spring\.GetMyTeamID\(\)',    str(team_id), content)
    return content


def extract_widget_name(content: str, fallback: str) -> str:
    m = re.search(r'name\s*=\s*"([^"]*)"', content)
    return m.group(1) if m else fallback


def write_script(path: Path, content: str) -> None:
    """Write a Spring start-script with LF line endings (CRLF breaks TdfParser)."""
    path.write_bytes(content.encode("utf-8"))


def shadow_bar_widgets(bar_dir: Path, dest_dir: Path, skip: set) -> None:
    if not bar_dir.is_dir():
        return
    for wf in bar_dir.glob("*.lua"):
        if wf.name in skip:
            continue
        dest = dest_dir / wf.name
        if dest.exists():
            continue
        dest.write_text(
            f"function widget:GetInfo()\n"
            f"    return {{ name='stub_{wf.stem}', enabled=false }}\nend\n",
            encoding="utf-8",
        )


def write_byar_config(config_dir: Path, names: list) -> None:
    config_dir.mkdir(parents=True, exist_ok=True)
    order = "\n".join(f'        ["{n}"] = {i + 1},' for i, n in enumerate(names))
    (config_dir / "BYAR.lua").write_text(
        "return {\n    allowUserWidgets = true,\n    data = {},\n    order = {\n"
        f"{order}\n    }},\n}}\n",
        encoding="utf-8",
    )


def copy_shared_deps(widgets_dir: Path, skip: set) -> None:
    bp_src = REPO_DIR / "blueprint_placer.lua"
    if bp_src.exists():
        (widgets_dir / "blueprint_placer.lua").write_bytes(bp_src.read_bytes())
        skip.add("blueprint_placer.lua")
    bps_src = REPO_DIR / "blueprints"
    if bps_src.is_dir():
        bps_dst = widgets_dir / "blueprints"
        if bps_dst.exists():
            shutil.rmtree(str(bps_dst))
        shutil.copytree(str(bps_src), str(bps_dst))


def setup_player(write_dir: Path, bot_files: list, team_id: int, suffix: str,
                 include_stats: bool, game_end_target: int, do_selfd: bool,
                 spring_data: str) -> list:
    """
    Populate one player's write_dir with bot widgets, shared deps, shadow stubs,
    BYAR config, and springsettings.cfg.  Returns list of active widget names.
    """
    widgets_dir = write_dir / "LuaUI" / "Widgets"
    widgets_dir.mkdir(parents=True, exist_ok=True)

    active: list = []
    skip:  set   = set()

    game_end = make_game_end_widget(game_end_target, do_selfd)
    (widgets_dir / "headless_game_end.lua").write_text(game_end, encoding="utf-8")
    skip.add("headless_game_end.lua")
    active.append("Game Ender")

    if include_stats:
        (widgets_dir / "headless_stats.lua").write_text(STATS_WIDGET, encoding="utf-8")
        skip.add("headless_stats.lua")
        active.append("Headless Stats")

    copy_shared_deps(widgets_dir, skip)

    for lua_file in bot_files:
        content    = lua_file.read_text(encoding="utf-8")
        orig_name  = extract_widget_name(content, lua_file.stem)
        wname      = f"{orig_name} {suffix}"
        patched    = patch_team(content, team_id, suffix)
        dest_name  = f"bot_{suffix.lower()}_{lua_file.name}"
        (widgets_dir / dest_name).write_text(patched, encoding="utf-8")
        skip.add(dest_name)
        active.append(wname)
        print(f"  [{suffix}] {lua_file.name} -> \"{wname}\"")

    shadow_bar_widgets(BAR_DATA_DIR / "LuaUI" / "Widgets", widgets_dir, skip)
    write_byar_config(write_dir / "LuaUI" / "Config", active)

    # Both headless clients need a long hang-timeout to survive archive scanning
    # and enough network patience to connect to the dedicated server.
    (write_dir / "springsettings.cfg").write_text(
        f"SpringData = {spring_data}\n"
        "LuaSocketEnabled = 0\n"
        "LogFlushLevel = 0\n"
        "HangTimeout = 120\n"
        "InitialNetworkTimeout = 300\n"
        "NetworkTimeout = 300\n",
        encoding="utf-8",
    )
    return active


def setup_dedicated(ded_dir: Path, spring_data: str) -> None:
    """Write springsettings for the lightweight dedicated server process.

    spring-dedicated is launched with -isolation-dir=ded_dir so ded_dir is
    its write directory (infolog.txt ends up here).

    Spring (dedicated) in isolation mode scans ded_dir/base, ded_dir/maps,
    ded_dir/packages, plus anything in SpringData.  It does NOT auto-discover
    the engine's base/ dir from SpringData the way headless does, so we copy
    the engine base archives (springcontent.sdz etc.) into ded_dir/base so
    Spring finds them.  We also seed ded_dir/cache from BAR's pre-built cache
    to skip the ~60 s full map scan.
    """
    ded_dir.mkdir(parents=True, exist_ok=True)

    engine_dir = find_engine("spring-dedicated.exe").parent

    # Copy engine base archives so Spring finds "Spring content v1" etc.
    engine_base = engine_dir / "base"
    ded_base    = ded_dir   / "base"
    if engine_base.is_dir():
        ded_base.mkdir(exist_ok=True)
        for src in engine_base.rglob("*.sdz"):
            dst = ded_base / src.name
            if not dst.exists():
                shutil.copy2(str(src), str(dst))

    # Seed archive cache from BAR's pre-built cache (speeds up map/package scan).
    data_cache = BAR_DATA_DIR / "cache" / "ArchiveCache22.lua"
    if data_cache.exists():
        cache_dir = ded_dir / "cache"
        cache_dir.mkdir(exist_ok=True)
        shutil.copy2(str(data_cache), str(cache_dir / "ArchiveCache22.lua"))

    (ded_dir / "springsettings.cfg").write_text(
        f"SpringData = {spring_data}\n"
        "LuaSocketEnabled = 0\n"
        "LogFlushLevel = 0\n"
        "InitialNetworkTimeout = 300\n"   # wait up to 5 min for clients to load
        "NetworkTimeout = 300\n",
        encoding="utf-8",
    )


def _common_script_body(game_type, map_name, save_replay) -> str:
    record = "1" if save_replay else "0"
    return (
        f"    GameType={game_type};\n    MapName={map_name};\n"
        "    StartPosType=0;\n    FixedRNGSeed=1;\n"
        f"    RecordDemo={record};\n    GameStartDelay=0;\n"
        "    NoHelperAIs=0;\n\n"
        "    [MODOPTIONS]\n    {\n"
        "        deathmode=com;\n        maxspeed=100;\n        minspeed=0.1;\n"
        "        allowuserwidgets=1;\n        allowunitcontrolwidgets=1;\n"
        "        allowuserscripts=1;\n    }\n\n"
        "    [ALLYTEAM0] { numallies=0; }\n    [ALLYTEAM1] { numallies=0; }\n\n"
        "    [TEAM0]\n    {\n"
        "        teamleader=0;\n        allyteam=0;\n"
        "        side=Cortex;\n        rgbcolor=0.2 0.4 0.9;\n    }\n"
        "    [TEAM1]\n    {\n"
        "        teamleader=1;\n        allyteam=1;\n"
        "        side=Cortex;\n        rgbcolor=0.9 0.2 0.2;\n    }\n\n"
        # fullview=1 so the stats widget on BotCtrl sees both teams' units
        "    [PLAYER0]\n    {\n        name=BotCtrl;\n        team=0;\n        fullview=1;\n    }\n"
        "    [PLAYER1]\n    {\n        name=BotB;\n        team=1;\n    }\n"
    )


def render_dedicated_script(game_type, map_name, save_replay, host_port) -> str:
    """Startscript for spring-dedicated: the authoritative server, no local player."""
    body = _common_script_body(game_type, map_name, save_replay)
    return (
        "[GAME]\n{\n"
        f"    IsHost=1;\n    HostPort={host_port};\n"
        + body + "}\n"
    )


def render_player_script(player_name, game_type, map_name, save_replay, host_port) -> str:
    """Startscript for a spring-headless client connecting to the dedicated server."""
    body = _common_script_body(game_type, map_name, save_replay)
    return (
        "[GAME]\n{\n"
        f"    MyPlayerName={player_name};\n    IsHost=0;\n"
        f"    HostIP=::1;\n    HostPort={host_port};\n"
        + body + "}\n"
    )


def graceful_stop(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        os.kill(proc.pid, signal.CTRL_BREAK_EVENT)
    except (OSError, AttributeError):
        proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bot1", required=True, metavar="PATH",
                   help="Team-0 bot folder")
    p.add_argument("--bot2", required=True, metavar="PATH",
                   help="Team-1 bot folder")
    p.add_argument("--duration", type=int, default=DEFAULT_DURATION, metavar="SECS",
                   help="Real seconds to run before killing (default: 240)")
    p.add_argument("--save-replay", action="store_true")
    p.add_argument("--map", default=MAP_NAME, dest="map_name")
    args = p.parse_args()

    bot1_dir = Path(args.bot1).resolve()
    bot2_dir = Path(args.bot2).resolve()

    for d, label in [(bot1_dir, "--bot1"), (bot2_dir, "--bot2")]:
        if not d.is_dir():
            sys.exit(f"{label}: folder not found: {d}")

    bot1_files = sorted(bot1_dir.glob("*.lua"))
    bot2_files = sorted(bot2_dir.glob("*.lua"))

    if not bot1_files:
        sys.exit(f"No .lua files in {bot1_dir}")
    if not bot2_files:
        sys.exit(f"No .lua files in {bot2_dir}")

    # ── Directories ────────────────────────────────────────────────────────────
    stamp    = datetime.now().strftime("%Y%m%d_%H%M%S")
    tmp      = Path(os.environ.get("LOCALAPPDATA", r"C:\Temp")) / "Temp"
    test_dir = tmp / f"bottest_{stamp}_{os.getpid()}"
    ded_dir  = test_dir / "dedicated"
    p0_dir   = test_dir / "p0"   # BotCtrl (team 0)
    p1_dir   = test_dir / "p1"   # BotB    (team 1)
    for d in (ded_dir, p0_dir, p1_dir):
        d.mkdir(parents=True, exist_ok=True)

    headless  = find_engine("spring-headless.exe")
    dedicated = find_engine("spring-dedicated.exe")
    game_type = get_game_type()

    import random
    host_port = random.randint(9000, 19000)

    spring_data = str(BAR_DATA_DIR)

    print(f"Write dir : {test_dir}")
    print(f"Engine    : {headless}")
    print(f"Dedicated : {dedicated}")
    print(f"Game type : {game_type}")
    print(f"Map       : {args.map_name}")
    print(f"Bot 0     : {bot1_dir.name}  ({len(bot1_files)} files)")
    print(f"Bot 1     : {bot2_dir.name}  ({len(bot2_files)} files)")
    print(f"Duration  : {args.duration}s real time")
    print(f"Host port : {host_port}")

    # Both players get the stats widget; P0 reports nc[0], P1 reports nc[1].
    # fullview=1 on BotCtrl doesn't propagate UnitCreated to widgets in headless
    # dedicated mode, so P1 must track its own units independently.
    # P1 self-destructs its commander after the gameplay window so the game ends
    # naturally, which causes Spring to finalize the replay (.sdfz) properly.
    game_end_target = max(30, args.duration - 150)
    setup_player(p0_dir, bot1_files, 0, "T0", include_stats=True,
                 game_end_target=game_end_target, do_selfd=False, spring_data=spring_data)
    setup_player(p1_dir, bot2_files, 1, "T1", include_stats=True,
                 game_end_target=game_end_target, do_selfd=True,  spring_data=spring_data)
    setup_dedicated(ded_dir, spring_data)

    # ── Start scripts (LF-only — CRLF breaks Spring's TdfParser) ──────────────
    write_script(ded_dir / "startscript.txt",
        render_dedicated_script(game_type, args.map_name, args.save_replay, host_port))
    write_script(p0_dir / "startscript.txt",
        render_player_script("BotCtrl", game_type, args.map_name, args.save_replay, host_port))
    write_script(p1_dir / "startscript.txt",
        render_player_script("BotB", game_type, args.map_name, args.save_replay, host_port))

    print("Scripts written.\n")

    # spring-dedicated uses -isolation-dir=ded_dir so it writes infolog.txt there.
    ded_log    = ded_dir / "infolog.txt"
    ded_stdout = ded_dir / "dedicated_stdout.log"
    p0_log     = p0_dir  / "headless.log"
    p1_log     = p1_dir  / "headless.log"

    env   = {**os.environ, "SPRING_DATADIR": spring_data}
    flags = subprocess.CREATE_NEW_PROCESS_GROUP

    global_start = time.monotonic()

    # -isolation-dir=ded_dir → ded_dir is the write dir (infolog goes there).
    # ded_dir/springsettings.cfg has SpringData=BAR_DATA_DIR so Spring also
    # scans the BAR data tree (maps, packages, engine/*/base for Spring content).
    # Run from the engine dir so Windows finds the engine DLLs.
    engine_dir = dedicated.parent

    print("Launching dedicated server...")
    with open(ded_stdout, "wb") as d_fh:
        ded_proc = subprocess.Popen(
            [str(dedicated), f"-isolation-dir={ded_dir}",
             str(ded_dir / "startscript.txt")],
            cwd=str(engine_dir), stdout=d_fh, stderr=subprocess.STDOUT,
            env=env, creationflags=flags,
        )
    print(f"  Dedicated PID: {ded_proc.pid}")

    # Brief pause so the server is listening before clients try to connect.
    time.sleep(2)

    print("Launching headless clients...")
    with open(p0_log, "wb") as h_fh:
        p0_proc = subprocess.Popen(
            [str(headless), "--isolation", "--write-dir", str(p0_dir),
             str(p0_dir / "startscript.txt")],
            cwd=str(p0_dir), stdout=h_fh, stderr=subprocess.STDOUT,
            env=env, creationflags=flags,
        )
    with open(p1_log, "wb") as h_fh:
        p1_proc = subprocess.Popen(
            [str(headless), "--isolation", "--write-dir", str(p1_dir),
             str(p1_dir / "startscript.txt")],
            cwd=str(p1_dir), stdout=h_fh, stderr=subprocess.STDOUT,
            env=env, creationflags=flags,
        )
    print(f"  BotCtrl PID: {p0_proc.pid}  (team 0)")
    print(f"  BotB    PID: {p1_proc.pid}  (team 1)")
    print(f"Running for {args.duration}s total.\n")

    deadline = global_start + args.duration
    procs = {"D": ded_proc, "P0": p0_proc, "P1": p1_proc}
    try:
        while time.monotonic() < deadline:
            tags = {k: ("done" if v.poll() is not None else "run ") for k, v in procs.items()}
            if all(t == "done" for t in tags.values()):
                elapsed = time.monotonic() - global_start
                print(f"\nAll processes exited after {elapsed:.0f}s.")
                break
            elapsed = time.monotonic() - global_start
            status = "  ".join(f"{k}:{t}" for k, t in tags.items())
            print(f"\r  {status}  {elapsed:.0f}s", end="", flush=True)
            time.sleep(2)
        else:
            elapsed = time.monotonic() - global_start
            print(f"\n\n{elapsed:.0f}s reached; stopping.")
            graceful_stop(p1_proc)
            graceful_stop(p0_proc)
            graceful_stop(ded_proc)
    except KeyboardInterrupt:
        print("\nInterrupted; stopping.")
        graceful_stop(p1_proc)
        graceful_stop(p0_proc)
        graceful_stop(ded_proc)

    # ── Parse stats ────────────────────────────────────────────────────────────
    # BotCtrl (p0, fullview=1) is authoritative for nc[0] and nc[1].
    # Fall back to p1's stats for nc[1] if p0 didn't see any team-1 units.
    def read_log(log_path: Path) -> str:
        text = ""
        for f in [log_path, log_path.with_name("infolog.txt")]:
            try:
                text += f.read_bytes().decode("utf-8", errors="replace")
            except Exception:
                pass
        return text

    p0_text = read_log(p0_log)
    p1_text = read_log(p1_log)
    ded_text = read_log(ded_log)   # BAR_DATA_DIR/infolog.txt from dedicated

    def extract_nc(text):
        nc = {0: 0, 1: 0}
        for line in text.splitlines():
            if "[STATS]" not in line:
                continue
            m0 = re.search(r"nc\[0\]=(\d+)", line)
            m1 = re.search(r"nc\[1\]=(\d+)", line)
            if m0:
                nc[0] = max(nc[0], int(m0.group(1)))
            if m1:
                nc[1] = max(nc[1], int(m1.group(1)))
        return nc

    nc_p0 = extract_nc(p0_text)
    nc_p1 = extract_nc(p1_text)
    nc = {
        0: nc_p0[0],
        1: nc_p0[1] if nc_p0[1] > 0 else nc_p1[1],
    }

    all_stats   = [l for l in (p0_text + p1_text).splitlines() if "[STATS]" in l]
    built_lines = [l for l in all_stats if "built" in l]

    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)
    print(f"Non-commander units built:")
    print(f"  Team 0 ({bot1_dir.name}): {nc[0]}")
    print(f"  Team 1 ({bot2_dir.name}): {nc[1]}")

    if built_lines:
        print(f"\nLast build events ({len(built_lines)} total):")
        for line in built_lines[-12:]:
            m = re.search(r"\[STATS\] (.+)", line)
            if m:
                print(f"  {m.group(1)}")

    print(f"\nSanity checks:")
    for t in range(2):
        tag  = "PASS" if nc[t] > 0 else "FAIL"
        name = bot1_dir.name if t == 0 else bot2_dir.name
        print(f"  [{tag}] Team {t} ({name}) built {nc[t]} non-commander unit(s)")

    # Show key events from dedicated + BotCtrl logs
    interesting = [l for l in (ded_text + p0_text).splitlines() if any(
        kw in l for kw in ("Loading widget", "ERROR", "[STATS]", "[MC]", "[LC]", "[UC]", "[WE]",
                           "Player ", "Connection", "Initial Spawn", "finished loading")
    )]
    print(f"\n--- Widget load + key events (last 20) ---")
    for ln in interesting[-20:]:
        print(ln)

    print("=" * 60)

    # Copy replay to BAR demos folder so the launcher can find it.
    if args.save_replay:
        demos_src = ded_dir / "demos-server"
        demos_dst = BAR_DATA_DIR / "demos"
        demos_dst.mkdir(exist_ok=True)
        copied = []
        for sdfz in sorted(demos_src.glob("*.sdfz")):
            if sdfz.stat().st_size > 0:
                dst = demos_dst / sdfz.name
                shutil.copy2(str(sdfz), str(dst))
                copied.append(dst)
        if copied:
            print(f"\nReplay copied to BAR demos folder:")
            for p in copied:
                print(f"  {p}")
            print("Open BAR launcher -> Replays tab to watch.")
        else:
            print("\nNo replay file found (game may not have ended naturally).")


if __name__ == "__main__":
    main()
