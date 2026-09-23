#!/usr/bin/env python3
"""
bot_testing.py  -  Bot-vs-bot headless tester for Beyond All Reason.

Architecture (default --server spectator):
  1. spring-headless.exe   — bot-less spectator; hosts the game
  2. spring-headless.exe   — team 0 — runs bot1 widgets, connects to the host
  3. spring-headless.exe   — team 1 — runs bot2 widgets, connects to the host
With --server host, process 2 hosts instead and there is no process 1; team 1 is then
the only side paying network latency. Each process gets its own main CPU core.

Players are named after their bot folder plus slot (e.g. DRAGON_BOT_s0), so they
can be told apart in replays.

The processes load independently and the host holds the game until every player
has sent its loadfinished signal.

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
# A match runs normally until this much GAME time has passed. Then both commanders
# self-destruct and the winner is declared from stats (see END_SCORE below). Configure with
# --end-minutes. The frame trigger is symmetric across both processes, and a clean
# self-destruct is also what lets the engine write the replay footer: a match stopped by
# the wall-clock kill leaves a 0-byte .sdfz.
END_MINUTES      = 60
FPS              = 30
END_FRAME        = END_MINUTES * 60 * FPS      # 108 000 game frames
# Winner score = army metal value + ECO_WEIGHT_SECS * metal income per second, i.e. the
# army you have plus that many seconds of the economy that will build the next one.
ECO_WEIGHT_SECS  = 60
TIE_MARGIN       = 1.1                         # a score must beat the other by 10%
# Rough real seconds per game frame on the test hardware, used only to pick a default
# --duration long enough for END_FRAME to be reached. Measured ~100-130 frames/s early on;
# it slows as unit counts grow, hence the conservative 80.
FRAMES_PER_REAL_SEC = 80
EXIT_GRACE       = 60                          # seconds to finish after the deadline
SPECTATOR_HOST_NAME = "MatchHost"              # the bot-less host in --server spectator
# How the match is networked, and how fast it runs. Every order a bot gives makes a round
# trip through the server; for a UDP client the engine adds ~33 ms each way (a hard-coded
# 30 packets/s cap in UDPConnection), so the lag in GAME frames is that fixed real time
# times the sim rate. Measured round trips (frames, team 0 / team 1, DRAGON_BOT mirror):
#   host,      speed 100, unpinned:  32 / 105-225   <- team 1 acted seconds late
#   host,      speed 10:              2 / 21        <- still one-sided
#   spectator, speed 20:             40 / 42
#   spectator, speed 10:             20 / 20
# "spectator" puts both bots behind the same UDP link, so neither side is favoured, and
# speed 10 keeps that shared lag at ~0.7 game-seconds. Raise --speed for faster, laggier runs.
DEFAULT_SERVER   = "spectator"
DEFAULT_SPEED    = 10

# ── Result dataclass ──────────────────────────────────────────────────────────

@dataclass
class MatchResult:
    """Structured output from a single bot-vs-bot match."""
    winner:             "int | None"    # 0, 1, or None (draw/unknown)
    winner_method:      str             # "end_score"|"end_score_wallclock"|"game_over"|"unit_count_fallback"|"draw"
    units_built:        dict            # {0: int, 1: int}  cumulative over whole match
    draw_score:         "dict | None"   # end-of-match score per team + score_winner; None if no limit was hit
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
    end_reason:         "str | None" = None   # "frame" (full length), "wallclock" (cut short), None
    tracker_timeline:   list = field(default_factory=list)  # [TRK] rows from the stats tracker
    order_latency:      dict = field(default_factory=dict)  # {team: {median,opening,worst,windows}} in frames

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
            "end_reason":        self.end_reason,
            "tracker_timeline":  self.tracker_timeline,
            "order_latency":     {str(k): v for k, v in self.order_latency.items()},
        }


# ── Utility widgets ───────────────────────────────────────────────────────────

# Logs unit creation events and periodic unit-count summaries.
STATS_WIDGET = r"""
-- Constants injected by setup_player.
local END_FRAME   = __END_FRAME__   -- game frame at which the match is ended by stats
local ECO_WEIGHT  = __ECO_WEIGHT__  -- seconds of metal income counted into the score
-- Wall-clock BACKSTOP. If the game-frame limit is not reached in this many real seconds
-- (slow hardware, or a deliberately short test run) the match is ended and scored anyway,
-- tagged reason=wallclock so it is never mistaken for a full-length verdict. It uses
-- os.time, not os.clock: os.clock is per-process CPU time, which drifts between the two
-- headless processes and made them adjudicate at different game frames.
local ADJ_SECS    = __ADJ_SECS__
local clock       = os.time or os.clock
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
    startTime = clock()
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
-- Only meaningful for the team this process controls: a headless client cannot see the
-- other team's units, so every process scores its OWN team and Python compares the two.
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

-- Army for the end-of-match score: finished, armed, mobile, non-commander units. Structures
-- are left out on purpose; the economy is scored separately through metal income.
local function myArmy(teamID)
    local mv, n = 0, 0
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        local d = defID and UnitDefs[defID]
        if d and not isCommander(defID) and d.canMove
           and d.weapons and #d.weapons > 0 and not Spring.GetUnitIsBeingBuilt(uid) then
            mv = mv + (d.metalCost or 0)
            n  = n + 1
        end
    end
    return mv, n
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

    -- End of match: score OWN team only, then self-destruct own commander. Python takes
    -- team 0's line from P0 and team 1's from P1 and compares them.
    local reason
    if n >= END_FRAME then
        reason = "frame"
    elseif startTime ~= nil and clock() - startTime >= ADJ_SECS then
        reason = "wallclock"
    end
    if reason and not drawDone then
        drawDone = true
        local myTeam = Spring.GetMyTeamID()
        local armyMv, armyN = myArmy(myTeam)
        local _, _, _, metalInc = Spring.GetTeamResources(myTeam, "metal")
        local _, _, _, energyInc = Spring.GetTeamResources(myTeam, "energy")
        metalInc = metalInc or 0
        local ecoMv = metalInc * ECO_WEIGHT
        Spring.Echo(string.format(
            "[END_SCORE] reason=%s frame=%d team=%d army_mv=%.0f army_n=%d metal_inc=%.2f "
            .. "energy_inc=%.1f eco_mv=%.0f score=%.0f",
            reason, n, myTeam, armyMv, armyN, metalInc, energyInc or 0, ecoMv, armyMv + ecoMv))
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


# Measures how many game frames pass between this process sending something to the server
# and the simulation seeing it: the same path every unit order takes. It sends itself a
# LuaUI message every 15 frames and logs the round trip, per 30 game-seconds, as
#   [LAT] team=T frame=F n=N min=.. med=.. p90=.. max=..
# A bot on a process with a higher figure acts that many frames late on every order.
LATENCY_PROBE_WIDGET = r"""
function widget:GetInfo()
    return { name="Latency Probe", desc="Order round-trip in game frames", layer=0, enabled=true }
end

local PREFIX = "mblat:"
local WINDOW = 900
local myPlayer, myTeam
local samples = {}

function widget:Initialize()
    myPlayer = Spring.GetMyPlayerID()
    myTeam   = Spring.GetMyTeamID()
end

local function Flush(n)
    table.sort(samples)
    local c = #samples
    Spring.Echo(string.format("[LAT] team=%d frame=%d n=%d min=%d med=%d p90=%d max=%d",
        myTeam, n, c, samples[1], samples[math.floor(c / 2) + 1],
        samples[math.min(c, math.floor(c * 0.9) + 1)], samples[c]))
    samples = {}
end

function widget:GameFrame(n)
    if n % 15 == 0 then Spring.SendLuaUIMsg(PREFIX .. n) end
    if n % WINDOW == 0 and #samples > 0 then Flush(n) end
end

function widget:RecvLuaMsg(msg, playerID)
    if playerID ~= myPlayer or msg:sub(1, #PREFIX) ~= PREFIX then return end
    local sent = tonumber(msg:sub(#PREFIX + 1))
    if sent then samples[#samples + 1] = Spring.GetGameFrame() - sent end
    return true
end
"""


def make_game_end_widget(target_secs: int, do_selfd: bool, speed: float = 100) -> str:
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
        # Redundant with the minspeed/maxspeed modoptions (see _common_script_body), kept as
        # a backstop. Only the hosting process is allowed to run these.
        f"    Spring.SendCommands('setmaxspeed {speed:g}', 'setminspeed {speed:g}')\n"
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
                 spring_data: str, end_frame: int = END_FRAME,
                 eco_weight: float = ECO_WEIGHT_SECS, speed: float = 100,
                 main_core_mask: int = 0) -> list:
    """
    Populate one player's write_dir with bot widgets, shared deps, shadow stubs,
    BYAR config, and springsettings.cfg.  Returns list of active widget names.
    """
    widgets_dir = write_dir / "LuaUI" / "Widgets"
    widgets_dir.mkdir(parents=True, exist_ok=True)

    active: list = []
    skip:  set   = set()

    game_end = make_game_end_widget(game_end_target, do_selfd, speed)
    (widgets_dir / "headless_game_end.lua").write_text(game_end, encoding="utf-8")
    skip.add("headless_game_end.lua")
    active.append("Game Ender")

    (widgets_dir / "headless_latency_probe.lua").write_text(LATENCY_PROBE_WIDGET, encoding="utf-8")
    skip.add("headless_latency_probe.lua")
    active.append("Latency Probe")

    if include_stats:
        (widgets_dir / "headless_stats.lua").write_text(
            STATS_WIDGET.replace("__ADJ_SECS__", str(game_end_target))
                        .replace("__END_FRAME__", str(end_frame))
                        .replace("__ECO_WEIGHT__", str(eco_weight)), encoding="utf-8")
        skip.add("headless_stats.lua")
        active.append("Headless Stats")

        # The general stats tracker: one private copy per process, so what it logs is what
        # that bot can actually see. Same file a bot would run in a real game.
        tracker_src = REPO_DIR / "metalbot_stats_tracker.lua"
        if tracker_src.exists():
            (widgets_dir / tracker_src.name).write_bytes(tracker_src.read_bytes())
            skip.add(tracker_src.name)
            active.append("Stats Tracker")
        else:
            print(f"  [{suffix}] WARNING: {tracker_src.name} missing; no tracker data")

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
        "NetworkTimeout = 300\n"
        + (f"SetCoreAffinity = {main_core_mask}\n" if main_core_mask else ""),
        encoding="utf-8",
    )
    return active


def main_core_masks(count: int) -> list:
    """One distinct CPU mask per engine process, for its main (sim) thread.

    Left alone, the engine pins every process's main thread to the same "preferred" core
    (observed: 0x4000 in all of them), so the processes of one match share one core and
    time-slice each other's simulation. Pick the highest even-numbered logical cores --
    one per physical core on a hyperthreaded CPU -- falling back to plain top cores.
    Returns zeros (engine default) when there are too few cores to separate them.
    """
    n = os.cpu_count() or 1
    step = 2 if n >= 4 * count else 1
    bits = [n - step * (i + 1) for i in range(count)]
    if bits[-1] < 0:
        return [0] * count
    return [1 << b for b in bits]


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


def bot_player_name(bot_dir, slot: int) -> str:
    """In-game player name for a bot: its folder name plus the slot, e.g. DRAGON_BOT_s1.

    Shown in the replay browser and in-game, so you can tell the bots apart when
    watching. The slot suffix keeps a mirror match's two names distinct (each process
    connects by name, so they must be unique) and shows which side had slot 0's edge.
    """
    base = Path(str(bot_dir).rstrip("/\\")).name
    base = re.sub(r"[^A-Za-z0-9_-]", "_", base)[:17] or "bot"
    return f"{base}_s{slot}"


def render_host_script(player_name: str, game_type: str, map_name: str,
                       save_replay: bool, host_port: int,
                       name0: str = "BotCtrl", name1: str = "BotB",
                       speed: float = 100, spectator: "str | None" = None) -> str:
    """Start script for the hosting process: P0, or the bot-less spectator host."""
    body = _common_script_body(game_type, map_name, save_replay, name0, name1, speed,
                               spectator)
    return (
        "[GAME]\n{\n"
        f"    IsHost=1;\n    MyPlayerName={player_name};\n    HostPort={host_port};\n"
        + body + "}\n"
    )


def _common_script_body(game_type, map_name, save_replay,
                        name0: str = "BotCtrl", name1: str = "BotB",
                        speed: float = 100, spectator: "str | None" = None) -> str:
    record = "1" if save_replay else "0"
    spec = (f"    [PLAYER2]\n    {{\n        name={spectator};\n        team=0;\n"
            "        spectator=1;\n    }\n") if spectator else ""
    return (
        f"    GameType={game_type};\n    MapName={map_name};\n"
        "    StartPosType=0;\n    FixedRNGSeed=1;\n"
        f"    RecordDemo={record};\n    GameStartDelay=0;\n"
        "    NoHelperAIs=0;\n\n"
        "    [MODOPTIONS]\n    {\n"
        # minspeed=maxspeed pins the requested speed: the server clamps its starting speed
        # into this range, the only way to set it on a dedicated server (which refuses
        # setminspeed from a non-host client). Speed control can still slow the sim below
        # it when a client cannot keep up -- it ignores minspeed.
        f"        deathmode=com;\n        maxspeed={speed:g};\n        minspeed={speed:g};\n"
        "        allowuserwidgets=1;\n        allowunitcontrolwidgets=1;\n"
        "        allowuserscripts=1;\n    }\n\n"
        "    [ALLYTEAM0] { numallies=0; }\n    [ALLYTEAM1] { numallies=0; }\n\n"
        "    [TEAM0]\n    {\n"
        "        teamleader=0;\n        allyteam=0;\n"
        "        side=Cortex;\n        rgbcolor=0.2 0.4 0.9;\n    }\n"
        "    [TEAM1]\n    {\n"
        "        teamleader=1;\n        allyteam=1;\n"
        "        side=Cortex;\n        rgbcolor=0.9 0.2 0.2;\n    }\n\n"
        # fullview=1 on BOTH players, kept symmetric so neither bot plays fogged while the
        # other sees the map. It is NOT relied on for stats: it has been observed not to
        # give cross-team visibility headless, so every process scores only its own team.
        # The stats tracker logs the fullview flag it actually gets ([TRK] init).
        f"    [PLAYER0]\n    {{\n        name={name0};\n        team=0;\n        fullview=1;\n    }}\n"
        f"    [PLAYER1]\n    {{\n        name={name1};\n        team=1;\n        fullview=1;\n    }}\n"
        + spec
    )


def render_dedicated_script(game_type, map_name, save_replay, host_port,
                            name0: str = "BotCtrl", name1: str = "BotB",
                            speed: float = 100) -> str:
    """Startscript for spring-dedicated: the authoritative server, no local player."""
    body = _common_script_body(game_type, map_name, save_replay, name0, name1, speed)
    return (
        "[GAME]\n{\n"
        f"    IsHost=1;\n    HostPort={host_port};\n"
        + body + "}\n"
    )


def render_player_script(player_name, game_type, map_name, save_replay, host_port,
                         name0: str = "BotCtrl", name1: str = "BotB",
                         speed: float = 100, spectator: "str | None" = None) -> str:
    """Startscript for a spring-headless client connecting to the host or dedicated server."""
    body = _common_script_body(game_type, map_name, save_replay, name0, name1, speed,
                               spectator)
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


def _parse_end_score(text: str, team: int) -> "dict | None":
    """This team's own [END_SCORE] line, or None. Only the team's own process is asked."""
    for line in reversed(text.splitlines()):
        if "[END_SCORE]" not in line:
            continue
        kv = dict(re.findall(r"(\w+)=(\S+)", line))
        if kv.get("team") != str(team):
            continue
        try:
            return {
                "reason":     kv["reason"],
                "frame":      int(kv["frame"]),
                "army_mv":    float(kv["army_mv"]),
                "army_n":     int(kv["army_n"]),
                "metal_inc":  float(kv["metal_inc"]),
                "energy_inc": float(kv["energy_inc"]),
                "eco_mv":     float(kv["eco_mv"]),
                "score":      float(kv["score"]),
            }
        except (KeyError, ValueError):
            return None
    return None


def _parse_tracker(text: str, team: int) -> list:
    """Rows from the stats-tracker widget: {kind, frame, team, <key>: number|str ...}."""
    rows: list = []
    for line in text.splitlines():
        m = re.search(r"\[TRK\] (\w+) frame=(\d+) team=(\d+) ?(.*)", line)
        if not m or int(m.group(3)) != team:
            continue
        row: dict = {"kind": m.group(1), "frame": int(m.group(2)), "team": team}
        for k, v in re.findall(r"(\w+)=(\S+)", m.group(4)):
            try:
                row[k] = float(v) if ("." in v or "e" in v.lower()) else int(v)
            except ValueError:
                row[k] = v
        rows.append(row)
    return rows


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


def _dedupe(rows: list) -> list:
    """Drop repeated rows. _read_log concatenates headless.log and infolog.txt, which both
    carry every Lua echo, so each timeline row is seen twice."""
    seen: set = set()
    out: list = []
    for r in rows:
        key = json.dumps(r, sort_keys=True)
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out


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
    # Adjudicate from each team's OWN [END_SCORE] line: team 0 from P0, team 1 from P1.
    # Neither process can see the other team, so each scores only itself and the two
    # numbers are compared here. If either line is missing (a process died, or the game
    # ended by a genuine commander kill first) there is no score verdict.
    es0 = _parse_end_score(p0_text, 0)
    es1 = _parse_end_score(p1_text, 1)
    draw_score = None
    end_reason = None
    if es0 is not None and es1 is not None:
        if   es0["score"] > es1["score"] * TIE_MARGIN: sw = 0
        elif es1["score"] > es0["score"] * TIE_MARGIN: sw = 1
        else:                                          sw = -1
        # "frame" only if BOTH sides hit the game-time limit.
        end_reason = "frame" if es0["reason"] == es1["reason"] == "frame" else "wallclock"
        draw_score = {
            "reason": end_reason, "score_winner": sw,
            "nc0": es0["army_n"],   "nc1": es1["army_n"],
            "mv0": es0["army_mv"],  "mv1": es1["army_mv"],
            "metal_inc0": es0["metal_inc"], "metal_inc1": es1["metal_inc"],
            "eco_mv0": es0["eco_mv"], "eco_mv1": es1["eco_mv"],
            "score0": es0["score"], "score1": es1["score"],
            "frame0": es0["frame"], "frame1": es1["frame"],
        }

    # Sanity, same rule: team 0 from P0, team 1 from P1. P0 used to overwrite P1's entry
    # for team 1 with its own blind reading, which is why team 1 reported "0 built at
    # 1 min" in literally every match ever run.
    sanity = {}
    s_p0, s_p1 = _parse_sanity(p0_text), _parse_sanity(p1_text)
    if 0 in s_p0: sanity[0] = s_p0[0]
    if 1 in s_p1: sanity[1] = s_p1[1]

    # Determine winner — priority: end score > natural GameOver > unit-count fallback.
    # The end score is only emitted when the match limit was reached, and then both
    # players self-d together, so the resulting GameOver just reflects whichever scripted
    # suicide the engine processed first. The stats score is the real verdict and must
    # outrank it. A genuine commander kill before the limit emits no end score at all
    # and falls through to winner_raw.
    game_winner = None
    game_method = "draw"
    if draw_score is not None:
        sw = draw_score.get("score_winner", -1)
        game_winner = sw if sw >= 0 else None
        base = "end_score" if end_reason == "frame" else "end_score_wallclock"
        game_method = base if game_winner is not None else base + "_tied"
    if game_winner is None and winner_raw is not None and draw_score is None:
        game_winner = winner_raw
        game_method = "game_over"
    # A tie on the end score stays a draw. Falling back to units built would let the
    # slot-0 unit-cap saturation decide exactly the games the stats could not separate.
    if game_winner is None and draw_score is None:
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
                           "finished loading", "[WINNER]", "[END_SCORE]", "[TRK] init", "[SANITY]")
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
        resource_timeline = _dedupe([r for r in _parse_resource_timeline(p0_text) if r.get("team") == 0]
                                    + [r for r in _parse_resource_timeline(p1_text) if r.get("team") == 1]),
        # Same sourcing rule: each team's rows come from the process that can see it.
        army_timeline     = _dedupe([r for r in _parse_army_timeline(p0_text) if r.get("team") == 0]
                                    + [r for r in _parse_army_timeline(p1_text) if r.get("team") == 1]),
        loss_summary      = {0: loss_p0.get(0, {}), 1: loss_p1.get(1, {})},
        lua_errors        = extract_lua_errors(p0_text, p1_text),
        duration_secs     = duration_secs,
        bot0_name         = bot0_name,
        bot1_name         = bot1_name,
        timestamp         = datetime.now(timezone.utc).isoformat(),
        log_excerpt       = "\n".join(interesting[-20:]),
        end_reason        = end_reason,
        # Own-team rows only, each from the process that controls that team.
        tracker_timeline  = _dedupe(_parse_tracker(p0_text, 0) + _parse_tracker(p1_text, 1)),
        order_latency     = {0: _parse_latency(p0_text, 0), 1: _parse_latency(p1_text, 1)},
    )


_LAT_RE = re.compile(r"\[LAT\] team=(\d+) frame=(\d+) n=\d+ min=-?\d+ med=(-?\d+) "
                     r"p90=(-?\d+) max=(-?\d+)")


def _parse_latency(text: str, team: int) -> dict:
    """Summarise one process's [LAT] rows: order round trip in game frames.

    `median` is the median of the per-window medians over the whole match, `opening` the
    same over the first 4 game-minutes (where a few frames compound the most), and
    `worst` the highest window median. Empty if the probe logged nothing.
    """
    # Keyed by frame: _read_log concatenates two copies of the same log.
    rows = sorted({int(f): (int(f), int(med), int(mx))
                   for t, f, med, _p90, mx in _LAT_RE.findall(text) if int(t) == team}.values())
    if not rows:
        return {}
    med = lambda xs: sorted(xs)[len(xs) // 2]
    opening = [m for f, m, _ in rows if f <= 4 * 60 * FPS] or [rows[0][1]]
    return {"median": med([m for _, m, _ in rows]), "opening": med(opening),
            "worst": max(m for _, m, _ in rows), "windows": len(rows)}


# ── Core run function ─────────────────────────────────────────────────────────

def run_match(
    bot0_dir: Path,
    bot1_dir: Path,
    duration: int = DEFAULT_DURATION,
    map_name: str = MAP_NAME,
    save_replay: bool = False,
    verbose: bool = True,
    end_frame: int = END_FRAME,
    eco_weight: float = ECO_WEIGHT_SECS,
    server: str = DEFAULT_SERVER,
    speed: float = DEFAULT_SPEED,
    pin_cores: bool = True,
) -> MatchResult:
    """
    Run a headless bot-vs-bot match and return a structured MatchResult.

    bot0_dir / bot1_dir must contain *.lua widget files.
    duration is wall-clock seconds; the game runs at ~20-100x in-game speed. It is a
    backstop: the match normally ends at end_frame game frames, and only ends earlier
    (result.end_reason == "wallclock") if duration - 150s of real time passes first.

    server="spectator": a bot-less headless process hosts and both bots connect to it, so
    both pay the same network latency. server="host": P0 hosts in-process and only P1 pays
    it -- team 1 then acts later on every order (see DEFAULT_SERVER).
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
    masks = main_core_masks(3) if pin_cores else [0, 0, 0]
    setup_player(p0_dir, bot0_files, 0, "T0", include_stats=True,
                 game_end_target=game_end_target, do_selfd=False, end_frame=end_frame,
                 eco_weight=eco_weight, spring_data=spring_data, speed=speed,
                 main_core_mask=masks[0])
    # do_selfd=False on BOTH players. It used to be True for P1 only, which meant team 1
    # self-destructed its own commander at game_end_target while team 0 never did --
    # with deathmode=com that handed team 0 an automatic "game_over" win in every match
    # that reached the deadline, and left team 1 with only half as long to build. Both
    # the winner and the units-built margin were artifacts of the slot, not the bot.
    # The stats widget now ends the match symmetrically at the same deadline instead.
    setup_player(p1_dir, bot1_files, 1, "T1", include_stats=True,
                 game_end_target=game_end_target, do_selfd=False, end_frame=end_frame,
                 eco_weight=eco_weight, spring_data=spring_data, speed=speed,
                 main_core_mask=masks[1])

    name0 = bot_player_name(bot0_dir, 0)
    name1 = bot_player_name(bot1_dir, 1)
    # "spectator": a third, bot-less headless process hosts, so both bots are ordinary
    # clients and pay the same network latency. It is a real headless client rather than
    # spring-dedicated because the host paces frame creation to its own local client;
    # spring-dedicated has no local client, creates frames on the wall clock, and (tested
    # at speed 100) left both bots thousands of frames behind with nothing to rein it in.
    separate = server == "spectator"
    spec = SPECTATOR_HOST_NAME if separate else None
    spec_dir = test_dir / "server"
    if separate:
        setup_player(spec_dir, [], 0, "SPEC", include_stats=False,
                     game_end_target=game_end_target, do_selfd=False, end_frame=end_frame,
                     eco_weight=eco_weight, spring_data=spring_data, speed=speed,
                     main_core_mask=masks[2])
        write_script(spec_dir / "startscript.txt",
            render_host_script(spec, game_type, map_name, save_replay, host_port,
                               name0, name1, speed, spec))
        write_script(p0_dir / "startscript.txt",
            render_player_script(name0, game_type, map_name, save_replay, host_port,
                                 name0, name1, speed, spec))
    else:
        write_script(p0_dir / "startscript.txt",
            render_host_script(name0, game_type, map_name, save_replay, host_port,
                               name0, name1, speed))
    write_script(p1_dir / "startscript.txt",
        render_player_script(name1, game_type, map_name, save_replay, host_port,
                             name0, name1, speed, spec))

    if verbose:
        print("Scripts written.\n")

    p0_log = p0_dir / "headless.log"
    p1_log = p1_dir / "headless.log"
    env    = {**os.environ, "SPRING_DATADIR": spring_data}
    flags  = subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0

    global_start = time.monotonic()

    spec_proc = None
    if separate:
        if verbose:
            print("Launching spectator host headless...")
        with open(spec_dir / "headless.log", "wb") as fh:
            spec_proc = subprocess.Popen(
                [str(headless), "--isolation", "--write-dir", str(spec_dir),
                 str(spec_dir / "startscript.txt")],
                cwd=str(spec_dir), stdout=fh, stderr=subprocess.STDOUT,
                env=env, creationflags=flags,
            )
        time.sleep(2)

    if verbose:
        print(f"Launching {'client' if separate else 'host'} headless (P0)...")
    with open(p0_log, "wb") as fh:
        p0_proc = subprocess.Popen(
            [str(headless), "--isolation", "--write-dir", str(p0_dir),
             str(p0_dir / "startscript.txt")],
            cwd=str(p0_dir), stdout=fh, stderr=subprocess.STDOUT,
            env=env, creationflags=flags,
        )
    if verbose:
        print(f"  {name0} PID: {p0_proc.pid}  (team 0{'' if separate else ', host'})")

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
        print(f"  {name1} PID: {p1_proc.pid}  (team 1)")
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
            if (spec_proc is not None and spec_proc.poll() is not None
                    and any(t == "run " for t in tags.values())):
                if verbose:
                    print(f"\nSpectator host exited early; see {spec_dir / 'infolog.txt'}")
                graceful_stop(p1_proc)
                graceful_stop(p0_proc)
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
    if spec_proc is not None:
        # The spectator host quits on GameOver like the players; this is only a backstop.
        try:
            spec_proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            graceful_stop(spec_proc)

    duration_secs = time.monotonic() - global_start

    if save_replay:
        # Either client may be the one that recorded it (observed: only P1's demos/ held
        # the file), so look in both and keep the largest non-empty one.
        found = [f for d in (p0_dir, p1_dir, spec_dir) for sub in ("demos", "demos-server")
                 for f in (d / sub).glob("*.sdfz") if f.stat().st_size > 0]
        demos_dst = BAR_DATA_DIR / "demos"
        demos_dst.mkdir(exist_ok=True)
        if found:
            best = max(found, key=lambda f: f.stat().st_size)
            shutil.copy2(str(best), str(demos_dst / best.name))
            if verbose:
                print(f"\nReplay saved: {demos_dst / best.name}")
        elif verbose:
            print("\nWARNING: --save-replay set but no non-empty .sdfz was found.")

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
        cut = "" if result.end_reason == "frame" else "  ** CUT SHORT by wall-clock, not a full-length verdict **"
        print(f"\nEnd score (frames {ds['frame0']}/{ds['frame1']}, {result.end_reason}){cut}:")
        for t in (0, 1):
            print(f"  Team {t}: score {ds[f'score{t}']:8.0f} = army {ds[f'mv{t}']:.0f} "
                  f"({ds[f'nc{t}']} units) + eco {ds[f'eco_mv{t}']:.0f} "
                  f"(metal income {ds[f'metal_inc{t}']:.1f}/s)")

    if any(result.order_latency.values()):
        print(f"\nOrder latency (game frames, 30 = 1 game-second; opening = first 4 min):")
        for t in (0, 1):
            lat = result.order_latency.get(t) or {}
            if lat:
                print(f"  Team {t}: opening {lat['opening']}  median {lat['median']}  "
                      f"worst {lat['worst']}")
        lats = [result.order_latency.get(t, {}).get("opening") for t in (0, 1)]
        if None not in lats and abs(lats[0] - lats[1]) > 10:
            print(f"  WARNING: teams differ by {abs(lats[0] - lats[1])} frames -- "
                  f"the slower side acts later on every order")

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
    p.add_argument("--duration", type=int, default=None, metavar="SECS",
                   help="Real-seconds backstop; the match is cut short (and marked so) if "
                        "the game-time limit is not reached by then. Default: long enough "
                        "for --end-minutes (~end-frame/80 + 300s), min %ds" % DEFAULT_DURATION)
    p.add_argument("--save-replay", action="store_true")
    p.add_argument("--map", default=MAP_NAME, dest="map_name")
    p.add_argument("--end-minutes", type=float, default=END_MINUTES, dest="end_minutes",
                   help="game minutes after which both commanders self-destruct and the "
                        "winner is declared from stats (default: %g)" % END_MINUTES)
    p.add_argument("--eco-weight", type=float, default=ECO_WEIGHT_SECS, dest="eco_weight",
                   help="seconds of metal income added to army metal value in the end "
                        "score (default: %g)" % ECO_WEIGHT_SECS)
    p.add_argument("--server", choices=("spectator", "host"), default=DEFAULT_SERVER,
                   help="spectator: a third, bot-less process hosts, so both bots get the "
                        "same order latency. host: team 0's process hosts, giving team 1 "
                        "extra latency (the old behaviour) (default: %(default)s)")
    p.add_argument("--speed", type=float, default=DEFAULT_SPEED,
                   help="game speed multiplier requested from the server (default: %(default)g)")
    p.add_argument("--no-pin-cores", action="store_true",
                   help="leave main-thread CPU affinity to the engine, which puts every "
                        "process on the same core")
    p.add_argument("--save-result", metavar="PATH",
                   help="Write result.json to this path after the match")
    args = p.parse_args()

    bot1_dir = Path(args.bot1).resolve()
    bot2_dir = Path(args.bot2).resolve()
    for d, label in [(bot1_dir, "--bot1"), (bot2_dir, "--bot2")]:
        if not d.is_dir():
            sys.exit(f"{label}: folder not found: {d}")

    end_frame = int(args.end_minutes * 60 * FPS)
    duration = args.duration or max(DEFAULT_DURATION, end_frame // FRAMES_PER_REAL_SEC + 300)
    result = run_match(
        bot0_dir    = bot1_dir,
        bot1_dir    = bot2_dir,
        duration    = duration,
        map_name    = args.map_name,
        save_replay = args.save_replay,
        verbose     = True,
        end_frame   = end_frame,
        eco_weight  = args.eco_weight,
        server      = args.server,
        speed       = args.speed,
        pin_cores   = not args.no_pin_cores,
    )

    print_result(result)

    if args.save_result:
        save_result(result, Path(args.save_result))
        print(f"\nResult saved to: {args.save_result}")


if __name__ == "__main__":
    main()
