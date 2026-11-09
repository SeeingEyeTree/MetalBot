-- bar_framework/air_lift.lua  (slow units go by air: a pool of T1 air transports that carries them to where their owner wants them)
--
-- User 2026-11-01: "Quakers are slow but they can be moved by light trans so they should be transported 800 elmos behind a group if they are far
-- out.  If they are defending at home they can just walk like normal.  You always want to air trans slow units in general."  And: "with the air
-- trans the reinforce time should be fine for them to stay out" -- support units are flown out to groups that stay on the map.
-- A general service: an owner (the army_groups elements: arty, aa) asks for a unit to be carried to (x, z); the pool gives the job to the nearest
-- idle transport (bar_framework/air_transport.lua does the two orders and follows the job).  The drop point steps back toward home while the
-- remembered enemy anti-air covers it.  While a unit is being picked up or carried it is Busy (its owner gives it no orders: the cargo's
-- army_broker claim is released at pickup); a job that fails goes back to waiting (dropped after MAX_FAILS).  Transports: every finished T1 air
-- transport that the nano-col ferry does not hold (WG.NcFerryTids); the pool asks the labs (WG.LabOrders, "lift:transport") for more: at least
-- MIN while WG.MetalBot.artyOn / stopOn, one per waiting job, at most MAX; high tier while jobs wait, normal otherwise.
-- 2026-11-02: heavy transports too (corseah / corhvytrans: a Tzar is too heavy for the light one): a job goes to a transport that can carry its unit
-- (AT.CanCarry), and "lift:heavy" asks the labs for heavy ones (MIN_HEAVY while stopOn, one per waiting heavy job, at most MAX_HEAVY).  An owner keeps
-- re-asking while its unit is in the air: when the spot moved more than REROUTE_R the transport is re-routed there (user 2026-11-02: Quakers were set
-- down outside the enemy base while their group pulled back).
--
--   LIFT.Init{ WG, EI, MM, ARMY, cfg }
--   LIFT.Request(uid, x, z, prio, key)   -- (re)asks; a waiting job takes the new spot, a job in the air keeps its own
--   LIFT.Busy(uid) -> bool               LIFT.Waiting(uid) -> bool         LIFT.Cancel(uid)
--   LIFT.Update(frame)                   -- every 30 frames (unit_runtime's tick)
-- Logs [LIFT] rows.  Published as WG.AirLift.

local AT = VFS.Include("LuaUI/Widgets/bar_framework/air_transport.lua")
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = {}

M.CFG = {
    MIN        = 2,          -- transports kept while the arty element is on
    MAX        = 6,
    MIN_HEAVY  = 2,          -- heavy transports kept while the stop element (Tzars) is on
    MAX_HEAVY  = 4,
    REROUTE_R  = 400,        -- an owner's new spot this far from the job's: the transport in the air goes there instead
    AA_MIN     = 150,        -- the drop point steps back while EI.ThreatAt(air) there is at least this
    STEP_BACK  = 400,        -- elmos per step toward home, at most AA_STEPS steps
    AA_STEPS   = 8,
    ROUTE_STEP = 300,        -- the flight is checked every this many elmos
    FIGHTER_MEMORY = 900,    -- enemy air that hits air, seen this many frames ago or less, ...
    FIGHTER_R  = 1500,       -- ... within this of the route blocks the flight
    ARRIVE     = 250,
    TIMEOUT    = 90 * 30,
    MAX_FAILS  = 3,
    PARK_R     = 400,        -- idle transports wait this far behind the base centre
    LOG_EVERY  = 900,
}

local O = {}
local trans = {}            -- [tid] = defID: transports in the pool
local jobs = {}             -- [uid] = { uid, x, z, prio, key, state = "wait" | "fly", tid, since, fails }
local parked = {}           -- [tid] = true once sent to its parking spot
local stats = { done = 0, failed = 0 }
local lastLog = -1e9

local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
local function TransportDef() return UnitDefNames and UnitDefNames[ROLES.Get("transport_air")] end
local function HeavyDefs()
    local out = {}
    for _, role in ipairs({ "transport_heavy", "transport_heavy_t1" }) do
        local d = UnitDefNames and UnitDefNames[ROLES.Get(role) or ""]
        if d then out[#out + 1] = d end
    end
    return out
end

function M.Init(o)
    O = o or {}
    for k, v in pairs(O.cfg or {}) do M.CFG[k] = v end
    trans, jobs, parked, stats = {}, {}, {}, { done = 0, failed = 0 }
    -- (RouteClear: the macro side's proxy convoy asks it too, sink_lift.lua)
    if O.WG then O.WG.AirLift = { Request = M.Request, Busy = M.Busy, Waiting = M.Waiting, Cancel = M.Cancel,
                                  RouteClear = function(ax, az, x, z) return M.RouteClear(Spring.GetGameFrame(), ax, az, x, z) end } end
    Spring.Echo(string.format("[LIFT] air lift on (transports %d..%d)", M.CFG.MIN, M.CFG.MAX))
end

function M.Request(uid, x, z, prio, key)
    if not (Alive(uid) and x and z) then return end
    local j = jobs[uid]
    if j then
        if j.state == "wait" then j.x, j.z, j.prio, j.key = x, z, prio or j.prio, key or j.key
        else j.wantX, j.wantZ, j.key = x, z, key or j.key end        -- in the air: Update re-routes when the spot moved
        return
    end
    jobs[uid] = { uid = uid, x = x, z = z, prio = prio or 0, key = key, state = "wait", since = Spring.GetGameFrame(), fails = 0 }
end

function M.Busy(uid) local j = jobs[uid]; return j ~= nil and j.state == "fly" end
function M.Waiting(uid) local j = jobs[uid]; return j ~= nil and j.state == "wait" end

function M.Cancel(uid)
    local j = jobs[uid]
    if not j then return end
    if j.state == "fly" and j.tid then AT.Cancel(j.tid) end
    jobs[uid] = nil
end

-- Is the flight from (ax, az) to (x, z) clear of the enemy's remembered anti-air (fighters seen lately count: game 2026-11-01, 14 of 15 transports
-- lost were shot down by Vampires)?  Sampled every ROUTE_STEP elmos.
-- Enemy fighters are remembered FIGHTER_MEMORY frames within FIGHTER_R of the route (EI.ThreatAt counts a mobile unit only 10 s; game 2026-11-01:
-- all 22 lost transports were shot down by Vampires / Avengers).
local function RouteClear(frame, ax, az, x, z)
    local EI = O.EI
    local d = math.sqrt((x - ax) ^ 2 + (z - az) ^ 2)
    local n = math.max(1, math.ceil(d / M.CFG.ROUTE_STEP))
    local fighters = {}
    if EI.Records then
        for _, rec in pairs(EI.Records()) do
            local c = rec.c
            if c and c.air and c.armed and c.hitsAir and frame - rec.frame <= M.CFG.FIGHTER_MEMORY then fighters[#fighters + 1] = rec end
        end
    end
    local fr2 = M.CFG.FIGHTER_R * M.CFG.FIGHTER_R
    for i = 1, n do
        local t = i / n
        local px, pz = ax + (x - ax) * t, az + (z - az) * t
        if EI.ThreatAt(frame, px, pz, "air") >= M.CFG.AA_MIN then return false end
        for _, rec in ipairs(fighters) do
            if (rec.x - px) ^ 2 + (rec.z - pz) ^ 2 <= fr2 then return false end
        end
    end
    return true
end
M.RouteClear = function(...) return RouteClear(...) end

-- The drop point: stepped back toward home until the route there from the transport is clear; nil when no step clears it (the unit walks)
local function SafeDrop(frame, tid, x, z)
    local EI, MM = O.EI, O.MM
    if not (EI and EI.ThreatAt and MM and MM.Ready and MM.Ready()) then return x, z end
    local ax, _, az = Spring.GetUnitPosition(tid)
    if not ax then return nil end
    local hx, hz = MM.Base()
    for _ = 0, M.CFG.AA_STEPS do
        if RouteClear(frame, ax, az, x, z) then return x, z end
        local dx, dz = hx - x, hz - z
        local d = math.sqrt(dx * dx + dz * dz)
        if d < M.CFG.STEP_BACK then break end
        x, z = x + dx / d * M.CFG.STEP_BACK, z + dz / d * M.CFG.STEP_BACK
    end
    return nil
end

local function Adopt(frame)
    local ids = {}
    local td = TransportDef()
    if td then ids[#ids + 1] = td.id end
    for _, d in ipairs(HeavyDefs()) do ids[#ids + 1] = d.id end
    if #ids == 0 then return end
    local ferry = {}
    for _, tid in ipairs((O.WG and O.WG.NcFerryTids) or {}) do ferry[tid] = true end
    for _, tid in ipairs((O.WG and O.WG.SinkLiftTids) or {}) do ferry[tid] = true end     -- the metal sink's own (sink_lift.lua)
    for _, tid in ipairs(Spring.GetTeamUnitsByDefs(Spring.GetMyTeamID(), ids) or {}) do
        if not trans[tid] and not ferry[tid] and not Spring.GetUnitIsBeingBuilt(tid) then
            trans[tid] = Spring.GetUnitDefID(tid)
            Spring.Echo(string.format("[LIFT] %s transport %d (%s) joins the pool", Clock(frame), tid, UnitDefs[trans[tid]].name))
        end
    end
    for tid in pairs(trans) do
        if not Alive(tid) or ferry[tid] then trans[tid], parked[tid] = nil, nil end
    end
end

local function Park(frame, tid)
    if parked[tid] then return end
    local MM = O.MM
    if not (MM and MM.Ready and MM.Ready()) then return end
    local bx, bz = MM.Base()
    local ax, az = MM.Axis()
    local x, z = bx - (ax or 0) * M.CFG.PARK_R, bz - (az or 0) * M.CFG.PARK_R
    if MM.Clamp then x, z = MM.Clamp(x, z, 200) end
    Spring.GiveOrderToUnit(tid, CMD.MOVE, { x, Spring.GetGroundHeight(x, z) or 0, z }, {})
    parked[tid] = true
end

function M.Update(frame)
    Adopt(frame)
    -- finished jobs
    for _, job in ipairs(AT.Update(frame)) do
        local j = job.uid and jobs[job.uid]
        if j and j.tid == job.transport then
            if job.state == "done" then
                stats.done = stats.done + 1
                jobs[job.uid] = nil
                Spring.Echo(string.format("[LIFT] %s %s %d set down at %.0f,%.0f (%s, %.0f s)", Clock(frame), UnitDefs[Spring.GetUnitDefID(job.uid) or -1]
                    and UnitDefs[Spring.GetUnitDefID(job.uid)].name or "?", job.uid, job.x, job.z, tostring(j.key), (frame - j.since) / 30))
            else
                j.fails, j.state, j.tid = j.fails + 1, "wait", nil
                stats.failed = stats.failed + 1
                Spring.Echo(string.format("[LIFT] %s job for %d failed (%s), %d / %d", Clock(frame), job.uid, tostring(job.why), j.fails, M.CFG.MAX_FAILS))
                if j.fails >= M.CFG.MAX_FAILS or not Alive(job.uid) then jobs[job.uid] = nil end
            end
            parked[job.transport] = nil
        end
    end
    for uid, j in pairs(jobs) do
        if not Alive(uid) then
            if j.state == "fly" and j.tid then AT.Cancel(j.tid); parked[j.tid] = nil end
            jobs[uid] = nil
        end
    end
    for tid in pairs(trans) do
        local aj = AT.Job(tid)
        if aj and aj.reroute and aj.state == "carrying" then
            aj.reroute = nil
            Spring.GiveOrderToUnit(tid, AT.CMD_UNLOAD_UNIT, { aj.x, Spring.GetGroundHeight(aj.x, aj.z) or 0, aj.z }, {})
        end
    end
    -- re-route: a job in the air whose owner now wants another spot (its group moved or pulled back) goes there; the route is checked again
    -- compared with the spot the owner asked for last time (j.reqX), not the safe drop (game 8, 2026-11-02: the safe drop was always > 400 from the ask,
    -- so a transport re-routed every 2 s -- 748 times -- and a pickup restarted each time)
    for uid, j in pairs(jobs) do
        if j.state == "fly" and j.tid and j.wantX and (j.wantX - (j.reqX or j.x)) ^ 2 + (j.wantZ - (j.reqZ or j.z)) ^ 2 > M.CFG.REROUTE_R ^ 2
           and frame - (j.rerouteF or -1e9) >= 60 then
            j.rerouteF = frame
            j.reqX, j.reqZ = j.wantX, j.wantZ
            local x, z = SafeDrop(frame, j.tid, j.wantX, j.wantZ)
            if not x and O.MM and O.MM.Ready and O.MM.Ready() then      -- no clear route to it: set down short of it, toward home
                local tx, _, tz = Spring.GetUnitPosition(j.tid)
                local hx, hz = O.MM.Base()
                if tx then
                    local d = math.max(1, math.sqrt((hx - tx) ^ 2 + (hz - tz) ^ 2))
                    x, z = tx + (hx - tx) / d * 600, tz + (hz - tz) / d * 600
                end
            end
            local aj = AT.Job(j.tid)
            if x and aj then
                if aj.state == "carrying" then
                    Spring.GiveOrderToUnit(j.tid, AT.CMD_UNLOAD_UNIT, { x, Spring.GetGroundHeight(x, z) or 0, z }, {})
                else
                    aj.reroute = true      -- still picking up: the drop is moved once the unit is aboard (the pickup is not restarted)
                end
                aj.x, aj.z = x, z
                Spring.Echo(string.format("[LIFT] %s transport %d re-routed: %d -> %.0f,%.0f (%s, was %.0f,%.0f)", Clock(frame), j.tid, uid, x, z,
                    tostring(j.key), j.x, j.z))
                j.x, j.z = x, z
            end
        end
    end
    -- assign: the waiting jobs, highest prio first, each to the nearest idle transport that can carry its unit
    local wait = {}
    for _, j in pairs(jobs) do if j.state == "wait" then wait[#wait + 1] = j end end
    table.sort(wait, function(a, b) if a.prio ~= b.prio then return a.prio > b.prio end if a.since ~= b.since then return a.since < b.since end return a.uid < b.uid end)
    for _, j in ipairs(wait) do
        local ux, _, uz = Spring.GetUnitPosition(j.uid)
        local best, bd
        if ux then
            local udef = Spring.GetUnitDefID(j.uid)
            for tid, tdef in pairs(trans) do
                if not AT.Job(tid) and udef and AT.CanCarry(tdef, udef) then
                    local tx, _, tz = Spring.GetUnitPosition(tid)
                    local d = tx and (tx - ux) ^ 2 + (tz - uz) ^ 2
                    if d and (not bd or d < bd) then best, bd = tid, d end
                end
            end
        end
        if best then
        local x, z = SafeDrop(frame, best, j.x, j.z)
        local job, why
        if x then job, why = AT.Move(best, j.uid, x, z, frame, { arrive = M.CFG.ARRIVE, timeout = M.CFG.TIMEOUT })
        else why = "no clear route (enemy anti-air)" end
        if job then
            job.uid = j.uid
            j.state, j.tid, j.x, j.z, j.reqX, j.reqZ = "fly", best, x, z, j.x, j.z
            parked[best] = nil
            if O.ARMY and O.ARMY.Release then O.ARMY.Release(j.uid) end
            Spring.GiveOrderToUnit(j.uid, CMD.STOP, {}, {})       -- wait for the pickup
            Spring.Echo(string.format("[LIFT] %s transport %d lifts %s %d -> %.0f,%.0f (%s)", Clock(frame), best,
                UnitDefs[Spring.GetUnitDefID(j.uid)].name, j.uid, x, z, tostring(j.key)))
        elseif not x then
            if not j.blockLogged then                             -- waits (the unit walks meanwhile); logged once per job
                j.blockLogged = true
                Spring.Echo(string.format("[LIFT] %s %d waits: %s", Clock(frame), j.uid, why))
            end
        else
            Spring.Echo(string.format("[LIFT] %s cannot lift %d: %s", Clock(frame), j.uid, tostring(why)))
            jobs[j.uid] = nil
        end
        end
    end
    for tid in pairs(trans) do if not AT.Job(tid) then Park(frame, tid) end end
    -- more transports from the labs
    local LO = O.WG and O.WG.LabOrders
    local td = TransportDef()
    if LO and td then
        local mb = O.WG.MetalBot
        -- waiting jobs by the transport they need: light (the light transport can carry the unit) or heavy (Tzars)
        local nLight, nHeavy = 0, 0
        for _, j in ipairs(wait) do
            local ud = Spring.GetUnitDefID(j.uid)
            if ud and AT.CanCarry(td.id, ud) then nLight = nLight + 1 else nHeavy = nHeavy + 1 end
        end
        local have, haveH = 0, 0
        for _, tdef in pairs(trans) do if tdef == td.id then have = have + 1 else haveH = haveH + 1 end end
        local on = mb and (mb.artyOn or mb.stopOn)
        local want = math.min(M.CFG.MAX, math.max(on and M.CFG.MIN or 0, nLight > 0 and math.min(M.CFG.MAX, have + nLight) or 0))
        if want > 0 then
            LO.Request("lift:transport", { picks = { td.name }, n = math.max(0, want - have), tier = nLight > 0 and "high" or "normal", held_ok = true,
                                           require = false })
        end
        local hd = HeavyDefs()
        local wantH = math.min(M.CFG.MAX_HEAVY, math.max((mb and mb.stopOn) and M.CFG.MIN_HEAVY or 0, nHeavy > 0 and haveH + nHeavy or 0))
        if wantH > 0 and #hd > 0 then
            local picks = {}
            for _, d in ipairs(hd) do picks[#picks + 1] = d.name end
            LO.Request("lift:heavy", { picks = picks, n = math.max(0, wantH - haveH), tier = nHeavy > 0 and "high" or "normal", held_ok = true,
                                       require = false })   -- no T2 air lab for them: the T1 heavy transport comes from the T1 air labs
        end
    end
    if frame - lastLog >= M.CFG.LOG_EVERY then
        lastLog = frame
        local nT, nW, nF = 0, 0, 0
        for _ in pairs(trans) do nT = nT + 1 end
        for _, j in pairs(jobs) do if j.state == "wait" then nW = nW + 1 else nF = nF + 1 end end
        if nT + nW + nF > 0 then
            Spring.Echo(string.format("[LIFT] %s transports %d, jobs waiting %d / in the air %d, done %d, failed %d", Clock(frame), nT, nW, nF, stats.done, stats.failed))
        end
    end
end

return M
