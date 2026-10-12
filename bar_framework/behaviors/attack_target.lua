-- bar_framework/behaviors/attack_target.lua
-- ARMY behaviour, LAST in an army stack: every unit nobody else claimed FIGHTs to one of pick_target's targets.  With more
-- than one target the units are split by cfg.weights (target 1 gets the biggest share: 50 / 30 / 20 %); while target 1 is
-- build power near an enemy lab, `lab_share` of the units go to it first.  No stage, no group, no waiting.
-- cfg: weights = { 0.5, 0.3, 0.2 }   lab_share = 0.7
-- ctx needs: shared (pick_target)
local M = { name = "attack_target", cfg = { weights = { 0.5, 0.3, 0.2 }, lab_share = 0.7 } }

function M.Update(st, group, ctx, frame, host)
    local sh, c = ctx.shared, st.cfg
    if not sh.tx then return nil end
    local ts = sh.targets or {}
    local k = #ts
    local w = {}
    if k > 1 then
        local sum = 0
        for i = 1, k do w[i] = (c.weights[i] or c.weights[#c.weights] or 1); sum = sum + w[i] end
        if sh.labBP and c.lab_share then          -- the lab's build power gets most of the army
            local rest = 0
            for i = 2, k do rest = rest + w[i] end
            for i = 2, k do w[i] = w[i] / rest * (1 - c.lab_share) end
            w[1] = c.lab_share
            sum = 1
        end
        for i = 1, k do w[i] = w[i] / sum end
    end
    local n = #group.list
    for i, u in ipairs(group.list) do
        local t, tx, tz = nil, sh.tx, sh.tz
        if k > 1 then
            local p, acc = (i - 0.5) / n, 0
            for j = 1, k do
                acc = acc + w[j]
                if p <= acc or j == k then t = ts[j]; break end
            end
            tx, tz = t.x, t.z
        end
        host:Order(frame, u.uid, 16, tx, tz)
    end
    return true
end

function M.Describe() return "everything left FIGHTs to the shared targets, split 50/30/20 (70% on lab build power)" end
return M
