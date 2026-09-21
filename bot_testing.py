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
from dataclasses import dataclass, field
from datetime import datetime, timezone
import gzip
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO_DIR     = Path(__file__).parent
BAR_DATA_DIR = Path(os.environ.get(
    "BAR_DATA_DIR",
    r"C:\Users\malco\AppData\Local\Programs\Beyond-All-Reason\data"
))
MAP_NAME         = "Full Metal Plate 1.7"
DEFAULT_DURATION = 400
MAX_GAME_MINUTES = 75                         # in-game time cap
DRAW_FRAME       = MAX_GAME_MINUTES * 60 * 30  # 135 000 game frames at 30 fps
# Game frame at which both sides self-destruct their commander so the match ends
# cleanly. A frame trigger is symmetric and deterministic across both processes,
# unlike the os.clock() deadline, which measures CPU time and drifts per process.
# The engine only writes a replay's footer on a clean shutdown, so without this a
# match stopped by the wall-clock kill leaves a 0-byte .sdfz.
END_FRAME        = 36000                       # 20 game-minutes at 30 fps
EXIT_GRACE       = 60                          # seconds to finish after the deadline

# ── Result dataclass ──────────────────────────────────────────────────────────

@dataclass
class MatchResult:
    """Structured output from a single bot-vs-bot match."""
    winner:             "int | None"    # 0, 1, or None (draw/unknown)
    winner_method:      str             # "game_over"|"draw_score"|"unit_count_fallback"|"draw"
    units_built:        dict            # {0: int, 1: int}  cumulative over whole match
    draw_score:         "dict | None"   # {nc0,nc1,mv0,mv1,score_winner} — only when time limit hit
    sanity:             dict            # {0: {alive_nc,built}, 1: ...} — from 1-game-min check
    sanity_pass:        dict            # {0: bool, 1: bool}
    resource_timeline:  list            # [{frame,game_min,team,metal,metal_inc,energy,energy_inc}]
    army_timeline:      list            # [{frame,game_min,team,mv,alive_nc}]
    loss_summary:       dict            # {0: {def_name: {count,total_mv}}, 1: ...}
    lua_errors:         list            # Lua/Spring error strings pulled from logs
    duration_secs:      float           # actual wall-clock seconds the match ran
    bot0_name:          str             # directory name of team-0 bot
    bot1_name:          str             # directory name of team-1 bot
    timestamp:          str             # ISO-8601 UTC
    log_excerpt:        str             # last 20 interesting log lines joined with \n

    def crashed(self, team: int) -> bool:
        """True when this team's bot failed the 1-minute sanity check."""
        return not self.sanity_pass.get(team, True)

    def to_dict(self) -> dict:
        """Return a JSON-serialisable dict (JSON requires string keys for objects)."""
        return {
            "winner":            self.winner,
            "winner_method":     self.winner_method,
            "units_built":       {str(k): v for k, v in self.units_built.items()},
            "draw_score":        self.draw_score,
            "sanity":            {str(k): v for k, v in self.sanity.items()},
            "sanity_pass":       {str(k): v for k, v in self.sanity_pass.items()},
            "resource_timeline": self.resource_timeline,
            "army_timeline":     self.army_timeline,
            "loss_summary":      {str(k): v for k, v in self.loss_summary.items()},
            "lua_errors":        self.lua_errors,
            "duration_secs":     self.duration_secs,
            "bot0_name":         self.bot0_name,
            "bot1_name":         self.bot1_name,
            "timestamp":         self.timestamp,
            "log_excerpt":       self.log_excerpt,
        }


# ── Utility widgets ───────────────────────────────────────────────────────────

# Logs unit creation events and periodic unit-count summaries.
STATS_WIDGET = r"""
-- frame constants (mirror bot_testing.py constants)
local DRAW_FRAME  = __END_FRAME__   -- game frame at which the match is ended
-- Wall-clock adjudication deadline, injected by setup_player. DRAW_FRAME alone is
-- unreachable in a normal match (the sim only reaches ~30k frames in 150 real seconds
-- on this hardware, not 135k), so without this the fair scoring path never ran.
local ADJ_SECS    = __ADJ_SECS__
local SANITY_FRAME = 1800    -- 1 game-minute
local startTime   = nil

-- cumulative build counts, driven by UnitCreated events.
-- NOTE: UnitCreated only fires for the player's own team in headless mode,
-- even with fullview=1.  P0 tracks team-0 builds; P1 tracks team-1 builds.
local nonComUnits = {[0]=0, [1]=0}
local drawDone    = false

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

function widget:GameStart()
    startTime = os.clock()
end

-- ── UnitCreated ───────────────────────────────────────────────────────────────
function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if (teamID ~= 0 and teamID ~= 1) or isCommander(unitDefID) then return end
    local d   = UnitDefs[unitDefID]
    local tag = (d and d.isFactory) and "factory" or "built"
    nonComUnits[teamID] = nonComUnits[teamID] + 1
    Spring.Echo(string.format(
        "[STATS] %s frame=%d team=%d def=%s mv=%d nc[0]=%d nc[1]=%d",
        tag, Spring.GetGameFrame(), teamID, (d and d.name or "?"),
        (d and d.metalCost or 0), nonComUnits[0], nonComUnits[1]))
end

-- ── UnitDestroyed ─────────────────────────────────────────────────────────────
function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID, attackerDefID, attackerTeamID)
    if (teamID ~= 0 and teamID ~= 1) or isCommander(unitDefID) then return end
    local d = UnitDefs[unitDefID]
    Spring.Echo(string.format(
        "[STATS] destroyed frame=%d team=%d def=%s mv=%d attacker_team=%d",
        Spring.GetGameFrame(), teamID, (d and d.name or "?"),
        (d and d.metalCost or 0), (attackerTeamID or -1)))
end

-- ── Helper: live stats via direct unit query ──────────────────────────────────
-- Works correctly on P0 (fullview=1) for both teams.
-- On P1, GetTeamUnits(0) returns empty — P0 log is authoritative.
local function teamLiveStats(teamID)
    local mv, nc = 0, 0
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID and not isCommander(defID) then
            local d = UnitDefs[defID]
            if d then
                mv = mv + (d.metalCost or 0)
                nc = nc + 1
            end
        end
    end
    return mv, nc
end

-- ── GameFrame ─────────────────────────────────────────────────────────────────
function widget:GameFrame(n)

    -- 1-game-minute sanity: bots should have started building by now
    if n == SANITY_FRAME then
        for tid = 0, 1 do
            local _, nc = teamLiveStats(tid)
            Spring.Echo(string.format("[SANITY] frame=%d team=%d alive_nc=%d cumulative_built=%d",
                n, tid, nc, nonComUnits[tid]))
        end
    end

    -- Resource + cumulative build snapshot every game-minute (1800 frames).
    -- Was every 5 game-minutes, which was far too coarse to choose a checkpoint: run-to-run
    -- noise grows over a match (1.06x at frame 9000, 1.68x at 27000) while the signal from a
    -- change only appears once the bots diverge from their scripted opening, so the usable
    -- window has to be found empirically. Echoing two extra lines a minute costs nothing.
    if n > 0 and n % 1800 == 0 then
        Spring.Echo(string.format("[STATS] frame=%d nc[0]=%d nc[1]=%d",
            n, nonComUnits[0], nonComUnits[1]))
        for tid = 0, 1 do
            local m, _, _, mi = Spring.GetTeamResources(tid, "metal")
            local e, _, _, ei = Spring.GetTeamResources(tid, "energy")
            if m then
                Spring.Echo(string.format(
                    "[STATS] res frame=%d team=%d metal=%.1f metal_inc=%.2f energy=%.1f energy_inc=%.2f",
                    n, tid, m, mi or 0, e or 0, ei or 0))
            end
        end
    end

    -- Army value snapshot every 2 game-minutes. This one iterates all team units, so it
    -- stays less frequent than the resource sample above.
    if n > 0 and n % 3600 == 0 then
        for tid = 0, 1 do
            local mv, nc = teamLiveStats(tid)
            Spring.Echo(string.format(
                "[STATS] army frame=%d team=%d mv=%.0f alive_nc=%d",
                n, tid, mv, nc))
        end
    end

    -- Draw detection at DRAW_FRAME: score the game, then self-d own commander.
    -- P0 (fullview) emits accurate cross-team scores; Python uses P0 as authoritative.
    -- Both processes independently kill their own commander so the game ends cleanly.
    local deadlineHit = (startTime ~= nil) and (os.clock() - startTime >= ADJ_SECS)
    if (n >= DRAW_FRAME or deadlineHit) and not drawDone then
        drawDone = true
        local mv0, nc0 = teamLiveStats(0)
        local mv1, nc1 = teamLiveStats(1)
        local scoreWinner = -1
        if mv0 > mv1 * 1.1 then scoreWinner = 0
        elseif mv1 > mv0 * 1.1 then scoreWinner = 1
        end
        Spring.Echo(string.format(
            "[DRAW_SCORE] frame=%d nc0=%d nc1=%d mv0=%.0f mv1=%.0f score_winner=%d",
            n, nc0, nc1, mv0, mv1, scoreWinner))
        local myTeam = Spring.GetMyTeamID()
        for _, uid in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
            local defID = Spring.GetUnitDefID(uid)
            if defID then
                local d = UnitDefs[defID]
                if d and d.customParams and
                   (d.customParams.iscommander or d.customParams.is_commander) then
                    Spring.GiveOrderToUnit(uid, CMD.SELFD, {}, {})
                end
            end
        end
    end
end
"""


def make_game_end_widget(target_secs: int, do_selfd: bool) -> str:
    """Widget that sets max speed, optionally self-ds the commander, and quits on game over.

    target_secs is wall-clock seconds (os.clock), not game-time seconds.
    The game runs at 100x speed, so game-frame thresholds are unreliable for
    real-time control — os.clock() is used instead.
    """
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
        "    for _, allyTeamID in ipairs(winners or {}) do\n"
        "        Spring.Echo('[WINNER] allyteam=' .. allyTeamID)\n"
        "    end\n"
        "    Spring.Echo('[GameEnder] GameOver, quitting')\n"
        "    Spring.SendCommands('quit')\n"
        "end\n"
    )


# ── Helpers ───────────────────────────────────────────────────────────────────

def find_engine(exe_name: str = "spring-headless.exe") -> Path:
    if sys.platform != "win32":
        exe_name = exe_name.replace(".exe", "")
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
    # blueprint_placer.lua — flat copy alongside bot widgets
    bp_src = REPO_DIR / "blueprint_placer.lua"
    if bp_src.exists():
        (widgets_dir / "blueprint_placer.lua").write_bytes(bp_src.read_bytes())
        skip.add("blueprint_placer.lua")

    # blueprints/ data directory
    bps_src = REPO_DIR / "blueprints"
    if bps_src.is_dir():
        bps_dst = widgets_dir / "blueprints"
        if bps_dst.exists():
            shutil.rmtree(str(bps_dst))
        shutil.copytree(str(bps_src), str(bps_dst))

    # bar_framework/ shared Lua utilities
    # Loaded in bot code via: VFS.Include("LuaUI/Widgets/bar_framework/<file>.lua")
    fw_src = REPO_DIR / "bar_framework"
    if fw_src.is_dir():
        fw_dst = widgets_dir / "bar_framework"
        fw_dst.mkdir(exist_ok=True)
        for lua_file in fw_src.glob("*.lua"):
            (fw_dst / lua_file.name).write_bytes(lua_file.read_bytes())


def setup_player(write_dir: Path, bot_files: list, team_id: int, suffix: str,
                 include_stats: bool, game_end_target: int, do_selfd: bool,
                 spring_data: str, end_frame: int = END_FRAME) -> list:
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
        (widgets_dir / "headless_stats.lua").write_text(
            STATS_WIDGET.replace("__ADJ_SECS__", str(game_end_target))
                        .replace("__END_FRAME__", str(end_frame)), encoding="utf-8")
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


def render_host_script(player_name: str, game_type: str, map_name: str,
                       save_replay: bool, host_port: int) -> str:
    """Start script for P0 running as the host (no separate dedicated server)."""
    body = _common_script_body(game_type, map_name, save_replay)
    return (
        "[GAME]\n{\n"
        f"    IsHost=1;\n    MyPlayerName={player_name};\n    HostPort={host_port};\n"
        + body + "}\n"
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
        # fullview=1 on BOTH players. P0 needs it so the stats widget can see both
        # teams' units. P1 needs it for *fairness*: without it team 1's bot plays
        # fogged while team 0 effectively has full map vision, which silently decided
        # every match -- side-swap tests showed whoever was --bot1 always won,
        # regardless of which bot it was. Do not remove without re-running a
        # side-swap sanity check. See knowledge/lessons_learned.md.
        "    [PLAYER0]\n    {\n        name=BotCtrl;\n        team=0;\n        fullview=1;\n    }\n"
        "    [PLAYER1]\n    {\n        name=BotB;\n        team=1;\n        fullview=1;\n    }\n"
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


# ── Log parsing ───────────────────────────────────────────────────────────────

_LUA_ERROR_RE = re.compile(
    r"(\[Error\]|Error in widget|Error in script|Script error|LuaError"
    r"|attempt to (index|call|perform|concatenate|compare|get length)"
    r"|stack traceback"
    r"|\[string )",
    re.IGNORECASE,
)

def _read_log(log_path: Path) -> str:
    text = ""
    for f in [log_path, log_path.with_name("infolog.txt")]:
        try:
            text += f.read_bytes().decode("utf-8", errors="replace")
        except Exception:
            pass
    return text


def extract_lua_errors(p0_text: str, p1_text: str) -> list:
    """Pull Lua/Spring error lines from both player logs, deduplicated."""
    errors: list = []
    seen: set = set()
    for text in (p0_text, p1_text):
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if _LUA_ERROR_RE.search(line):
                snippet = "\n".join(
                    l.strip() for l in lines[max(0, i - 1):i + 3] if l.strip()
                )
                key = snippet[:120]
                if key not in seen:
                    seen.add(key)
                    errors.append(snippet)
    return errors[:20]


def _extract_nc(text: str) -> dict:
    nc = {0: 0, 1: 0}
    for line in text.splitlines():
        if "[STATS]" not in line:
            continue
        for t in (0, 1):
            m = re.search(rf"nc\[{t}\]=(\d+)", line)
            if m:
                nc[t] = max(nc[t], int(m.group(1)))
    return nc


def _parse_winner(text: str) -> "int | None":
    for line in text.splitlines():
        m = re.search(r"\[WINNER\] allyteam=(\d+)", line)
        if m:
            return int(m.group(1))
    return None


def _parse_draw_score(text: str) -> "dict | None":
    for line in reversed(text.splitlines()):
        m = re.search(
            r"\[DRAW_SCORE\].*nc0=(\d+).*nc1=(\d+).*mv0=([\d.]+).*mv1=([\d.]+).*score_winner=(-?\d+)",
            line)
        if m:
            return {
                "nc0": int(m.group(1)), "nc1": int(m.group(2)),
                "mv0": float(m.group(3)), "mv1": float(m.group(4)),
                "score_winner": int(m.group(5)),
            }
    return None


def _parse_sanity(text: str) -> dict:
    result: dict = {}
    for line in text.splitlines():
        m = re.search(r"\[SANITY\].*team=(\d+).*alive_nc=(\d+).*cumulative_built=(\d+)", line)
        if m:
            result[int(m.group(1))] = {
                "alive_nc": int(m.group(2)), "built": int(m.group(3))}
    return result


def _parse_resource_timeline(text: str) -> list:
    rows: list = []
    for line in text.splitlines():
        m = re.search(
            r"\[STATS\] res frame=(\d+) team=(\d+) metal=([\d.]+) metal_inc=([\d.]+)"
            r" energy=([\d.]+) energy_inc=([\d.]+)", line)
        if m:
            rows.append({
                "frame":      int(m.group(1)),
                "game_min":   round(int(m.group(1)) / 1800, 1),
                "team":       int(m.group(2)),
                "metal":      float(m.group(3)),
                "metal_inc":  float(m.group(4)),
                "energy":     float(m.group(5)),
                "energy_inc": float(m.group(6)),
            })
    return rows


def _parse_army_timeline(text: str) -> list:
    rows: list = []
    for line in text.splitlines():
        m = re.search(
            r"\[STATS\] army frame=(\d+) team=(\d+) mv=([\d.]+) alive_nc=(\d+)", line)
        if m:
            rows.append({
                "frame":    int(m.group(1)),
                "game_min": round(int(m.group(1)) / 1800, 1),
                "team":     int(m.group(2)),
                "mv":       float(m.group(3)),
                "alive_nc": int(m.group(4)),
            })
    return rows


def _parse_loss_summary(text: str) -> dict:
    losses: dict = {0: {}, 1: {}}
    for line in text.splitlines():
        m = re.search(r"\[STATS\] destroyed.*team=(\d+) def=(\S+) mv=(\d+)", line)
        if m:
            tid, dname, mv = int(m.group(1)), m.group(2), int(m.group(3))
            if tid in losses:
                entry = losses[tid].setdefault(dname, {"count": 0, "total_mv": 0})
                entry["count"]    += 1
                entry["total_mv"] += mv
    return losses


def _parse_logs(p0_text: str, p1_text: str, bot0_name: str, bot1_name: str,
                duration_secs: float) -> MatchResult:
    """Build a MatchResult from the raw log text of both headless processes."""
    nc_p0 = _extract_nc(p0_text)
    nc_p1 = _extract_nc(p1_text)
    # Team 0 from P0, team 1 from P1 -- ALWAYS, no cross-team fallback. This used to read
    # team 1 from P0 whenever P0 saw any team-1 unit at all, but P0 cannot actually see
    # team 1 (fullview=1 does not work cross-team in headless), so it undercounted
    # whoever sat in slot 2 by roughly 5x. In a mirror match of one bot against itself
    # that reported 2263 vs 341 when the true figures were 2263 vs 1731.
    nc = {0: nc_p0[0], 1: nc_p1[1]}

    winner_raw = _parse_winner(p0_text) if _parse_winner(p0_text) is not None \
                 else _parse_winner(p1_text)
    # Adjudicate by army metal value, taking each side's figure from the process that
    # can actually see it. Both processes emit a [DRAW_SCORE] line at the same deadline,
    # but each one's numbers for the *other* team are blind: in one mirror match P0
    # reported mv0=194262 mv1=12599 while P1 reported mv0=9904 mv1=54920 for the very
    # same frame. Only the own-team half of each line is trustworthy, so take mv0/nc0
    # from P0 and mv1/nc1 from P1 and compare those.
    ds0 = _parse_draw_score(p0_text)
    ds1 = _parse_draw_score(p1_text)
    draw_score = None
    if ds0 is not None and ds1 is not None:
        mv0, ncl0 = ds0["mv0"], ds0["nc0"]
        mv1, ncl1 = ds1["mv1"], ds1["nc1"]
        if   mv0 > mv1 * 1.1: sw = 0
        elif mv1 > mv0 * 1.1: sw = 1
        else:                 sw = -1
        draw_score = {"nc0": ncl0, "nc1": ncl1, "mv0": mv0, "mv1": mv1,
                      "score_winner": sw}

    # Sanity, same rule: team 0 from P0, team 1 from P1. P0 used to overwrite P1's entry
    # for team 1 with its own blind reading, which is why team 1 reported "0 built at
    # 1 min" in literally every match ever run.
    sanity = {}
    s_p0, s_p1 = _parse_sanity(p0_text), _parse_sanity(p1_text)
    if 0 in s_p0: sanity[0] = s_p0[0]
    if 1 in s_p1: sanity[1] = s_p1[1]

    # Determine winner — priority: draw score > natural GameOver > unit-count fallback.
    # draw_score is only emitted when the adjudication deadline was reached, and in that
    # case both players self-d simultaneously, so the resulting GameOver just reflects
    # whichever scripted suicide the engine processed first. The army-value score is the
    # real verdict, so it has to outrank it. A genuine commander kill before the deadline
    # emits no draw_score at all, and falls through to winner_raw as before.
    game_winner = None
    game_method = "draw"
    if draw_score is not None:
        sw = draw_score.get("score_winner", -1)
        game_winner = sw if sw >= 0 else None
        game_method = "draw_score" if game_winner is not None else "draw_tied"
    if game_winner is None and winner_raw is not None and draw_score is None:
        game_winner = winner_raw
        game_method = "game_over"
    if game_winner is None:
        if nc[0] > nc[1]:
            game_winner, game_method = 0, "unit_count_fallback"
        elif nc[1] > nc[0]:
            game_winner, game_method = 1, "unit_count_fallback"
        else:
            game_method = "draw"

    sanity_pass = {}
    for t in (0, 1):
        s = sanity.get(t)
        sanity_pass[t] = bool(s and (s["built"] > 0 or s["alive_nc"] > 0)) \
                         if s else (nc[t] > 0)

    loss_p0 = _parse_loss_summary(p0_text)
    loss_p1 = _parse_loss_summary(p1_text)

    interesting = [l for l in (p0_text + p1_text).splitlines() if any(
        kw in l for kw in ("Loading widget", "ERROR", "[STATS]", "[MC]", "[LC]",
                           "[UC]", "[WE]", "Player ", "Connection", "Initial Spawn",
                           "finished loading", "[WINNER]", "[DRAW_SCORE]", "[SANITY]")
    )]

    return MatchResult(
        winner            = game_winner,
        winner_method     = game_method,
        units_built       = nc,
        draw_score        = draw_score,
        sanity            = sanity,
        sanity_pass       = sanity_pass,
        # Per-team sourcing again: P0 for team 0, P1 for team 1. Concatenating the two
        # logs mostly worked because each process only logs its own team mid-game, but
        # both log both teams once the game is over, which injected junk rows.
        resource_timeline = ([r for r in _parse_resource_timeline(p0_text) if r.get("team") == 0]
                             + [r for r in _parse_resource_timeline(p1_text) if r.get("team") == 1]),
        # Same sourcing rule: each team's rows come from the process that can see it.
        army_timeline     = ([r for r in _parse_army_timeline(p0_text) if r.get("team") == 0]
                             + [r for r in _parse_army_timeline(p1_text) if r.get("team") == 1]),
        loss_summary      = {0: loss_p0.get(0, {}), 1: loss_p1.get(1, {})},
        lua_errors        = extract_lua_errors(p0_text, p1_text),
        duration_secs     = duration_secs,
        bot0_name         = bot0_name,
        bot1_name         = bot1_name,
        timestamp         = datetime.now(timezone.utc).isoformat(),
        log_excerpt       = "\n".join(interesting[-20:]),
    )


# ── Core run function ─────────────────────────────────────────────────────────

def run_match(
    bot0_dir: Path,
    bot1_dir: Path,
    duration: int = DEFAULT_DURATION,
    map_name: str = MAP_NAME,
    save_replay: bool = False,
    verbose: bool = True,
    end_frame: int = END_FRAME,
) -> MatchResult:
    """
    Run a headless bot-vs-bot match and return a structured MatchResult.

    bot0_dir / bot1_dir must contain *.lua widget files.
    duration is wall-clock seconds; the game runs at ~20-100x in-game speed.
    """
    bot0_files = sorted(Path(bot0_dir).glob("*.lua"))
    bot1_files = sorted(Path(bot1_dir).glob("*.lua"))
    if not bot0_files:
        raise ValueError(f"No .lua files in {bot0_dir}")
    if not bot1_files:
        raise ValueError(f"No .lua files in {bot1_dir}")

    stamp    = datetime.now().strftime("%Y%m%d_%H%M%S")
    _la      = os.environ.get("LOCALAPPDATA")
    tmp      = Path(_la) / "Temp" if _la else Path(os.environ.get("TMPDIR", "/tmp"))
    test_dir = tmp / f"bottest_{stamp}_{os.getpid()}"
    p0_dir   = test_dir / "p0"
    p1_dir   = test_dir / "p1"
    for d in (p0_dir, p1_dir):
        d.mkdir(parents=True, exist_ok=True)

    headless  = find_engine("spring-headless.exe")
    game_type = get_game_type()

    import random
    host_port   = random.randint(9000, 19000)
    spring_data = str(BAR_DATA_DIR)

    if verbose:
        print(f"Write dir : {test_dir}")
        print(f"Engine    : {headless}")
        print(f"Game type : {game_type}")
        print(f"Map       : {map_name}")
        print(f"Bot 0     : {Path(bot0_dir).name}  ({len(bot0_files)} files)")
        print(f"Bot 1     : {Path(bot1_dir).name}  ({len(bot1_files)} files)")
        print(f"Duration  : {duration}s real time")
        print(f"Host port : {host_port}")

    # The self-d/GameOver timer below only starts counting from widget:GameStart(),
    # which doesn't fire until BAR finishes loading -- observed at 50-65s real time
    # on Raspberry Pi hardware (confirmed 2026-09-16 via SSH diagnostic on dme43).
    # A 30s margin left no room for that load time before the external kill deadline,
    # so matches were always force-killed instead of ending cleanly -- and a killed
    # process never flushes its .sdfz replay. 150s covers load (~65s worst case) plus
    # shutdown (quit + demo write + process exit, up to graceful_stop's 15s wait).
    game_end_target = max(30, duration - 150)
    setup_player(p0_dir, bot0_files, 0, "T0", include_stats=True,
                 game_end_target=game_end_target, do_selfd=False, end_frame=end_frame,
                 spring_data=spring_data)
    # do_selfd=False on BOTH players. It used to be True for P1 only, which meant team 1
    # self-destructed its own commander at game_end_target while team 0 never did --
    # with deathmode=com that handed team 0 an automatic "game_over" win in every match
    # that reached the deadline, and left team 1 with only half as long to build. Both
    # the winner and the units-built margin were artifacts of the slot, not the bot.
    # The stats widget now ends the match symmetrically at the same deadline instead.
    setup_player(p1_dir, bot1_files, 1, "T1", include_stats=True,
                 game_end_target=game_end_target, do_selfd=False, end_frame=end_frame,
                 spring_data=spring_data)

    write_script(p0_dir / "startscript.txt",
        render_host_script("BotCtrl", game_type, map_name, save_replay, host_port))
    write_script(p1_dir / "startscript.txt",
        render_player_script("BotB", game_type, map_name, save_replay, host_port))

    if verbose:
        print("Scripts written.\n")

    p0_log = p0_dir / "headless.log"
    p1_log = p1_dir / "headless.log"
    env    = {**os.environ, "SPRING_DATADIR": spring_data}
    flags  = subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0

    global_start = time.monotonic()

    if verbose:
        print("Launching host headless (P0)...")
    with open(p0_log, "wb") as fh:
        p0_proc = subprocess.Popen(
            [str(headless), "--isolation", "--write-dir", str(p0_dir),
             str(p0_dir / "startscript.txt")],
            cwd=str(p0_dir), stdout=fh, stderr=subprocess.STDOUT,
            env=env, creationflags=flags,
        )
    if verbose:
        print(f"  BotCtrl PID: {p0_proc.pid}  (team 0, host)")

    time.sleep(2)

    if verbose:
        print("Launching client headless (P1)...")
    with open(p1_log, "wb") as fh:
        p1_proc = subprocess.Popen(
            [str(headless), "--isolation", "--write-dir", str(p1_dir),
             str(p1_dir / "startscript.txt")],
            cwd=str(p1_dir), stdout=fh, stderr=subprocess.STDOUT,
            env=env, creationflags=flags,
        )
    if verbose:
        print(f"  BotB    PID: {p1_proc.pid}  (team 1)")
        print(f"Running for {duration}s total.\n")

    deadline = global_start + duration
    procs = {"P0": p0_proc, "P1": p1_proc}
    try:
        while time.monotonic() < deadline:
            tags = {k: ("done" if v.poll() is not None else "run ") for k, v in procs.items()}
            if all(t == "done" for t in tags.values()):
                if verbose:
                    elapsed = time.monotonic() - global_start
                    print(f"\nAll processes exited after {elapsed:.0f}s.")
                break
            if verbose:
                elapsed = time.monotonic() - global_start
                status = "  ".join(f"{k}:{t}" for k, t in tags.items())
                print(f"\r  {status}  {elapsed:.0f}s", end="", flush=True)
            time.sleep(2)
        else:
            # Both commanders have been self-d'd by the adjudicator by now; give
            # the engine a moment to run GameOver, quit, and flush the replay
            # footer. Killing it here is what produced 0-byte .sdfz files.
            if verbose:
                elapsed = time.monotonic() - global_start
                print(f"\n\n{elapsed:.0f}s reached; waiting up to {EXIT_GRACE}s "
                      f"for a clean finish.")
            grace_end = time.monotonic() + EXIT_GRACE
            while time.monotonic() < grace_end:
                if all(v.poll() is not None for v in procs.values()):
                    if verbose:
                        print("  game ended cleanly; replay written.")
                    break
                time.sleep(2)
            else:
                if verbose:
                    print("  no clean exit; stopping (replay may be empty).")
            graceful_stop(p1_proc)
            graceful_stop(p0_proc)
    except KeyboardInterrupt:
        if verbose:
            print("\nInterrupted; stopping.")
        graceful_stop(p1_proc)
        graceful_stop(p0_proc)

    duration_secs = time.monotonic() - global_start

    if save_replay:
        demos_src = p0_dir / "demos"
        if not demos_src.is_dir():
            demos_src = p0_dir / "demos-server"
        demos_dst = BAR_DATA_DIR / "demos"
        demos_dst.mkdir(exist_ok=True)
        for sdfz in sorted(demos_src.glob("*.sdfz")):
            if sdfz.stat().st_size > 0:
                shutil.copy2(str(sdfz), str(demos_dst / sdfz.name))
                if verbose:
                    print(f"\nReplay saved: {demos_dst / sdfz.name}")

    return _parse_logs(
        _read_log(p0_log), _read_log(p1_log),
        Path(bot0_dir).name, Path(bot1_dir).name,
        duration_secs,
    )


def save_result(result: MatchResult, path: Path) -> None:
    """Write result.json into path (directory or file)."""
    dest = Path(path)
    if dest.is_dir():
        dest = dest / "result.json"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(result.to_dict(), indent=2), encoding="utf-8")


def print_result(result: MatchResult) -> None:
    """Pretty-print a MatchResult to stdout."""
    W = 60
    print("\n" + "=" * W)
    print("RESULTS")
    print("=" * W)

    if result.winner is not None:
        wname = result.bot0_name if result.winner == 0 else result.bot1_name
        print(f"Winner  : Team {result.winner} ({wname})  [{result.winner_method}]")
    else:
        print(f"Result  : DRAW  [{result.winner_method}]")

    print(f"\nNon-commander units built (cumulative):")
    print(f"  Team 0 ({result.bot0_name}): {result.units_built.get(0, 0)}")
    print(f"  Team 1 ({result.bot1_name}): {result.units_built.get(1, 0)}")

    if result.draw_score:
        ds = result.draw_score
        print(f"\nDraw score at {MAX_GAME_MINUTES} game-min:")
        print(f"  Team 0: {ds['nc0']} alive units  {ds['mv0']:.0f} metal value")
        print(f"  Team 1: {ds['nc1']} alive units  {ds['mv1']:.0f} metal value")

    print(f"\nSanity check (1 game-minute):")
    for t in (0, 1):
        name = result.bot0_name if t == 0 else result.bot1_name
        s    = result.sanity.get(t)
        ok   = result.sanity_pass.get(t, False)
        tag  = "PASS" if ok else "FAIL"
        if s:
            print(f"  [{tag}] Team {t} ({name}): {s['built']} built  {s['alive_nc']} alive at 1 min")
        else:
            print(f"  [{tag}] Team {t} ({name}): {result.units_built.get(t, 0)} cumulative (no sanity line)")

    if result.lua_errors:
        print(f"\nLua errors detected ({len(result.lua_errors)}):")
        for e in result.lua_errors[:5]:
            print(f"  {e.splitlines()[0][:100]}")

    if result.resource_timeline:
        print(f"\nMetal income over time:")
        for team in (0, 1):
            name = result.bot0_name if team == 0 else result.bot1_name
            snaps = [r for r in result.resource_timeline if r["team"] == team]
            if snaps:
                print(f"  Team {team} ({name}):")
                for r in snaps[::2][-6:]:
                    print(f"    {r['game_min']:5.1f} min  "
                          f"metal_inc={r['metal_inc']:5.2f}  "
                          f"energy_inc={r['energy_inc']:6.1f}  "
                          f"metal_stored={r['metal']:.0f}")

    if result.army_timeline:
        print(f"\nArmy value over time (P0 view):")
        for team in (0, 1):
            name  = result.bot0_name if team == 0 else result.bot1_name
            snaps = [a for a in result.army_timeline if a["team"] == team][-5:]
            if snaps:
                print(f"  Team {team} ({name}):")
                for a in snaps:
                    print(f"    {a['game_min']:5.1f} min  mv={a['mv']:7.0f}  alive={a['alive_nc']}")

    print(f"\nCombat losses (top units by metal lost):")
    for team in (0, 1):
        name   = result.bot0_name if team == 0 else result.bot1_name
        losses = result.loss_summary.get(team, {})
        if losses:
            top = sorted(losses.items(), key=lambda x: x[1]["total_mv"], reverse=True)[:6]
            print(f"  Team {team} ({name}):")
            for dname, data in top:
                print(f"    {dname:<20} {data['count']:4}x  ({data['total_mv']:6} metal lost)")
        else:
            print(f"  Team {team} ({name}): no loss data recorded")

    print(f"\n--- Widget load + key events (last 20) ---")
    for ln in result.log_excerpt.splitlines():
        print(ln)

    print("=" * W)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bot1", required=True, metavar="PATH", help="Team-0 bot folder")
    p.add_argument("--bot2", required=True, metavar="PATH", help="Team-1 bot folder")
    p.add_argument("--duration", type=int, default=DEFAULT_DURATION, metavar="SECS",
                   help="Real seconds to run before killing (default: 300)")
    p.add_argument("--save-replay", action="store_true")
    p.add_argument("--map", default=MAP_NAME, dest="map_name")
    p.add_argument("--end-frame", type=int, default=END_FRAME, dest="end_frame",
                   help="game frame at which both commanders self-destruct so the "
                        "match ends cleanly and the replay is written "
                        "(default: 36000 = 20 game-min)")
    p.add_argument("--save-result", metavar="PATH",
                   help="Write result.json to this path after the match")
    args = p.parse_args()

    bot1_dir = Path(args.bot1).resolve()
    bot2_dir = Path(args.bot2).resolve()
    for d, label in [(bot1_dir, "--bot1"), (bot2_dir, "--bot2")]:
        if not d.is_dir():
            sys.exit(f"{label}: folder not found: {d}")

    result = run_match(
        bot0_dir    = bot1_dir,
        bot1_dir    = bot2_dir,
        duration    = args.duration,
        map_name    = args.map_name,
        save_replay = args.save_replay,
        verbose     = True,
        end_frame   = args.end_frame,
    )

    print_result(result)

    if args.save_result:
        save_result(result, Path(args.save_result))
        print(f"\nResult saved to: {args.save_result}")


if __name__ == "__main__":
    main()
