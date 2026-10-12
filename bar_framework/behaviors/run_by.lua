-- bar_framework/behaviors/run_by.lua
-- ARMY behaviour.  A big army (>= `min_n` units, or army value >= `ratio` x the enemy's armed value at the target, and at
-- least `min_av`) sends every `every`-th unit on MOVE straight to the target -- past the defence, not stopping to shoot --
-- and switches it to FIGHT once it is within `fight_r` of the target.
-- cfg: min_n=40 ratio=3 min_av=2500 fight_r=700 every=2
-- ctx needs: shared (pick_target)
local M = { name = "run_by", cfg = { min_n = 40, ratio = 3.0, min_av = 2500, fight_r = 700, every = 2 } }

function M.Update(st, group, ctx, frame, host)
    local sh, c = ctx.shared, st.cfg
    local total = sh.total or 0
    if total < c.min_av or not ((sh.n or 0) >= c.min_n or total >= c.ratio * (sh.enemyV or 0)) then return nil end
    local claimed = {}
    for i, u in ipairs(group.list) do
        if i % c.every == 0 and math.sqrt((u.x - sh.tx) ^ 2 + (u.z - sh.tz) ^ 2) > c.fight_r then
            host:Order(frame, u.uid, 10, sh.tx, sh.tz)
            claimed[u.uid] = true
        end
    end
    return claimed
end

function M.Describe(cfg) return string.format("big army: 1 in %d units runs past the defence on MOVE", cfg.every) end
return M
