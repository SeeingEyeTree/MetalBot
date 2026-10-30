-- bar_framework/support/spam.lua  (army_groups element: cheap bots run ahead of a group for vision and to soak the first shots)
-- User 2026-10-30: "a spam support element that is just a bot lab with 4 nanos that always makes grunts and it just sends those grunts ahead
-- of the group to get vision and tank enemy shots."  The lab is line_transition/spam_lab.lua (built once any record opts into spam:
-- WG.ArmyGroups.SpamWanted()); lab_rules' "spam-lab" want fills it while the element is short.  Only units BORN in that lab are spam (a
-- Grunt from any other lab is an ordinary army unit).  Each spam unit FIGHTs AHEAD elmos in front of the group's centre, spread across it;
-- one that dies is simply replaced by the next out of the lab.
-- cfg: n (units per group), AHEAD, SPREAD, UNIT (role).
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = { name = "spam" }
M.CFG = { N = 6, AHEAD = 500, SPREAD = 90, UNIT = "grunt" }

function M.Picks(cfg) return { ROLES.Get(cfg.UNIT or M.CFG.UNIT) } end     -- what the spam lab makes (lab_rules "spam-lab")

function M.Accept(defID, born, cfg, ctx)
    local lab = ctx.WG and ctx.WG.SpamLab
    return born ~= nil and lab ~= nil and lab.id == born
end

function M.Update(rec, units, cfg, frame, ctx)
    local ahead = rec.id == 0 and 0 or (cfg.AHEAD or 500)       -- the pool waits on the stage point for the next group
    local cmd = rec.id == 0 and ctx.CMD_MOVE or ctx.CMD_FIGHT
    for i, uid in ipairs(units) do
        local x, z = ctx.Spot(rec, ahead, i, cfg.SPREAD)
        ctx.Claim(uid, "SUP_SPAM", cmd, x, z, frame)
    end
end

return M
