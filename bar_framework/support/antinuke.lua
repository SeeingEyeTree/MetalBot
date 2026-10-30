-- bar_framework/support/antinuke.lua  (army_groups element: a mobile anti-nuke with a group in the open field)
-- User 2026-10-30: "It could also have a cormabm near it to make sure it does not get nuked on the open field."  The Savior MOVEs BEHIND elmos
-- behind the group's centre (its interceptor covers ~1200 round it).  defense_crew.lua keeps stockpiling it but no longer moves a Savior this
-- element owns (WG.ArmyGroups.Owns).  SILO_ONLY (default): wanted only once an enemy nuke silo has been scouted (WG.MetalBot.intel.silos).
-- cfg: n, BEHIND, SILO_ONLY, PICKS.
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = { name = "antinuke" }
M.CFG = { N = 1, BEHIND = 200, SILO_ONLY = true, PICKS = { "savior" } }

local function Names(cfg)
    local out = {}
    for _, role in ipairs(cfg.PICKS or M.CFG.PICKS) do out[#out + 1] = ROLES.Get(role) end
    return out
end

function M.Picks(cfg) return Names(cfg) end

function M.Gate(cfg, ctx)
    if not cfg.SILO_ONLY then return true end
    local mb = ctx.WG and ctx.WG.MetalBot
    return mb ~= nil and mb.intel ~= nil and (mb.intel.silos or 0) > 0
end

function M.Accept(defID, born, cfg)
    local d = UnitDefs[defID]
    if not d then return false end
    for _, n in ipairs(Names(cfg)) do if d.name == n then return true end end
    return false
end

function M.Update(rec, units, cfg, frame, ctx)
    local back = rec.id == 0 and 0 or -(cfg.BEHIND or 200)
    for i, uid in ipairs(units) do
        local x, z = ctx.Spot(rec, back, i - 1, 80)
        ctx.Claim(uid, "SUP_ANTINUKE", ctx.CMD_MOVE, x, z, frame)
    end
end

return M
