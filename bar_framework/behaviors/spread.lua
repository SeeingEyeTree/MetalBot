-- bar_framework/behaviors/spread.lua
-- ARMY behaviour.  No resistance (enemy armed value at the main target, around the army AND at each chosen target all
-- <= `open` x the army's value): every `every`-th unit splits over the best targets (build power / eco first), at least
-- `group` units each, instead of everyone hitting one.  The rest keep the main target.  Reads "no resistance" from what
-- is SEEN, so a fogged base reads empty -- hence the extra checks and the half-army cap.
-- cfg: open=0.15 min_av=1500 k=6 group=12 every=2
-- ctx needs: shared (pick_target)  TopTargets  ThreatAt
local M = { name = "spread", cfg = { open = 0.15, min_av = 1500, k = 6, group = 12, every = 2 } }

function M.Update(st, group, ctx, frame, host)
    local sh, c = ctx.shared, st.cfg
    local total = sh.total or 0
    if total < c.min_av or (sh.enemyV or 0) > c.open * total then return nil end
    if (ctx.ThreatAt(frame, sh.cx, sh.cz) or 0) > c.open * total then return nil end
    local want = math.min(c.k, math.floor((sh.n or 0) / c.every / c.group))
    if want < 2 then return nil end
    local targets = {}
    for _, t in ipairs(ctx.TopTargets(frame, sh.cx, sh.cz, want, nil)) do
        if (ctx.ThreatAt(frame, t.x, t.z) or 0) <= c.open * total then targets[#targets + 1] = t end
    end
    if #targets < 2 then return nil end
    local claimed = {}
    for i, u in ipairs(group.list) do
        if i % c.every == 1 % c.every then
            local t = targets[(math.floor(i / c.every) % #targets) + 1]
            host:Order(frame, u.uid, 16, t.x, t.z)
            claimed[u.uid] = true
        end
    end
    return claimed
end

function M.Describe(cfg) return string.format("no resistance: 1 in %d units splits over up to %d targets", cfg.every, cfg.k) end
return M
