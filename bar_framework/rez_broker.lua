-- bar_framework/rez_broker.lua  (rez bots: ONE owner of every order a rez bot gets, and jobs that commit instead of flip-flopping)
--
-- rez_crew.lua re-decided every bot's job from scratch on every pass: "a damaged friend" and "a wreck" flipped as hp and distances
-- moved, a bot at 40% hp left the nano it was walking to the moment it reached 41%, and two bots picked the same target.  Each flip
-- is a new order, so a bot spent its life turning round.  Here the decision has memory:
--
--   * A bot HOLDS a job until the job says it is finished (target gone, healed, out of reach) or it has held it MAX_HOLD frames.
--   * A higher-priority job may take a bot off a lower one only after MIN_HOLD frames, except an `urgent` job (patient) which may
--     take it at once, and a bot on an `idle` job (follow) which any job takes at once.
--   * A wreck is reserved by the bots working it (one per SHARE_METAL of metal); a friend being repaired is not picked by a second bot.
--   * The claim for a held job is identical every pass, so army_broker issues no new order for it.
--
-- User 2026-10-31 ("less passive and more of them as needed"):
--   * Rez bots RECLAIM wrecks (RESURRECT = false; trees and rocks are not wrecks, rez_crew.IsWreck).  They are not tied to the army: each
--     bot takes the best wreck (metal / (distance + DIST_K)) on our half (OWN_FRAC) or within ARMY_REACH of our ground combat units -- the
--     enemy side too: 1k reclaimed there is a 2k swing (we get it, they lose it).  The one hard rule: no order (wreck, repair, move) within
--     ENEMY_CLEAR (500) of a known enemy unit that can hit ground; everything else is fair game.  Such an enemy within EVADE_R of a bot makes it walk away (EVADE).
--   * An idle bot FOLLOWS the attack group most likely to trade soon (click_army groups, scored by value / distance to the fight), a little
--     behind it, so it starts reclaiming as soon as the fight starts; with no group out it waits at the stage.
--   * Two jobs deep: a working bot always has its next wreck (or friend) queued behind the current one (army_broker spec.queue, shift), so
--     it does not stand between jobs waiting for the next pass.  When the current one is done the queued one is promoted.
--   * Repair only when there is no wreck (prio below wreck), and never a chase: only a structure or a unit standing still (STILL_SPEED);
--     a friend that walks out of build reach is dropped.  A unit pulled back to heal (unit_runtime's retreat pass, SetPatients) is a
--     PATIENT of the nearest bot, which repairs it first (urgent job).
--   * Demand() = how many rez bots the work wants: allowed wreck metal / RECLAIM_PER_BOT + missing army hp (metal) / REPAIR_PER_BOT, at most
--     DEMAND_MAX.  unit_runtime publishes it as WG.MetalBot.rez; lab_rules sizes the rez floor with it.
--
-- Jobs are registered, not hard-coded (the same shape as lab_broker's wants), so new rez logic is one RB.AddJob{...}:
--     RB.AddJob{ name = "assist-nano", prio = 55, urgent = false,
--         find    = function(bot) -> target | nil                -- bot = { uid, x, z, hp, i, n, frame }; target is any value
--         valid   = function(bot, st) -> boolean                 -- st = { job, target, since }: still worth doing?
--         claim   = function(bot, st) -> army_broker spec        -- { role = "REZ", cmd = ..., targetID = ... / x, z [, queue, qkey] }
--         promote = function(bot, st) -> boolean                 -- optional: the job ended; move to its queued next target instead
--         refresh = function(bot, st)                            -- optional: every pass while held (pick the queued next target)
--     }
-- Built-in jobs, best first: evade (90, urgent), patient (65, urgent), wreck (60), repair (50), follow (10, idle).  rez_crew supplies the
-- finders (the wreck list, DamagedFriend) and HealPoint, which the retreat pass still uses for wounded units.
--
-- Every claim goes through army_broker at HOME_GUARD priority with role "REZ" (the same as rez_crew); nothing else may order a rez
-- bot.  The lab side of rez bots is lab_rules' "rez-lab" / "rez-starter" / "rez" wants.  Tests: tests/test_rez_broker.lua.
--
--   RB.Init{ RC = rez_crew, MM = MM, ARMY = army_broker, EI = enemy_intel, UQ = unit_query, combat = {[uid] = defID},
--            groups = fn() -> click_army groups, stage = fn() -> x, z, cfg = {...} }
--   RB.Update(frame, frontX, frontZ)          -- instead of RC.Update
--   RB.SetPatients({[uid] = true})            -- the units the retreat pass sent to a rez bot
--   RB.Demand() -> { want, reclaim, repair, bots }
--   RB.Status() -> { bots, jobs = {name = n}, switches, queued }

local M = {}

M.CFG = {
    MIN_HOLD       = 150,    -- frames a bot keeps a job before a (non-urgent) better one may take it
    MAX_HOLD       = 900,    -- ...and the longest it keeps one (30 s) before the pick is redone
    REPAIR_STOP    = 0.99,   -- a friend is repaired up to this share (rez_crew starts it below REPAIR_BELOW)
    FRIEND_LEASH   = 1.6,    -- x REPAIR_RADIUS: a friend that walks further than this is dropped
    RESURRECT      = false,  -- user 2026-10-31: reclaim only for now.  true: an armed wreck is RESURRECTED while the metal bank is above RESURRECT_BANK ...
    RESURRECT_BANK = 0.50,
    RESURRECT_KEEP = 0.35,   -- ... and a resurrect already under way goes back to reclaim below this share
    SPREAD_FRIENDS = true,   -- another bot is already repairing this friend: prefer a different one
    QUEUE          = true,   -- keep the next wreck / friend queued behind the current one (two jobs deep)
    RECLAIM_MIN    = 15,     -- metal left in a wreck before it is worth the walk
    DIST_K         = 600,    -- wreck score = metal / (distance + DIST_K): near ones first, a rich one is worth a walk
    SHARE_METAL    = 400,    -- one bot per this much metal in a wreck (a big wreck takes several)
    ENEMY_CLEAR    = 500,    -- user 2026-10-31: no order (wreck, repair, move) within this of a known enemy unit that can hit ground; everything else is fair game
    BLIP_FRESH     = 300,    -- a moving radar dot counts as an enemy for this long
    OWN_FRAC       = 0.5,    -- wrecks are allowed on our half ...
    ARMY_REACH     = 1200,   -- ... or within this of one of our ground combat units (the reclaim is in the fight, and on the enemy side it counts double)
    EVADE_R        = 500,    -- an enemy that can hit ground this close: walk away from it (urgent)
    EVADE_STEP     = 500,
    FOLLOW_K       = 800,    -- follow score = group value / (distance to its fight + FOLLOW_K)
    FOLLOW_BACK    = 350,    -- idle bots wait this far behind the group they follow ...
    FOLLOW_SPREAD  = 120,    -- ... this far apart
    FOLLOW_STEP    = 200,    -- a point too close to the enemy is moved toward home in steps of this
    STILL_SPEED    = 0.5,    -- elmos per frame: a friend moving faster is not followed (no chasing)
    REPAIR_REACH   = 100,    -- a moving friend is dropped once it is further than the bot's build range + this
    PATIENT_PRIO   = 65,
    RECLAIM_PER_BOT = 300,   -- Demand(): one rez bot per this much wreck metal in the zone ...
    REPAIR_PER_BOT  = 600,   -- ... plus one per this much missing army hp (in metal)
    DEMAND_MAX     = 100,
    LOG_EVERY      = 1800,
}

local RC, MM, ARMY, EI, UQ
local combat = {}
local jobs, jobByName = {}, {}
local state = {}           -- [uid] = { job, target, since }
local wreckBusy = {}       -- [featureID] = bots working it (primary target)
local friendBusy = {}      -- [unitID] = uid
local stats = { switches = 0 }
local demand = { want = 0, reclaim = 0, repair = 0, bots = 0 }
local lastLog = -1e9
local wrecks, wreckByID = {}, {}     -- this pass: the wrecks in the work zone
local patients, patientFor, patientBot = {}, {}, {}    -- [uid] = true; [botID] = unitID; [unitID] = botID
local passFrame = 0

local CMD_MOVE, CMD_REPAIR, CMD_RECLAIM = 10, 40, 90
local CMD_RESURRECT = (CMD and CMD.RESURRECT) or 125

local function Cfg(k) return M.CFG[k] end

function M.Init(o)
    RC, MM, ARMY, EI, UQ = o.RC, o.MM, o.ARMY, o.EI, o.UQ
    combat = o.combat or {}
    for k, v in pairs(o.cfg or {}) do M.CFG[k] = v end
    state, wreckBusy, friendBusy, stats, lastLog = {}, {}, {}, { switches = 0 }, -1e9
    demand = { want = 0, reclaim = 0, repair = 0, bots = 0 }
    wrecks, wreckByID, patients, patientFor, patientBot = {}, {}, {}, {}, {}
    M.groupsFn, M.stageFn = o.groups, o.stage
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

local function MaxUnits() return Game and Game.maxUnits or 32000 end

local function Forward(x, z) return (MM.Forward and MM.Forward(x, z)) or 0 end

-- a unit standing still (or a structure): repairable without a chase
local function Still(uid)
    if not Spring.GetUnitVelocity then return true end
    local vx, _, vz = Spring.GetUnitVelocity(uid)
    if not vx then return true end
    return vx * vx + vz * vz <= Cfg("STILL_SPEED") ^ 2
end

local function BuildRange(uid)
    local d = UnitDefs and UnitDefs[Spring.GetUnitDefID(uid) or -1]
    return (d and d.buildDistance) or 128
end

-- ── where rez bots may go (once per pass) ──────────────────────────────────────
-- User 2026-10-31: "No orders within 500 elmos of an enemy unit but every thing else is fair game."  Reclaim on the enemy side counts double
-- (we get it, they lose it), so a wreck is allowed on our half (OWN_FRAC) or within ARMY_REACH of our combat units (the fight is where the
-- metal is), and never within ENEMY_CLEAR of a known enemy unit that can hit ground (mobile ones only while their position is fresh; radar
-- dots while moving, since they could be anything).  User 2026-10-31: an unarmed building (mex, wind) or an aircraft that cannot hit ground
-- does not push a rez bot away.  The same rule is applied to every move point and repair target, and to EVADE.

local enemyGrid, armyGrid = {}, {}   -- this pass: cell -> { {x, z}... }
local CELL = 500

local function Key(cx, cz) return cx * 100003 + cz end

local function GridAdd(g, x, z)
    local k = Key(math.floor(x / CELL), math.floor(z / CELL))
    local l = g[k]
    if not l then l = {}; g[k] = l end
    l[#l + 1] = x; l[#l + 1] = z
end

-- anything in grid g within r (r <= CELL x n) of (x, z)?
local function GridNear(g, x, z, r)
    local n = math.ceil(r / CELL)
    local cx, cz, r2 = math.floor(x / CELL), math.floor(z / CELL), r * r
    for i = cx - n, cx + n do
        for j = cz - n, cz + n do
            local l = g[Key(i, j)]
            if l then
                for k = 1, #l, 2 do
                    if (l[k] - x) ^ 2 + (l[k + 1] - z) ^ 2 <= r2 then return l[k], l[k + 1] end
                end
            end
        end
    end
    return nil
end

local function BuildGrids()
    enemyGrid, armyGrid = {}, {}
    if EI then
        local fresh = EI.POSITION_FRESH or 900
        for _, rec in pairs(EI.Records() or {}) do
            local c = rec.c
            if rec.x and (not c or c.hitsGnd) and (not c or not c.mobile or passFrame - (rec.frame or 0) <= fresh) then GridAdd(enemyGrid, rec.x, rec.z) end
        end
        if EI.Blips then
            for _, b in pairs(EI.Blips() or {}) do
                if b.x and b.moved and passFrame - (b.frame or 0) <= Cfg("BLIP_FRESH") then GridAdd(enemyGrid, b.x, b.z) end
            end
        end
    end
    for uid, defID in pairs(combat) do
        if not UQ or not UQ.is_air(defID) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then GridAdd(armyGrid, x, z) end
        end
    end
end

-- no known enemy unit within ENEMY_CLEAR of (x, z)
local function Clear(x, z) return GridNear(enemyGrid, x, z, Cfg("ENEMY_CLEAR")) == nil end
M.Clear = function(x, z) return Clear(x, z) end

-- may a rez bot work at (x, z)?  our half, or near our army -- and clear of the enemy
local function Allowed(x, z)
    if not Clear(x, z) then return false end
    if not (MM.Forward and MM.Dist) then return true end
    if Forward(x, z) <= Cfg("OWN_FRAC") * (MM.Dist() or 0) then return true end
    return GridNear(armyGrid, x, z, Cfg("ARMY_REACH")) ~= nil
end

local function BuildWrecks()
    wrecks, wreckByID = {}, {}
    local total = 0
    for _, w in ipairs(RC.Wrecks and RC.Wrecks(Cfg("RECLAIM_MIN")) or {}) do
        if Allowed(w.x, w.z) then
            wrecks[#wrecks + 1], wreckByID[w.fid] = w, w
            total = total + w.metal
        end
    end
    return total
end

local function Room(fid)
    local w = wreckByID[fid]
    if not w then return false end
    return (wreckBusy[fid] or 0) < math.max(1, math.ceil(w.metal / Cfg("SHARE_METAL")))
end

-- The best allowed wreck for a bot at (x, z): metal / (distance + DIST_K), only wrecks with room (not `exclude`).
local function PickWreck(x, z, exclude)
    local best, bestS
    local dk = Cfg("DIST_K")
    for _, w in ipairs(wrecks) do
        if w.fid ~= exclude and Room(w.fid) then
            local s = w.metal / (math.sqrt(Dist2(x, z, w.x, w.z)) + dk)
            if not bestS or s > bestS then best, bestS = w, s end
        end
    end
    return best
end

local function WreckCmd(w)
    if Cfg("RESURRECT") and w.rez and BankFrac() > Cfg("RESURRECT_BANK") then return CMD_RESURRECT end
    return CMD_RECLAIM
end

-- (not `Spring.GetFeaturePosition and Spring.GetFeaturePosition(fid)`: `and` keeps only the first value, so z was nil)
local function FeatureXZ(fid)
    if not Spring.GetFeaturePosition then return nil end
    local x, _, z = Spring.GetFeaturePosition(fid)
    return x, z
end

local function WreckAlive(fid)
    if Spring.ValidFeatureID and not Spring.ValidFeatureID(fid) then return false end
    local metal = Spring.GetFeatureResources and Spring.GetFeatureResources(fid) or 0
    return (metal or 0) > 0
end

local function Busy(fid, d) wreckBusy[fid] = math.max(0, (wreckBusy[fid] or 0) + d); if wreckBusy[fid] == 0 then wreckBusy[fid] = nil end end

local WRECK = {
    name = "wreck", prio = 60,
    find = function(bot)
        local w = PickWreck(bot.x, bot.z)
        if w then return { fid = w.fid, cmd = WreckCmd(w) } end
    end,
    valid = function(bot, st)
        local fid = st.target.fid
        if not WreckAlive(fid) then return false end
        local fx, fz = FeatureXZ(fid)
        if fx and not Clear(fx, fz) then return false end                   -- an enemy came within ENEMY_CLEAR of it
        return true
    end,
    -- the current wreck is done: the queued one becomes current (the bot is already working it)
    promote = function(bot, st)
        local nx = st.target.next
        if not (nx and WreckAlive(nx) and Room(nx)) then return false end
        Busy(st.target.fid, -1)
        local w = wreckByID[nx]
        st.target = { fid = nx, cmd = w and WreckCmd(w) or CMD_RECLAIM }
        Busy(nx, 1)
        return true
    end,
    refresh = function(bot, st)
        local t = st.target
        if t.cmd == CMD_RESURRECT and BankFrac() < Cfg("RESURRECT_KEEP") then t.cmd = CMD_RECLAIM end   -- bank ran down: reclaim instead
        if not Cfg("QUEUE") then t.next = nil; return end
        if t.next and not (t.next ~= t.fid and WreckAlive(t.next) and Room(t.next)) then t.next = nil end
        if not t.next then
            local fx, fz = FeatureXZ(t.fid)
            local w = PickWreck(fx or bot.x, fz or bot.z, t.fid)
            t.next = w and w.fid or nil
        end
    end,
    claim = function(bot, st)
        local t, mu = st.target, MaxUnits()
        local spec = { role = "REZ", cmd = t.cmd, targetID = t.fid + mu }
        if t.next then spec.queue, spec.qkey = { { cmd = CMD_RECLAIM, targetID = t.next + mu } }, "w" .. t.next end
        return spec
    end,
    take = function(bot, st) Busy(st.target.fid, 1) end,
    drop = function(bot, st) Busy(st.target.fid, -1) end,
}

-- a friend worth repairing from this bot: not air (rez_crew), not chased, where a rez bot may go
local function Repairable(fid)
    if not Still(fid) then return false end
    local x, _, z = Spring.GetUnitPosition(fid)
    return x ~= nil and Allowed(x, z)
end

local function FriendValid(bot, fid)
    if not Spring.GetUnitDefID(fid) then return false end
    local h = Hp(fid)
    if not h or h >= Cfg("REPAIR_STOP") then return false end
    local fx, _, fz = Spring.GetUnitPosition(fid)
    if not fx or not Clear(fx, fz) then return false end
    local d2 = Dist2(fx, fz, bot.x, bot.z)
    if d2 > (RC.REPAIR_RADIUS * Cfg("FRIEND_LEASH")) ^ 2 then return false end
    -- no chase: a friend on the move that is out of build reach is let go
    if not Still(fid) and d2 > (BuildRange(bot.uid) + Cfg("REPAIR_REACH")) ^ 2 then return false end
    return true
end

local REPAIR = {
    name = "repair", prio = 50,
    find = function(bot)
        local fid = RC.DamagedFriend(bot.uid, bot.x, bot.z, Repairable)
        if fid and not Repairable(fid) then return nil end
        if fid and Cfg("SPREAD_FRIENDS") and friendBusy[fid] and friendBusy[fid] ~= bot.uid then return nil end
        if fid then return { fid = fid } end
    end,
    valid = function(bot, st) return FriendValid(bot, st.target.fid) end,
    promote = function(bot, st)
        local nx = st.target.next
        if not (nx and FriendValid(bot, nx) and not friendBusy[nx]) then return false end
        if friendBusy[st.target.fid] == bot.uid then friendBusy[st.target.fid] = nil end
        st.target = { fid = nx }
        friendBusy[nx] = bot.uid
        return true
    end,
    refresh = function(bot, st)
        local t = st.target
        if not Cfg("QUEUE") then t.next = nil; return end
        if t.next and (t.next == t.fid or friendBusy[t.next] or not FriendValid(bot, t.next)) then t.next = nil end
        if not t.next then
            local fx, _, fz = Spring.GetUnitPosition(t.fid)
            local nx = fx and RC.DamagedFriend(bot.uid, fx, fz,
                function(f) return f ~= t.fid and not friendBusy[f] and Repairable(f) end)
            if nx and nx ~= t.fid and not friendBusy[nx] and Repairable(nx) then t.next = nx end
        end
    end,
    claim = function(bot, st)
        local t = st.target
        local spec = { role = "REZ", cmd = CMD_REPAIR, targetID = t.fid }
        if t.next then spec.queue, spec.qkey = { { cmd = CMD_REPAIR, targetID = t.next } }, "r" .. t.next end
        return spec
    end,
    take = function(bot, st) friendBusy[st.target.fid] = bot.uid end,
    drop = function(bot, st) if friendBusy[st.target.fid] == bot.uid then friendBusy[st.target.fid] = nil end end,
}

-- a unit the retreat pass pulled back to be healed: the nearest bot repairs it before anything else (it is walking to us, so no chase)
local PATIENT = {
    name = "patient", prio = 65, urgent = true,
    find = function(bot)
        local fid = patientFor[bot.uid]
        if fid then return { fid = fid } end
    end,
    valid = function(bot, st)
        local fid = st.target.fid
        if not (patients[fid] and patientBot[fid] == bot.uid and Spring.GetUnitDefID(fid)) then return false end
        local h = Hp(fid)
        return h ~= nil and h < Cfg("REPAIR_STOP")
    end,
    claim = function(bot, st) return { role = "REZ", cmd = CMD_REPAIR, targetID = st.target.fid } end,
}

-- ── following the army ─────────────────────────────────────────────────────────
-- User 2026-10-31: the old trail (a line behind the army's centroid) did not match how the army moves any more.  An idle bot now follows the
-- click_army attack group most likely to trade soon -- value / (distance to its nearest armed enemy or its target + FOLLOW_K), shared out so a
-- group's followers grow with its score -- FOLLOW_BACK behind it (away from where it is heading), spread FOLLOW_SPREAD apart, so the bots start
-- reclaiming as soon as the fight starts.  With no group out they wait at the stage.  Every point is moved back toward home until it is clear
-- of the enemy (ENEMY_CLEAR).

local dangerGrid = {}        -- this pass: what EVADE walks away from (= enemyGrid)
local follow = { groups = {}, byId = {}, n = {}, idx = {} }

local function BuildDanger() dangerGrid = enemyGrid end     -- the same set: enemies that can hit ground, and moving radar dots

-- (x, z) moved toward home in FOLLOW_STEP steps until no enemy is within ENEMY_CLEAR
local function SafePoint(x, z)
    local hx, hz = MM.Home()
    for _ = 1, 12 do
        if Clear(x, z) then break end
        local dx, dz = hx - x, hz - z
        local d = math.sqrt(dx * dx + dz * dz)
        if d < 1 then break end
        local st = math.min(d, Cfg("FOLLOW_STEP"))
        x, z = x + dx / d * st, z + dz / d * st
    end
    return MM.Clamp(x, z, 200)
end

local function NearestArmed(x, z)
    if not EI then return nil end
    local best
    local fresh = EI.POSITION_FRESH or 900
    for _, rec in pairs(EI.Records() or {}) do
        local c = rec.c
        if rec.x and c and c.armed and not c.air and (not c.mobile or passFrame - (rec.frame or 0) <= fresh) then
            local d = Dist2(x, z, rec.x, rec.z)
            if not best or d < best then best = d end
        end
    end
    return best and math.sqrt(best) or nil
end

-- the attack groups this pass, scored by how soon they will trade
local function BuildFollow()
    follow = { groups = {}, byId = {}, n = {}, idx = {} }
    local list = M.groupsFn and M.groupsFn() or nil
    local ax, az = MM.Axis()
    for _, g in ipairs(list or {}) do
        if g.state == "attack" and g.cx and (g.n or 1) > 0 then
            local hx, hz = ax, az                          -- heading: toward the target, else along the axis
            local dt
            if g.target and g.target.x then
                local dx, dz = g.target.x - g.cx, g.target.z - g.cz
                dt = math.sqrt(dx * dx + dz * dz)
                if dt > 1 then hx, hz = dx / dt, dz / dt end
            end
            local d = math.min(NearestArmed(g.cx, g.cz) or math.huge, dt or math.huge)
            if d == math.huge then d = 3000 end
            local f = { id = g.id, x = g.cx, z = g.cz, hx = hx, hz = hz, score = (g.value or 1) / (d + Cfg("FOLLOW_K")) }
            follow.groups[#follow.groups + 1], follow.byId[g.id] = f, f
        end
    end
end

local FOLLOW = {
    name = "follow", prio = 10, idle = true,      -- idle: any real job may take the bot at once
    find = function(bot)
        local best, bs
        for _, f in ipairs(follow.groups) do
            local s = f.score / (1 + (follow.n[f.id] or 0))      -- shared out by score
            if not bs or s > bs then best, bs = f, s end
        end
        if best then return { gid = best.id } end
        return { gid = false }                                   -- no group out: the stage
    end,
    valid = function(bot, st)
        if st.target.gid then return follow.byId[st.target.gid] ~= nil end
        return #follow.groups == 0
    end,
    take = function(bot, st) if st.target.gid then follow.n[st.target.gid] = (follow.n[st.target.gid] or 0) + 1 end end,
    claim = function(bot, st)
        local gid = st.target.gid
        local f = gid and follow.byId[gid]
        local key = gid or "stage"
        local i = (follow.idx[key] or 0) + 1
        follow.idx[key] = i
        local k = (i % 2 == 0) and (i / 2) or -((i - 1) / 2)     -- 0, 1, -1, 2, -2 ...
        local x, z
        if f then
            x = f.x - f.hx * Cfg("FOLLOW_BACK") - f.hz * k * Cfg("FOLLOW_SPREAD")
            z = f.z - f.hz * Cfg("FOLLOW_BACK") + f.hx * k * Cfg("FOLLOW_SPREAD")
        else
            local c = bot.ctx
            local sx, sz
            if M.stageFn then sx, sz = M.stageFn() end
            if not sx then sx, sz = c.tx, c.tz end
            x, z = sx + c.px * k * RC.TRAIL_SPREAD, sz + c.pz * k * RC.TRAIL_SPREAD
        end
        x, z = SafePoint(x, z)
        return { role = "REZ", cmd = CMD_MOVE, x = x, z = z }
    end,
}

-- far out a rez bot has to care about surviving: an armed enemy within EVADE_R -> walk away from it (leaning toward home) at once
local EVADE = {
    name = "evade", prio = 90, urgent = true,
    find = function(bot)
        local ex, ez = GridNear(dangerGrid, bot.x, bot.z, Cfg("EVADE_R"))
        if ex then return { x = ex, z = ez } end
    end,
    valid = function(bot, st)
        local ex, ez = GridNear(dangerGrid, bot.x, bot.z, Cfg("EVADE_R"))
        if ex then st.target.x, st.target.z = ex, ez end
        return ex ~= nil
    end,
    claim = function(bot, st)
        local hx, hz = MM.Home()
        local dx, dz = bot.x - st.target.x, bot.z - st.target.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d < 1 then dx, dz, d = hx - bot.x, hz - bot.z, 1 end
        local ux, uz = dx / math.max(d, 1), dz / math.max(d, 1)
        local tx, tz = hx - bot.x, hz - bot.z
        local td = math.sqrt(tx * tx + tz * tz)
        if td > 1 then ux, uz = ux + 0.5 * tx / td, uz + 0.5 * tz / td end
        local l = math.max(1e-6, math.sqrt(ux * ux + uz * uz))
        local x, z = SafePoint(bot.x + ux / l * Cfg("EVADE_STEP"), bot.z + uz / l * Cfg("EVADE_STEP"))
        return { role = "REZ", cmd = CMD_MOVE, x = x, z = z, urgent = true }
    end,
}

function M.ResetJobs()
    jobs, jobByName = {}, {}
    -- rez_crew's RECLAIM_FIRST: a safe wreck outranks repairing; off, repairing comes first
    local reclaimFirst = (RC and RC.RECLAIM_FIRST ~= false)
    WRECK.prio, REPAIR.prio = reclaimFirst and 60 or 50, reclaimFirst and 50 or 60
    PATIENT.prio = Cfg("PATIENT_PRIO")
    for _, j in ipairs({ EVADE, PATIENT, WRECK, REPAIR, FOLLOW }) do
        j.seq = nil
        M.AddJob(j)
    end
end

-- ── patients ──────────────────────────────────────────────────────────────────

function M.SetPatients(set) patients = set or {} end

-- each patient goes to the nearest bot that has none yet (a bot keeps the patient it has)
local function AssignPatients(bots)
    for uid, b in pairs(patientBot) do
        if not patients[uid] or not Spring.GetUnitDefID(uid) or not Spring.GetUnitDefID(b) then
            patientBot[uid] = nil
            if patientFor[b] == uid then patientFor[b] = nil end
        end
    end
    for uid in pairs(patients) do
        if not patientBot[uid] then
            local x, _, z = Spring.GetUnitPosition(uid)
            local best, bd
            if x then
                for _, bot in ipairs(bots) do
                    if not patientFor[bot.uid] then
                        local d = Dist2(x, z, bot.x, bot.z)
                        if not bd or d < bd then best, bd = bot.uid, d end
                    end
                end
            end
            if best then patientBot[uid], patientFor[best] = best, uid end
        end
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
        local valid = (not cur.valid) or cur.valid(bot, st)
        if not valid and cur.promote and cur.promote(bot, st) then valid, st.since = true, frame end
        keep = valid and frame - st.since < Cfg("MAX_HOLD")
    end
    local released = false
    if st and not keep then
        -- an ended (or timed-out) job gives up what it holds first, so the re-pick may take the same target again
        Release(bot, st); released = true
    end
    -- best job first: a better one may take the bot (at once if urgent, else after MIN_HOLD); an ended job re-picks freely
    for _, j in ipairs(jobs) do
        if keep and j.prio <= cur.prio then break end          -- nothing here beats what it holds
        if not keep or j.urgent or cur.idle or frame - st.since >= Cfg("MIN_HOLD") then
            local target = j.find(bot)
            if target then
                if not released then Release(bot, st) end
                if not st or st.job ~= j.name then stats.switches = stats.switches + 1 end
                -- the same target re-picked after MAX_HOLD keeps its queued next
                if st and st.job == j.name and st.target and st.target.fid == target.fid then target.next = st.target.next end
                st = Take(bot, j, target, frame)
                state[bot.uid] = st
                return j, st
            end
        end
    end
    if keep then return cur, st end
    -- a job that ended: forget it so the next pass starts clean
    state[bot.uid] = nil
    return nil
end

-- missing hp of the army (in metal), for Demand()
local function RepairNeed()
    if not UQ then return 0 end
    local total = 0
    for uid, defID in pairs(combat) do
        if not UQ.is_air(defID) then
            local h = Hp(uid)
            if h and h < 0.95 then total = total + (1 - h) * UQ.metal_cost(defID) end
        end
    end
    return total
end

function M.Update(frame, frontX, frontZ)
    if not (ARMY and MM and MM.Ready() and RC) then return end
    passFrame = frame
    RC.RefreshNanos(frame)
    local hx, hz = MM.Home()
    local ax, az = MM.Axis()
    local px, pz = MM.Perp()
    local tx, tz = hx, hz
    if frontX then tx, tz = frontX - ax * RC.TRAIL, frontZ - az * RC.TRAIL end
    local ctx = { tx = tx, tz = tz, px = px, pz = pz }

    BuildGrids()
    BuildDanger()
    BuildFollow()
    local reclaim = BuildWrecks()

    local ids = RC.Members()
    for uid in pairs(state) do
        if not Spring.GetUnitDefID(uid) then
            local st = state[uid]
            Release({ uid = uid }, st)
            state[uid] = nil
        end
    end
    -- the reservations, rebuilt from what the bots hold (nothing can leak)
    wreckBusy, friendBusy = {}, {}
    for uid, st in pairs(state) do
        if st.job == "wreck" and st.target then Busy(st.target.fid, 1)
        elseif st.job == "repair" and st.target then friendBusy[st.target.fid] = uid
        elseif st.job == "follow" and st.target and st.target.gid then follow.n[st.target.gid] = (follow.n[st.target.gid] or 0) + 1 end
    end

    local bots = {}
    for i, uid in ipairs(ids) do
        local x, _, z = Spring.GetUnitPosition(uid)
        local hp = Hp(uid)
        if x and hp then bots[#bots + 1] = { uid = uid, x = x, z = z, hp = hp, i = i, n = #ids, frame = frame, ctx = ctx } end
    end
    AssignPatients(bots)

    local counts, queued = {}, 0
    for _, bot in ipairs(bots) do
        local j, st = Decide(bot, frame)
        if j then
            if j.refresh then j.refresh(bot, st) end
            local spec = j.claim(bot, st)
            if spec.queue then queued = queued + 1 end
            ARMY.Claim(ARMY.PRIO.HOME_GUARD, bot.uid, spec, frame)
            counts[j.name] = (counts[j.name] or 0) + 1
        else
            -- nothing at all (no trail job registered): keep what it was doing
            counts.none = (counts.none or 0) + 1
        end
    end
    stats.bots, stats.jobs, stats.queued = #ids, counts, queued

    local repair = RepairNeed()
    local want = math.ceil(reclaim / Cfg("RECLAIM_PER_BOT") + repair / Cfg("REPAIR_PER_BOT"))
    demand = { want = math.min(Cfg("DEMAND_MAX"), want), reclaim = reclaim, repair = repair, bots = #ids, frame = frame }

    if frame - lastLog >= Cfg("LOG_EVERY") and (#ids > 0 or demand.want > 0) then
        lastLog = frame
        local parts = {}
        for name, n in pairs(counts) do parts[#parts + 1] = name .. "=" .. n end
        table.sort(parts)
        Spring.Echo(string.format("[RB] %d:%02d rez bots=%d %s switches=%d queued=%d want=%d reclaim=%.0f (%d wrecks) repair=%.0f groups=%d patients=%d",
            math.floor(frame / 1800), math.floor(frame / 30) % 60, #ids, table.concat(parts, " "), stats.switches, queued,
            demand.want, reclaim, #wrecks, repair, #follow.groups, (function() local n = 0; for _ in pairs(patients) do n = n + 1 end; return n end)()))
    end
end

function M.Demand() return demand end
function M.Status() return stats end
function M.State(uid) return state[uid] end

return M
