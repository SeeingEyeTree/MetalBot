-- bar_framework/behaviors/dragon_defend.lua   (DRAGON_ECO, user 2026-10-14)
-- The Dragons that are waiting for their wave (dragon_raid claims the ones in a wave first; stack this after it) help defend.
--   INTRUSION  ctx.Intruders() are the armed enemy ground groups inside our perimeter (perimeter_guard).  The nearest waiting
--              Dragons FIGHT them, until `mult` x the group's value is sent (at least `min_units`).  They stay on it until
--              the group has been gone `return_after` frames, then go back.
--   WAITING    otherwise they gather at ctx.Gather() (the Dragon lab, `gather` elmos toward the enemy), spread over a small disc.
-- ctx needs: Intruders() -> { {x, z, v, n}, ... }   Gather() -> x, z or nil
-- Log rows "[DW]".
local M = { name = "dragon_defend", cfg = {
    mult         = 1.5,
    min_units    = 2,
    return_after = 600,
    spread       = 120,     -- elmos: waiting Dragons stand on a disc of about this radius
} }

local CMD_MOVE, CMD_FIGHT = 10, 16

local function Clock(frame) return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end
local function D2(ax, az, bx, bz) return (ax - bx) ^ 2 + (az - bz) ^ 2 end

function M.Init(st) st.resp = {}; st.n = 0 end

function M.Update(st, group, ctx, frame, host)
    local cfg = st.cfg
    local gx, gz = ctx.Gather()
    local clusters = ctx.Intruders and ctx.Intruders() or {}
    local inGroup = {}
    for _, u in ipairs(group.list) do inGroup[u.uid] = true end
    for uid in pairs(st.resp) do if not inGroup[uid] then st.resp[uid] = nil end end

    local taken = {}
    for _, cl in ipairs(clusters) do
        local cand = {}
        for _, u in ipairs(group.list) do
            if not taken[u.uid] then cand[#cand + 1] = { u = u, d = D2(u.x, u.z, cl.x, cl.z) } end
        end
        table.sort(cand, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.u.uid < b.u.uid end)
        local sent, n = 0, 0
        for _, c in ipairs(cand) do
            if n >= cfg.min_units and sent >= cfg.mult * cl.v then break end
            taken[c.u.uid] = true
            if not st.resp[c.u.uid] then st.n = st.n + 1 end
            st.resp[c.u.uid] = { x = cl.x, z = cl.z, last = frame }
            sent, n = sent + c.u.v, n + 1
        end
        if n > 0 and frame - (st.logF or -1e9) >= 300 then
            st.logF = frame
            Spring.Echo(string.format("[DW] %s %d waiting Dragons defend against %d intruders (value %.0f) at (%d, %d)",
                Clock(frame), n, cl.n or 0, cl.v, cl.x, cl.z))
        end
    end
    for uid, r in pairs(st.resp) do
        if not taken[uid] and frame - r.last > cfg.return_after then st.resp[uid] = nil end
    end

    local i = 0
    for _, u in ipairs(group.list) do
        local r = st.resp[u.uid]
        if r then
            host:Order(frame, u.uid, CMD_FIGHT, r.x, r.z)
        elseif gx then
            i = i + 1
            local a = i * 2.399963                       -- golden angle: an even spread however many wait
            local rad = cfg.spread * math.sqrt(i) / 3
            host:Order(frame, u.uid, CMD_MOVE, gx + math.cos(a) * rad, gz + math.sin(a) * rad)
        end
    end
    return true
end

function M.Describe(cfg) return "waiting Dragons fight intruders inside the perimeter, else gather at the Dragon lab" end
return M
