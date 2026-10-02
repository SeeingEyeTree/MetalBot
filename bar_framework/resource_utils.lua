-- bar_framework/resource_utils.lua
-- Resource querying helpers shared across bot widgets.
--
-- Load in a widget with:
--   local RU = VFS.Include("LuaUI/Widgets/bar_framework/resource_utils.lua")
--
-- All functions take a teamID argument so they work for any team (do not assume
-- both teams; a headless client reliably sees only its own team, so query your own).

local M = {}

-- Returns a snapshot table: {metal, metal_inc, metal_storage, energy, energy_inc, energy_storage}
-- Any field may be 0 if Spring.GetTeamResources returns nil (team not in game).
function M.get(teamID)
    local m, ms, _, mi = Spring.GetTeamResources(teamID, "metal")
    local e, es, _, ei = Spring.GetTeamResources(teamID, "energy")
    return {
        metal         = m  or 0,
        metal_inc     = mi or 0,
        metal_storage = ms or 0,
        energy        = e  or 0,
        energy_inc    = ei or 0,
        energy_storage = es or 0,
    }
end

-- True when the team's metal store is below `threshold` fraction of capacity.
-- Default threshold: 0.15 (15%).  Use to pause builds when metal is low.
function M.is_metal_stalling(teamID, threshold)
    threshold = threshold or 0.15
    local m, ms = Spring.GetTeamResources(teamID, "metal")
    if not m or not ms or ms == 0 then return false end
    return (m / ms) < threshold
end

-- True when the team's energy store is below `threshold` fraction of capacity.
function M.is_energy_stalling(teamID, threshold)
    threshold = threshold or 0.15
    local e, es = Spring.GetTeamResources(teamID, "energy")
    if not e or not es or es == 0 then return false end
    return (e / es) < threshold
end

-- True when both metal and energy are not stalling.
function M.is_economy_healthy(teamID)
    return not M.is_metal_stalling(teamID) and not M.is_energy_stalling(teamID)
end

-- Fraction of metal storage currently filled (0.0–1.0).
function M.metal_fill(teamID)
    local m, ms = Spring.GetTeamResources(teamID, "metal")
    if not m or not ms or ms == 0 then return 0 end
    return m / ms
end

return M
