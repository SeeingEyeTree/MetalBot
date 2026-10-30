-- bar_framework/support/aa.lua  (army_groups element: ground AA that walks with a group)
-- User 2026-10-30: "You want corsent (T2) or cormist (T1) as ground aa to support army groups ... when there are like 6 for a group it has
-- enough aa support and more do not need to be made."  The labs build the first pick any lab can make (flak truck once a T2 vehicle plant
-- stands, else the Lasher); each unit FIGHTs on a spiral BEHIND elmos behind the group's centre, so it shoots whatever flies over the group.
-- cfg: n (units per group), BEHIND, SPREAD, PICKS (role names, best first).
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = { name = "aa" }
M.CFG = { N = 6, BEHIND = 300, SPREAD = 60, PICKS = { "aa_flak_truck", "aa_t1_veh" } }

local function Names(cfg)
    local out = {}
    for _, role in ipairs(cfg.PICKS or M.CFG.PICKS) do out[#out + 1] = ROLES.Get(role) end
    return out
end

function M.Picks(cfg) return Names(cfg) end

function M.Accept(defID, born, cfg)
    local d = UnitDefs[defID]
    if not d then return false end
    for _, n in ipairs(Names(cfg)) do if d.name == n then return true end end
    return false
end

function M.Update(rec, units, cfg, frame, ctx)
    local back = rec.id == 0 and 0 or -(cfg.BEHIND or 300)      -- the pool waits on the stage point
    for i, uid in ipairs(units) do
        local x, z = ctx.Spot(rec, back, i, cfg.SPREAD)
        ctx.Claim(uid, "SUP_AA", ctx.CMD_FIGHT, x, z, frame)
    end
end

return M
