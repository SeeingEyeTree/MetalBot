-- bar_framework/behaviors/stun_target.lua
-- Spread a pack of focus-fire units over the enemies near it.  Extracted from unit_controller's AssignStuns, which
-- ran it for Shurikens (stun) and Wasps (damage) with two config tables; here they are two assignments of one
-- behaviour:  Assign(uid, "stun_target", {stuns = true, ...})  /  Assign(uid, "stun_target", {stuns = false, r = 1500,
-- hp_per = 900, need_min = 1, need_max = 8}).
--
-- Stunners (stuns = true): an unstunned target gets `need` units (need_min..need_max by its max health / hp_per), a
-- stunned one keeps a single keeper, the spare units spread over the still-moving targets.  Damage dealers
-- (stuns = false): every target counts as moving, `need` is by CURRENT health, targets are ranked by value per unit
-- committed and the spare pile onto the best three.  Assignments stick while they still fit.
--
-- ctx needs:  ctx.TargetsNear(x, z, r) -> { {id, hp, mhp, para, value} ... } (mobile, visible, enemy)
-- Returns nil when nothing is in reach, so the unit falls through to the next behaviour in its stack.

local M = {
    name = "stun_target",
    cfg = {
        stuns     = true,
        r         = 1200,    -- elmos around the pack to look for targets
        hp_per    = 700,     -- health one unit is worth when sizing a target's crew
        need_min  = 2,
        need_max  = 6,
        log_every = 900,
        tag       = "stun",
    },
}

local CMD_ATTACK = (CMD and CMD.ATTACK) or 20

function M.Init(st)
    st.target, st.logF = {}, -1e9
end

function M.Update(st, group, ctx, frame, host)
    local cfg, list = group.cfg, group.list
    local found = ctx.TargetsNear(group.cx, group.cz, cfg.r) or {}
    local targets, byId = {}, {}
    for _, e in ipairs(found) do
        if e.mhp and e.mhp > 0 then
            local t = { id = e.id, mhp = e.mhp, v = e.value or 0, have = {},
                        stunned = cfg.stuns and (e.para or 0) > e.mhp or false }
            if cfg.stuns then
                t.need = t.stunned and 1 or math.max(cfg.need_min, math.min(cfg.need_max, math.ceil(e.mhp / cfg.hp_per)))
            else
                t.need = math.max(cfg.need_min, math.min(cfg.need_max, math.ceil((e.hp or e.mhp) / cfg.hp_per)))
                t.score = t.v / t.need            -- value killed per unit committed
            end
            targets[#targets + 1] = t
            byId[t.id] = t
        end
    end
    if #targets == 0 then
        for _, u in ipairs(list) do st.target[u.uid] = nil end
        return nil
    end
    -- unstunned (still moving) first, then the most valuable
    table.sort(targets, function(a, b)
        if a.stunned ~= b.stunned then return not a.stunned end
        if a.score and b.score and a.score ~= b.score then return a.score > b.score end
        if a.v ~= b.v then return a.v > b.v end
        return a.id < b.id
    end)
    -- keep sticky assignments that still fit
    local free = {}
    for _, u in ipairs(list) do
        local t = byId[st.target[u.uid] or -1]
        if t and #t.have < t.need then t.have[#t.have + 1] = u else free[#free + 1] = u end
    end
    -- fill what is still needed, nearest unit first
    local pos = {}
    for _, e in ipairs(found) do pos[e.id] = e end
    for _, t in ipairs(targets) do
        if #free == 0 then break end
        local e = pos[t.id]
        while #t.have < t.need and #free > 0 do
            local bi, bd
            for i, u in ipairs(free) do
                local d = e and e.x and ((u.x - e.x) ^ 2 + (u.z - e.z) ^ 2) or 0
                if not bd or d < bd then bi, bd = i, d end
            end
            t.have[#t.have + 1] = table.remove(free, bi)
        end
    end
    -- spare units: round-robin over the unstunned targets (never pile onto a stunned one)
    local moving = {}
    for _, t in ipairs(targets) do if not t.stunned then moving[#moving + 1] = t end end
    if not cfg.stuns then while #moving > 3 do table.remove(moving) end end
    local k = 0
    while #free > 0 and #moving > 0 do
        k = k % #moving + 1
        moving[k].have[#moving[k].have + 1] = table.remove(free, 1)
    end
    local nStun, nMove, claimed = 0, 0, {}
    for _, t in ipairs(targets) do
        for _, u in ipairs(t.have) do
            st.target[u.uid] = t.id
            host:Order(frame, u.uid, CMD_ATTACK, nil, nil, t.id)
            claimed[u.uid] = true
        end
        if t.stunned then nStun = nStun + 1 else nMove = nMove + 1 end
    end
    if frame - st.logF >= cfg.log_every then
        st.logF = frame
        local sec = math.floor(frame / 30)
        Spring.Echo(string.format("[BH/%s] %d:%02d %d units on %d targets (%d stunned, %d still moving)",
            cfg.tag, math.floor(sec / 60), sec % 60, #list, #targets, nStun, nMove))
    end
    return claimed
end

function M.Describe(cfg)
    return cfg.stuns and "stun the nearest enemies, one keeper on each stunned one, the rest on moving ones"
        or "split damage dealers over the best few kills by value per unit committed"
end

return M
