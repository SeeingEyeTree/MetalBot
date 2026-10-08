"""Tests the --server single shim (single_client.SHIM_HEAD/SHIM_TAIL) in lupa's Lua 5.1 against a fake engine.

    python tests/test_single_client.py

Units: 1 = team 0's commander, 2 = team 1's unit in team 0's LOS, 3 = team 1's unit unseen by team 0, 4 = team 1's
radar blip (never seen: untyped). Each team's widget runs in its own environment, as in BAR's widget handler.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import lupa.lua51 as lupa  # noqa: E402  (the engine's Lua 5.1)
import single_client as sc  # noqa: E402

ENGINE = r"""
local units = { [1] = {team=0, def=10}, [2] = {team=1, def=11}, [3] = {team=1, def=12}, [4] = {team=1, def=13} }
-- LOS bits as seen by allyteam 0: 2 in LOS, 3 unseen, 4 radar only. Allyteam 1 sees everything.
local los0 = { [2] = 1 + 4, [3] = 0, [4] = 2 }
orders, echoes = {}, {}
local function list(f) local r = {} for u = 1, 4 do if f(u) then r[#r + 1] = u end end return r end
Spring = {
  ALL_UNITS = -1, MY_UNITS = -2, ALLY_UNITS = -3, ENEMY_UNITS = -4,
  GetMyTeamID = function() return 0 end, GetMyAllyTeamID = function() return 0 end,
  GetSpectatingState = function() return true, true end,
  Echo = function(s) echoes[#echoes + 1] = s end,
  GetUnitAllyTeam = function(u) return units[u] and units[u].team end,
  GetUnitTeam = function(u) return units[u] and units[u].team end,
  GetUnitDefID = function(u) return units[u] and units[u].def end,
  GetUnitPosition = function(u) return 100 * u, 0, 0 end,
  GetUnitHealth = function(u) return 50, 100 end,
  GetUnitCommands = function(u) return {} end,
  GetUnitLosState = function(u, a, raw)
    if units[u].team == a then return 15 end
    if a == 0 then return los0[u] end
    return 1
  end,
  GetAllUnits = function() return list(function() return true end) end,
  GetUnitsInCylinder = function(x, z, r, team)
    if team == -4 then return list(function(u) return units[u].team ~= 0 end) end  -- spectator's view: allyteam 0
    if team == -2 or team == -3 then return list(function(u) return units[u].team == 0 end) end
    if team and team >= 0 then return list(function(u) return units[u].team == team end) end
    return list(function() return true end)
  end,
  GetTeamUnits = function(t) return list(function(u) return units[u].team == t end) end,
  GetTeamResources = function(t) return 100, 1000, 0, 5, 0 end,
  IsPosInLos = function(x, y, z, a) return a end,
  GiveOrderToUnit = function(u, cmd) orders[#orders + 1] = u; return true end,
  GiveOrderToUnitArray = function(l) for _, u in ipairs(l) do orders[#orders + 1] = u end; return true end,
}
VFS = { Include = function(f, env) return env end }
WG = {}
"""

WIDGET = r"""
function widget:GetInfo() return { name = "Probe", enabled = true } end
seen = {}
function widget:UnitCreated(u, d, team) seen[#seen + 1] = "c" .. u end
function widget:UnitDestroyed(u, d, team) seen[#seen + 1] = "d" .. u end
"""


def env_for(lua, team):
    make = lua.eval("""function(src)
        local w = setmetatable({}, { __index = _G })
        w.widget = w
        local chunk = assert(loadstring(src))
        setfenv(chunk, w)
        chunk()
        return w
    end""")
    return make(sc.wrap(WIDGET, team, f"T{team}", bot=False))


def main():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ENGINE)
    w0, w1 = env_for(lua, 0), env_for(lua, 1)
    run = lua.eval("function(w, src) local f = assert(loadstring(src)); setfenv(f, w); return f() end")
    tbl = lambda t: sorted(t.values()) if t is not None else None  # noqa: E731

    assert run(w0, "return Spring.GetMyTeamID()") == 0 and run(w1, "return Spring.GetMyTeamID()") == 1
    assert run(w1, "return Spring.GetMyAllyTeamID()") == 1
    assert run(w1, "return (Spring.GetSpectatingState())") is False

    # Fog: team 0 sees its own unit, unit 2 (LOS) and the blip 4; team 1 sees everything of its own plus unit 1.
    assert tbl(run(w0, "return Spring.GetAllUnits()")) == [1, 2, 4]
    assert tbl(run(w1, "return Spring.GetAllUnits()")) == [1, 2, 3, 4]
    assert run(w0, "return Spring.GetUnitDefID(2)") == 11
    assert run(w0, "return Spring.GetUnitDefID(3)") is None
    assert run(w0, "return Spring.GetUnitDefID(4)") is None, "untyped blip"
    assert run(w0, "return (Spring.GetUnitPosition(4))") == 400, "blip has a position"
    assert run(w0, "return (Spring.GetUnitHealth(4))") is None, "blip has no health"
    assert run(w0, "return Spring.GetUnitCommands(2)") is None, "enemy commands are hidden"
    assert run(w0, "return Spring.GetTeamResources(1)") is None
    assert run(w0, "return (Spring.GetTeamResources(0))") == 100
    assert tbl(run(w0, "return Spring.GetTeamUnits(1)")) == [2, 4]
    assert run(w1, "return Spring.IsPosInLos(0, 0, 0)") == 1, "LOS checks default to the team's allyteam"

    # Area-query selectors resolve against the shim's team, not the spectator's allyteam 0.
    assert tbl(run(w1, "return Spring.GetUnitsInCylinder(0, 0, 9, Spring.ENEMY_UNITS)")) == [1]
    assert tbl(run(w1, "return Spring.GetUnitsInCylinder(0, 0, 9, Spring.MY_UNITS)")) == [2, 3, 4]
    assert tbl(run(w0, "return Spring.GetUnitsInCylinder(0, 0, 9, Spring.ENEMY_UNITS)")) == [2, 4]
    assert tbl(run(w0, "return Spring.GetUnitsInCylinder(0, 0, 9)")) == [1, 2, 4]

    # Orders only reach the team's own units.
    assert run(w0, "return Spring.GiveOrderToUnit(2, 10)") is False
    assert run(w0, "return Spring.GiveOrderToUnit(1, 10)") is True
    run(w1, "Spring.GiveOrderToUnitArray({1, 2, 3})")
    assert tbl(lua.globals().orders) == [1, 2, 3], tbl(lua.globals().orders)

    # Per-team WG, falling back to the real one.
    lua.execute("WG.Shared = 'yes'")
    run(w0, "WG.MetalBot = 'zero'")
    run(w1, "WG.MetalBot = 'one'")
    assert run(w0, "return WG.MetalBot") == "zero" and run(w1, "return WG.MetalBot") == "one"
    assert run(w1, "return WG.Shared") == "yes"
    assert lua.eval("WG.MetalBot") is None

    # Includes get the team's Spring.
    assert run(w1, "return VFS.Include('x').Spring.GetMyTeamID()") == 1

    # Echo is tagged.
    run(w1, "Spring.Echo('[CK] hi')")
    assert list(lua.globals().echoes.values())[-1] == "<T1> [CK] hi"

    # Callins: own-team creations only; destructions of own units and enemies in LOS.
    run(w0, "widget:UnitCreated(1, 10, 0); widget:UnitCreated(2, 11, 1)")
    run(w0, "widget:UnitDestroyed(2, 11, 1); widget:UnitDestroyed(3, 12, 1); widget:UnitDestroyed(1, 10, 0)")
    assert list(run(w0, "return seen").values()) == ["c1", "d2", "d1"], list(run(w0, "return seen").values())
    assert run(w0, "return widget:GetInfo().name") == "Probe T0"
    print("test_single_client: all passed")


if __name__ == "__main__":
    main()
