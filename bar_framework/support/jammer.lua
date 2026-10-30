-- bar_framework/support/jammer.lua  (army_groups element: a radar jammer over a group)
-- User 2026-10-30: "Or a coreter to jam enemy radar and it might be able to move in closer without being spotted."  The jammer MOVEs BEHIND
-- elmos behind the group's centre, so its jamming radius covers the group; it has no weapon, so nothing else ever ordered one.
-- cfg: n, BEHIND, PICKS (T2 vehicle jammer first, then the T2 bot one).
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = { name = "jammer" }
M.CFG = { N = 1, BEHIND = 100, PICKS = { "jammer_veh", "jammer_bot" } }

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
    local back = rec.id == 0 and 0 or -(cfg.BEHIND or 100)
    for i, uid in ipairs(units) do
        local x, z = ctx.Spot(rec, back, i - 1, 120)
        ctx.Claim(uid, "SUP_JAMMER", ctx.CMD_MOVE, x, z, frame)
    end
end

return M
