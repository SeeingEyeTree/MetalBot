-- bar_framework/home_defence.lua
-- The builders defend themselves (user 2026-10-26, from the _Opal_ game: a few enemy scouts killed the base's cons while the nanos
-- and cons stood next to them).  Two jobs, both above every other order a nano gets (nano_broker PRIO.DEFEND):
--   1. RECLAIM: an enemy unit that is inside a nano's / con's build range is reclaimed.  Nanos are static, so "in range" is all they can do;
--      a con is only given the order when the target is already in reach (it never walks after one).  A con keeps its queue: the reclaim is
--      INSERTed at the front and removed again when the enemy dies or leaves reach, so the job it was on resumes.
--   2. REPAIR: a con (or the commander) that lost health in the last few seconds is repaired by every nano in reach, until it is healed
--      or has not been hit for a while.
-- Both drop the order when the enemy / the damage is gone: the nano gets a STOP (nano_broker.Sweep) and is free for its normal work.
-- Entering uses 95% of the build range and keeping uses 110%, so a unit at the edge does not make the order flip on and off.
-- "[HD]" rows: reclaims started / repairs started, once per LOG_EVERY frames.
--
-- USAGE (macro_runtime, every 10 game frames, after NANO.Sweep)
--   HD.Init{ teamID = t, allyID = a, NANO = nano_broker, UQ = unit_query }
--   HD.Update(frame)

local M = {}

M.MAX_COST   = 400    -- metal: enemy units dearer than this are not worth a nano's time (it would never finish)
M.ENTER      = 0.95   -- start an order when the target is inside this share of the build range
M.KEEP       = 1.10   -- keep it until the target is beyond this share
M.HURT_S     = 5      -- seconds after the last hit that a builder counts as "under attack"
M.REPAIR_S   = 10     -- a repair order lasts at most this long after the last hit
M.EVERY      = 10     -- frames between updates (the caller's cadence; builders are checked every SCAN frames)
M.SCAN       = 20
M.LOG_EVERY  = 900
M.CONS       = true   -- cons reclaim too (not only nanos)
M.REPAIR     = true
M.DEBUG      = false

local CMD_RECLAIM, CMD_INSERT, CMD_REMOVE = 90, 1, 2
local frame_now = 0
local S = { team = nil, ally = nil, NANO = nil, hp = {}, conJob = {}, started = 0, repairs = 0, lastLog = -1e9 }
M.state = S

function M.Init(o)
    S.team, S.ally, S.NANO = o.teamID, o.allyID, o.NANO
    M.UQ = o.UQ
    for k, v in pairs(o.cfg or {}) do M[k] = v end
    S.hp, S.conJob, S.started, S.repairs, S.lastLog = {}, {}, 0, 0, -1e9
    if CMD then CMD_RECLAIM = CMD.RECLAIM or 90; CMD_INSERT = CMD.INSERT or 1; CMD_REMOVE = CMD.REMOVE or 2 end
end

local kindOf = {}      -- defID -> "nano" | "con" | "other"
local function Kind(defID)
    local k = kindOf[defID]
    if k then return k end
    local d = UnitDefs[defID]
    k = "other"
    if d and d.isBuilder and not d.isFactory and (d.buildSpeed or 0) > 0 and (d.buildDistance or 0) > 0 and not (d.customParams and d.customParams.iscommander) then
        k = ((d.speed or 0) == 0 and not d.canFly) and "nano" or "con"
    end
    kindOf[defID] = k
    return k
end

-- An enemy worth reclaiming: seen (has a def), not a commander, not a finished structure, cheap enough.
local function Reclaimable(eid)
    local defID = Spring.GetUnitDefID(eid)
    local d = defID and UnitDefs[defID]
    if not d or d.reclaimable == false then return false end
    if d.customParams and d.customParams.iscommander then return false end
    if (d.metalCost or 0) > M.MAX_COST then return false end
    if d.isBuilding and not Spring.GetUnitIsBeingBuilt(eid) then return false end
    return true
end

local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

-- The nearest reclaimable enemy inside `reach` of (x, z), or nil.
local function NearestEnemy(x, z, reach)
    local best, bd
    for _, eid in ipairs(Spring.GetUnitsInCylinder(x, z, reach) or {}) do
        if Spring.GetUnitAllyTeam(eid) ~= S.ally and Reclaimable(eid) then
            local ex, _, ez = Spring.GetUnitPosition(eid)
            if ex then
                local d = Dist(x, z, ex, ez)
                if d <= reach and (not bd or d < bd) then best, bd = eid, d end
            end
        end
    end
    return best, bd
end

-- keep-test for a static builder's job: the target is alive and still inside KEEP x range of (x, z)
local function KeepReclaim(x, z, range)
    return function(eid)
        local ex, _, ez = Spring.GetUnitPosition(eid)
        return ex ~= nil and Dist(x, z, ex, ez) <= range * M.KEEP
    end
end

local function RemoveConJob(uid, job)
    local q = Spring.GetUnitCommands(uid, 3)
    if type(q) == "table" then
        for _, c in ipairs(q) do
            if c.id == CMD_RECLAIM and c.params and c.params[1] == job.target and c.tag then
                Spring.GiveOrderToUnit(uid, CMD_REMOVE, { c.tag }, {})
                break
            end
        end
    end
    S.conJob[uid] = nil
end

function M.Update(frame)
    if not (S.team and S.NANO) then return end
    frame_now = frame
    local snap = M.UQ and M.UQ.snapshot(S.team)
    if not snap then return end
    local nanos, cons = {}, {}
    for _, uid in ipairs(snap.ids) do
        local k = Kind(snap.defOf[uid])
        if k ~= "other" and not Spring.GetUnitIsBeingBuilt(uid) then
            if k == "nano" then nanos[#nanos + 1] = uid else cons[#cons + 1] = uid end
        end
    end
    local slice = math.floor(frame / M.EVERY)
    local nSlices = math.max(1, math.floor(M.SCAN / M.EVERY))

    -- 1a. cons: drop a finished / out-of-reach reclaim first
    for uid, job in pairs(S.conJob) do
        local ux, _, uz = Spring.GetUnitPosition(uid)
        local ex, _, ez = Spring.GetUnitPosition(job.target)
        local range = UnitDefs[snap.defOf[uid] or 0] and UnitDefs[snap.defOf[uid]].buildDistance or 0
        if not (ux and ex and Dist(ux, uz, ex, ez) <= range * M.KEEP) then
            if ux then RemoveConJob(uid, job) else S.conJob[uid] = nil end
        end
    end

    -- 1b. reclaim assignments (each builder is looked at once per SCAN frames; a running job is re-checked by its keep-test every update)
    local function Scan(uid, isCon)
        local defID = snap.defOf[uid]
        local range = UnitDefs[defID].buildDistance
        local x, _, z = Spring.GetUnitPosition(uid)
        if not x then return end
        local eid = NearestEnemy(x, z, range * M.ENTER)
        if not eid then return end
        if isCon then
            if S.conJob[uid] then return end
            Spring.GiveOrderToUnit(uid, CMD_INSERT, { 0, CMD_RECLAIM, 0, eid }, {})
            S.conJob[uid] = { target = eid, frame = frame }
        else
            if S.NANO.Defend(uid, eid, KeepReclaim(x, z, range), "reclaim") then
                local a = S.NANO.Assignment(uid)
                if a and a.target == eid and not a.counted then a.counted = true; S.started = S.started + 1 end
            end
        end
    end
    for _, uid in ipairs(nanos) do
        local a = S.NANO.Assignment(uid)
        local free = not (a and a.mode == "defend-reclaim")
        if free and (uid + slice) % nSlices == 0 then Scan(uid, false) end
    end
    if M.CONS then
        for _, uid in ipairs(cons) do
            if not S.conJob[uid] and (uid + slice) % nSlices == 0 then Scan(uid, true) end
        end
    end

    -- 2. repair: builders hit in the last HURT_S seconds are repaired by the nanos in reach
    if M.REPAIR and #nanos > 0 then
        local hurt = {}
        local function Watch(uid)
            local hp, mx = Spring.GetUnitHealth(uid)
            if not hp then return end
            local rec = S.hp[uid]
            if not rec then rec = { hp = hp, hit = -1e9 }; S.hp[uid] = rec end
            if hp < rec.hp - 0.5 then rec.hit = frame end
            rec.hp = hp
            if hp < mx and frame - rec.hit <= M.HURT_S * 30 then hurt[#hurt + 1] = { uid = uid, rec = rec, mx = mx } end
        end
        for _, uid in ipairs(cons) do Watch(uid) end
        local cm = M.UQ.get_commander and M.UQ.get_commander(S.team)
        if cm then Watch(cm) end
        for uid in pairs(S.hp) do if not Spring.GetUnitDefID(uid) then S.hp[uid] = nil end end
        for _, h in ipairs(hurt) do
            local cx, _, cz = Spring.GetUnitPosition(h.uid)
            if cx then
                for _, nid in ipairs(nanos) do
                    local nx, _, nz = Spring.GetUnitPosition(nid)
                    local range = UnitDefs[snap.defOf[nid]].buildDistance
                    if nx and Dist(nx, nz, cx, cz) <= range * M.ENTER then
                        local a = S.NANO.Assignment(nid)
                        if not (a and a.mode == "defend-reclaim") and not (a and a.mode == "defend-repair" and a.target == h.uid) then
                            local rec, uid2 = h.rec, h.uid
                            if S.NANO.Defend(nid, uid2, function(t)
                                local hp, mx = Spring.GetUnitHealth(t)
                                if not hp or hp >= mx or frame_now - rec.hit > M.REPAIR_S * 30 then return false end
                                local tx, _, tz = Spring.GetUnitPosition(t)
                                return tx ~= nil and Dist(nx, nz, tx, tz) <= range * M.KEEP
                            end, "repair") then S.repairs = S.repairs + 1 end
                        end
                    end
                end
            end
        end
    end

    if (S.started + S.repairs > 0) and frame - S.lastLog >= M.LOG_EVERY then
        S.lastLog = frame
        Spring.Echo(string.format("[HD] %d:%02d nano reclaims started %d, repair orders %d, con reclaims active %d",
            math.floor(frame / 1800), math.floor(frame / 30) % 60, S.started, S.repairs, (function() local n = 0 for _ in pairs(S.conJob) do n = n + 1 end return n end)()))
    end
end

return M
