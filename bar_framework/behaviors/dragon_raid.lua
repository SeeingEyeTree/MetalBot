-- bar_framework/behaviors/dragon_raid.lua   (DRAGON_ECO, user 2026-10-14)
-- Dragon waves.  Stack it BEFORE dragon_defend: it claims the Dragons that are in a wave and leaves the waiting ones alone.
--
--   WAVE     once `wave` Dragons are not in a wave (they wait for it, see dragon_defend) and the enemy base is known, they are
--            launched together.  A wave lives until fewer than `min_left` of it stand; the rest then go back to waiting
--            and join the next wave.
--   TARGET   the wave's target is picked by priority (user 2026-10-14): the enemy COMMANDER, else build power (factories,
--            nanos, constructors), else anti-air, else the closest eco building; if none of these is known, the nearest
--            enemy structure, else the enemy base.  Within a class the target nearest the wave is taken.  Re-picked every
--            `retarget` frames, and at once when the target is gone, so a commander that shows up mid-flight pulls the wave.
--   ORDERS   MOVE to the target until the wave's centre is within `arrive`, then ATTACK the unit when it is in view (else FIGHT
--            at its last position).  Classes other than the commander split the wave over the `split` nearest targets.
--
-- ctx needs: EnemyBase() -> x, z    EnemyRecords() -> { [uid] = {x, z, frame, c = enemy_intel class} }
--            EnemyCommander() -> x, z, frame, uid (enemy_intel.Commander)
-- Log rows "[DW]".
local M = { name = "dragon_raid", cfg = {
    wave          = 50,
    min_left      = 10,
    arrive        = 1200,
    retarget      = 240,
    split         = 3,
    commander_age = 5400,      -- frames: a commander sighting older than this is not chased
    fresh         = 1800,      -- frames: a mobile record (a constructor, mobile AA) older than this is not a target
    order         = { "commander", "bp", "aa", "eco" },
} }

local CMD_MOVE, CMD_FIGHT, CMD_ATTACK = 10, 16, 20

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Clock(frame) return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end

-- class tests on an enemy_intel record's class table
local KIND = {
    bp  = function(c) return (c.bp or 0) > 0 and not c.air end,
    aa  = function(c) return c.armed and c.hitsAir and not c.air end,
    eco = function(c) return c.eco and not c.mobile end,
}

-- The k nearest targets of the first class in cfg.order that has any: { kind, list = { {x, z, uid} ... } }.  Pure (tests).
function M.Pick(cfg, ctx, frame, cx, cz, k)
    local recs = ctx.EnemyRecords and ctx.EnemyRecords() or {}
    for _, kind in ipairs(cfg.order) do
        if kind == "commander" then
            local x, z, f, uid
            if ctx.EnemyCommander then x, z, f, uid = ctx.EnemyCommander() end
            if x and (not f or frame - f <= cfg.commander_age) then return { kind = kind, list = { { x = x, z = z, uid = uid } } } end
        elseif KIND[kind] then
            local found = {}
            for uid, rec in pairs(recs) do
                local c = rec.c
                if rec.x and c and not c.commander and KIND[kind](c) and (not c.mobile or frame - (rec.frame or -1e9) <= cfg.fresh) then
                    found[#found + 1] = { x = rec.x, z = rec.z, uid = uid, d = Dist(rec.x, rec.z, cx, cz) }
                end
            end
            if #found > 0 then
                table.sort(found, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.uid < b.uid end)
                local list = {}
                for i = 1, math.min(k, #found) do list[i] = found[i] end
                return { kind = kind, list = list }
            end
        end
    end
    -- nothing of the classes: the nearest enemy structure we know, else the base
    local best
    for uid, rec in pairs(recs) do
        local c = rec.c
        if rec.x and c and not c.mobile and not c.air then
            local d = Dist(rec.x, rec.z, cx, cz)
            if not best or d < best.d or (d == best.d and uid < best.uid) then best = { x = rec.x, z = rec.z, uid = uid, d = d } end
        end
    end
    if best then return { kind = "structure", list = { best } } end
    local bx, bz = ctx.EnemyBase()
    return { kind = "base", list = { { x = bx, z = bz } } }
end

function M.Init(st) st.waves, st.n, st.of = {}, 0, {} end

local function Visible(uid)
    return uid ~= nil and Spring.GetUnitPosition(uid) ~= nil
end

function M.Update(st, group, ctx, frame, host)
    local cfg = st.cfg
    local alive = {}
    for _, u in ipairs(group.list) do alive[u.uid] = u end
    for uid, n in pairs(st.of) do if not alive[uid] then st.of[uid] = nil end end

    -- launch
    local waiting = {}
    for _, u in ipairs(group.list) do if not st.of[u.uid] then waiting[#waiting + 1] = u end end
    local bx, bz = ctx.EnemyBase()
    if #waiting >= cfg.wave and bx then
        st.n = st.n + 1
        local w = { n = st.n, since = frame, arrived = false }
        for _, u in ipairs(waiting) do st.of[u.uid] = w.n end
        st.waves[w.n] = w
        Spring.Echo(string.format("[DW] %s wave %d launched (%d Dragons)", Clock(frame), w.n, #waiting))
    end

    local claimed = {}
    for n, w in pairs(st.waves) do
        local members, sx, sz = {}, 0, 0
        for _, u in ipairs(group.list) do
            if st.of[u.uid] == n then members[#members + 1] = u; sx, sz = sx + u.x, sz + u.z end
        end
        if #members < cfg.min_left then
            for _, u in ipairs(members) do st.of[u.uid] = nil end
            Spring.Echo(string.format("[DW] %s wave %d over (%d Dragons left -> waiting)", Clock(frame), n, #members))
            st.waves[n] = nil
        else
            local cx, cz = sx / #members, sz / #members
            local recs = ctx.EnemyRecords and ctx.EnemyRecords() or {}
            -- re-pick on schedule, or at once when the target is gone
            local gone = false
            if w.pick and w.pick.kind ~= "base" then
                for _, t in ipairs(w.pick.list) do
                    if t.uid and w.pick.kind ~= "commander" and not recs[t.uid] then gone = true; break end
                end
                if w.pick.kind == "commander" and not ctx.EnemyCommander() then gone = true end
            end
            if not w.pick or gone or frame - (w.pickF or -1e9) >= cfg.retarget then
                local pick = M.Pick(cfg, ctx, frame, cx, cz, cfg.split)
                if pick.kind == "commander" then pick.list = { pick.list[1] } end
                if not w.pick or w.pick.kind ~= pick.kind or w.pick.list[1].uid ~= pick.list[1].uid then
                    Spring.Echo(string.format("[DW] %s wave %d (%d Dragons) -> %s at (%d, %d)", Clock(frame), n, #members,
                        pick.kind, pick.list[1].x, pick.list[1].z))
                    w.arrived = false
                end
                w.pick, w.pickF = pick, frame
            end
            local list = w.pick.list
            if Dist(cx, cz, list[1].x, list[1].z) <= cfg.arrive then w.arrived = true end
            for i, u in ipairs(members) do
                local t = list[(i - 1) % #list + 1]
                if not w.arrived then
                    host:Order(frame, u.uid, CMD_MOVE, t.x, t.z)
                elseif t.uid and Visible(t.uid) and w.pick.kind ~= "base" then
                    host:Order(frame, u.uid, CMD_ATTACK, t.x, t.z, t.uid)
                else
                    host:Order(frame, u.uid, CMD_FIGHT, t.x, t.z)
                end
                claimed[u.uid] = true
            end
        end
    end
    return claimed
end

function M.Describe(cfg) return "waves of " .. cfg.wave .. " Dragons: commander, then build power, then anti-air, then the closest eco" end
return M
