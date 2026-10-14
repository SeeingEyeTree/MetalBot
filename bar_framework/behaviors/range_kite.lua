-- bar_framework/behaviors/range_kite.lua
-- Keep the nearest enemy at the edge of OUR weapon range (user, game review 2026-10-13: "the Demon's default behaviour
-- should be kiting units at the edge of its range.  It moves at around the same speed as tanks and if it kites back it
-- can kill many more.  That is only when fighting in the open field; when defending raids they should move in front").
--
-- Per unit (not per cohort: kite.lua's one centroid for every unit with the same tunables put Demons on opposite sides
-- of the map into one "group"):
--   the nearest armed mobile ground enemy is inside edge x our range, and does NOT outrange us
--   (its range < outranged x ours: against a longer-ranged enemy backing off only feeds it free shots -- close in instead)
--   -> MOVE straight away from it to back_to x our range (at least min_step), hold for that step's travel time, then
--   hand the unit back (return nothing for it) so it fires and its controller (click_army, ...) moves it again.
-- Not while defending: ctx.Defending(uid) true (raid response / home guard) -> the unit is left to its controller.
--
-- ctx needs:  ctx.EnemiesNear(x, z, r) -> { {uid, x, z, range, value, mobile} }
-- optional:   ctx.Range(defID) -> our max weapon range   ctx.Defending(uid) -> bool   ctx.Clamp(x, z)   ctx.Speed(defID)

local M = {
    name = "range_kite",
    cfg = {
        edge           = 0.85,   -- kite when the nearest enemy is inside this share of our range
        back_to        = 0.95,   -- ...back off until it would be at this share
        min_step       = 120,    -- elmos: never a smaller step (orders have latency)
        outranged      = 1.0,    -- enemy range >= this x ours: do not kite
        scan_mult      = 1.2,    -- look for enemies within this x our range
        hold_scale     = 1.0,    -- hold for step / speed x this seconds
        speed_fallback = 50,
        range_fallback = 0,      -- our range when unknown (0: the unit is skipped)
        log_every      = 150,
    },
}

local CMD_MOVE = 10

function M.Init(st)
    st.holdUntil, st.logF, st.n = {}, -1e9, 0
end

local function Range(ctx, def, cfg)
    local r = ctx.Range and ctx.Range(def)
    if not r and UnitDefs and UnitDefs[def] then r = UnitDefs[def].maxWeaponRange end
    return (r and r > 0) and r or cfg.range_fallback
end

local function Speed(ctx, def, cfg)
    local s = ctx.Speed and ctx.Speed(def)
    if not s and UnitDefs and UnitDefs[def] then s = UnitDefs[def].speed end
    return (s and s > 0) and s or cfg.speed_fallback
end

-- The step for one unit: target x, z, the threat and its distance -- or nil (no kite).
function M.Step(cfg, u, ctx)
    local R = Range(ctx, u.def, cfg)
    if R <= 0 then return nil end
    local near, nd
    for _, e in ipairs(ctx.EnemiesNear(u.x, u.z, R * cfg.scan_mult) or {}) do
        if e.mobile then
            local d = math.sqrt((u.x - e.x) ^ 2 + (u.z - e.z) ^ 2)
            if not nd or d < nd then near, nd = e, d end
        end
    end
    if not near or nd >= cfg.edge * R or (near.range or 0) >= cfg.outranged * R then return nil end
    local step = math.max(cfg.min_step, cfg.back_to * R - nd)
    local ux, uz
    if nd > 1 then ux, uz = (u.x - near.x) / nd, (u.z - near.z) / nd
    elseif ctx.Axis then local ax, az = ctx.Axis(); ux, uz = -ax, -az
    else ux, uz = -1, 0 end
    local x, z = u.x + ux * step, u.z + uz * step
    if ctx.Clamp then x, z = ctx.Clamp(x, z) end
    return x, z, near, nd, step, R
end

function M.Update(st, group, ctx, frame, host)
    local cfg = group.cfg
    local claimed, any = {}, false
    for _, u in ipairs(group.list) do
        if not (ctx.Defending and ctx.Defending(u.uid)) then
            local x, z, near, nd, step, R = M.Step(cfg, u, ctx)
            if x then
                host:Order(frame, u.uid, CMD_MOVE, x, z)
                local hold = math.floor(step / Speed(ctx, u.def, cfg) * 30 * cfg.hold_scale)
                st.holdUntil[u.uid] = frame + hold
                if host.Hold then host:Hold(u.uid, frame + hold) end
                claimed[u.uid], any = true, true
                st.n = st.n + 1
                if frame - st.logF >= cfg.log_every then
                    st.logF = frame
                    local sec = math.floor(frame / 30)
                    Spring.Echo(string.format("[RKITE] %d:%02d unit %d back %dm: enemy at %dm (range %d vs ours %d), %d steps so far",
                        math.floor(sec / 60), sec % 60, u.uid, step, nd, near.range or 0, R, st.n))
                end
            elseif frame < (st.holdUntil[u.uid] or -1) then
                claimed[u.uid], any = true, true          -- let the step finish
            else
                st.holdUntil[u.uid] = nil
            end
        end
    end
    return any and claimed or nil
end

function M.Describe(cfg)
    return string.format("keep the nearest enemy at %d-%d%% of our range (unless it outranges us); not while defending",
        math.floor(cfg.edge * 100), math.floor(cfg.back_to * 100))
end

return M
