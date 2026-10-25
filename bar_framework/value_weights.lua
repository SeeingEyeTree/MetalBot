-- bar_framework/value_weights.lua   (2026-10-25)
-- What a unit is WORTH when it dies, for the fight ledger (ledger_logger.lua, ledger_report.py).  Not its price: killing economy or build
-- power takes away future value, so those are worth more than their cost; killing army is worth its cost.  (User, 2026-10-25: "a mex
-- worth its cost + 60 seconds of its income, same for other eco buildings, BP should always be worth the most".)
--
--   cost      = metalCost + energyCost / ENERGY_PER_METAL                      (the project's UnitValue)
--   eco       = cost + SECONDS x income, income in metal-equivalent per second:
--               a mex  extractsMetal x MEX_PER_EXTRACT (T1 2.37 m/s, T2 9.48 m/s on Full Metal Plate: knowledge/economy_numbers.md),
--               an energy plant  energyMake (or windGenerator x WIND_AVG, tidal) / ENERGY_PER_METAL;  storage and the rest: cost only
--   bp        = BP_MULT x cost + SECONDS x buildSpeed x BP_METAL_PER_BP        (nanos, labs, constructors, decoy commanders, rez bots)
--               -- build power is the multiplier that moves it the most: a nano (276 cost) is worth ~1.4k, a T2 mex ~1.3k, a Fusion ~4.6k
--   commander = COMMANDER (it ends the game; the decoys are "bp")
--   army      = cost       (mobile and armed)
--   defence   = cost       (a structure with weapons)
--   other     = cost       (radar, jammers, mines, unarmed mobile units ...)
-- A unit still under construction is worth its build progress x the above.
-- All the numbers are in M.CFG: change them there (or pass an override table to M.New).
--
--   local VW = VFS.Include("LuaUI/Widgets/bar_framework/value_weights.lua")
--   local v, cat = VW.Value(defID)              -- value in metal-equivalent, category ("army" "eco" "bp" "defence" "commander" "other")
--   local v, cat = VW.Value(defID, 0.4)         -- a unit 40% built
--   VW.Category(defID), VW.Cost(defID), VW.Describe(defID)
-- Test: tests/test_value_weights.lua.  Python mirror for old logs: none (the ledger logs values, not just counts).

local M = {}

M.CFG = {
    SECONDS          = 60,       -- seconds of income an eco building (or of throughput a bp unit) is worth on top of its cost
    ENERGY_PER_METAL = 70,       -- energy valued at 1/70 metal (same as lab_rules UnitValue)
    MEX_PER_EXTRACT  = 2370,     -- m/s per unit of extractsMetal: cormex 0.001 -> 2.37, cormoho 0.004 -> 9.48
    WIND_AVG         = 0.6,      -- a wind generator makes about this share of its windGenerator figure on average
    BP_MULT          = 3.0,      -- build-power units count this many times their cost ...
    BP_METAL_PER_BP  = 0.05,     -- ... plus SECONDS x buildSpeed x this (metal/s one point of build power can move)
    COMMANDER        = 25000,    -- the commander (kill it and the game is over)
}

function M.New(over)
    local K = {}
    for k, v in pairs(M.CFG) do K[k] = v end
    for k, v in pairs(over or {}) do K[k] = v end
    local self = { CFG = K }
    local cache = {}                       -- [defID] = { value, category }

    local function Def(defID)
        if type(defID) == "table" then return defID end
        return defID and UnitDefs[defID]
    end

    local function Cost(d)
        return (d.metalCost or 0) + (d.energyCost or 0) / K.ENERGY_PER_METAL
    end

    local function IsCommander(d)
        local cp = d.customParams
        return cp ~= nil and (cp.iscommander ~= nil or cp.is_commander ~= nil)
    end

    local function Armed(d) return d.weapons ~= nil and #d.weapons > 0 end

    -- income of an economy building in metal-equivalent per second (nil = not an eco building)
    local function EcoIncome(d)
        if (d.extractsMetal or 0) > 0 then return d.extractsMetal * K.MEX_PER_EXTRACT end
        local e = (d.windGenerator or 0) * K.WIND_AVG + (d.tidalGenerator or 0)
        if not d.isBuilder and (d.energyMake or 0) > 0 then e = e + d.energyMake end
        if e > 0 then return e / K.ENERGY_PER_METAL end
        if (d.makesMetal or 0) > 0 then return d.makesMetal end
        if (d.energyStorage or 0) >= 1000 or (d.metalStorage or 0) >= 1000 then return 0 end     -- storages: eco, worth their cost
        return nil
    end

    local function Classify(d)
        local mobile = (d.speed or 0) > 0
        if IsCommander(d) then return "commander" end
        if d.isFactory or (d.isBuilder and (d.buildSpeed or 0) > 0) then return "bp" end
        if not mobile then
            local inc = EcoIncome(d)
            if inc then return "eco", inc end
            if Armed(d) then return "defence" end
            return "other"
        end
        if Armed(d) then return "army" end
        return "other"
    end

    function self.Category(defID)
        local d = Def(defID)
        if not d then return "other" end
        return (Classify(d))
    end

    function self.Cost(defID)
        local d = Def(defID)
        return d and Cost(d) or 0
    end

    -- value, category of a finished unit (progress 0..1 scales it for a unit under construction)
    function self.Value(defID, progress)
        local d = Def(defID)
        if not d then return 0, "other" end
        local c = type(defID) == "number" and cache[defID]
        if not c then
            local cat, inc = Classify(d)
            local v
            if cat == "commander" then v = K.COMMANDER
            elseif cat == "bp" then v = K.BP_MULT * Cost(d) + K.SECONDS * (d.buildSpeed or 0) * K.BP_METAL_PER_BP
            elseif cat == "eco" then v = Cost(d) + K.SECONDS * (inc or 0)
            else v = Cost(d) end
            c = { v, cat }
            if type(defID) == "number" then cache[defID] = c end
        end
        local p = progress
        if p == nil or p > 1 then p = 1 elseif p < 0 then p = 0 end
        return c[1] * p, c[2]
    end

    function self.Describe(defID)
        local d = Def(defID)
        if not d then return "?" end
        local v, cat = self.Value(defID)
        return string.format("%s: %s, cost %.0f, value %.0f (x%.2f)", d.name or "?", cat, Cost(d), v, Cost(d) > 0 and v / Cost(d) or 0)
    end

    return self
end

-- the default instance, for callers that do not tune anything
local default
local function D() default = default or M.New(); return default end
function M.Value(defID, progress) return D().Value(defID, progress) end
function M.Category(defID) return D().Category(defID) end
function M.Cost(defID) return D().Cost(defID) end
function M.Describe(defID) return D().Describe(defID) end

return M
