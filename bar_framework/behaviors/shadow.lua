-- bar_framework/behaviors/shadow.lua
-- A fast unit (Rascal / corfav, or anything quicker and longer-sighted than the early enemy units) that tails the enemy
-- and keeps it at the EDGE OF ITS VISION: close enough that the enemy stays in line of sight (so the bot keeps tracking
-- it), far enough that the unit is beyond what it can shoot.  Per unit (not per cohort):
--   enemy in view   nearest armed enemy closer than edge-band of our sight  -> MOVE straight away (from all enemies near,
--                                                                              weighted by 1/distance) to edge x sight
--                   farther than edge+band                                  -> close in to edge x sight
--                   in between                                              -> hold (stand still; re-issued as a MOVE onto itself)
--   radar dot       (nothing in sight) go and look: move to the edge of sight of the nearest ground dot
--   enemy lost      go to where it was last seen (up to lost_for frames), to edge x sight of that spot
--   nothing known   PATROL: each shadow sweeps its own lane in a fan round the bearing to the enemy base, out and back between
--                   patrol_min and patrol_max from the army (never past patrol_cap of the way to the enemy), so it finds groups
--                   before they reach the perimeter.  patrol = false: ride `lead` elmos ahead of the army instead.
--   hurt            below flee_hp health -> back to the army
-- `max` limits how many units of a cohort shadow (the rest are left to the other controllers); 0 = all.
--
-- ctx needs:  ctx.EnemiesNear(x, z, r) -> { {uid, x, z, range, ...} }  (visible armed enemies)
-- optional:   ctx.Sight(defID)  ctx.Friends() -> { {uid, x, z, value} } own armed mobile units   ctx.Axis()  ctx.Clamp(x, z)
--             ctx.Speed(defID)

local M = {
    name = "shadow",
    cfg = {
        edge           = 0.85,   -- keep the nearest enemy at this share of our sight radius
        band           = 0.06,   -- dead zone either side of it (no jitter)
        scan_mult      = 1.3,    -- look for enemies within this x our sight (units on radar-only are not seen)
        min_step       = 80,     -- elmos: never a smaller move (orders have latency)
        hold_frames    = 20,     -- other controllers keep their hands off for this long after each order
        lost_for       = 900,    -- frames to chase the last seen spot
        lead           = 700,    -- elmos ahead of the friendly army toward the enemy when nothing is known
        follow_r       = 250,    -- elmos: close enough to the lead point -> stand
        flee_hp        = 0.4,    -- health share below which it retreats to the army
        max            = 0,      -- shadows per cohort (0 = all of them)
        sight_fallback = 450,
        blip_r         = 3500,   -- elmos: a radar dot this near (and nothing in sight) is worth a look
        patrol         = true,   -- nothing known: sweep the lanes toward the enemy (false = ride `lead` ahead of the army)
        patrol_min     = 1200,   -- elmos from the army: the sweep goes out and back between these
        patrol_max     = 3400,
        patrol_fan     = 0.9,    -- radians either side of the enemy bearing the shadows are spread over
        patrol_period  = 70,     -- seconds for one out-and-back
        patrol_cap     = 0.45,   -- never further than this share of the way to the enemy base
        log_every      = 300,
        pos_every      = 900,    -- frames between position rows ([SHADOW] ... at (x, z)) per shadow
    },
}

local CMD_MOVE = 10

function M.Init(st)
    st.seen, st.logF, st.mode, st.posF = {}, -1e9, {}, {}
end

local function Sight(ctx, def, cfg)
    local s = ctx.Sight and ctx.Sight(def)
    if not s and UnitDefs and UnitDefs[def] then s = UnitDefs[def].losRadius end
    return (s and s > 0) and s or cfg.sight_fallback
end

local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

-- The point at distance `want` from (tx, tz) on the line from (tx, tz) through (ux, uz).
local function Ring(tx, tz, ux, uz, want)
    local d = Dist(ux, uz, tx, tz)
    if d < 1 then return tx + want, tz end
    return tx + (ux - tx) / d * want, tz + (uz - tz) / d * want
end

-- The step for one unit: x, z, mode, enemy distance (or nil, nil for "nothing to do").  Pure -- the tests call it.
-- anchor = { x, z } of the friendly army (or nil); seen = { x, z, f } last seen enemy spot (or nil).
function M.Step(cfg, u, ctx, frame, anchor, seen, idx, count)
    local S = Sight(ctx, u.def, cfg)
    local want = S * cfg.edge
    local foes = ctx.EnemiesNear(u.x, u.z, S * cfg.scan_mult) or {}
    local near, nd
    for _, e in ipairs(foes) do
        local d = Dist(u.x, u.z, e.x, e.z)
        if not nd or d < nd then near, nd = e, d end
    end

    if u.hp < cfg.flee_hp and anchor then
        return anchor.x, anchor.z, "flee", nd
    end

    if near then
        if nd < S * (cfg.edge - cfg.band) then
            -- away from every enemy in reach, the close ones counting most
            local ax, az = 0, 0
            for _, e in ipairs(foes) do
                local d = math.max(Dist(u.x, u.z, e.x, e.z), 1)
                ax, az = ax + (u.x - e.x) / d / d, az + (u.z - e.z) / d / d
            end
            local n = math.sqrt(ax * ax + az * az)
            if n < 1e-9 then ax, az, n = 1, 0, 1 end
            local step = math.max(cfg.min_step, want - nd)
            return u.x + ax / n * step, u.z + az / n * step, "back", nd, near
        elseif nd > S * (cfg.edge + cfg.band) then
            local x, z = Ring(near.x, near.z, u.x, u.z, want)
            return x, z, "close", nd, near
        end
        return u.x, u.z, "hold", nd, near
    end

    if seen and frame - seen.f <= cfg.lost_for then
        local x, z = Ring(seen.x, seen.z, u.x, u.z, want)
        return x, z, "lost", nil
    end

    if ctx.BlipsNear and cfg.blip_r > 0 then       -- nothing in sight but a radar dot: go and look at it, to the edge of our sight
        local best, bd
        for _, b in ipairs(ctx.BlipsNear(u.x, u.z, cfg.blip_r) or {}) do
            local d = Dist(u.x, u.z, b.x, b.z)
            if not bd or d < bd then best, bd = b, d end
        end
        if best and bd > S * (cfg.edge + cfg.band) then
            local x, z = Ring(best.x, best.z, u.x, u.z, want)
            return x, z, "investigate", bd
        end
    end

    if anchor and cfg.patrol then
        -- the lanes: shadow i of n takes a bearing in the fan round the enemy's, and goes out and back along it, each on its own phase
        local ux, uz = 1, 0
        local ex, ez
        if ctx.EnemyBase then ex, ez = ctx.EnemyBase() end
        if ex then
            local dx, dz = ex - anchor.x, ez - anchor.z
            local l = math.max(math.sqrt(dx * dx + dz * dz), 1)
            ux, uz = dx / l, dz / l
        elseif ctx.Axis then ux, uz = ctx.Axis() end
        idx, count = idx or 1, math.max(count or 1, 1)
        local a = math.atan2(uz, ux) + cfg.patrol_fan * (((idx - 0.5) / count - 0.5) * 2)
        local hi = cfg.patrol_max
        if ex then hi = math.min(hi, cfg.patrol_cap * Dist(anchor.x, anchor.z, ex, ez)) end
        local lo = math.min(cfg.patrol_min, hi)
        local ph = idx * 2.1
        local R = lo + (hi - lo) * (0.5 + 0.5 * math.sin(2 * math.pi * (frame / 30) / cfg.patrol_period + ph))
        return anchor.x + math.cos(a) * R, anchor.z + math.sin(a) * R, "patrol", nil
    end

    if anchor then
        local ux, uz = 1, 0
        if ctx.Axis then ux, uz = ctx.Axis() end
        local x, z = anchor.x + ux * cfg.lead, anchor.z + uz * cfg.lead
        if Dist(u.x, u.z, x, z) <= cfg.follow_r then return u.x, u.z, "follow_hold", nil end
        return x, z, "follow", nil
    end
    return nil
end

local function Anchor(ctx, host)
    if not ctx.Friends then return nil end
    local sx, sz, sv = 0, 0, 0
    for _, f in ipairs(ctx.Friends() or {}) do
        local names = host.Behaviours_Of and host:Behaviours_Of(f.uid)
        local shadow = false
        for _, n in ipairs(names or {}) do if n == "shadow" then shadow = true end end
        if not shadow then
            local w = math.max(f.value or 1, 1)
            sx, sz, sv = sx + f.x * w, sz + f.z * w, sv + w
        end
    end
    if sv <= 0 then return nil end
    return { x = sx / sv, z = sz / sv }
end

function M.Update(st, group, ctx, frame, host)
    local cfg = group.cfg
    local anchor = Anchor(ctx, host)
    local claimed, any = {}, false
    local count = cfg.max > 0 and math.min(cfg.max, #group.list) or #group.list
    for i, u in ipairs(group.list) do
        if cfg.max <= 0 or i <= cfg.max then
            local x, z, mode, nd, near = M.Step(cfg, u, ctx, frame, anchor, st.seen[u.uid], i, count)
            if near then st.seen[u.uid] = { x = near.x, z = near.z, f = frame } end
            if x then
                if ctx.Clamp then x, z = ctx.Clamp(x, z) end
                host:Order(frame, u.uid, CMD_MOVE, x, z)
                if host.Hold then host:Hold(u.uid, frame + cfg.hold_frames) end
                claimed[u.uid], any = true, true
                if st.mode[u.uid] ~= mode and frame - st.logF >= cfg.log_every then
                    st.logF = frame
                    local sec = math.floor(frame / 30)
                    Spring.Echo(string.format("[SHADOW] %d:%02d unit %d %s%s", math.floor(sec / 60), sec % 60, u.uid, mode,
                        nd and string.format(" (enemy at %dm of %dm sight)", nd, Sight(ctx, u.def, cfg)) or ""))
                end
                st.mode[u.uid] = mode
                if frame - (st.posF[u.uid] or -1e9) >= cfg.pos_every then
                    st.posF[u.uid] = frame
                    local sec = math.floor(frame / 30)
                    Spring.Echo(string.format("[SHADOW] %d:%02d unit %d %s at (%d, %d), ordered to (%d, %d), %d from the army",
                        math.floor(sec / 60), sec % 60, u.uid, mode, u.x, u.z, x, z, anchor and Dist(u.x, u.z, anchor.x, anchor.z) or -1))
                end
            end
        end
    end
    return any and claimed or nil
end

function M.Describe(cfg)
    return string.format("tail the nearest enemy at %d%% of our sight radius; ride ahead of the army when none is in view",
        math.floor(cfg.edge * 100))
end

return M
