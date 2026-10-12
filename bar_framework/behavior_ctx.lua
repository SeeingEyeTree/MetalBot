-- bar_framework/behavior_ctx.lua
-- The ctx behavior_host hands to behaviours, built from the framework's own modules (unit_query, map_model):
--   EnemiesNear(x, z, r) -> { {uid, x, z, range, value, mobile, vx, vz (elmos/s)} }  armed enemies that can hit ground
--   TargetsNear(x, z, r) -> { {id, x, z, hp, mhp, para, value} }                      visible mobile enemies
--   Axis() -> ux, uz (home -> foe)    Clamp(x, z)    Speed(defID)
-- One ctx per unit controller; `New` takes the modules, nothing is global.

local M = {}

function M.New(o)
    local UQ, MM, allyID = o.UQ, o.MM, o.allyID or 0
    local ctx = {}

    function ctx.EnemiesNear(x, z, r)
        local out = {}
        for _, uid in ipairs(UQ.enemies_near(x, z, r, allyID) or {}) do
            local defID = Spring.GetUnitDefID(uid)
            if defID and UQ.has_weapons(defID) and not UQ.is_air(defID) and UQ.can_hit_ground(defID)
               and not UQ.is_scout(defID) then
                local ex, _, ez = Spring.GetUnitPosition(uid)
                if ex then
                    local vx, vz = 0, 0
                    if Spring.GetUnitVelocity then
                        local a, _, b = Spring.GetUnitVelocity(uid)
                        vx, vz = (a or 0) * 30, (b or 0) * 30      -- Spring reports elmos per frame
                    end
                    out[#out + 1] = { uid = uid, x = ex, z = ez, range = UQ.max_weapon_range(defID),
                                      value = UQ.metal_cost(defID) or 0, mobile = UQ.is_mobile(defID), vx = vx, vz = vz }
                end
            end
        end
        return out
    end

    function ctx.TargetsNear(x, z, r)
        local out = {}
        for _, eid in ipairs(Spring.GetUnitsInCylinder(x, z, r) or {}) do
            local defID = Spring.GetUnitDefID(eid)
            if defID and Spring.GetUnitAllyTeam(eid) ~= allyID and UQ.is_mobile(defID) then
                local hp, mhp, para = Spring.GetUnitHealth(eid)
                if hp and mhp and mhp > 0 then
                    local ex, _, ez = Spring.GetUnitPosition(eid)
                    local d = UnitDefs[defID]
                    out[#out + 1] = { id = eid, x = ex, z = ez, hp = hp, mhp = mhp, para = para or 0,
                                      value = d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0 }
                end
            end
        end
        return out
    end

    function ctx.Axis() return MM.Axis() end
    function ctx.Clamp(x, z) return MM.Clamp(x, z, o.margin or 150) end
    function ctx.Speed(defID) return UQ.max_speed and UQ.max_speed(defID) or nil end
    return ctx
end

return M
