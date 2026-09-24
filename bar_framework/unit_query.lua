-- bar_framework/unit_query.lua
-- Unit classification and querying helpers shared across bot widgets.
--
-- Load in a widget with:
--   local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
--
-- NOTE: Spring.GetTeamUnits() respects visibility.  P0 (fullview=1) can query
-- both teams; P1 can only reliably query its own team.

local M = {}

-- ── Classification helpers ────────────────────────────────────────────────────

function M.is_commander(defID)
    local d = defID and UnitDefs[defID]
    if not d then return false end
    return (d.customParams and
            (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil))
        or (d.name and string.find(string.lower(d.name), "commander") ~= nil)
end

function M.is_factory(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.isFactory == true
end

function M.is_builder(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.isBuilder == true and not d.isFactory
end

-- Metal cost of a unit definition (0 if unknown).
function M.metal_cost(defID)
    local d = defID and UnitDefs[defID]
    return d and (d.metalCost or 0) or 0
end

function M.is_air(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.canFly == true
end

function M.is_mobile(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and (d.speed or 0) > 0
end

-- Top speed in elmos/second (0 for structures).  Pair with map_model.TravelFrames
-- to turn a distance into an arrival frame.
function M.max_speed(defID)
    local d = defID and UnitDefs[defID]
    return d and (d.speed or 0) or 0
end

-- ── Weapon capability ─────────────────────────────────────────────────────────

local capsCache = {}

-- What can this unit shoot at?  Read from the weapons' own targeting restrictions:
--   onlyTargets.vtol      -> anti-air only        onlyTargets.surface -> cannot hit air
--   canAttackGround=false -> cannot hit ground    otherwise           -> both
--
-- EVERY weapon is inspected.  Judging a unit by its first weapon misled this
-- project once, and a unit with a dedicated AA gun plus a main gun reads as
-- ground-only if you stop at weapon 1.  Kept identical to the stats tracker's
-- capsOf() so bot decisions and [TRK] numbers cannot disagree.
local function caps(defID)
    local c = capsCache[defID]
    if c then return c[1], c[2], c[3] end
    local air, gnd = false, false
    local d = defID and UnitDefs[defID]
    if d and d.weapons then
        for i = 1, #d.weapons do
            local w  = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            local only = (w and w.onlyTargets) or {}
            local groundOK = not (wd and wd.canAttackGround == false)
            if only.vtol then
                air = true
            else
                if not only.surface and not only.notair then air = true end
                if groundOK then gnd = true end
            end
        end
    end
    capsCache[defID] = { air, gnd, air and not gnd }
    return air, gnd, air and not gnd
end

function M.can_hit_air(defID)    local a = caps(defID)          return a end
function M.can_hit_ground(defID) local _, g = caps(defID)       return g end

-- Real AA: hits air and cannot hit ground.  This is the test to trust when asking
-- "do we have an answer to bombers" -- a flag saying a weapon MAY target air does
-- not mean it is any good at it.
function M.is_dedicated_aa(defID)
    local _, _, aaOnly = caps(defID)
    return aaOnly
end

function M.has_weapons(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.weapons ~= nil and #d.weapons > 0
end

local rangeCache = {}

-- Longest weapon range, across all weapons (0 if unarmed).
function M.max_weapon_range(defID)
    local r = rangeCache[defID]
    if r then return r end
    r = 0
    local d = defID and UnitDefs[defID]
    if d and d.weapons then
        for i = 1, #d.weapons do
            local w  = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            if wd and (wd.range or 0) > r then r = wd.range end
        end
    end
    rangeCache[defID] = r
    return r
end

-- A bomber: flies and drops bombs.  Read from the weapon type, with the Cortex/Armada
-- names as a fallback in case a def reports something unexpected.  Bombers are one-way
-- strike units -- no repair pads exist in BAR -- so planners treat them apart from the
-- line and never retreat them.
local BOMBER_NAMES = { corshad = true, corhurc = true, armthund = true, armpnix = true }
local bomberCache = {}
function M.is_bomber(defID)
    local b = bomberCache[defID]
    if b ~= nil then return b end
    b = false
    local d = defID and UnitDefs[defID]
    if d and d.canFly then
        if BOMBER_NAMES[d.name] then b = true end
        for i = 1, #(d.weapons or {}) do
            local w  = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            if wd and wd.type == "AircraftBomb" then b = true end
        end
    end
    if defID then bomberCache[defID] = b end
    return b
end

-- Is this def a scout?  Category and name tests first, then the fallback that
-- catches anything fast and unarmed.
function M.is_scout(defID)
    local d = defID and UnitDefs[defID]
    if not d then return false end
    local mc = d.modCategories
    if mc then
        for k in pairs(mc) do
            if string.find(k, "scout") then return true end
        end
    end
    local cat = d.category
    if type(cat) == "string" and string.find(string.lower(cat), "scout") then return true end
    local name  = string.lower(d.name or "")
    local hName = string.lower((d.translatedHumanName or d.humanName) or "")
    if string.find(name,  "scout")  or string.find(hName, "scout")
    or string.find(name,  "peep")   or string.find(name,  "flea")
    or string.find(name,  "fink")   or string.find(name,  "phantom")
    or string.find(name,  "weasel") or string.find(name,  "wheelie") then
        return true
    end
    return (d.speed or 0) > 150 and not M.has_weapons(defID)
end

-- ── Team-wide queries ─────────────────────────────────────────────────────────

-- Returns alive non-commander units split by role.
-- result = {combat={uid,...}, builders={uid,...}, factories={uid,...}, commanders={uid,...}}
function M.get_by_role(teamID)
    local result = {combat={}, builders={}, factories={}, commanders={}}
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID then
            if M.is_commander(defID) then
                table.insert(result.commanders, uid)
            elseif M.is_factory(defID) then
                table.insert(result.factories, uid)
            elseif M.is_builder(defID) then
                table.insert(result.builders, uid)
            else
                table.insert(result.combat, uid)
            end
        end
    end
    return result
end

-- Total metal value of all alive non-commander units for a team.
function M.army_metal_value(teamID)
    local mv = 0
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID and not M.is_commander(defID) then
            mv = mv + M.metal_cost(defID)
        end
    end
    return mv
end

-- Count of alive non-commander units for a team.
function M.army_count(teamID)
    local n = 0
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID and not M.is_commander(defID) then
            n = n + 1
        end
    end
    return n
end

-- Returns the commander unit ID for a team, or nil if dead/not found.
function M.get_commander(teamID)
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID and M.is_commander(defID) then
            return uid
        end
    end
    return nil
end

-- Returns a list of enemy unitIDs within `radius` elmos of position (x, z).
-- Clamps the cylinder query to map bounds automatically.
function M.enemies_near(x, z, radius, myAllyTeam)
    local msx = Game.mapSizeX
    local msz = Game.mapSizeZ
    local cx  = math.max(radius, math.min(msx - radius, x))
    local cz  = math.max(radius, math.min(msz - radius, z))
    local found = Spring.GetUnitsInCylinder(cx, cz, radius) or {}
    local enemies = {}
    for _, uid in ipairs(found) do
        if Spring.GetUnitAllyTeam(uid) ~= myAllyTeam then
            table.insert(enemies, uid)
        end
    end
    return enemies
end

return M
