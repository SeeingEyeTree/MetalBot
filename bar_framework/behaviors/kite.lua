-- bar_framework/behaviors/kite.lua
-- Back away from anything that is closing on the group, then hand the units back (to the next behaviour in their
-- stack, e.g. "advance") once the step is done.  Replaces slow_front's Chargers rule, which only fired on enemies
-- closing at >= 55 elmos/s (fast units).  Here ANY approaching enemy counts, weighted by what it is worth:
--   an enemy threatens when it is closing at >= min_closing elmos/s and can reach firing range within trigger_ttc s
--   (time to contact = (distance - its weapon range) / closing speed; already inside its range counts as 0 s);
--   the group backs off when the threats' summed value is >= min_threat_frac of the group's value, so a lone scout
--   does not push eight Lashers around, and the step grows with the threat ratio up to `step` at full_ratio.
--
-- ctx needs:  ctx.EnemiesNear(x, z, r) -> { {uid, x, z, range, value, mobile, vx, vz (elmos/s)} ... }
-- optional:   ctx.Axis() -> ux, uz (home -> foe; used when the threats' centre sits on the group)
--             ctx.Clamp(x, z) -> x, z      ctx.Speed(defID) -> elmos/s
-- Tunables (all overridable per assignment): see cfg.

local M = {
    name = "kite",
    cfg = {
        scan_r          = 1100,  -- look for threats this far from the group core
        trigger_ttc     = 4.0,   -- s: back off when a threat can be in range within this long
        min_closing     = 8,     -- elmos/s along the line to the nearest unit: slower than this is not "approaching"
        min_threat_frac = 0.10,  -- summed threat value / group value needed to react
        full_ratio      = 0.50,  -- threat ratio at which the full step is used
        step            = 400,   -- elmos backed off at full ratio
        step_min        = 150,   -- elmos backed off at min_threat_frac
        hold_scale      = 0.8,   -- hold (not re-advance) for step / slowest speed * hold_scale seconds
        speed_fallback  = 50,    -- elmos/s when a unit's speed is unknown
        mobile_only     = true,  -- ignore static defences (they do not approach anyway)
        log_every       = 90,    -- frames between "[KITE]" log rows
    },
}

local function Norm(x, z, fx, fz)
    local d = math.sqrt(x * x + z * z)
    if d < 1e-6 then return fx, fz end
    return x / d, z / d
end

function M.Init(st)
    st.backF, st.hold, st.logF, st.n = -1e9, 0, -1e9, 0
end

local function Speed(ctx, def, cfg)
    local s = ctx.Speed and ctx.Speed(def)
    if not s and UnitDefs and UnitDefs[def] then s = UnitDefs[def].speed end
    return (s and s > 0) and s or cfg.speed_fallback
end

-- The enemies that threaten the group.  Returns the list and its total value.
function M.Threats(cfg, group, ctx)
    local out, value = {}, 0
    for _, e in ipairs(ctx.EnemiesNear(group.cx, group.cz, cfg.scan_r) or {}) do
        if e.mobile or not cfg.mobile_only then
            local best, bd
            for _, u in ipairs(group.list) do
                local d = math.sqrt((u.x - e.x) ^ 2 + (u.z - e.z) ^ 2)
                if not bd or d < bd then best, bd = u, d end
            end
            if best and bd > 1 then
                local closing = (e.vx or 0) * (best.x - e.x) / bd + (e.vz or 0) * (best.z - e.z) / bd
                if closing >= cfg.min_closing and math.max(0, bd - (e.range or 0)) <= closing * cfg.trigger_ttc then
                    out[#out + 1] = e
                    value = value + (e.value or 0)
                    e.closing, e.dist = closing, bd
                end
            end
        end
    end
    return out, value
end

function M.Update(st, group, ctx, frame, host)
    local cfg = group.cfg
    local threats, tv = M.Threats(cfg, group, ctx)
    local ratio = group.value > 0 and tv / group.value or 0

    if #threats > 0 and ratio >= cfg.min_threat_frac then
        local tx, tz, tw = 0, 0, 0
        for _, e in ipairs(threats) do
            local w = math.max(1, e.value or 1)
            tx, tz, tw = tx + e.x * w, tz + e.z * w, tw + w
        end
        local fx, fz = -1, 0
        if ctx.Axis then local ax, az = ctx.Axis(); fx, fz = -ax, -az end
        local bx, bz = Norm(group.cx - tx / tw, group.cz - tz / tw, fx, fz)
        local k = math.min(1, ratio / cfg.full_ratio)
        local step = cfg.step_min + (cfg.step - cfg.step_min) * k
        local slow = 1e9
        for _, u in ipairs(group.list) do slow = math.min(slow, Speed(ctx, u.def, cfg)) end
        st.backF, st.hold, st.n = frame, math.floor(step / slow * 30 * cfg.hold_scale), st.n + 1
        if frame - st.logF >= cfg.log_every then
            st.logF = frame
            local c = threats[1]
            Spring.Echo(string.format("[KITE] %d back %dm: %d threat(s), first closing %.0f/s at %dm, value %d vs %d",
                math.floor(frame / 30), step, #threats, c.closing or 0, c.dist or 0, tv, group.value))
        end
        host:Translate(frame, group.list, group.cx, group.cz, bx, bz, step, host.CMD_MOVE or 10, ctx.Clamp)
        if host.Hold then for _, u in ipairs(group.list) do host:Hold(u.uid, frame + st.hold) end end
        return true
    elseif frame - st.backF < st.hold then
        return true                                   -- let the back step finish
    end
    return nil
end

function M.Describe(cfg)
    return string.format("back off %d-%d elmos from any enemy that reaches range within %.1fs (threat >= %d%% of group)",
        cfg.step_min, cfg.step, cfg.trigger_ttc, math.floor(cfg.min_threat_frac * 100))
end

return M
