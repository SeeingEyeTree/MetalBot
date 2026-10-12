-- bar_framework/behaviors/flank.lua
-- ARMY behaviour.  Every `every`-th unit (once the army has `min_units`) goes round the side: MOVE to a waypoint `offset`
-- elmos off the line army -> target (the side flips each `hold` frames), then FIGHT a second target away from the main
-- one (next-best build power / eco), so the enemy has to defend two places.
-- cfg: every=6 min_units=12 offset=2600 reached=600 hold=1200 min_dist=1500
-- ctx needs: shared (pick_target)  TopTargets(frame,cx,cz,k,avoid)  Clamp(x,z)
local M = { name = "flank", cfg = { every = 6, min_units = 12, offset = 2600, reached = 600, hold = 1200, min_dist = 1500 } }

function M.Init(st) st.done = {} end

function M.Update(st, group, ctx, frame, host)
    local sh, c = ctx.shared, st.cfg
    if (sh.n or 0) < c.min_units then return nil end
    local ux, uz = sh.tx - sh.cx, sh.tz - sh.cz
    local d = math.sqrt(ux * ux + uz * uz)
    if d < c.min_dist then return nil end
    ux, uz = ux / d, uz / d
    local side = (math.floor(frame / c.hold) % 2 == 0) and 1 or -1
    local wx, wz = ctx.Clamp(sh.tx - ux * 1200 - uz * side * c.offset, sh.tz - uz * 1200 + ux * side * c.offset)
    local second = (sh.targets and sh.targets[2]) or ctx.TopTargets(frame, sh.cx, sh.cz, 1, sh.target)[1]
    local claimed = {}
    for i, u in ipairs(group.list) do
        if i % c.every == 0 then
            if not st.done[u.uid] and math.sqrt((u.x - wx) ^ 2 + (u.z - wz) ^ 2) > c.reached then
                host:Order(frame, u.uid, 10, wx, wz)
            else
                st.done[u.uid] = true
                host:Order(frame, u.uid, 16, second and second.x or sh.tx, second and second.z or sh.tz)
            end
            claimed[u.uid] = true
        end
    end
    return claimed
end

function M.Describe(cfg) return string.format("1 in %d units circles %d elmos wide and hits a second target", cfg.every, cfg.offset) end
return M
