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
