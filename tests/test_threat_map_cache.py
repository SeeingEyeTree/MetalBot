"""threat_map.lua's per-frame own-combatant snapshot must give exactly what the old per-call scans gave.

    python tests/test_threat_map_cache.py

The reference functions below are the pre-snapshot OwnStrength / AvailableStrength (2026-10-08), run against the same
fake engine as the module over random armies, channels and spots, within a frame and across frames (units move).
"""
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
import lupa.lua51 as lupa  # noqa: E402  (the engine's Lua 5.1)

STUB = r"""
units, frame = {}, 0
Spring = {
  GetGameFrame = function() return frame end,
  GetTeamUnits = function(t) local r = {} for _, u in ipairs(units) do if u.team == t then r[#r + 1] = u.id end end return r end,
  GetUnitDefID = function(id) for _, u in ipairs(units) do if u.id == id then return u.def end end end,
  GetUnitPosition = function(id) for _, u in ipairs(units) do if u.id == id then return u.x, 0, u.z end end end,
  GetUnitAllyTeam = function(id) return 0 end,
}
-- defs: speed, cost, flags
DEFS = {}
UQ = {
  is_mobile = function(d) return DEFS[d].mobile end, has_weapons = function(d) return DEFS[d].weapons end,
  is_builder = function(d) return DEFS[d].builder end, is_factory = function(d) return false end,
  is_commander = function(d) return DEFS[d].com end, is_dedicated_aa = function(d) return DEFS[d].aa end,
  can_hit_air = function(d) return DEFS[d].hitair end, can_hit_ground = function(d) return DEFS[d].hitground end,
  max_speed = function(d) return DEFS[d].speed end, metal_cost = function(d) return DEFS[d].cost end,
}
"""

REFERENCE = r"""
local TM = ...
local function ChannelValue(defID, channel)
    local v = TM.Intrinsic(defID)
    if channel == "air" then
        if UQ.is_dedicated_aa(defID) then return v end
        if UQ.can_hit_air(defID) then return v * TM.NONSPECIALIST_AA_WEIGHT end
        return 0
    end
    return UQ.can_hit_ground(defID) and v or 0
end
local function IsOwnCombatant(defID)
    return defID and UQ.is_mobile(defID) and UQ.has_weapons(defID)
       and not UQ.is_builder(defID) and not UQ.is_factory(defID) and not UQ.is_commander(defID)
end
REF = {}
function REF.OwnStrength(team, channel)
    local total = 0
    for _, uid in ipairs(Spring.GetTeamUnits(team) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if IsOwnCombatant(defID) then total = total + ChannelValue(defID, channel) end
    end
    return total
end
function REF.AvailableStrength(team, channel, x, z)
    local total = 0
    for _, uid in ipairs(Spring.GetTeamUnits(team) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if IsOwnCombatant(defID) then
            local v = ChannelValue(defID, channel)
            if v > 0 then
                local ux, _, uz = Spring.GetUnitPosition(uid)
                if ux then
                    local d = math.sqrt((ux - x) ^ 2 + (uz - z) ^ 2)
                    local eta = (d / math.max(1, UQ.max_speed(defID))) * 30
                    if eta <= TM.RESPONSE_HORIZON then total = total + v end
                end
            end
        end
    end
    return total
end
"""


def main():
    rng = random.Random(7)
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUB)
    g = lua.globals()
    for d in range(1, 13):
        g.DEFS[d] = lua.table_from({
            "speed": rng.choice([0, 0.5, 40, 85, 150, 297]), "cost": rng.randint(20, 900),
            "mobile": rng.random() < 0.85, "weapons": rng.random() < 0.8, "builder": rng.random() < 0.15,
            "com": d == 1, "aa": rng.random() < 0.2, "hitair": rng.random() < 0.4, "hitground": rng.random() < 0.8})
    TM = lua.execute((ROOT / "bar_framework" / "threat_map.lua").read_text(encoding="utf-8"))
    TM.Init(lua.table_from({"MM": None, "UQ": g.UQ, "teamID": 0, "allyID": 0}))
    lua.execute(REFERENCE, TM)
    ref = g.REF
    checks = 0
    for frame in range(1, 40):
        g.frame = frame
        units = lua.table()
        for i in range(rng.randint(0, 120)):
            units[i + 1] = lua.table_from({"id": rng.randint(1, 30000), "team": rng.choice([0, 0, 0, 1]),
                                           "def": rng.randint(1, 12), "x": rng.uniform(0, 12000),
                                           "z": rng.uniform(0, 12000)})
        if frame % 3:          # same unit ids, new positions/units: a real new frame
            g.units = units
        for _ in range(25):
            ch = rng.choice(["air", "ground", "unknown"])
            x, z = rng.uniform(0, 12000), rng.uniform(0, 12000)
            assert TM.OwnStrength(ch) == ref.OwnStrength(0, ch), (frame, ch)
            assert TM.AvailableStrength(ch, x, z) == ref.AvailableStrength(0, ch, x, z), (frame, ch, x, z)
            checks += 2
        if frame % 7 == 0:     # a death mid-frame drops the snapshot
            TM.OnUnitDestroyed(1, 2, True, frame, None)
    print(f"test_threat_map_cache: {checks} comparisons identical")


if __name__ == "__main__":
    main()
