-- bar_framework/raid_response.lua  (what the army does when enemies slip behind the line: answer them, then stand down)
--
-- Driven by what we SEE, not by damage: damage means we were already too late.  Any remembered enemy mobile unit on our side of the
-- line is an intruder; nearby intruders form a group; the nearest able units are sent at it until they are worth up to
-- NEED_MULT x what we saw there.  Fast responders get ahead of the raiders (the stance's "intercept" behaviour,
-- behaviors/intercept.lua); Shurikens and Wasps split the targets (stun / kill assignment).  The unit controller runs it once a
-- second (a half step while a unit is in the clock's HIGH tier); it also publishes the raid state the labs read (mb.raid,
-- mb.airLosses).
--
--     local RR = VFS.Include("LuaUI/Widgets/bar_framework/raid_response.lua")
--     local resp = RR.New{ cfg = BC.Preset("raid_response", "RAID"), label = "RAID_BOT",
--         ARMY = ARMY, UQ = UQ, TM = TM, CA = CA,
--         combatUnits = ..., musterPool = ..., responding = ...,           -- shared tables (the controller keeps the same objects)
--         teamID = ..., allyID = ..., isCommander = fn(defID),
--         line = function() return nodes, baseX, baseZ, advDir, perpDir end, lineAdvAt = fn(lateral),
--         host = function() return HOST end, ctx = function() return CTX end }
--     resp.Dispatch(frame)    resp.Publish(frame, mb)    resp.clusters (last pass's intruder groups)
--     resp.Assets(frame)      resp.Order(frame, uid, cmd, x, z)     the behaviour context's asset list and order sink
--     resp.Forget(uid)        resp.NoteAirLoss(frame)               resp.icpt (state: units, hist, raid, airLoss)
--
-- Options (RR.CFG; bar_framework/presets/raid_response.lua has the RAID group):
--   NEED_MULT        commit this multiple of the enemy value present
--   INTRUDER_TTL     frames a sighting is acted on once out of sight
--   PAST_MARGIN      elmos behind the line before an enemy counts as past it
--   CLUSTER_RADIUS   intruders this close are one group
--   KEEP             a responder stays with a group this close to its last
--   KEEP_MULT        (nil = off) as raiders die, release responders down to KEEP_MULT x the raid's value (furthest first, one stays)
--   CHANNEL_VALUE    size the response by the value in the raid's channel (a ground raid does not count air), not its total cost
--   REASSIGN_STANCE  a responder that stops responding gets its stance behaviours back
--   HOME_R           (nil = off; preset HOME) ground units answer only intruders within HOME_R of the base and are released once the group (or
--                    they) are more than HOME_R + HOME_SLACK out: early home guards stay at home and do not chase scouts (user 2026-10-26).
--                    Measured from the nearest eco structure (MM.BaseDist), not the commander's spawn (user 2026-10-28)
--   OUR_HALF         (default off) any intruder in our half of the map (MM.IsOurHalf) or within HOME_R of the base counts, not only past the line
--   REINFORCE_PULL   (nil = off; user 2026-10-30, CORE_v4: 54 gators walked up while every group was across the map and only new units answered) a distance in
--                    elmos: units waiting in the muster pool, and units of an attack group that are within this of the eco (reinforcements that have
--                    not left yet) are pulled into the response while it is short of its need
--   SQUAD_MIN        (nil = off; user 2026-10-30) responders to a group first gather at a rally point SQUAD_RALLY of the way from the eco to the intruders and go out
--                    together once their value is >= min(SQUAD_MIN, need) or SQUAD_WAIT seconds passed: early interception by a squad, not one unit at a time
--   THREAT_HOME      (default off; user 2026-10-29, the BM_akumar6 game: a few Rovers anywhere on our half set off under_attack, recalled every raid
--                    and held the army share at 1.0 for minutes) the raid record also carries `home` = the THREAT value of the intruder groups
--                    within THREAT_HOME_R of the eco footprint (MM.BaseDist).  A group's threat is its cost with scouts (UQ.is_scout) counted at
--                    SCOUT_WEIGHT.  The fsm signals under_attack / enemy_near_base read `home` when it is there (signals.lua)
--   CONTACTS         (nil = off; user 2026-10-30, CORE_v4: "intercept far out units but I don't want it to count as a raid ... keep the fighting
--                    away from the base") { LEAK_R, LEAK_ETA_S, CONVERT_FWD, MIN_THREAT }.  An intruder group farther than LEAK_R from the eco footprint is a
--                    CONTACT: it is met by interceptors taken only from the stage, new production and the muster pool (never home guards or
--                    attack groups), with no HOME_R limit, and it is NOT a raid: it is not in mb.raid, so under_attack / enemy_near_base /
--                    holdHome / the share machine do not see it.  A group becomes a LEAK -- the old raid response, home guards and all, and
--                    counted in mb.raid -- once it is inside LEAK_R, or when the interceptors are short of its need and it is closing on the
--                    eco with LEAK_ETA_S seconds or less to go.  Interceptors whose contact is gone and that stand past CONVERT_FWD of the way
--                    to the enemy become raiders where they are (click_army Adopt: a new group, or the weakest one).  mb.contacts = { n, value }.
--                    MIN_THREAT (default 0): a contact whose threat (cost, scouts at SCOUT_WEIGHT) is under this gets no interceptors (lone scouts).
--   COVER            (nil = off; user 2026-10-30, CORE_v4 game review): { <cover_defence.lua CFG keys> }.  The GROUND answer to threats on our
--                    side goes to bar_framework/cover_defence.lua (radar dots included, a line in front of the threatened eco that pushes out,
--                    cut-offs, a launch gate through mb.cover); this module keeps air raids, stuns and Wasps.  Replaces CONTACTS for ground.

local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")

local RR = {}

RR.CFG = { NEED_MULT = 2.0, INTRUDER_TTL = 900, PAST_MARGIN = 200, CLUSTER_RADIUS = 700, KEEP = 1500,
           KEEP_MULT = nil, CHANNEL_VALUE = false, REASSIGN_STANCE = false, HOME_R = nil, HOME_SLACK = 150, OUR_HALF = false,
           THREAT_HOME = false, THREAT_HOME_R = 1200, SCOUT_WEIGHT = 0.1, REINFORCE_PULL = nil, SQUAD_MIN = nil, SQUAD_WAIT = 20, SQUAD_RALLY = 0.4,
           CONTACTS = nil, COVER = nil }
RR.NIL_OPTIONS = { "KEEP_MULT", "HOME_R", "REINFORCE_PULL", "SQUAD_MIN", "CONTACTS", "COVER" }

function RR.New(o)
    local C = {}
    for k, v in pairs(RR.CFG) do C[k] = v end
    BC.Apply("raid_response", C, o.cfg, o.label, RR.NIL_OPTIONS)

    local r = { clusters = {}, cfg = C }
    local ARMY, UQ, TM, CA = o.ARMY, o.UQ, o.TM, o.CA
    local MM = o.MM                                  -- map_model (HOME_R is measured from the eco footprint; OUR_HALF)
    local combatUnits, musterPool, responding = o.combatUnits, o.musterPool, o.responding
    -- COVER: the ground answer (cover_defence.lua); its units sit in `responding` as { cover = true, ... } and are skipped below
    local COV = C.COVER and VFS.Include("LuaUI/Widgets/bar_framework/cover_defence.lua").New{
        cfg = C.COVER, ARMY = o.ARMY, UQ = o.UQ, TM = o.TM, EI = o.EI, MM = o.MM, CA = o.CA,
        combatUnits = combatUnits, musterPool = musterPool, responding = responding, teamID = o.teamID, allyID = o.allyID } or nil
    r.cover = COV
    local myTeamID, myAllyID = o.teamID, o.allyID
    local IsCommander, LineAdvAt = o.isCommander, o.lineAdvAt
    local function host() return o.host and o.host() end
    local function ctx() return o.ctx and o.ctx() end
    local nodes, baseX, baseZ, advDir, perpDir       -- the line, synced at the start of Dispatch
    local INTRUDER_TTL, PAST_MARGIN, CLUSTER_RADIUS = C.INTRUDER_TTL, C.PAST_MARGIN, C.CLUSTER_RADIUS
    local RESPOND_KEEP, RESPOND_NEED_MULT, RESPOND_KEEP_MULT = C.KEEP, C.NEED_MULT, C.KEEP_MULT
    local CMD_FIGHT = (CMD and CMD.FIGHT) or 16
    local CMD_MOVE_ = (CMD and CMD.MOVE) or 10
    local spGetUnitDefID, spGetUnitPosition = Spring.GetUnitDefID, Spring.GetUnitPosition
    local spGetUnitHealth, spGetUnitAllyTeam = Spring.GetUnitHealth, Spring.GetUnitAllyTeam
    local spGetUnitsInCylinder, spGetGroundHeight, spIsPosInLos = Spring.GetUnitsInCylinder, Spring.GetGroundHeight, Spring.IsPosInLos

    local function CanAnswer(defID, channel)
        if channel == "air" then return UQ.can_hit_air(defID) end
        return UQ.can_hit_ground(defID)
    end

    -- STANCE_BOT raid response (behaviors/intercept.lua).
    --   hist     [enemy id] = {x, z, f, vx, vz, still}  position history -> velocity (elmos/s) and when it last went slow
    --   units    [uid] = true: responders the host's "intercept" behaviour is moving
    --   assets   what the raiders' path is checked against {x, z, w}, rescanned every ASSET_EVERY frames
    --   raid     last published raid record (labs read it as mb.raid)
    local ICPT = {
        ON = true,
        MIN_SPEED   = 60,     -- a responder slower than this (and slower than 0.7x the raiders) keeps its plain FIGHT
        STILL_SPEED = 14,     -- elmos/s: the same threshold the behaviour uses for "stopped"
        ASSET_EVERY = 150,
        hist = {}, units = {}, assets = {}, assetF = -1e9, raid = nil, airLoss = {}, sq = {},
    }

    -- Velocity of one enemy contact from its last two distinct sightings.
    function ICPT.Track(id, c)
        local h = ICPT.hist[id]
        if not h then
            ICPT.hist[id] = { x = c.x, z = c.z, f = c.frame, vx = 0, vz = 0, still = c.frame }
            return ICPT.hist[id]
        end
        if c.frame > h.f then
            local dt = (c.frame - h.f) / 30
            local vx, vz = (c.x - h.x) / dt, (c.z - h.z) / dt
            if dt > 12 then vx, vz = 0, 0 end                      -- too old a pair to say anything
            h.vx, h.vz = 0.5 * h.vx + 0.5 * vx, 0.5 * h.vz + 0.5 * vz
            h.x, h.z, h.f = c.x, c.z, c.frame
            if math.sqrt(h.vx * h.vx + h.vz * h.vz) >= ICPT.STILL_SPEED then h.still = c.frame end
        end
        return h
    end

    local function IntruderGroups(frame)   -- reads the line (nodes, baseX, advDir, perpDir) synced by Dispatch
        local groups = {}
        if not (nodes and baseX and TM and UQ) then return groups end
        for cid, c in pairs(TM.Contacts()) do
            local age = frame - c.frame
            if age <= INTRUDER_TTL and c.defID and UQ.is_mobile(c.defID) then
                -- We can see the spot but nothing has been seen there since: it moved on.
                local gone = age > TM.SCAN_PERIOD * 1.5 and spIsPosInLos
                    and spIsPosInLos(c.x, spGetGroundHeight(c.x, c.z) or 0, c.z, myAllyID)
                if not gone then
                    local dx, dz = c.x - baseX, c.z - baseZ
                    local adv = dx * advDir.x + dz * advDir.z
                    local lat = dx * perpDir.x + dz * perpDir.z
                    -- user 2026-10-28: an enemy seen on our side of the map is there to attack, so it counts even before it is
                    -- past the line (OUR_HALF); a unit inside / next to the eco footprint always counts
                    local ours = adv < LineAdvAt(lat) - PAST_MARGIN
                    if not ours and C.OUR_HALF and MM and MM.Ready() then
                        ours = MM.IsOurHalf(c.x, c.z) or (MM.BaseDist and MM.BaseDist(c.x, c.z) <= (C.HOME_R or 700))
                    end
                    if ours then
                        local cost = UQ.metal_cost(c.defID) or c.v or 0
                        local g
                        for _, o in ipairs(groups) do
                            if (o.x - c.x) ^ 2 + (o.z - c.z) ^ 2 <= CLUSTER_RADIUS ^ 2 then g = o; break end
                        end
                        if not g then
                            g = { x = c.x, z = c.z, n = 0, cost = 0, threat = 0, air = 0, gnd = 0, wvx = 0, wvz = 0, stillS = 1e9 }
                            groups[#groups + 1] = g
                        end
                        local n = g.n + 1
                        g.x, g.z = (g.x * g.n + c.x) / n, (g.z * g.n + c.z) / n
                        g.n, g.cost = n, g.cost + cost
                        g.threat = g.threat + cost * ((UQ.is_scout and UQ.is_scout(c.defID)) and C.SCOUT_WEIGHT or 1)   -- THREAT_HOME: scouts count little
                        local h = ICPT.Track(cid, c)
                        local w = math.max(1, cost)
                        g.wvx, g.wvz = g.wvx + h.vx * w, g.wvz + h.vz * w
                        g.stillS = math.min(g.stillS, (frame - h.still) / 30)
                        if c.air then g.air = g.air + cost else g.gnd = g.gnd + cost end
                    end
                end
            end
        end
        for _, g in ipairs(groups) do
            g.channel = (g.air > g.gnd) and "air" or "ground"
            local w = math.max(1, g.cost)
            g.vx, g.vz = g.wvx / w, g.wvz / w
            g.speed = math.sqrt(g.vx * g.vx + g.vz * g.vz)
            -- CONTACTS: how far from the eco, and how soon it gets there (only while it is closing on the base)
            if C.CONTACTS and MM and MM.BaseDist then
                g.dEco = MM.BaseDist(g.x, g.z)
                g.contact = g.dEco > (C.CONTACTS.LEAK_R or 1500)
                g.etaEco = math.huge
                local bx, bz = MM.Base()
                if bx and g.speed >= ICPT.STILL_SPEED then
                    local dx, dz = bx - g.x, bz - g.z
                    local d = math.sqrt(dx * dx + dz * dz)
                    local closing = d > 0 and (g.vx * dx + g.vz * dz) / d or 0      -- elmos/s toward the base
                    if closing > 1 then g.etaEco = g.dEco / closing end
                end
            end
        end
        -- forget enemies not seen for a while
        for id, h in pairs(ICPT.hist) do
            if frame - h.f > INTRUDER_TTL * 2 then ICPT.hist[id] = nil end
        end
        table.sort(groups, function(a, b) return a.cost > b.cost end)
        return groups
    end

    -- LINE_CLICK_v13 (user): Shuriken micro.  ~30 Shurikens all stunned the SAME unit.  Their weapon paralyses: stun a
    -- unit, leave ONE on it to keep it stunned, and send the rest to the next enemy that is still moving.  Each responding
    -- Shuriken gets an ATTACK on its own target: an unstunned target gets NEED Shurikens (2-6 by its health), a stunned
    -- one keeps a single keeper; the rest spread over the unstunned targets.  Assignments stick while they still fit.
    local STUN = { NAMES = { corbw = true }, R = 1200, HP_PER = 700, NEED_MIN = 2, NEED_MAX = 6, LOG_EVERY = 900,
             STUNS = true, tag = "stun", target = {}, logF = -1e9 }
    -- LINE_CLICK_v16 (user): the same split for Wasps.  No stun, so every target counts as still moving: NEED Wasps by its
    -- health, the spare spread round-robin over the targets.
    local SPLIT_WASP = { NAMES = { corape = true }, R = 1500, HP_PER = 900, NEED_MIN = 1, NEED_MAX = 8, LOG_EVERY = 900,
                   tag = "wasp", target = {}, logF = -1e9 }
    local CMD_ATTACK_ = (CMD and CMD.ATTACK) or 20

    local AssignStuns = function(frame, ids, P, cx, cz)
        P = P or STUN
        local stunTarget = P.target
        if #ids == 0 then return end
        -- the enemies near the stunners: mobile, visible, not dead
        local sx, sz = 0, 0
        for _, uid in ipairs(ids) do
            local x, _, z = spGetUnitPosition(uid)
            if x then sx, sz = sx + x, sz + z end
        end
        sx, sz = sx / #ids, sz / #ids
        -- a raid group's own spot: the pack looks for targets there, not at the middle of packs on different sides
        if cx then sx, sz = cx, cz end
        local targets, byId = {}, {}
        for _, eid in ipairs(spGetUnitsInCylinder(sx, sz, P.R) or {}) do
            local defID = spGetUnitDefID(eid)
            if defID and spGetUnitAllyTeam(eid) ~= myAllyID and UQ.is_mobile(defID) then
                local hp, mhp, para = spGetUnitHealth(eid)
                if hp and mhp and mhp > 0 then
                    local ud = UnitDefs[defID]
                    local v = ud and ((ud.metalCost or 0) + (ud.energyCost or 0) / 70) or 0
                    local t = { id = eid, stunned = P.STUNS and (para or 0) > mhp or false, mhp = mhp, v = v, have = {} }
                    if P.STUNS then
                        t.need = t.stunned and 1 or math.max(P.NEED_MIN, math.min(P.NEED_MAX, math.ceil(mhp / P.HP_PER)))
                    else
                        -- damage dealers: enough to kill what is LEFT of it (current health), then they move on
                        t.need = math.max(P.NEED_MIN, math.min(P.NEED_MAX, math.ceil(hp / P.HP_PER)))
                        t.score = v / t.need            -- value killed per Wasp committed
                    end
                    targets[#targets + 1] = t
                    byId[eid] = t
                end
            end
        end
        if #targets == 0 then      -- nothing to stun near them yet: fly at the intruders like everyone else
            for _, uid in ipairs(ids) do
                stunTarget[uid] = nil
                local g = responding[uid]
                if g then ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "RESPOND", cmd = CMD_FIGHT, x = g.x, z = g.z }, frame) end
            end
            return
        end
        -- unstunned (still moving) first, then the most valuable
        table.sort(targets, function(a, b)
            if a.stunned ~= b.stunned then return not a.stunned end
            if a.score and b.score and a.score ~= b.score then return a.score > b.score end
            return a.v > b.v
        end)
        -- keep sticky assignments that still fit
        local free = {}
        for _, uid in ipairs(ids) do
            local t = byId[stunTarget[uid] or -1]
            if t and #t.have < t.need then t.have[#t.have + 1] = uid else free[#free + 1] = uid end
        end
        -- fill what is still needed, nearest stunner first
        for _, t in ipairs(targets) do
            if #free == 0 then break end
            local tx, _, tz = spGetUnitPosition(t.id)
            while #t.have < t.need and #free > 0 and tx do
                local bi, bd
                for i, uid in ipairs(free) do
                    local x, _, z = spGetUnitPosition(uid)
                    local d = x and ((x - tx) ^ 2 + (z - tz) ^ 2) or math.huge
                    if not bd or d < bd then bi, bd = i, d end
                end
                t.have[#t.have + 1] = table.remove(free, bi)
            end
        end
        -- spare stunners: round-robin over the unstunned targets (never pile onto a stunned one)
        local moving = {}
        for _, t in ipairs(targets) do if not t.stunned then moving[#moving + 1] = t end end
        local k = 0
        -- damage dealers pile the spare onto the best few kills (overkill only wastes seconds); stunners spread out
        if not P.STUNS then while #moving > 3 do table.remove(moving) end end
        while #free > 0 and #moving > 0 do
            k = k % #moving + 1
            local t = moving[k]
            t.have[#t.have + 1] = table.remove(free, 1)
        end
        local nStun, nMove = 0, 0
        for _, t in ipairs(targets) do
            for _, uid in ipairs(t.have) do
                stunTarget[uid] = t.id
                ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "RESPOND", cmd = CMD_ATTACK_, targetID = t.id }, frame)
            end
            if t.stunned then nStun = nStun + 1 else nMove = nMove + 1 end
        end
        if frame - P.logF >= P.LOG_EVERY then
            P.logF = frame
            local sec = math.floor(frame / 30)
            Spring.Echo(string.format("[UC/%s] %d:%02d %d units on %d targets (%d stunned, %d still moving)",
                P.tag, math.floor(sec / 60), sec % 60, #ids, #targets, nStun, nMove))
        end
    end

    -- What the raiders' path is checked against: the commander, factories, build power, mexes and generators.
    -- w = metal cost x a role factor (build power and the commander are what a raid hurts most).
    function ICPT.Assets(frame)
        if frame - ICPT.assetF < ICPT.ASSET_EVERY then return ICPT.assets end
        ICPT.assetF = frame
        local out = {}
        for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
            local defID = spGetUnitDefID(uid)
            local d = defID and UnitDefs[defID]
            if d and (d.speed or 0) <= 0 or (d and IsCommander(defID)) then
                local f
                if IsCommander(defID) then f = 4
                elseif d.isFactory then f = 1.5
                elseif (d.buildSpeed or 0) > 0 and (d.speed or 0) <= 0 then f = 1.5
                elseif (d.extractsMetal or 0) > 0 then f = 1.2
                elseif (d.energyMake or 0) >= 20 or (d.windGenerator or 0) > 0 then f = 0.8 end
                if f then
                    local x, _, z = spGetUnitPosition(uid)
                    if x then out[#out + 1] = { x = x, z = z, w = math.max(20, d.metalCost or 0) * f } end
                end
            end
        end
        ICPT.assets = out
        return out
    end

    -- The behaviour's order sink: through the army broker (retreat still outranks it).  The broker re-sends a MOVE only when
    -- the target has moved 250 elmos; a raider outruns that, so a changed target 80+ elmos from the last one goes out
    -- directly (at most every 30 frames) and the broker's record is updated to match.
    function ICPT.Order(frame, uid, cmd, x, z)
        local before = ARMY.OrdersIssued()
        ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "RESPOND", cmd = cmd, x = x, z = z }, frame)
        if ARMY.OrdersIssued() ~= before then return end
        local d = ARMY.Duty(uid)
        if d and d.role == "RESPOND" and d.issuedX and d.lastOrderFrame and frame - d.lastOrderFrame >= 30
           and (d.lastCmd ~= cmd or (x - d.issuedX) ^ 2 + (z - d.issuedZ) ^ 2 > 80 * 80) then
            Spring.GiveOrderToUnit(uid, cmd, { x, spGetGroundHeight(x, z) or 0, z }, {})
            d.lastOrderFrame, d.lastCmd, d.issuedX, d.issuedZ, d.tx, d.tz = frame, cmd, x, z, x, z
        end
    end

    -- Can this unit usefully get ahead of that cluster?  Slow units against fast raiders keep the plain FIGHT.
    function ICPT.Eligible(uid, defID, g)
        if not (ICPT.ON and host() and ctx()) then return false end
        local sp = UQ.max_speed(defID) or 0
        return sp >= math.min(ICPT.MIN_SPEED, 0.7 * (g.speed or 0))
    end

    local function EndIntercept(uid)
        if ICPT.units[uid] then
            ICPT.units[uid] = nil
            local HOST = host()
            if HOST then
                HOST:Remove(uid)
                -- RAID_BOT: a responder that stops responding gets its stance behaviours back (intercept replaced them)
                local defID = combatUnits[uid]
                if C.REASSIGN_STANCE and defID and WG and WG.Strategy and spGetUnitDefID(uid) then WG.Strategy:Assign(HOST, uid, defID) end
            end
        end
    end

    -- The raid's value in the channel its responders answer (user 2026-10-13: "not including air" for a ground raid).
    local function ChannelValue(g)
        if not C.CHANNEL_VALUE then return g.cost or 0 end
        return (g.channel == "air") and (g.air or 0) or (g.gnd or 0)
    end

    -- HOME_R: a ground unit stays inside the radius around the base (air units are not bound)
    local function OutsideHome(defID, x, z, extra)
        if not C.HOME_R or not baseX or (UnitDefs[defID] or {}).canFly then return false end
        local r = C.HOME_R + (extra or 0)
        -- user 2026-10-28: from the nearest eco structure (MM.BaseDist), not a circle round the commander's spawn -- the
        -- circle left ground raiders in the outer mex fields unanswered once the base had grown past HOME_R
        if MM and MM.BaseDist then return MM.BaseDist(x, z) > r end
        return (x - baseX) ^ 2 + (z - baseZ) ^ 2 > r * r
    end

    local function DispatchResponses(frame)
        if not ARMY or not UQ then return end
        nodes, baseX, baseZ, advDir, perpDir = o.line()
        local HOST = host()

        local groups = IntruderGroups(frame)
        r.clusters = groups
        if COV then                     -- COVER: ground threats are cover_defence's; this pass answers air raids only
            local airOnly = {}
            for _, g in ipairs(groups) do if g.channel == "air" then airOnly[#airOnly + 1] = g end end
            groups = airOnly
        end

        -- Each responder stays with the group nearest its last one; no group near, stand down.
        local have = {}   -- [group] = value committed
        local convert = {}  -- CONTACTS: interceptors whose contact is gone, far enough out to raid from where they are
        for uid, last in pairs(responding) do
          if not last.cover then          -- COVER units are cover_defence's
            local role = ARMY.RoleOf(uid)
            local best, bestD = nil, RESPOND_KEEP ^ 2
            for _, g in ipairs(groups) do
                local d = (g.x - last.x) ^ 2 + (g.z - last.z) ^ 2
                if d < bestD then best, bestD = g, d end
            end
            -- (a CONTACT is met wherever it is: HOME_R only binds the answer to a leak)
            if best and not best.contact and OutsideHome(combatUnits[uid], best.x, best.z, C.HOME_SLACK) then best = nil end       -- the raid moved out of the home radius
            local ux0, _, uz0 = spGetUnitPosition(uid)
            if best and not best.contact and ux0 and OutsideHome(combatUnits[uid], ux0, uz0, 2 * C.HOME_SLACK) then best = nil end   -- the unit itself got too far out
            if not best or not spGetUnitDefID(uid) or role == "RETREAT" then
                if role == "RESPOND" then ARMY.Release(uid) end
                responding[uid] = nil
                EndIntercept(uid)
                if C.CONTACTS and last.contact and ux0 and role ~= "RETREAT" and MM and MM.Ready() and spGetUnitDefID(uid)
                   and MM.Forward(ux0, uz0) >= (C.CONTACTS.CONVERT_FWD or 0.3) * MM.Dist() then
                    convert[#convert + 1] = uid
                end
            else
                responding[uid] = best
                have[best] = (have[best] or 0) + (UQ.metal_cost(combatUnits[uid]) or 0)
            end
          end
        end

        if #convert > 0 and CA and CA.Adopt then CA.Adopt(frame, convert) end

        if RESPOND_KEEP_MULT then
            -- RAID_BOT: as raiders die, pull responders off down to RESPOND_KEEP_MULT x the raid's channel value (furthest
            -- first, at least one stays).  In the reviewed game 24 units (18k) were still chasing 2 raiders worth 470.
            for _, g in ipairs(groups) do
                local keep = RESPOND_KEEP_MULT * ChannelValue(g)
                if (have[g] or 0) > keep then
                    local mine = {}
                    for uid, rg in pairs(responding) do
                        if rg == g then
                            local ux, _, uz = spGetUnitPosition(uid)
                            if ux then
                                mine[#mine + 1] = { uid = uid, cost = UQ.metal_cost(combatUnits[uid]) or 0,
                                                    d = (ux - g.x) ^ 2 + (uz - g.z) ^ 2 }
                            end
                        end
                    end
                    table.sort(mine, function(a, b) if a.d ~= b.d then return a.d > b.d end return a.uid < b.uid end)
                    local released, freed, moved = 0, 0, 0
                    for i, m in ipairs(mine) do
                        if have[g] - m.cost < keep or i == #mine then break end
                        -- an extra goes first to another raid that is short of its need (in the first match the extras were
                        -- released and the same tick fresh units were pulled for the cluster next door)
                        local to
                        for _, g2 in ipairs(groups) do
                            if g2 ~= g and (have[g2] or 0) < ChannelValue(g2) * RESPOND_NEED_MULT
                               and CanAnswer(combatUnits[m.uid], g2.channel) then to = g2; break end
                        end
                        if to then
                            responding[m.uid] = to
                            have[to] = (have[to] or 0) + m.cost
                            moved = moved + 1
                        else
                            if ARMY.RoleOf(m.uid) == "RESPOND" then ARMY.Release(m.uid) end
                            responding[m.uid] = nil
                            EndIntercept(m.uid)
                            released, freed = released + 1, freed + m.cost
                        end
                        have[g] = have[g] - m.cost
                    end
                    if moved > 0 then
                        local sec = math.floor(frame / 30)
                        Spring.Echo(string.format("[INTERCEPT] %d:%02d move %d extra units to another raid short of its need",
                            math.floor(sec / 60), sec % 60, moved))
                    end
                    if released > 0 then
                        local sec = math.floor(frame / 30)
                        Spring.Echo(string.format("[INTERCEPT] %d:%02d release %d units (%.0f): kept %.0f of %.0f allowed (%.1fx the raid's %s value %.0f)",
                            math.floor(sec / 60), sec % 60, released, freed, have[g], keep, RESPOND_KEEP_MULT, g.channel,
                            ChannelValue(g)))
                    end
                end
            end
        end

        -- CONTACTS: a contact's interceptors come from the stage, new production and the muster pool only, wherever the contact is
        local function ContactCands(g)
            local cands = {}
            for uid, defID in pairs(combatUnits) do
                if spGetUnitDefID(uid) and not responding[uid] and CanAnswer(defID, g.channel) then
                    local role = ARMY.RoleOf(uid)
                    local ok = musterPool[uid] or role == nil or (role == "BLOB" and CA and not CA.InGroup(uid))
                    if ok then
                        local ux, _, uz = spGetUnitPosition(uid)
                        if ux then
                            cands[#cands + 1] = { uid = uid, cost = UQ.metal_cost(defID) or 0,
                                                  eta = math.sqrt((ux - g.x) ^ 2 + (uz - g.z) ^ 2) / math.max(1, UQ.max_speed(defID)) }
                        end
                    end
                end
            end
            return cands
        end

        for _, g in ipairs(groups) do
            local need = ChannelValue(g) * RESPOND_NEED_MULT
            local got  = have[g] or 0
            local mode = "leak"
            if C.CONTACTS and g.contact then
                mode = "contact"
                if got < need and (g.threat or g.cost or 0) >= (C.CONTACTS.MIN_THREAT or 0) then
                    local cands = ContactCands(g)
                    table.sort(cands, function(a, b) return a.eta < b.eta end)
                    local added = 0
                    for _, c in ipairs(cands) do
                        if got >= need or (added > 0 and got + c.cost > need) then break end
                        responding[c.uid] = g
                        got, added = got + c.cost, added + 1
                    end
                    if added > 0 then
                        local sec = math.floor(frame / 30)
                        Spring.Echo(string.format("[UC/contact] %d:%02d %s contact at %d,%d (%.0f from the eco, eta %s): seen %d units cost %.0f, +%d interceptors (committed %.0f / %.0f)",
                            math.floor(sec / 60), sec % 60, g.channel, g.x, g.z, g.dEco or 0,
                            (g.etaEco or math.huge) < 1e8 and string.format("%.0fs", g.etaEco) or "-", g.n, g.cost, added, got, need))
                    end
                end
                -- a contact we cannot stop in time is a leak: the full raid response (home guards, the pull) answers the rest
                g.leak = got < need and (g.etaEco or math.huge) <= (C.CONTACTS.LEAK_ETA_S or 25)
                if g.leak then mode = "leak" end
            else
                g.leak = true
            end
            if mode == "leak" and got < need then
                local cands = {}
                for uid, defID in pairs(combatUnits) do
                    local pulled = false
                    if C.REINFORCE_PULL and spGetUnitDefID(uid) and not responding[uid] and CanAnswer(defID, g.channel) then
                        if musterPool[uid] then pulled = true
                        elseif CA and CA.InGroup(uid) and MM and MM.BaseDist and not (UnitDefs[defID] or {}).canFly then
                            local px, _, pz = spGetUnitPosition(uid)
                            if px and MM.BaseDist(px, pz) <= C.REINFORCE_PULL then
                                -- only a straggler of a group that is far away is pulled; the test reads the group's centre and detaches
                                -- after it (2026-10-30: Detach ran first, so every group just launched from the stage, ~1600 from the eco,
                                -- lost all its units the next tick: 630 of 653 launches ended "0 of peak N left after 0s")
                                local cx, cz = (CA.GroupCentre or CA.Detach)(uid)
                                pulled = cx ~= nil and MM.BaseDist(cx, cz) > 2 * C.REINFORCE_PULL
                                if pulled and CA.GroupCentre then CA.Detach(uid) end
                            end
                        end
                    end
                    if spGetUnitDefID(uid) and not responding[uid] and (pulled or not musterPool[uid])
                       and CanAnswer(defID, g.channel) and not OutsideHome(defID, g.x, g.z, 0) then
                        local role = ARMY.RoleOf(uid)
                        local ok = role == nil or role == "HOME_GUARD"
                        -- LINE_CLICK: only reinforcements (new units and the ones waiting at the stage), home
                        -- guards and air defend the base.  A unit in an attack group never does -- the groups
                        -- stay on the other side of the map.
                        if role == "BLOB" and CA and not CA.InGroup(uid) then ok = true end
                        if pulled then ok = true end
                        if role == "LINE" then
                            -- A unit holding a node that is fighting stays and fights.
                            local node = nodes and nodes[ARMY.Slot(uid) or 0]
                            ok = not (node and node.engaged)
                        end
                        if ok then
                            local ux, _, uz = spGetUnitPosition(uid)
                            if ux then
                                cands[#cands + 1] = {
                                    uid = uid, cost = UQ.metal_cost(defID) or 0,
                                    eta = math.sqrt((ux - g.x) ^ 2 + (uz - g.z) ^ 2)
                                          / math.max(1, UQ.max_speed(defID)),
                                }
                            end
                        end
                    end
                end
                table.sort(cands, function(a, b) return a.eta < b.eta end)

                local added = 0
                for _, c in ipairs(cands) do
                    -- Up to 2x what was seen, but never zero units for a real intruder.
                    if got >= need or (added > 0 and got + c.cost > need) then break end
                    responding[c.uid] = g
                    got, added = got + c.cost, added + 1
                end
                have[g] = got
                if added > 0 then
                    local sec = math.floor(frame / 30)
                    Spring.Echo(string.format(
                        "[UC/respond] %d:%02d %s intruders at %d,%d: seen %d units cost %.0f, +%d units (committed %.0f / %.0f)",
                        math.floor(sec / 60), sec % 60, g.channel, g.x, g.z, g.n, g.cost,
                        added, got, need))
                end
            end
            have[g] = got
        end

        -- SQUAD_MIN: a group's responders form up first (rally point toward the intruders), then go out together
        local forming = {}
        if C.SQUAD_MIN then
            local per = {}
            for uid, g in pairs(responding) do
                local t0 = ICPT.sq[uid]
                if not t0 then t0 = frame; ICPT.sq[uid] = t0 end
                local e = per[g]
                if not e then e = { v = 0, t0 = frame }; per[g] = e end
                e.v = e.v + (UQ.metal_cost(combatUnits[uid]) or 0)
                if t0 < e.t0 then e.t0 = t0 end
            end
            for uid in pairs(ICPT.sq) do if not responding[uid] then ICPT.sq[uid] = nil end end
            for g, e in pairs(per) do
                local want = math.min(C.SQUAD_MIN, ChannelValue(g) * RESPOND_NEED_MULT)
                if e.v < want and frame - e.t0 < C.SQUAD_WAIT * 30 and baseX then
                    local f = C.SQUAD_RALLY
                    g.rx, g.rz = baseX + (g.x - baseX) * f, baseZ + (g.z - baseZ) * f
                    forming[g] = true
                end
            end
        end
        local stunners, wasps = {}, {}
        for uid, g in pairs(responding) do
            local nm = (UnitDefs[combatUnits[uid] or -1] or {}).name or ""
            if g.cover then
                -- COVER: cover_defence orders this unit
            elseif forming[g] and not STUN.NAMES[nm] and not SPLIT_WASP.NAMES[nm] and not (UnitDefs[combatUnits[uid] or -1] or {}).canFly then
                EndIntercept(uid)
                ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "RESPOND", cmd = CMD_MOVE_, x = g.rx, z = g.rz }, frame)
            elseif STUN.NAMES[nm] then
                stunners[#stunners + 1] = uid
            elseif SPLIT_WASP.NAMES[nm] then
                wasps[#wasps + 1] = uid
            elseif ICPT.Eligible(uid, combatUnits[uid], g) then
                -- get ahead of the raiders (behaviors/intercept.lua), not to where they were
                if not ICPT.units[uid] then
                    if HOST:Assign(uid, "intercept") then ICPT.units[uid] = true end
                end
                if not ICPT.units[uid] then
                    ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "RESPOND", cmd = CMD_FIGHT, x = g.x, z = g.z }, frame)
                end
            else
                EndIntercept(uid)
                ARMY.Claim(ARMY.PRIO.RESPOND, uid, {
                    role = "RESPOND", cmd = CMD_FIGHT, x = g.x, z = g.z,
                }, frame)
            end
        end
        -- one assignment per raid group: with two groups on different sides one pooled pack averaged to a spot between
        -- them and stunned whatever was nearest that, while the other raid went unanswered
        local function PerGroup(ids, P)
            local byGroup, order = {}, {}
            for _, uid in ipairs(ids) do
                local g = responding[uid]
                if g then
                    if not byGroup[g] then byGroup[g] = {}; order[#order + 1] = g end
                    local l = byGroup[g]; l[#l + 1] = uid
                end
            end
            for _, g in ipairs(order) do AssignStuns(frame, byGroup[g], P, g.x, g.z) end
        end
        PerGroup(stunners, STUN)
        PerGroup(wasps, SPLIT_WASP)
    end

    r.icpt = ICPT
    r.Dispatch = function(frame)
        DispatchResponses(frame)
        if COV then
            local ok, err = pcall(COV.Step, frame)     -- a planner error is logged, not fatal to the unit controller
            if not ok then Spring.Echo("[COVER] error: " .. tostring(err)) end
        end
    end
    r.Assets = ICPT.Assets
    r.Order = ICPT.Order
    function r.Forget(uid) ICPT.units[uid] = nil end
    function r.NoteAirLoss(frame) ICPT.airLoss[#ICPT.airLoss + 1] = frame end
    -- the raid state the labs read: the intruder clusters now (value, channel, speed), kept for them to apply a TTL
    function r.Publish(frame, mb)
        if COV then COV.Publish(frame, mb) end
        if #r.clusters > 0 or (COV and #COV.FightGroups() > 0) then
            -- CONTACTS: only leaks are a raid; contacts are published apart (mb.contacts)
            local raidGroups = r.clusters
            if COV then
                raidGroups = {}
                for _, g in ipairs(r.clusters) do if g.channel == "air" then raidGroups[#raidGroups + 1] = g end end
                for _, g in ipairs(COV.FightGroups()) do raidGroups[#raidGroups + 1] = g end
            elseif C.CONTACTS then
                raidGroups = {}
                local cn, cv = 0, 0
                for _, g in ipairs(r.clusters) do
                    if g.leak or not g.contact then raidGroups[#raidGroups + 1] = g else cn, cv = cn + 1, cv + (g.cost or 0) end
                end
                mb.contacts = { frame = frame, n = cn, value = cv }
            end
            local v, gnd, air, spd, moving = 0, 0, 0, 0, false
            for _, g in ipairs(raidGroups) do
                v, gnd, air = v + g.cost, gnd + g.gnd, air + g.air
                spd = math.max(spd, g.speed or 0)
                if (g.speed or 0) >= ICPT.STILL_SPEED then moving = true end
            end
            -- user 2026-10-28 (proportional response): `need` = what the intruders we can reach (inside HOME_R of the eco footprint) call for
            -- (NEED_MULT x their channel value), `committed` = the value of the units answering now.  holdHome keeps new production home only
            -- while committed < need, so a raid in our half does not freeze production once it is answered
            local need, committed = 0, 0
            for _, g in ipairs(raidGroups) do
                if not (C.HOME_R and MM and MM.BaseDist and MM.BaseDist(g.x, g.z) > C.HOME_R) then need = need + ChannelValue(g) * RESPOND_NEED_MULT end
            end
            for uid in pairs(responding) do committed = committed + (UQ.metal_cost(combatUnits[uid]) or 0) end
            -- THREAT_HOME: the threat value (scouts count SCOUT_WEIGHT) of the groups near our eco, not anywhere on our half
            local home
            if C.THREAT_HOME and MM and MM.BaseDist then
                home = 0
                for _, g in ipairs(raidGroups) do
                    if MM.BaseDist(g.x, g.z) <= C.THREAT_HOME_R then home = home + (g.threat or g.cost or 0) end
                end
            end
            if #raidGroups > 0 then
                ICPT.raid = { frame = frame, value = v, ground = gnd, air = air, speed = spd, moving = moving,
                              channel = (air > gnd) and "air" or "ground", n = #raidGroups, need = need, committed = committed, home = home }
            end
        end
        mb.raid = ICPT.raid
        local nl, keep = 0, {}
        for _, f in ipairs(ICPT.airLoss) do
            if frame - f <= 900 then keep[#keep + 1] = f end
        end
        ICPT.airLoss = keep
        mb.airLosses = #keep      -- own air units shot down by enemy fighters in the last 30 s
    end
    return r
end

return RR
