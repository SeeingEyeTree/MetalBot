"""
Single-client matches (bot_testing.py --server single): ONE spring-headless process runs both bots.

The normal harness runs three engine processes per match (a spectator host plus one client per bot). Each of them
simulates the whole game, and the speed governor slows the game down so the clients' order round trip stays near 30
frames. Here a single spectator process owns the game:

  - both teams are led by NullAI (ships with the engine; does nothing), so the game needs no second player;
  - the spectator turns on `cheat` + `godmode 3` (control every team). Widget orders still go through the engine's
    local network loop, so the order round trip grows with speed (150-320 frames at a pinned 150-280x); CONTROL_WIDGET
    governs the speed to hold it near --target-lag, like the normal harness, and both bots share the same lag;
  - both bots' widgets load into the same LuaUI. Each bot file (and each team's stats widgets) is wrapped in
    SHIM_HEAD / SHIM_TAIL below, which make it behave like a fogged player on its own team.

What the shim emulates (per wrapped widget, team T):
  - Spring.GetMyTeamID/GetMyAllyTeamID -> T; GetSpectatingState -> not spectating.
  - Enemy units are visible only through allyteam T's LOS/radar (Spring.GetUnitLosState as seen by T):
    GetAllUnits / GetUnitsIn* / GetTeamUnits drop units T cannot see (GetUnitsIn*'s MY/ALLY/ENEMY_UNITS selectors are
    resolved against T, not the spectator); GetUnitDefID is nil for an untyped radar blip;
    position/team for blips; health, velocity etc. need LOS; commands, worker tasks and team resources are own-team only.
    IsPosInLos/Radar/AirLos default to allyteam T.
  - Orders (GiveOrderToUnit*, GiveOrderArrayToUnit*) only reach team T's units. godmode would otherwise let a bot bug
    command the enemy's units.
  - WG is per team (WG.MetalBot of team 0 and team 1 no longer collide); reads fall through to the real WG.
  - VFS.Include runs modules with the team's Spring/VFS (modules otherwise see the global, unshimmed Spring).
  - Unit callins: UnitCreated/Finished/FromFactory/Idle/Command/... only for T's units (as a headless player gets
    them); UnitDamaged/UnitDestroyed for T's units and enemies in T's LOS.
  - Spring.Echo prefixes "<T0> "/"<T1> "; split_log() turns the one log back into per-team logs for _parse_logs.
  - GetPlayerInfo of the local player says "not spectating, on team T"; IsReplay is false.

BAR's stock widgets that automate a player's own units (STOCK_WIDGETS, e.g. nano turrets on FIGHT) do nothing for
a spectator, so each team also gets a shimmed copy of them, read from the installed game archive.

Not emulated: radar position error, cloaked/stealth units, attacker fields hidden by fog, the selection (shared, bots
should not use it), and callin order (team 0's widgets run before team 1's every frame).
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

import bot_testing as bt

# Lua placed before each wrapped widget's code. __T__ is the team id.
SHIM_HEAD = r"""-- [single-client shim, team __T__] added by single_client.py; see its docstring
do
    local T = __T__
    local RS, RV, RWG = Spring, VFS, WG
    local G = (getfenv and getfenv(0)) or _G
    local floor, unpack = math.floor, unpack or table.unpack
    local spAlly, spTeam, spLos = RS.GetUnitAllyTeam, RS.GetUnitTeam, RS.GetUnitLosState

    -- 3 = own allyteam or in LOS, 2 = radar blip of a known type, 1 = untyped radar blip, 0 = unseen
    local function vis(u)
        local a = spAlly(u)
        if a == nil then return 0 end
        if a == T then return 3 end
        local n = spLos(u, T, true)
        if type(n) ~= "number" then return 0 end
        if n % 2 == 1 then return 3 end
        -- a blip keeps its type only if seen in LOS (4) AND on radar ever since (8), as the engine's "typed" rule
        if floor(n / 2) % 2 == 1 then return (floor(n / 4) % 2 == 1 and floor(n / 8) % 2 == 1) and 2 or 1 end
        return 0
    end
    local function filt(list)
        if type(list) ~= "table" then return list end
        local out = {}
        for i = 1, #list do
            local u = list[i]
            if vis(u) > 0 then out[#out + 1] = u end
        end
        return out
    end
    local function own(u) return spTeam(u) == T end

    local S = setmetatable({}, { __index = RS })
    S.GetMyTeamID       = function() return T end
    S.GetMyAllyTeamID   = function() return T end
    S.GetLocalTeamID    = function() return T end
    S.GetLocalAllyTeamID = function() return T end
    S.GetSpectatingState = function() return false, false, false end
    S.IsReplay = function() return false end
    local myPlayer = RS.GetMyPlayerID and RS.GetMyPlayerID()
    S.GetPlayerInfo = function(pid, ...)
        local r = { RS.GetPlayerInfo(pid, ...) }
        if pid == myPlayer and r[1] ~= nil then r[3], r[4], r[5] = false, T, T end  -- spectator, team, allyteam
        return unpack(r, 1, table.maxn(r))
    end

    local echo, tag = RS.Echo, "<T" .. T .. "> "
    S.Echo = function(a, ...) return echo(tag .. tostring(a), ...) end

    for _, name in ipairs({ "GetAllUnits", "GetVisibleUnits" }) do
        local f = RS[name]
        if f then S[name] = function(...) return filt(f(...)) end end
    end
    -- Area queries take an optional team selector (a team id, or MY_UNITS -2 / ALLY_UNITS -3 / ENEMY_UNITS -4),
    -- which the engine resolves against the SPECTATOR's allyteam. Resolve it against T instead.
    local ALL, MY, ALLY, ENEMY = RS.ALL_UNITS or -1, RS.MY_UNITS or -2, RS.ALLY_UNITS or -3, RS.ENEMY_UNITS or -4
    for name, argc in pairs({ GetUnitsInCylinder = 3, GetUnitsInRectangle = 4, GetUnitsInSphere = 4,
                              GetUnitsInBox = 6, GetUnitsInPlanes = 1 }) do
        local f = RS[name]
        if f then
            S[name] = function(...)
                local args = { ... }
                local sel = args[argc + 1]
                if sel == MY or sel == ALLY then args[argc + 1] = T; return f(unpack(args, 1, argc + 1)) end
                if sel == ENEMY then
                    args[argc + 1] = ALL
                    local r, out = f(unpack(args, 1, argc + 1)), {}
                    for i = 1, #(r or {}) do
                        local u = r[i]
                        if spAlly(u) ~= T and vis(u) > 0 then out[#out + 1] = u end
                    end
                    return out
                end
                return filt(f(...))
            end
        end
    end
    S.GetTeamUnits = function(team, ...)
        local r = RS.GetTeamUnits(team, ...)
        if team == T then return r end
        return filt(r)
    end
    for _, name in ipairs({ "GetTeamUnitCount", "GetTeamResources", "GetTeamStatsHistory", "GetTeamUnitsCounts",
                            "GetTeamUnitsSorted", "GetTeamUnitsByDefs", "GetTeamUnitDefCount" }) do
        local f = RS[name]
        if f then S[name] = function(team, ...) if team == T then return f(team, ...) end return nil end end
    end

    local function gate(names, need)
        for _, name in ipairs(names) do
            local f = RS[name]
            if f then S[name] = function(u, ...) if u and vis(u) >= need then return f(u, ...) end return nil end end
        end
    end
    gate({ "GetUnitDefID" }, 2)
    gate({ "GetUnitPosition", "GetUnitTeam", "GetUnitAllyTeam", "GetUnitBasePosition", "GetUnitIsDead" }, 1)
    gate({ "GetUnitHealth", "GetUnitVelocity", "GetUnitIsBeingBuilt", "GetUnitIsBuilding", "GetUnitBuildFacing",
           "GetUnitDirection", "GetUnitHeading", "GetUnitRadius", "GetUnitIsStunned", "GetUnitStates",
           "GetUnitExperience", "GetUnitIsActive", "GetUnitRulesParam", "GetUnitIsCloaked", "GetUnitTransporter",
           "GetUnitIsTransporting", "GetUnitWeaponState", "GetUnitNearestEnemy" }, 3)
    for _, name in ipairs({ "GetUnitCommands", "GetUnitCommandCount", "GetFactoryCommands", "GetUnitWorkerTask",
                            "GetUnitStockpile", "GetUnitLastAttacker", "GetUnitResources", "GetUnitCurrentCommand",
                            "GetCommandQueue" }) do
        local f = RS[name]
        if f then S[name] = function(u, ...) if u and spAlly(u) == T then return f(u, ...) end return nil end end
    end

    for _, name in ipairs({ "IsPosInLos", "IsPosInRadar", "IsPosInAirLos", "GetPositionLosState" }) do
        local f = RS[name]
        if f then S[name] = function(x, y, z, a) return f(x, y, z, a or T) end end
    end

    S.GiveOrderToUnit = function(u, ...) if own(u) then return RS.GiveOrderToUnit(u, ...) end return false end
    S.GiveOrderArrayToUnit = function(u, ...)
        if own(u) then return RS.GiveOrderArrayToUnit(u, ...) end
        return false
    end
    local function ownList(list)
        local out = {}
        for i = 1, #list do if own(list[i]) then out[#out + 1] = list[i] end end
        return out
    end
    S.GiveOrderToUnitArray = function(list, ...) return RS.GiveOrderToUnitArray(ownList(list), ...) end
    S.GiveOrderArrayToUnitArray = function(list, ...) return RS.GiveOrderArrayToUnitArray(ownList(list), ...) end
    S.GiveOrderToUnitMap = function(map, ...)
        local out = {}
        for u, v in pairs(map) do if own(u) then out[u] = v end end
        return RS.GiveOrderToUnitMap(out, ...)
    end

    RWG.__mbTeams = RWG.__mbTeams or {}
    local tw = RWG.__mbTeams[T]
    if not tw then
        tw = setmetatable({}, { __index = RWG })
        RWG.__mbTeams[T] = tw
    end

    -- Modules see what they saw before (the LuaUI globals, no bare WG) except Spring and VFS. Normally every include
    -- shares LuaUI's one global table, so the env is shared by all of team T's widgets (and only theirs).
    RWG.__mbInc = RWG.__mbInc or {}
    local incEnv = RWG.__mbInc[T]
    if not incEnv then
        incEnv = setmetatable({ Spring = S }, { __index = G })
        RWG.__mbInc[T] = incEnv
    end
    local V = setmetatable({}, { __index = RV })
    V.Include = function(f, env, mode) return RV.Include(f, env or incEnv, mode) end
    incEnv.VFS = V

    Spring, VFS, WG = S, V, tw
    __MB_SHIM = { T = T, vis = vis }
end

"""

# Lua placed after the widget's code: gates its unit callins (see the module docstring).
SHIM_TAIL = r"""

-- [single-client shim] callin gate
do
    local sh = __MB_SHIM
    local T, vis = sh.T, sh.vis
    for _, name in ipairs({ "UnitCreated", "UnitFinished", "UnitFromFactory", "UnitIdle", "UnitCommand",
                            "UnitCmdDone", "UnitGiven", "UnitTaken", "UnitLoaded", "UnitUnloaded",
                            "UnitStockpileChanged", "UnitExperience", "UnitReverseBuilt" }) do
        local f = widget[name]
        if type(f) == "function" then
            widget[name] = function(self, u, d, team, ...)
                if team == T then return f(self, u, d, team, ...) end
            end
        end
    end
    for _, name in ipairs({ "UnitDamaged", "UnitDestroyed" }) do
        local f = widget[name]
        if type(f) == "function" then
            widget[name] = function(self, u, d, team, ...)
                if team == T or vis(u) == 3 then return f(self, u, d, team, ...) end
            end
        end
    end
end
"""

# Turns on control of every team and governs the speed. Ends the process on GameOver: a spectator's plain "quit"
# never exits (a probe kept simulating to frame 1.47M), "quitforce" does.
#
# Widget orders still travel through the engine's (local) network loop, which takes a few real milliseconds: at a
# pinned 150-280x that measured a 150-320 frame order round trip (5-10 game-seconds), and LINE_CLICK's opening
# stalled (builders idle, 4-8k army at 20:00 instead of ~50k). So, like SPEED_GOVERNOR_WIDGET in bot_testing.py, the
# speed follows the round trip of the Latency Probe's messages (same process here): every 0.25 real seconds, worst
# lag > 1.25 x TARGET cuts the speed in proportion (at most halving it), < 0.8 x TARGET raises it 10%.
# The "speed" logged is the speed actually achieved over the last 300 frames.
CONTROL_WIDGET = r"""
function widget:GetInfo()
    return { name = "Single Control", desc = "cheat + godmode + speed governor", layer = -1000, enabled = true }
end

local MIN_SPEED, MAX_SPEED, TARGET = __MIN__, __MAX__, __TARGET__
local INTERVAL = 0.25
local speed = MIN_SPEED
local worst = 0
local timer, logTimer, lastF

local function SetSpeed(s)
    if s < speed then
        Spring.SendCommands("setminspeed " .. s, "setmaxspeed " .. s)
    else
        Spring.SendCommands("setmaxspeed " .. s, "setminspeed " .. s)
    end
    speed = s
end

-- Start where the lag is still tiny (~1 frame at 11x on its own core) instead of ramping up from MIN_SPEED.
function widget:GameStart()
    Spring.SendCommands("cheat 1", "godmode 3")
    speed = MAX_SPEED
    SetSpeed(math.max(MIN_SPEED, math.min(MAX_SPEED, 20)))
    timer, logTimer, lastF = Spring.GetTimer(), Spring.GetTimer(), 0
end

function widget:RecvLuaMsg(msg, playerID)
    local sent = msg:match("^mblat:(%d+)")
    if not sent then return end
    local lag = Spring.GetGameFrame() - tonumber(sent)
    if lag > worst then worst = lag end
end

function widget:GameFrame(n)
    if not timer then return end
    local now = Spring.GetTimer()
    if Spring.DiffTimers(now, timer) >= INTERVAL then
        timer = now
        if worst > 0 then
            local new = speed
            if worst > TARGET * 1.25 then
                new = speed * math.max(0.5, TARGET / worst)
            elseif worst < TARGET * 0.8 then
                new = speed * 1.1
            end
            new = math.floor(math.max(MIN_SPEED, math.min(MAX_SPEED, new)) * 10 + 0.5) / 10
            if new ~= speed then SetSpeed(new) end
        end
        worst = 0
    end
    if n - lastF >= 300 then
        local dt = Spring.DiffTimers(now, logTimer)
        if dt > 0 then
            Spring.Echo(string.format("[GOV] frame=%d speed=%.1f lag=%d set=%.1f", n, (n - lastF) / dt / 30,
                worst, speed))
        end
        logTimer, lastF = now, n
    end
end

function widget:GameOver(winners)
    for _, a in ipairs(winners or {}) do Spring.Echo("[WINNER] allyteam=" .. a) end
    Spring.Echo("[GameEnder] GameOver, quitting")
    Spring.SendCommands("quitforce")
end
"""

# A Lua out-of-memory, or one of the match's own widgets (a bot, tracker, stats, stock copy or control) removed
# after an error: from then on that side plays without it.
LUA_FAILURE_RE = re.compile(r"\[f=(-?\d+)\] ((?:Error: \[LuaUI::RunCallInTraceback\] error=4.*|.*not enough memory.*|"
                            r"Removed widget: .* T[01]\s*$|Removed widget: (?:Single Control|Latency Probe)\s*$))", re.M)

# Both bots, two trackers and 44 stock-widget copies allocate into one LuaUI heap. The engine's incremental collector
# and BAR's backstop (barwidgets.lua) run per Update -- real time -- so at 30-60x game speed garbage outran them: LuaUI
# hit 1.07-1.18 GB in 20-min LINE_CLICK games, and the end-of-game self-destruct took it past BAR's fixed all-Lua limit
# (modrules LuaAllocLimit = 1536 MB): LUA_ERRMEM, every widget dead, the process never quit. This collects per SIM frame
# instead and logs "[MEM] frame=F peak_mb=P" each game-minute.
GC_WIDGET = r"""
function widget:GetInfo()
    return { name = "Single GC", desc = "garbage collection per sim frame", layer = -1001, enabled = true }
end
local SOFT_KB, HARD_KB = 500000, 900000
local peak = 0
function widget:GameFrame(n)
    local kb = collectgarbage("count")
    if kb > peak then peak = kb end
    if kb > HARD_KB then
        collectgarbage("collect")
    elseif kb > SOFT_KB then
        collectgarbage("step", 2048)
    end
    if n % 1800 == 0 then
        Spring.Echo(string.format("[MEM] frame=%d peak_mb=%d now_mb=%d", n, peak / 1000, collectgarbage("count") / 1000))
        peak = 0
    end
end
"""
TAG_RE = re.compile(r"^(\[t=[^\]]*\]\[f=[^\]]*\] )?<T([01])> ")


def rename(content: str, suffix: str) -> str:
    """Append suffix to the widget name in GetInfo (patch_team's rename takes the file's first `name = "..."`,
    which in the stats tracker is an Echo format string)."""
    i = content.find("GetInfo")
    i = 0 if i < 0 else i
    return content[:i] + re.sub(r'(name\s*=\s*)(["\'])(.*?)\2', lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)} "
                                f"{suffix}{m.group(2)}", content[i:], count=1)


def info_name(content: str, fallback: str) -> str:
    """The widget name in GetInfo (see rename)."""
    i = max(0, content.find("GetInfo"))
    m = re.search(r'name\s*=\s*(["\'])(.*?)\1', content[i:])
    return m.group(2) if m else fallback


def wrap(content: str, team: int, suffix: str, bot: bool = True) -> str:
    """A widget's code wrapped for team `team`. Bot files also get patch_team, exactly as in a normal match."""
    body = bt.patch_team(content, team, suffix) if bot else rename(content, suffix)
    return SHIM_HEAD.replace("__T__", str(team)) + body + SHIM_TAIL


# BAR's own widgets that automate a player's units (enabled by default, give orders, do nothing for a spectator).
# In a normal match each bot process runs them for its team, and the bots depend on them -- unit_immobile_builder
# keeps nano turrets on FIGHT so they assist anything in range. Without them the single process's bots spent ~35%
# less by 5:00 (lab assisted by 0 nanos instead of 3, lanes stalled). Each team gets a shimmed copy instead.
# List = default-enabled cmd_/unit_ widgets that call GiveOrder* and check GetSpectatingState, all of which load in a
# normal bot process (BAR test-31530, 2026-10-08).
STOCK_WIDGETS = [
    "cmd_area_commands_filter.lua", "cmd_commandinsert.lua", "cmd_fac_holdposition.lua",
    "cmd_guard_transport_factory.lua", "cmd_holdfire_fix.lua", "cmd_no_duplicate_orders.lua",
    "cmd_transport_preserve_commands.lua", "unit_alt_set_target_type.lua", "unit_area_reclaim_enemy.lua",
    "unit_auto_cloak.lua", "unit_auto_repair_idle_builders.lua", "unit_bombers_default_hold_fire.lua",
    "unit_builder_priority.lua", "unit_clean_builder_queue.lua", "unit_dgun_stall_assist.lua",
    "unit_factory_assist_fix.lua", "unit_factory_quota.lua", "unit_immobile_builder.lua",
    "unit_load_own_moving.lua", "unit_set_fighters_fly.lua", "unit_smart_area_reclaim.lua", "unit_stateprefs.lua",
]


# BAR's display-only widgets (by file prefix). Headless nobody sees them, yet they cost LuaUI time every frame
# (AdvPlayersList alone ~8 s of a 20-min game), so single mode disables them (order 0 in BYAR.lua).
UI_WIDGET_PREFIXES = ("gui_", "gfx_", "snd_", "camera_", "map_", "minimap_", "logo_", "dbg_")
# ...except ones other (kept) widgets depend on: gui_fonthandler provides WG.fonts (Share Tracker, Share Unit Command).
UI_WIDGET_KEEP = ("gui_fonthandler.lua",)


def ui_widget_names() -> "list[str]":
    """GetInfo names of BAR's display-only widgets in the installed game."""
    files = read_game_files(lambda p: p.startswith("luaui/widgets/")
                            and p[len("luaui/widgets/"):].startswith(UI_WIDGET_PREFIXES) and p.endswith(".lua")
                            and "/" not in p[len("luaui/widgets/"):]
                            and p[len("luaui/widgets/"):] not in UI_WIDGET_KEEP)
    return sorted({info_name(src, "") for src in files.values()} - {""})


def read_game_files(paths) -> "dict[str, str]":
    """Files from the installed BAR game archive (rapid pool: versions.gz -> packages/<md5>.sdp -> pool/), by
    lower-case path. `paths` is a list of paths or a predicate on the lower-case path. Missing files are left out."""
    import gzip
    want = paths if callable(paths) else {p.lower() for p in paths}.__contains__
    data = bt.BAR_DATA_DIR
    tag, md5 = bt.get_game_type(), None
    with gzip.open(data / "rapid/repos-cdn.beyondallreason.dev/byar/versions.gz", "rt", encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\r\n").split(",")
            if len(p) >= 4 and p[3].strip() == tag:
                md5 = p[1]
    if not md5:
        return {}
    raw, i, out = gzip.open(data / "packages" / f"{md5}.sdp").read(), 0, {}
    while i < len(raw):
        n = raw[i]
        name = raw[i + 1:i + 1 + n].decode("utf-8", "replace").lower()
        h = raw[i + 1 + n:i + 17 + n].hex()
        i += 25 + n                                   # name length, name, md5, crc32, size
        if want(name):
            with gzip.open(data / "pool" / h[:2] / (h[2:] + ".gz")) as g:
                out[name] = g.read().decode("utf-8", "replace")
    return out


def write_byar_config(config_dir: Path, names: list, disabled: list) -> None:
    """bot_testing.write_byar_config plus order 0 (= disabled, barwidgets.lua) for `disabled`."""
    def q(s: str) -> str:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    config_dir.mkdir(parents=True, exist_ok=True)
    order = [f"        [{q(n)}] = {i + 1}," for i, n in enumerate(names)]
    order += [f"        [{q(n)}] = 0," for n in disabled]
    (config_dir / "BYAR.lua").write_text(
        "return {\n    allowUserWidgets = true,\n    data = {},\n    order = {\n" + "\n".join(order) + "\n    },\n}\n",
        encoding="utf-8")


def split_log(text: str) -> "tuple[str, str]":
    """The single process's log as (team 0 log, team 1 log): tagged lines go to their team, untagged to both."""
    out = ([], [])
    for line in text.splitlines():
        m = TAG_RE.match(line)
        if m:
            out[int(m.group(2))].append((m.group(1) or "") + line[m.end():])
        else:
            out[0].append(line)
            out[1].append(line)
    return "\n".join(out[0]), "\n".join(out[1])


def render_script(game_type: str, map_name: str, save_replay: bool, host_port: int,
                  name0: str, name1: str, max_speed: float) -> str:
    sp_type, sp = bt.start_pos_override()
    return (
        "[GAME]\n{\n"
        f"    IsHost=1;\n    MyPlayerName=MatchHost;\n    HostPort={host_port};\n"
        f"    GameType={game_type};\n    MapName={map_name};\n"
        f"    StartPosType={sp_type};\n    FixedRNGSeed=1;\n"
        f"    RecordDemo={1 if save_replay else 0};\n    GameStartDelay=0;\n"
        "    NoHelperAIs=0;\n\n"
        "    [MODOPTIONS]\n    {\n"
        f"        deathmode={os.environ.get('METALBOT_DEATHMODE', 'com')};\n        maxunits=3000;\n"
        f"        maxspeed={max_speed:g};\n        minspeed=1;\n"
        "        allowuserwidgets=1;\n        allowunitcontrolwidgets=1;\n"
        "        allowuserscripts=1;\n    }\n\n"
        "    [ALLYTEAM0] { numallies=0; }\n    [ALLYTEAM1] { numallies=0; }\n\n"
        "    [TEAM0]\n    {\n        teamleader=0;\n        allyteam=0;\n"
        "        side=Cortex;\n        rgbcolor=0.2 0.4 0.9;\n" + sp[0] + "    }\n"
        "    [TEAM1]\n    {\n        teamleader=0;\n        allyteam=1;\n"
        "        side=Cortex;\n        rgbcolor=0.9 0.2 0.2;\n" + sp[1] + "    }\n\n"
        "    [PLAYER0]\n    {\n        name=MatchHost;\n        team=0;\n        spectator=1;\n    }\n"
        f"    [AI0]\n    {{\n        Name={name0};\n        ShortName=NullAI;\n        Version=0.1;\n"
        "        Team=0;\n        Host=0;\n    }\n"
        f"    [AI1]\n    {{\n        Name={name1};\n        ShortName=NullAI;\n        Version=0.1;\n"
        "        Team=1;\n        Host=0;\n    }\n"
        "}\n"
    )


def setup(write_dir: Path, bot_files: "tuple[list, list]", game_end_target: int, end_frame: int,
          eco_weight: float, spring_data: str, speeds: "tuple[float, float, float]", profile: bool,
          main_core_mask: int = 0) -> list:
    widgets_dir = write_dir / "LuaUI" / "Widgets"
    widgets_dir.mkdir(parents=True, exist_ok=True)
    active, skip = [], set()

    def put(fname: str, text: str, wname: str) -> None:
        (widgets_dir / fname).write_text(text, encoding="utf-8")
        skip.add(fname)
        active.append(wname)

    lo, hi, target = speeds
    put("single_control.lua", CONTROL_WIDGET.replace("__MIN__", f"{lo:g}").replace("__MAX__", f"{hi:g}")
        .replace("__TARGET__", f"{target:g}"), "Single Control")
    put("headless_latency_probe.lua", bt.LATENCY_PROBE_WIDGET, "Latency Probe")
    put("single_gc.lua", GC_WIDGET, "Single GC")
    if profile:
        put("headless_profiler.lua", bt.PROFILER_WIDGET, "Harness Profiler")

    stats = (bt.STATS_WIDGET.replace("__ADJ_SECS__", str(game_end_target))
             .replace("__END_FRAME__", str(end_frame)).replace("__ECO_WEIGHT__", str(eco_weight)))
    tracker_src = bt.REPO_DIR / "metalbot_stats_tracker.lua"
    tracker = tracker_src.read_text(encoding="utf-8") if tracker_src.exists() else None
    dump_src = bt.REPO_DIR / "metalbot_state_dump.lua"   # defs + per-minute unit snapshots for eco_sim.py
    dump = dump_src.read_text(encoding="utf-8") if dump_src.exists() else None
    bt.copy_shared_deps(widgets_dir, skip)

    for team in (0, 1):
        suffix = f"T{team}"
        put(f"headless_stats_{team}.lua", wrap(stats, team, suffix, bot=False), f"Headless Stats {suffix}")
        if tracker:
            put(f"stats_tracker_{team}.lua", wrap(tracker, team, suffix, bot=False),
                f"{bt.extract_widget_name(tracker, 'Stats Tracker')} {suffix}")
        if dump:
            put(f"state_dump_{team}.lua", wrap(dump, team, suffix, bot=False), f"State Dump {suffix}")
        for lua_file in bot_files[team]:
            content = lua_file.read_text(encoding="utf-8")
            wname = f"{bt.extract_widget_name(content, lua_file.stem)} {suffix}"
            put(f"bot_{suffix.lower()}_{lua_file.name}", wrap(content, team, suffix), wname)
            print(f"  [{suffix}] {lua_file.name} -> \"{wname}\"")

    stock = read_game_files([f"luaui/widgets/{n}" for n in STOCK_WIDGETS])
    missing = [n for n in STOCK_WIDGETS if f"luaui/widgets/{n}" not in stock]
    if missing:
        print(f"  WARNING: BAR stock widgets not found in the game archive: {', '.join(missing)}")
    for name in STOCK_WIDGETS:
        src = stock.get(f"luaui/widgets/{name}")
        if src is None:
            continue
        for team in (0, 1):
            suffix = f"T{team}"
            put(f"stock_{suffix.lower()}_{name}", wrap(src, team, suffix, bot=False),
                f"{info_name(src, name)} {suffix}")
    print(f"  BAR stock automation widgets: {len(stock)} x 2 teams")

    bt.shadow_bar_widgets(bt.BAR_DATA_DIR / "LuaUI" / "Widgets", widgets_dir, skip)
    disabled = [n for n in ui_widget_names() if n not in active]
    write_byar_config(write_dir / "LuaUI" / "Config", active, disabled)
    print(f"  BAR display widgets disabled: {len(disabled)}")
    (write_dir / "springsettings.cfg").write_text(
        f"SpringData = {spring_data}\n"
        "LuaSocketEnabled = 0\n"
        "LogFlushLevel = 0\n"
        "HangTimeout = 120\n"
        + (f"SetCoreAffinity = {main_core_mask}\n" if main_core_mask else ""),
        encoding="utf-8",
    )
    return active


def claim_core():
    """(mask, lock file) for a physical core no other single match on this machine holds.

    One lock file per core in the temp dir, locked for the life of this process (the OS drops the lock if it dies).
    Cores a normal match pins (main_core_masks(3)) are tried last. (0, None) when every core is taken.
    """
    import tempfile
    n = os.cpu_count() or 1
    step = 2 if n >= 8 else 1
    bits = [n - step * (i + 1) for i in range(n // step)]
    normal = {m.bit_length() - 1 for m in bt.main_core_masks(3) if m}
    bits = [b for b in bits if b not in normal] + [b for b in bits if b in normal]
    for b in bits:
        fh = open(Path(tempfile.gettempdir()) / f"metalbot_single_core_{b}.lock", "a+")
        try:
            fh.seek(0)
            if sys.platform == "win32":
                import msvcrt
                msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return 1 << b, fh
        except OSError:
            fh.close()
    return 0, None


def run_match_single(bot0_dir, bot1_dir, duration: int, map_name: str, save_replay: bool, verbose: bool,
                     end_frame: int, eco_weight: float, max_speed: float, profile: bool = False,
                     min_speed: float = 2, target_lag: float = 30, pin_cores: bool = True):
    """Like bot_testing.run_match, in one process. Returns a bot_testing.MatchResult."""
    files = (sorted(Path(bot0_dir).glob("*.lua")), sorted(Path(bot1_dir).glob("*.lua")))
    if not files[0] or not files[1]:
        raise ValueError(f"No .lua files in {bot0_dir if not files[0] else bot1_dir}")

    from datetime import datetime
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    tmp = Path(os.environ.get("LOCALAPPDATA", "")) / "Temp" if os.environ.get("LOCALAPPDATA") else Path("/tmp")
    test_dir = tmp / f"bottest_{stamp}_{os.getpid()}"
    solo_dir = test_dir / "solo"
    solo_dir.mkdir(parents=True, exist_ok=True)

    import random
    host_port = random.randint(9000, 19000)
    spring_data = str(bt.BAR_DATA_DIR)
    headless = bt.find_engine("spring-headless.exe")
    game_type = bt.get_game_type()
    name0, name1 = bt.bot_player_name(bot0_dir, 0), bt.bot_player_name(bot1_dir, 1)
    if verbose:
        print(f"Write dir : {test_dir}  (single client)")
        print(f"Map       : {map_name}")
        print(f"Bot 0     : {Path(bot0_dir).name}  ({len(files[0])} files)")
        print(f"Bot 1     : {Path(bot1_dir).name}  ({len(files[1])} files)")
        print(f"Speed     : {min_speed:g}-{max_speed:g}x, holding the order round trip near {target_lag:g} frames")

    game_end_target = max(30, duration - 150)
    # Left alone the engine pins its main thread to one "preferred" core (0x4000 here) -- the core a normal match's
    # P0 gets from main_core_masks(3), which halved this process's speed while one ran. Claim a free core instead,
    # so several single matches can run side by side (each uses one core).
    mask, core_lock = claim_core() if pin_cores else (0, None)
    if verbose and mask:
        print(f"Core      : {mask.bit_length() - 1} (mask {mask})")
    setup(solo_dir, files, game_end_target, end_frame, eco_weight, spring_data, (min_speed, max_speed, target_lag),
          profile, mask)
    bt.write_script(solo_dir / "startscript.txt",
                    render_script(game_type, map_name, save_replay, host_port, name0, name1, max_speed))

    log = solo_dir / "headless.log"
    env = {**os.environ, "SPRING_DATADIR": spring_data}
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0
    start = time.monotonic()
    with open(log, "wb") as fh:
        proc = subprocess.Popen([str(headless), "--isolation", "--write-dir", str(solo_dir),
                                 str(solo_dir / "startscript.txt")],
                                cwd=str(solo_dir), stdout=fh, stderr=subprocess.STDOUT, env=env, creationflags=flags)
    if verbose:
        print(f"  PID {proc.pid}; running for up to {duration}s.\n")
    try:
        while proc.poll() is None and time.monotonic() - start < duration + bt.EXIT_GRACE:
            if verbose:
                print(f"\r  run  {time.monotonic() - start:.0f}s", end="", flush=True)
            time.sleep(2)
        if verbose:
            print(f"\n{'Exited' if proc.poll() is not None else 'Timed out'} after {time.monotonic() - start:.0f}s.")
    except KeyboardInterrupt:
        if verbose:
            print("\nInterrupted; stopping.")
    bt.graceful_stop(proc)
    duration_secs = time.monotonic() - start

    if save_replay:
        found = [f for sub in ("demos", "demos-server") for f in (solo_dir / sub).glob("*.sdfz")
                 if f.stat().st_size > 0]
        if found:
            import shutil
            best = max(found, key=lambda f: f.stat().st_size)
            (bt.BAR_DATA_DIR / "demos").mkdir(exist_ok=True)
            shutil.copy2(str(best), str(bt.BAR_DATA_DIR / "demos" / best.name))
            if verbose:
                print(f"\nReplay saved: {bt.BAR_DATA_DIR / 'demos' / best.name}")
        elif verbose:
            print("\nWARNING: --save-replay set but no non-empty .sdfz was found.")

    text = bt._read_log(log)
    p0_text, p1_text = split_log(text)
    result = bt._parse_logs(p0_text, p1_text, Path(bot0_dir).name, Path(bot1_dir).name, duration_secs,
                            host_text=text)
    m = LUA_FAILURE_RE.search(text)
    if m:
        result.lua_failure = {"what": m.group(2).strip()[:200], "frame": int(m.group(1))}
        if verbose:
            print(f"\nWARNING: LUA FAILURE at frame {m.group(1)} ({int(m.group(1)) / 1800:.1f} min): "
                  f"{m.group(2).strip()[:160]} -- the bots may have stopped there")
    m = re.search(r"Sync error for (\S+) in frame (\d+)", text)
    if m:
        result.desync = {"player": m.group(1), "frame": int(m.group(2))}
    return result
