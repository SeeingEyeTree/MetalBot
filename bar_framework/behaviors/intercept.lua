-- bar_framework/behaviors/intercept.lua
-- Answer a raid by getting IN FRONT of the raiders, not by chasing them.  A FIGHT order to where the raiders are now
-- arrives behind a fast raider every time; a MOVE to where it is GOING lands between it and what it is after.
--   moving raiders   each responder MOVEs to the point where it can meet the raiders' path: the raiders' predicted position
--                    (their velocity, t seconds on) pushed `lead` elmos further along raider -> asset, with the smallest t
--                    the responder can reach at its own speed.  Re-aimed every tick, so the units keep up.  Units spread
--                    across the path (`spread` elmos apart) so they block it rather than queue on it.
--   can't catch      a responder that cannot reach any point on the path inside `horizon` s (or whose cluster is much faster)
--                    holds a station on the line raider -> asset, `stand_off` short of the asset: between them.
--   they stopped     no longer moving for `stop_s` seconds: they can be caught, so FIGHT them.
-- The asset is the most valuable thing we have that the raiders' path points at (ctx.Assets), else the nearest of weight.
--
-- ctx needs:  ctx.ClusterOf(uid) -> the cluster that unit answers:
--                 { x, z, vx, vz (elmos/s), speed, stillS (s the whole cluster has been slow), n, cost, channel }
--             ctx.Assets() -> { {x, z, w} ... } what we protect, w = weight
--   optional: ctx.Speed(defID) -> elmos/s   ctx.Clamp(x, z) -> x, z
--             ctx.Order(frame, uid, cmd, x, z)   order sink (default host:Order); the unit controller routes it through
--                 the army broker so retreat still outranks it
-- Tunables (per assignment): see cfg.

local M = {
    name = "intercept",
    cfg = {
        lead       = 250,    -- elmos past the raiders' predicted position, toward the asset
        horizon    = 14,     -- s: look this far ahead for a meeting point
        stop_speed = 14,     -- elmos/s: a cluster slower than this is "not moving"
        stop_s     = 2.0,    -- s the cluster must be slow before the units fight it
        stand_off  = 400,    -- elmos short of the asset the blocking station sits
        spread     = 110,    -- elmos between neighbours across the path
        spread_max = 330,    -- widest half-width of the block
        speed_fallback = 60, -- elmos/s when a unit's speed is unknown
        log_every  = 150,    -- frames between "[INTERCEPT]" log rows
    },
}

local CMD_MOVE, CMD_FIGHT = 10, 16

function M.Init(st) st.logF, st.n, st.mode = -1e9, 0, {} end

local function Norm(x, z)
    local d = math.sqrt(x * x + z * z)
    if d < 1e-6 then return 0, 0, 0 end
    return x / d, z / d, d
end

-- The asset the cluster is heading for: weight x alignment of its heading with the line to the asset, over distance.
-- A cluster with no usable heading gets the nearest weighty asset.
function M.PickAsset(cl, assets)
    local best, bs
    local ux, uz, s = Norm(cl.vx or 0, cl.vz or 0)
    for _, a in ipairs(assets or {}) do
        local dx, dz = a.x - cl.x, a.z - cl.z
        local d = math.sqrt(dx * dx + dz * dz)
        local score
        if s > 1 and d > 1 then
            local cosv = (dx * ux + dz * uz) / d
            score = (cosv > 0.25) and (a.w * cosv * cosv / (d + 300)) or (a.w * 0.02 / (d + 300))
        else
            score = a.w / (d + 300)
        end
        if not bs or score > bs then best, bs = a, score end
    end
    return best
end

-- Where a unit at (px, pz) with speed `sp` can meet the cluster: smallest t (1 s steps up to horizon) with the point
-- P(t) + dir*lead within sp*t of the unit.  Returns x, z, t or nil.
function M.MeetingPoint(cfg, cl, asset, px, pz, sp)
    local dx, dz = asset.x - cl.x, asset.z - cl.z
    local ux, uz, dist = Norm(dx, dz)
    for t = 0, cfg.horizon do
        local rx, rz = cl.x + (cl.vx or 0) * t, cl.z + (cl.vz or 0) * t
        local lead = cfg.lead
        local remain = math.sqrt((asset.x - rx) ^ 2 + (asset.z - rz) ^ 2)
        if remain < lead + cfg.stand_off then lead = math.max(0, remain - cfg.stand_off) end   -- never past the asset
        local mx, mz = rx + ux * lead, rz + uz * lead
        local d = math.sqrt((mx - px) ^ 2 + (mz - pz) ^ 2)
        if d <= sp * t + 30 then return mx, mz, t end
    end
    return nil
end

-- The blocking station: on the line raider -> asset, stand_off short of the asset (halfway if the raider is closer).
function M.Station(cfg, cl, asset)
    local ux, uz, dist = Norm(asset.x - cl.x, asset.z - cl.z)
    local back = math.min(cfg.stand_off, dist * 0.5)
    return asset.x - ux * back, asset.z - uz * back, ux, uz
end

function M.Update(st, group, ctx, frame, host)
    local cfg = group.cfg
    local order = ctx.Order or function(f, uid, cmd, x, z) return host:Order(f, uid, cmd, x, z) end
    local assets = ctx.Assets and ctx.Assets() or {}
    -- units by the cluster they answer
    local byCluster, clusters = {}, {}
    for _, u in ipairs(group.list) do
        local cl = ctx.ClusterOf and ctx.ClusterOf(u.uid)
        if cl then
            if not byCluster[cl] then byCluster[cl] = {}; clusters[#clusters + 1] = cl end
            local l = byCluster[cl]
            l[#l + 1] = u
        end
    end
    local claimed, nChase, nStation, nFight = {}, 0, 0, 0
    for _, cl in ipairs(clusters) do
        local list = byCluster[cl]
        local moving = (cl.speed or 0) >= cfg.stop_speed or (cl.stillS or 0) < cfg.stop_s
        local asset = moving and M.PickAsset(cl, assets) or nil
        if not asset then
            -- stopped (or nothing to protect): fight them where they are
            for _, u in ipairs(list) do
                order(frame, u.uid, CMD_FIGHT, cl.x, cl.z); claimed[u.uid] = true; nFight = nFight + 1
            end
        else
            local sx, sz, ux, uz = M.Station(cfg, cl, asset)
            -- across the path: units sorted by where they stand across it, so neighbours stay neighbours
            local px, pz = -uz, ux
            table.sort(list, function(a, b) return a.x * px + a.z * pz < b.x * px + b.z * pz end)
            local n = #list
            local half = math.min(cfg.spread_max, cfg.spread * (n - 1) / 2)
            for i, u in ipairs(list) do
                local off = (n == 1) and 0 or ((i - 1) / (n - 1) * 2 - 1) * half
                local sp = (ctx.Speed and ctx.Speed(u.def)) or cfg.speed_fallback
                local mx, mz = M.MeetingPoint(cfg, cl, asset, u.x, u.z, sp)
                local tx, tz
                if mx then tx, tz = mx + px * off, mz + pz * off; nChase = nChase + 1
                else tx, tz = sx + px * off, sz + pz * off; nStation = nStation + 1 end
                if ctx.Clamp then tx, tz = ctx.Clamp(tx, tz) end
                order(frame, u.uid, CMD_MOVE, tx, tz)
                claimed[u.uid] = true
            end
            if frame - st.logF >= cfg.log_every then
                st.logF = frame
                Spring.Echo(string.format("[INTERCEPT] %d:%02d %d units vs %d raiders (%.0f/s, value %d) at %d,%d -> asset %d,%d: %d meet, %d block",
                    math.floor(frame / 1800), math.floor(frame / 30) % 60, n, cl.n or 0, cl.speed or 0, cl.cost or 0,
                    cl.x, cl.z, asset.x, asset.z, nChase, nStation))
            end
        end
    end
    st.n = st.n + 1
    if next(claimed) == nil then return nil end
    return claimed
end

function M.Describe(cfg)
    return string.format("MOVE ahead of raiders on their path (lead %d, spread %d) toward what they threaten; FIGHT once they stop %.0fs",
        cfg.lead, cfg.spread, cfg.stop_s)
end

return M
