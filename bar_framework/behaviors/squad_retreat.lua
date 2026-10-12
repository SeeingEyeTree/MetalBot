-- bar_framework/behaviors/squad_retreat.lua
-- ARMY behaviour (ported from click_army's UpdateSquads).  A hurt squad pulls back: <= squad_max units within `radius` of
-- each other, average health under `hp`, with more enemy armed value near them than they are worth, retreat toward home
-- (10% along home -> foe) at RETREAT priority (so it outranks the other army behaviours).  They are released at `release`
-- health, or once nothing armed is near and `calm_frames` have passed.  Put it FIRST in the stack so a retreating unit is
-- claimed before pick_target counts it.
-- The squad table is the unit controller's too (ctx.squad = click_army's squad; IsSquadRetreating reads it).
-- cfg: squad_max=6 hp=0.6 release=0.85 radius=600 near_r=900 calm_frames=450
-- ctx needs: squad  ArmedValueNear(frame,x,z,r)  Retreat(frame,uid)  EndRetreat(uid)  Log
local M = { name = "squad_retreat", cfg = { squad_max = 6, hp = 0.60, release = 0.85, radius = 600, near_r = 900, calm_frames = 450 } }

function M.Update(st, group, ctx, frame)
    local c, squad = st.cfg, ctx.squad
    local byUid = {}
    for _, u in ipairs(group.list) do byUid[u.uid] = u end
    local claimed = {}
    -- squads already retreating
    for uid, since in pairs(squad) do
        local u = byUid[uid]
        if not u then
            if Spring.GetUnitDefID(uid) == nil then squad[uid] = nil end
        else
            local calm = ctx.ArmedValueNear(frame, u.x, u.z, c.near_r) <= 0
            if u.hp >= c.release or (calm and frame - since > c.calm_frames) then
                ctx.EndRetreat(uid)
                squad[uid] = nil
            else
                ctx.Retreat(frame, uid)
                claimed[uid] = true
            end
        end
    end
    -- new ones among the units not already in a squad
    local free, taken = {}, {}
    for _, u in ipairs(group.list) do if not squad[u.uid] then free[#free + 1] = u end end
    for _, a in ipairs(free) do
        if not taken[a.uid] then
            local members, sumHp, val = {}, 0, 0
            for _, b in ipairs(free) do
                if not taken[b.uid] and math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) <= c.radius then
                    members[#members + 1] = b; sumHp = sumHp + b.hp; val = val + b.v
                end
            end
            for _, b in ipairs(members) do taken[b.uid] = true end
            if #members <= c.squad_max and sumHp / #members < c.hp and ctx.ArmedValueNear(frame, a.x, a.z, c.near_r) > val then
                for _, b in ipairs(members) do
                    squad[b.uid] = frame
                    ctx.Retreat(frame, b.uid)
                    claimed[b.uid] = true
                end
                ctx.Log(frame, "squad retreat n=%d hp=%.2f", #members, sumHp / #members)
            end
        end
    end
    return claimed
end

function M.Describe(cfg) return string.format("squads of <= %d under %d%% health with enemies near pull back", cfg.squad_max, cfg.hp * 100) end
return M
