-- bar_framework/rez_broker.lua  (rez bots: ONE owner of every order a rez bot gets, and jobs that commit instead of flip-flopping)
--
-- rez_crew.lua re-decided every bot's job from scratch on every pass: "a damaged friend" and "a wreck" flipped as hp and distances
-- moved, a bot at 40% hp left the nano it was walking to the moment it reached 41%, and two bots picked the same target.  Each flip
-- is a new order, so a bot spent its life turning round.  Here the decision has memory:
--
--   * A bot HOLDS a job until the job says it is finished (target gone, healed, out of reach) or it has held it MAX_HOLD frames.
--   * A higher-priority job may take a bot off a lower one only after MIN_HOLD frames, except an `urgent` job (none built in) which may
--     take it at once (none built in), and a bot on an `idle` job (trail) which any job takes at once.
--   * A wreck is reserved by the bot working it; a friend being repaired is not picked by a second bot while others need help.
--   * The claim for a held job is identical every pass, so army_broker issues no new order for it.
--
-- Jobs are registered, not hard-coded (the same shape as lab_broker's wants), so new rez logic is one RB.AddJob{...}:
--     RB.AddJob{ name = "assist-nano", prio = 55, urgent = false,
--         find  = function(bot) -> target | nil                -- bot = { uid, x, z, hp, i, n, frame }; target is any value
--         valid = function(bot, st) -> boolean                 -- st = { job, target, since }: still worth doing?
--         claim = function(bot, st) -> army_broker spec        -- { role = "REZ", cmd = ..., targetID = ... / x, z }
--     }
-- Built-in jobs, best first: wreck (RECLAIM; RESURRECT an armed unit only while the metal bank is over RESURRECT_BANK; safe wrecks only), repair, trail (follow
-- the army's front).  rez_crew supplies the finders (it stays the home of HealPoint, which the retreat pass still uses for wounded units, / IsRezDef / the wreck + friend scans).
--
-- Every claim goes through army_broker at HOME_GUARD priority with role "REZ" (the same as rez_crew); nothing else may order a rez
-- bot.  The lab side of rez bots is lab_rules' "rez-lab" want (WG.RezLab, lab.only).  Tests: tests/test_rez_broker.lua.
--
--   RB.Init{ RC = rez_crew, MM = MM, ARMY = army_broker, cfg = {...} }
--   RB.Update(frame, frontX, frontZ)          -- instead of RC.Update
--   RB.Status() -> { bots, jobs = {name = n}, switches }

local M = {}

M.CFG = {
    MIN_HOLD       = 150,    -- frames a bot keeps a job before a (non-urgent) better one may take it
    MAX_HOLD       = 900,    -- ...and the longest it keeps one (30 s) before the pick is redone
    REPAIR_STOP    = 0.99,   -- a friend is repaired up to this share (rez_crew starts it below REPAIR_BELOW)
    FRIEND_LEASH   = 1.6,    -- x REPAIR_RADIUS: a friend that walks further than this is dropped
    RESURRECT_BANK = 0.50,   -- the wreck job RECLAIMS by default; it RESURRECTS only while the metal bank is above this share of storage ...
    RESURRECT_KEEP = 0.35,   -- ... and a resurrect already under way is dropped (back to reclaim) below this share
    SPREAD_FRIENDS = true,   -- another bot is already repairing this friend: prefer a different one
    LOG_EVERY      = 1800,
}

local RC, MM, ARMY
local jobs, jobByName = {}, {}
local state = {}           -- [uid] = { job, target, since }
local wreckBusy = {}       -- [featureID] = uid   (shared with rez_crew's BestWreck)
local friendBusy = {}      -- [unitID] = uid
local stats = { switches = 0 }
local lastLog = -1e9

local CMD_MOVE, CMD_REPAIR, CMD_RECLAIM = 10, 40, 90
local CMD_RESURRECT = (CMD and CMD.RESURRECT) or 125

local function Cfg(k) return M.CFG[k] end

function M.Init(o)
    RC, MM, ARMY = o.RC, o.MM, o.ARMY
    for k, v in pairs(o.cfg or {}) do M.CFG[k] = v end
    state, wreckBusy, friendBusy, stats, lastLog = {}, {}, {}, { switches = 0 }, -1e9
    M.ResetJobs()
end

-- ── jobs ──────────────────────────────────────────────────────────────────────

local function SortJobs()
    table.sort(jobs, function(a, b) if a.prio ~= b.prio then return a.prio > b.prio end return a.seq < b.seq end)
end

function M.AddJob(spec)
    assert(spec.name and spec.find and spec.claim, "rez_broker job needs name, find and claim")
    assert(not jobByName[spec.name], "rez_broker job registered twice: " .. spec.name)
    spec.prio, spec.seq = spec.prio or 0, #jobs + 1
    jobs[#jobs + 1], jobByName[spec.name] = spec, spec
    SortJobs()
    return spec
end

function M.RemoveJob(name)
    local j = jobByName[name]
    if not j then return end
    jobByName[name] = nil
    for i, x in ipairs(jobs) do if x == j then table.remove(jobs, i); break end end
end

local function Dist2(ax, az, bx, bz) return (ax - bx) ^ 2 + (az - bz) ^ 2 end

local function Hp(uid)
    local hp, mx = Spring.GetUnitHealth(uid)
    if hp and mx and mx > 0 then return hp / mx end
    return nil
end

local function BankFrac()
    local cur, store = Spring.GetTeamResources(Spring.GetMyTeamID(), "metal")
    if cur and store and store > 0 then return cur / store end
    return 0
end

local WRECK = {
    name = "wreck", prio = 60,
    find = function(bot)
        local fid, cmd = RC.BestWreck(bot.frame, bot.uid, bot.x, bot.z, wreckBusy, BankFrac() <= Cfg("RESURRECT_BANK"))
        if fid then return { fid = fid, cmd = cmd } end
    end,
    valid = function(bot, st)
        local fid = st.target.fid
        if Spring.ValidFeatureID and not Spring.ValidFeatureID(fid) then return false end
        if st.target.cmd == CMD_RESURRECT and BankFrac() < Cfg("RESURRECT_KEEP") then return false end   -- bank ran down: reclaim instead
        if st.target.cmd == CMD_RECLAIM then
            local metal = Spring.GetFeatureResources and Spring.GetFeatureResources(fid) or 0
            if (metal or 0) <= 0 then return false end
        end
        return true
    end,
    claim = function(bot, st)
        local maxUnits = Game and Game.maxUnits or 32000
        return { role = "REZ", cmd = st.target.cmd, targetID = st.target.fid + maxUnits }
    end,
    take = function(bot, st) wreckBusy[st.target.fid] = bot.uid end,
    drop = function(bot, st) if wreckBusy[st.target.fid] == bot.uid then wreckBusy[st.target.fid] = nil end end,
}

local REPAIR = {
    name = "repair", prio = 50,
    find = function(bot)
        local fid = RC.DamagedFriend(bot.uid, bot.x, bot.z)
        if fid and Cfg("SPREAD_FRIENDS") and friendBusy[fid] and friendBusy[fid] ~= bot.uid then return nil end
        if fid then return { fid = fid } end
    end,
    valid = function(bot, st)
        local fid = st.target.fid
        if not Spring.GetUnitDefID(fid) then return false end
        local h = Hp(fid)
        if not h or h >= Cfg("REPAIR_STOP") then return false end
        local fx, _, fz = Spring.GetUnitPosition(fid)
        return fx ~= nil and Dist2(fx, fz, bot.x, bot.z) <= (RC.REPAIR_RADIUS * Cfg("FRIEND_LEASH")) ^ 2
    end,
    claim = function(bot, st) return { role = "REZ", cmd = CMD_REPAIR, targetID = st.target.fid } end,
    take = function(bot, st) friendBusy[st.target.fid] = bot.uid end,
    drop = function(bot, st) if friendBusy[st.target.fid] == bot.uid then friendBusy[st.target.fid] = nil end end,
}

local TRAIL = {
    name = "trail", prio = 10, idle = true,      -- idle: any real job may take the bot at once
    find = function(bot) return { } end,
    valid = function() return true end,
    claim = function(bot, st)
        local c = bot.ctx
        local k = (bot.i - 1) - (bot.n - 1) / 2
        local wx, wz = MM.Clamp(c.tx + c.px * k * RC.TRAIL_SPREAD, c.tz + c.pz * k * RC.TRAIL_SPREAD, 200)
        return { role = "REZ", cmd = CMD_MOVE, x = wx, z = wz }
    end,
}

function M.ResetJobs()
    jobs, jobByName = {}, {}
    -- rez_crew's RECLAIM_FIRST: a safe wreck outranks repairing; off, repairing comes first
    local reclaimFirst = (RC and RC.RECLAIM_FIRST ~= false)
    WRECK.prio, REPAIR.prio = reclaimFirst and 60 or 50, reclaimFirst and 50 or 60
    for _, j in ipairs({ WRECK, REPAIR, TRAIL }) do
        j.seq = nil
        M.AddJob(j)
    end
end

-- ── the pass ──────────────────────────────────────────────────────────────────

local function Release(bot, st)
    local j = st and st.job and jobByName[st.job]
    if j and j.drop and st.target then j.drop(bot, st) end
end

local function Take(bot, j, target, frame)
    local st = { job = j.name, target = target, since = frame }
    if j.take then j.take(bot, st) end
    return st
end

local function Decide(bot, frame)
    local st = state[bot.uid]
    local cur = st and jobByName[st.job]
    local keep = false
    if cur then
        local held = frame - st.since
        keep = held < Cfg("MAX_HOLD") and (not cur.valid or cur.valid(bot, st))
    end
    -- best job first: a better one may take the bot (at once if urgent, else after MIN_HOLD); an ended job re-picks freely
    for _, j in ipairs(jobs) do
        if keep and j.prio <= cur.prio then break end          -- nothing here beats what it holds
        if not keep or j.urgent or cur.idle or frame - st.since >= Cfg("MIN_HOLD") then
            local target = j.find(bot)
            if target then
                Release(bot, st)
                if not st or st.job ~= j.name then stats.switches = stats.switches + 1 end
                st = Take(bot, j, target, frame)
                state[bot.uid] = st
                return j, st
            end
        end
    end
    if keep then return cur, st end
    -- a job that ended: forget it so the next pass starts clean
    Release(bot, st)
    state[bot.uid] = nil
    return nil
end

function M.Update(frame, frontX, frontZ)
    if not (ARMY and MM and MM.Ready() and RC) then return end
    RC.RefreshNanos(frame)
    local hx, hz = MM.Home()
    local ax, az = MM.Axis()
    local px, pz = MM.Perp()
    local tx, tz = hx, hz
    if frontX then tx, tz = frontX - ax * RC.TRAIL, frontZ - az * RC.TRAIL end
    local ctx = { tx = tx, tz = tz, px = px, pz = pz }

    local ids = RC.Members()
    for uid in pairs(state) do
        if not Spring.GetUnitDefID(uid) then
            local st = state[uid]
            Release({ uid = uid }, st)
            state[uid] = nil
        end
    end
    for fid, uid in pairs(wreckBusy) do
        if not state[uid] or (Spring.ValidFeatureID and not Spring.ValidFeatureID(fid)) then wreckBusy[fid] = nil end
    end
    for fid, uid in pairs(friendBusy) do
        if not state[uid] or not Spring.GetUnitDefID(fid) then friendBusy[fid] = nil end
    end

    local counts = {}
    for i, uid in ipairs(ids) do
        local x, _, z = Spring.GetUnitPosition(uid)
        local hp = Hp(uid)
        if x and hp then
            local bot = { uid = uid, x = x, z = z, hp = hp, i = i, n = #ids, frame = frame, ctx = ctx }
            local j, st = Decide(bot, frame)
            if j then
                ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, j.claim(bot, st), frame)
                counts[j.name] = (counts[j.name] or 0) + 1
            else
                -- nothing at all (no trail job registered): keep what it was doing
                counts.none = (counts.none or 0) + 1
            end
        end
    end
    stats.bots, stats.jobs = #ids, counts

    if frame - lastLog >= Cfg("LOG_EVERY") and #ids > 0 then
        lastLog = frame
        local parts = {}
        for name, n in pairs(counts) do parts[#parts + 1] = name .. "=" .. n end
        table.sort(parts)
        Spring.Echo(string.format("[RB] %d:%02d rez bots=%d %s switches=%d", math.floor(frame / 1800), math.floor(frame / 30) % 60,
            #ids, table.concat(parts, " "), stats.switches))
    end
end

function M.Status() return stats end
function M.State(uid) return state[uid] end

return M
