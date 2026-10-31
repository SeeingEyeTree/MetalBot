-- bar_framework/cover_defence.lua  (user 2026-10-30, the CORE_v4 vs CORE_ROWS_ECO review, screenshots A-D)
-- COVER: every enemy ground group on our side of the map gets defenders worth COVER_MULT x its value, standing between it and the eco
-- it can reach, before any raid group may launch.  raid_response hands its ground answer to this planner when RAID_RESPONSE.COVER is set
-- (air raids, Shuriken stuns and Wasp splits stay there).
--
-- The user's rules, and where they live:
--   * radar dots are answered: a dot's type is guessed from its speed and the enemy types seen (enemy_intel GuessType); an unknown dot
--     is worth UNKNOWN_MULT x that ("not knowing what it is makes it a bigger threat")                                       -> Threats
--   * urgency is time: how soon the threat reaches the eco it points at vs how soon our units get in front of it.  New production
--     covers a threat while the labs can make (and walk over) enough before it arrives -- a threat heading for the labs is covered by
--     them, one moving away from the labs and our units is not ("group 2 ... reinforce time will get larger")                -> Assess
--   * the defenders stand on a LINE in front of the threatened eco, across the threat's approach; while the threat does not attack
--     the line PUSHES out toward it; on contact, or when it dives at the eco, each defender runs at one of its units (MOVE to the
--     first point of that unit's path it can reach, a little past it, re-aimed every second); moving at the eco, they CUT it off on
--     its path.  MOVE orders only (user 2026-10-30: FIGHT and ATTACK "will stop and keep firing but the enemy units can just walk
--     past and out of range"); units shoot on the move.  Pushed far out and covered by production alone, the defenders become RAIDERS from where they stand (click_army Adopt)
--     ("just holding does nothing")                                                                                            -> Orders
--   * the spine is not special: a cover post is the eco the threat can reach, never the commander / lab weighting of intercept.lua
--   * no raid launches while a threat is uncovered: mb.cover.uncovered, read by unit_runtime's holdHome hook                 -> Publish
-- Orders go through army_broker at RESPOND priority with role "COVER"; the units sit in the shared `responding` table (so click_army
-- leaves them alone) as { cover = true, ... }.  Running raid groups are never recalled.  Log rows: [COVER].
--
--   local CD = VFS.Include("LuaUI/Widgets/bar_framework/cover_defence.lua")
--   local cov = CD.New{ cfg = {...}, ARMY, UQ, TM, EI, MM, CA, combatUnits, musterPool, responding, teamID, allyID }
--   cov.Step(frame)  (once a second)      cov.Publish(frame, mb)      cov.FightGroups()  (threats in fight mode, raid-group shaped)

local M = {}

M.CFG = {
    TTL         = 450,    -- frames a sighting is acted on once out of sight
    CLUSTER_R   = 700,    -- contacts this close are one threat
    TRACK_R     = 1000,   -- a threat this close to last tick's is the same one (keeps its line / push state and its defenders)
    SIDE_R      = 3000,   -- a threat on our half of the map, or this close to the eco, is ours to answer
    UNKNOWN_MULT = 1.25,  -- a radar dot is worth this x its guessed type
    SCOUT_WEIGHT = 0.1,   -- a seen scout counts at this x its cost
    MIN_VALUE   = 120,    -- a threat worth less than this gets no cover (a lone scout)
    COVER_MULT  = 1.2,    -- defenders + what production brings in time must be worth this x the threat ("comparable value")
    KEEP_MULT   = 1.8,    -- above this x the need, the farthest defenders are released
    CONE_COS    = 0.5,    -- a moving threat points at the eco inside +-60 degrees of its heading
    LINE_OFF    = 400,    -- the line stands this far out from the threatened eco ...
    PUSH_EVERY  = 180,    -- ... and moves PUSH_STEP toward the threat every PUSH_EVERY frames while it does not attack
    PUSH_STEP   = 300,
    CONTACT_GAP = 350,    -- the pushed line stops this short of the threat (then its units' FIGHT orders find it)
    LEAK_R      = 1500,   -- a threat this close to the eco and closing is a dive: fight it, pull the line in
    FIGHT_R     = 700,    -- a threat this close to the eco: fight it, whatever it does
    ENGAGE_R    = 650,    -- our defenders this close to the threat: in contact, fight
    CLOSING     = 20,     -- elmos/s toward its eco point = closing
    STILL       = 14,     -- elmos/s: slower than this = not moving
    SPREAD      = 90,     -- elmos between defenders across the line ...
    SPREAD_MAX  = 600,    -- ... half-width at most
    REINF_SPEED = 90,     -- elmos/s new production walks at, for the time it needs from a lab to the cover post
    PROD_FRAC   = 0.8,    -- the share of the army production (income x army share) that would answer this threat in time ...
                          -- (production only counts for the launch gate -- "is it covered?" -- never instead of defenders: game 2026-10-30,
                          -- a 15-Incisor group 2000 out was "covered by production" with nobody in front of it and hit the southern field)
    PROD_R      = 1500,   -- ... counted only for a cover post this close to a lab (new units come out right there: the "group 2" case), and
                          -- shared: one production stream covers the threats in slack order (game 2026-10-30: unshared and everywhere, every
                          -- threat was "covered" by production and none got defenders)
    CONVERT_FWD = 0.35,   -- defenders past this share of the way to the enemy, whose threat production now covers alone, become raiders
    HORIZON     = 20,     -- s: a cutting defender looks this far ahead for a point on the threat's path it can reach first
    CHASE_PAST  = 120,    -- elmos past the meeting point a chasing defender runs to (it keeps moving with the raider, shooting)
    CHASE_AHEAD = 3,      -- s: a raider out of reach is chased toward where it will be this much later
    LEAD        = 250,    -- elmos past the threat's predicted position, toward the eco
    STAND_OFF   = 300,    -- never closer to the eco point than this
    LOG_EVERY   = 150,
}

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Norm(x, z) local d = math.sqrt(x * x + z * z); if d < 1e-6 then return 0, 0, 0 end; return x / d, z / d, d end
local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do
        if M.CFG[k] == nil then Spring.Echo("[COVER] option '" .. tostring(k) .. "' is not a cover_defence option (typo?)") end
        C[k] = v
    end
    local ARMY, UQ, TM, EI, MM, CA = o.ARMY, o.UQ, o.TM, o.EI, o.MM, o.CA
    local combatUnits, musterPool, responding = o.combatUnits, o.musterPool, o.responding
    local myTeamID, myAllyID = o.teamID, o.allyID
        local CMD_MOVE = (CMD and CMD.MOVE) or 10
    local spGetUnitDefID, spGetUnitPosition = Spring.GetUnitDefID, Spring.GetUnitPosition

    local cv = { threats = {}, nextId = 1, hist = {}, labs = {}, labF = -1e9, logF = -1e9, fight = {},
                 pub = { frame = 0, threats = 0, uncovered = 0, uncoveredValue = 0, covered = 0 } }

    -- ── helpers ────────────────────────────────────────────────────────────────
    local function Value(defID)
        local d = UnitDefs[defID]
        return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
    end
    local function Speed(defID) return (UQ.max_speed and UQ.max_speed(defID)) or ((UnitDefs[defID] or {}).speed or 0) end
    local function IsGround(defID) local d = UnitDefs[defID]; return d ~= nil and not d.canFly end

    -- velocity of one contact from its last two distinct sightings (raid_response ICPT.Track, the same rule)
    local function Track(id, x, z, f)
        local h = cv.hist[id]
        if not h then h = { x = x, z = z, f = f, vx = 0, vz = 0, still = f }; cv.hist[id] = h; return h end
        if f > h.f then
            local dt = (f - h.f) / 30
            local vx, vz = (x - h.x) / dt, (z - h.z) / dt
            if dt > 12 then vx, vz = 0, 0 end
            h.vx, h.vz = 0.5 * h.vx + 0.5 * vx, 0.5 * h.vz + 0.5 * vz
            h.x, h.z, h.f = x, z, f
            if math.sqrt(h.vx * h.vx + h.vz * h.vz) >= C.STILL then h.still = f end
        end
        return h
    end

    local function RefreshLabs(frame)
        if frame - cv.labF < 300 then return end
        cv.labF = frame
        local out = {}
        for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
            local d = UnitDefs[spGetUnitDefID(uid) or -1]
            if d and d.isFactory then
                local x, _, z = spGetUnitPosition(uid)
                if x then out[#out + 1] = { x = x, z = z } end
            end
        end
        cv.labs = out
    end

    -- army production rate (metal value / s): income x the strategy's army share
    local function ProdRate()
        local _, _, _, inc = Spring.GetTeamResources(myTeamID, "metal")
        local share = WG and WG.Strategy and WG.Strategy.Share and WG.Strategy:Share() or 0.5
        return (tonumber(inc) or 0) * (tonumber(share) or 0)
    end

    -- ── 1. threats ─────────────────────────────────────────────────────────────
    local function Threats(frame)
        local groups = {}
        local recs = EI and EI.Records and EI.Records() or {}
        local los, gh = Spring.IsPosInLos, Spring.GetGroundHeight
        for cid, c in pairs(TM.Contacts()) do
            local age = frame - c.frame
            if age <= C.TTL and not c.air then
                local defID = c.defID or (recs[cid] and recs[cid].defID)
                local v, sp, dot, guess
                if defID then
                    if UQ.is_mobile(defID) and IsGround(defID) then
                        v, sp = Value(defID), Speed(defID)
                        if UQ.is_scout and UQ.is_scout(defID) then v = v * C.SCOUT_WEIGHT end
                    end
                elseif EI and EI.GuessType then
                    local g = EI.GuessType(cid)
                    if g then v, sp, dot, guess = g.value * C.UNKNOWN_MULT, g.speed, true, g.name end
                end
                local gone = v and age > (TM.SCAN_PERIOD or 150) * 1.5 and los and los(c.x, gh(c.x, c.z) or 0, c.z, myAllyID)
                local ours = v and not gone and MM.Ready() and (MM.IsOurHalf(c.x, c.z) or MM.BaseDist(c.x, c.z) <= C.SIDE_R)
                if ours and v > 0 then
                    local h = Track(cid, c.x, c.z, c.frame)
                    local g
                    for _, o2 in ipairs(groups) do
                        if (o2.x - c.x) ^ 2 + (o2.z - c.z) ^ 2 <= C.CLUSTER_R ^ 2 then g = o2; break end
                    end
                    if not g then
                        g = { x = c.x, z = c.z, n = 0, v = 0, dots = 0, wvx = 0, wvz = 0, wsp = 0, stillS = 1e9, guess = {}, ids = {} }
                        groups[#groups + 1] = g
                    end
                    local n = g.n + 1
                    g.x, g.z = (g.x * g.n + c.x) / n, (g.z * g.n + c.z) / n
                    g.n, g.v = n, g.v + v
                    g.ids[#g.ids + 1] = cid
                    g.wvx, g.wvz, g.wsp = g.wvx + h.vx * v, g.wvz + h.vz * v, g.wsp + (sp or 0) * v
                    g.stillS = math.min(g.stillS, (frame - h.still) / 30)
                    if dot then g.dots = g.dots + 1; g.guess[guess or "?"] = (g.guess[guess or "?"] or 0) + 1 end
                end
            end
        end
        for id, h in pairs(cv.hist) do if frame - h.f > 2 * C.TTL then cv.hist[id] = nil end end
        local out = {}
        for _, g in ipairs(groups) do
            if g.v >= C.MIN_VALUE then
                g.vx, g.vz = g.wvx / g.v, g.wvz / g.v
                g.speed = math.sqrt(g.vx * g.vx + g.vz * g.vz)
                g.typeSpeed = g.wsp / g.v
                out[#out + 1] = g
            end
        end
        return out
    end

    -- carry each threat's state (id, line push, defenders) over from last tick: the nearest old one within TRACK_R
    local function Match(groups)
        local old, used, out = cv.threats, {}, {}
        for _, g in ipairs(groups) do
            local best, bd
            for i, t in ipairs(old) do
                if not used[i] then
                    local d = Dist(g.x, g.z, t.x, t.z)
                    if d <= C.TRACK_R and (not bd or d < bd) then best, bd = i, d end
                end
            end
            if best then
                used[best] = true
                local t = old[best]
                g.id, g.pushD, g.pushF, g.mode, g.bornF = t.id, t.pushD, t.pushF, t.mode, t.bornF
            else
                g.id, g.bornF = cv.nextId, nil
                cv.nextId = cv.nextId + 1
            end
            out[#out + 1] = g
        end
        local gone = {}
        for i, t in ipairs(old) do if not used[i] then gone[t.id] = t end end
        return out, gone
    end

    -- ── 2. what each threat can hit, and when ─────────────────────────────────
    local function Assess(frame, t, prodRate)
        local moving = t.speed >= C.STILL
        local ex, ez, dEco
        if moving and MM.BaseNearestInCone then ex, ez, dEco = MM.BaseNearestInCone(t.x, t.z, t.vx, t.vz, C.CONE_COS) end
        if not ex and MM.BaseNearestInCone then ex, ez, dEco = MM.BaseNearestInCone(t.x, t.z, 0, 0, -2) end
        if not ex then ex, ez = MM.Base(); dEco = ex and Dist(t.x, t.z, ex, ez) or 0 end
        t.ex, t.ez, t.dEco = ex, ez, dEco
        t.ux, t.uz = Norm(t.x - ex, t.z - ez)                      -- from the eco point toward the threat
        if t.ux == 0 and t.uz == 0 then local ax, az = MM.Axis(); t.ux, t.uz = ax or 1, az or 0 end
        local closing = -(t.vx * t.ux + t.vz * t.uz)               -- elmos/s toward the eco point
        t.closing = closing
        t.tThreat = dEco / math.max(30, moving and math.max(t.speed, 0.6 * t.typeSpeed) or t.typeSpeed)
        t.pushD = t.pushD or C.LINE_OFF
        local maxPush = math.max(C.LINE_OFF, dEco - C.CONTACT_GAP)
        if t.pushD > maxPush then t.pushD = maxPush end
        t.px, t.pz = MM.Clamp(ex + t.ux * t.pushD, ez + t.uz * t.pushD, 100)
        -- new production in time: what the labs make while the threat walks in, less the walk from the nearest lab to the post
        local tLab = math.huge
        for _, l in ipairs(cv.labs) do tLab = math.min(tLab, Dist(l.x, l.z, t.px, t.pz) / C.REINF_SPEED) end
        -- what production could bring before the threat arrives: prodAll anywhere (the convert rule: far threats), prodPot near a lab
        t.prodAll = (tLab < math.huge) and prodRate * C.PROD_FRAC * math.max(0, t.tThreat - tLab) or 0
        t.prodPot = (tLab * C.REINF_SPEED <= C.PROD_R) and t.prodAll or 0
        t.prodCover = 0                                           -- shared out in Step, in slack order
        t.need = C.COVER_MULT * t.v
    end

    -- ── 3. orders ──────────────────────────────────────────────────────────────
    -- MOVE through the army broker; it re-sends only after a big change of target, so a chase point that moved 80+ elmos goes out
    -- directly (at most every 30 frames) and the broker's record follows (raid_response ICPT.Order, the same rule)
    local function Claim(frame, uid, cmd, x, z)
        local before = ARMY.OrdersIssued and ARMY.OrdersIssued()
        ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "COVER", cmd = cmd, x = x, z = z }, frame)
        if not before or ARMY.OrdersIssued() ~= before then return end
        local d = ARMY.Duty and ARMY.Duty(uid)
        if d and d.role == "COVER" and d.issuedX and d.lastOrderFrame and frame - d.lastOrderFrame >= 30
           and (d.lastCmd ~= cmd or (x - d.issuedX) ^ 2 + (z - d.issuedZ) ^ 2 > 80 * 80) then
            Spring.GiveOrderToUnit(uid, cmd, { x, Spring.GetGroundHeight(x, z) or 0, z }, {})
            d.lastOrderFrame, d.lastCmd, d.issuedX, d.issuedZ, d.tx, d.tz = frame, cmd, x, z, x, z
        end
    end
    local chaseOf = {}      -- [our unit] = the enemy unit it runs at (sticky while that one lives and is still in the threat)
    -- where a defender at (px, pz) with speed sp meets an enemy at (ex, ez) moving (vx, vz): the first point of its path in reach,
    -- pushed CHASE_PAST along its heading so the defender keeps running with it; out of reach, its position CHASE_AHEAD s on
    local function ChasePoint(px, pz, sp, ex, ez, vx, vz)
        for s = 0, 10 do
            local mx, mz = ex + vx * s, ez + vz * s
            if Dist(mx, mz, px, pz) <= sp * s + 40 then
                local ux, uz = Norm(vx, vz)
                return mx + ux * C.CHASE_PAST, mz + uz * C.CHASE_PAST
            end
        end
        return ex + vx * C.CHASE_AHEAD, ez + vz * C.CHASE_AHEAD
    end

    local function MeetingPoint(t, px, pz, sp)
        for s = 0, C.HORIZON do
            local rx, rz = t.x + t.vx * s, t.z + t.vz * s
            local remain = Dist(t.ex, t.ez, rx, rz)
            local lead = C.LEAD
            if remain < lead + C.STAND_OFF then lead = math.max(0, remain - C.STAND_OFF) end
            local mx, mz = rx - t.ux * lead, rz - t.uz * lead
            if Dist(mx, mz, px, pz) <= sp * s + 30 then return mx, mz end
        end
        return nil
    end

    local function Orders(frame, t, units)
        -- contact: our defenders are on it (a threat with no defenders still gets its mode: a dive with nobody on it is a raid)
        local contact = false
        if #units > 0 then
            local cx, cz = 0, 0
            for _, u in ipairs(units) do cx, cz = cx + u.x, cz + u.z end
            contact = Dist(cx / #units, cz / #units, t.x, t.z) <= C.ENGAGE_R
        end
        local dive = t.dEco <= C.LEAK_R and t.closing >= C.CLOSING
        local mode
        if contact or dive or t.dEco <= C.FIGHT_R then mode = "fight"
        elseif t.speed >= C.STILL and t.closing >= C.CLOSING then mode = "cut"
        else mode = "line" end
        if mode ~= "line" then t.pushF = nil end
        if dive then t.pushD = C.LINE_OFF end                        -- a dive pulls the line in
        t.mode = mode
        if #units == 0 then return end
        if mode == "fight" then
            -- each defender runs at one enemy unit of the threat (MOVE to the chase point, re-aimed every second): the nearest, while
            -- it has fewer than its share of chasers; a target that died or left the threat is replaced
            local tgts, count, inThreat = {}, {}, {}
            for _, eid in ipairs(t.ids) do
                if spGetUnitDefID(eid) or Spring.GetUnitPosition(eid) then
                    local ex, _, ez = spGetUnitPosition(eid)
                    local h = cv.hist[eid]
                    if ex then tgts[#tgts + 1] = { id = eid, x = ex, z = ez, vx = h and h.vx or 0, vz = h and h.vz or 0 }; inThreat[eid] = true; count[eid] = 0 end
                end
            end
            if #tgts == 0 then                                -- nothing to aim at (out of sight): move onto where it was heading
                local fx, fz = MM.Clamp(t.x + t.vx * 3, t.z + t.vz * 3, 50)
                for _, u in ipairs(units) do Claim(frame, u.uid, CMD_MOVE, fx, fz) end
                return
            end
            local share = math.ceil(#units / #tgts) + 1
            for _, u in ipairs(units) do
                local cur = chaseOf[u.uid]
                if cur and inThreat[cur] and count[cur] < share then count[cur] = count[cur] + 1 else chaseOf[u.uid] = nil end
            end
            local byId = {}
            for _, e in ipairs(tgts) do byId[e.id] = e end
            for _, u in ipairs(units) do
                if not chaseOf[u.uid] then
                    local best, bd
                    for _, e in ipairs(tgts) do
                        local d = Dist(u.x, u.z, e.x, e.z)
                        if count[e.id] < share and (not bd or d < bd) then best, bd = e, d end
                    end
                    best = best or tgts[1]
                    chaseOf[u.uid] = best.id
                    count[best.id] = count[best.id] + 1
                end
                local e = byId[chaseOf[u.uid]]
                local mx, mz = ChasePoint(u.x, u.z, u.sp, e.x, e.z, e.vx, e.vz)
                mx, mz = MM.Clamp(mx, mz, 50)
                Claim(frame, u.uid, CMD_MOVE, mx, mz)
            end
            return
        end
        -- line across the approach, through the post (or the cut point): neighbours stay neighbours
        local qx, qz = -t.uz, t.ux
        table.sort(units, function(a, b) return a.x * qx + a.z * qz < b.x * qx + b.z * qz end)
        local half = math.min(C.SPREAD_MAX, C.SPREAD * (#units - 1) / 2)
        for i, u in ipairs(units) do
            local off = (#units == 1) and 0 or ((i - 1) / (#units - 1) * 2 - 1) * half
            local bx, bz = t.px, t.pz
            local cmd = CMD_MOVE                             -- stand on the line (units still shoot what comes in range); never FIGHT
            if mode == "cut" then
                local mx, mz = MeetingPoint(t, u.x, u.z, u.sp)
                if mx then bx, bz, cmd = mx, mz, CMD_MOVE end
            end
            local tx, tz = MM.Clamp(bx + qx * off, bz + qz * off, 50)
            Claim(frame, u.uid, cmd, tx, tz)
        end
        -- push: the line has stood without contact for PUSH_EVERY and is worth the need -> it moves out toward the threat
        if mode == "line" then
            local have = 0
            for _, u in ipairs(units) do have = have + u.v end
            if have >= t.need then
                t.pushF = t.pushF or frame
                if frame - t.pushF >= C.PUSH_EVERY then
                    t.pushF = frame
                    t.pushD = math.min(t.pushD + C.PUSH_STEP, math.max(C.LINE_OFF, t.dEco - C.CONTACT_GAP))
                end
            else
                t.pushF = nil
            end
        end
    end

    -- ── step ───────────────────────────────────────────────────────────────────
    local function Release(uid)
        responding[uid] = nil
        if ARMY.RoleOf(uid) == "COVER" then ARMY.Release(uid) end
    end

    local function UnitRec(uid, defID)
        local x, _, z = spGetUnitPosition(uid)
        if not x then return nil end
        return { uid = uid, defID = defID, x = x, z = z, v = Value(defID), sp = math.max(1, Speed(defID)) }
    end

    function cv.Step(frame)
        if not (MM and MM.Ready and MM.Ready() and TM and ARMY) then return end
        RefreshLabs(frame)
        local prodRate = ProdRate()
        local threats, goneT = Match(Threats(frame))
        local byId = {}
        for _, t in ipairs(threats) do t.bornF = t.bornF or frame; Assess(frame, t, prodRate); byId[t.id] = t end

        -- current defenders, by threat; a threat that is gone: its defenders raid from there when far out, else go free
        local mine, convert = {}, {}
        for uid, r in pairs(responding) do
            if r.cover then
                local defID = combatUnits[uid]
                local t = byId[r.id]
                if not defID or not spGetUnitDefID(uid) or ARMY.RoleOf(uid) == "RETREAT" then
                    responding[uid] = nil
                elseif not t then
                    local x, _, z = spGetUnitPosition(uid)
                    if x and MM.Forward(x, z) >= C.CONVERT_FWD * MM.Dist() then convert[#convert + 1] = uid end
                    Release(uid)
                else
                    local u = UnitRec(uid, defID)
                    if u then mine[t.id] = mine[t.id] or {}; table.insert(mine[t.id], u) else Release(uid) end
                end
            end
        end

        -- a threat production alone covers in time, with its defenders far out: they become raiders ("just holding does nothing")
        for _, t in ipairs(threats) do
            local list = mine[t.id]
            if list and #list > 0 and t.prodAll >= t.need then
                local fx = 0
                for _, u in ipairs(list) do fx = fx + MM.Forward(u.x, u.z) end
                if fx / #list >= C.CONVERT_FWD * MM.Dist() then
                    for _, u in ipairs(list) do convert[#convert + 1] = u.uid; Release(u.uid) end
                    mine[t.id] = nil
                    t.converted = (t.converted or 0) + #list
                end
            end
        end
        if #convert > 0 and CA and CA.Adopt then CA.Adopt(frame, convert) end

        -- too many on one threat: the farthest go free
        for _, t in ipairs(threats) do
            local list = mine[t.id]
            if list then
                local have = 0
                for _, u in ipairs(list) do have = have + u.v end
                if have > C.KEEP_MULT * t.need and #list > 1 then
                    table.sort(list, function(a, b) return Dist(a.x, a.z, t.x, t.z) > Dist(b.x, b.z, t.x, t.z) end)
                    while #list > 1 and have - list[1].v >= C.COVER_MULT * t.need do
                        have = have - list[1].v
                        Release(list[1].uid)
                        table.remove(list, 1)
                    end
                end
            end
        end

        -- the free pool: ground combat units in no attack group and on no other job
        local pool = {}
        for uid, defID in pairs(combatUnits) do
            if not responding[uid] and IsGround(defID) and spGetUnitDefID(uid) and (not UQ.can_hit_ground or UQ.can_hit_ground(defID)) then
                local role = ARMY.RoleOf(uid)
                local ok = role == nil or role == "BLOB" or role == "HOME_GUARD" or role == "HOME_RETURN" or role == "LINE" or musterPool[uid]
                if ok and CA and CA.InGroup and CA.InGroup(uid) then ok = false end
                if ok then local u = UnitRec(uid, defID); if u then pool[#pool + 1] = u end end
            end
        end

        -- fill the most urgent first: slack = time the threat needs to reach its eco - time our nearest free unit needs to get in front
        for _, t in ipairs(threats) do
            local have = 0
            for _, u in ipairs(mine[t.id] or {}) do have = have + u.v end
            t.have = have
            local best = math.huge
            for _, u in ipairs(pool) do best = math.min(best, Dist(u.x, u.z, t.px, t.pz) / u.sp) end
            t.slack = (best < math.huge) and (t.tThreat - best) or -9999   -- nobody free: as urgent as it gets
        end
        table.sort(threats, function(a, b) return a.slack < b.slack end)
        local taken, prodUsed = {}, 0
        for _, t in ipairs(threats) do
            t.prodCover = math.max(0, math.min(t.prodPot - prodUsed, t.need - t.have))
            prodUsed = prodUsed + t.prodCover
            if t.have < t.need then                    -- real defenders up to the full need; production is only for the gate
                local cands = {}
                for i, u in ipairs(pool) do
                    if not taken[i] then cands[#cands + 1] = { i = i, u = u, eta = Dist(u.x, u.z, t.px, t.pz) / u.sp } end
                end
                table.sort(cands, function(a, b) return a.eta < b.eta end)
                for _, c in ipairs(cands) do
                    if t.have >= t.need then break end
                    taken[c.i] = true
                    t.have = t.have + c.u.v
                    mine[t.id] = mine[t.id] or {}
                    table.insert(mine[t.id], c.u)
                    responding[c.u.uid] = { cover = true, id = t.id, x = t.x, z = t.z }
                end
            end
            for _, u in ipairs(mine[t.id] or {}) do
                local r = responding[u.uid]
                if r then r.x, r.z = t.x, t.z end
            end
        end

        -- orders, the published state and the fight-mode threats (the raid record)
        local unc, uncV, cov, fight = 0, 0, 0, {}
        for _, t in ipairs(threats) do
            Orders(frame, t, mine[t.id] or {})
            t.covered = t.have + t.prodCover >= t.need
            if t.covered then cov = cov + 1 else unc, uncV = unc + 1, uncV + t.v end
            if t.mode == "fight" then
                fight[#fight + 1] = { x = t.x, z = t.z, n = t.n, cost = t.v, threat = t.v, gnd = t.v, air = 0, channel = "ground",
                                      speed = t.speed, vx = t.vx, vz = t.vz, stillS = t.stillS }
            end
        end
        cv.threats, cv.fight = threats, fight
        cv.pub = { frame = frame, threats = #threats, uncovered = unc, uncoveredValue = uncV, covered = cov }

        if frame - cv.logF >= C.LOG_EVERY and #threats > 0 then
            cv.logF = frame
            for _, t in ipairs(threats) do
                local g = {}
                for name, k in pairs(t.guess) do g[#g + 1] = k .. "x " .. name end
                Spring.Echo(string.format("[COVER] %s #%d at %d,%d value %.0f (%d units%s) -> eco %d,%d %.0f away, %.0fs (closing %.0f/s) | "
                    .. "have %.0f + production %.0f / need %.0f %s | slack %.0fs | %s, line %.0f out",
                    Clock(frame), t.id, t.x, t.z, t.v, t.n, t.dots > 0 and (", " .. t.dots .. " radar dots as " .. table.concat(g, " ")) or "",
                    t.ex, t.ez, t.dEco, t.tThreat, t.closing, t.have, t.prodCover, t.need, t.covered and "covered" or "UNCOVERED",
                    t.slack, t.mode or "-", t.pushD))
            end
        end
    end

    function cv.Publish(frame, mb) mb.cover = cv.pub end
    function cv.FightGroups() return cv.fight end
    function cv.Owns(uid) local r = responding[uid]; return r ~= nil and r.cover == true end
    return cv
end

return M
