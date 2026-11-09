-- bar_framework/defence/army.lua  (area_defence: army units borrowed for the part of a threat the wall and the air squad cannot cover)
-- cover_defence.lua's defender rules (user 2026-10-30): a LINE in front of the threatened member, across the threat's approach, that pushes out
-- while the threat does not attack; CUT it off on its path while it moves at the eco; on contact (or a dive) each defender runs at one of its
-- units.  MOVE orders only ("FIGHT and ATTACK ... the enemy units can just walk past").  The units sit in the shared `responding` table as
-- { cover = true, def = true, id = threat id } (click_army and raid_response leave them alone) with army_broker role "COVER".
-- User 2026-11-08: "Once the threat no longer needs the normal army units the defending system should hand the units back to the normal army so
-- the units can go out and raid" -- Release, or CA.Adopt for units already far forward (they raid from where they stand).
--
--   local DA = VFS.Include("LuaUI/Widgets/bar_framework/defence/army.lua")
--   local army = DA.New{ cfg, ARMY, UQ, MM, CA, combatUnits, musterPool, responding, hist = TH.Hist }
--   DA.Mode(t, defenders, C)  DA.ChasePoint(...)  DA.MeetingPoint(...)          -- shared with the wall
--   army.Mine(byId) -> { [tid] = { unitRec } }, gone   army.Pool(owned) -> { unitRec }   army.Take(uid, t)   army.Release(uid)   army.Orders(frame, t, units)

local M = {}

M.CFG = {
    PUSH_EVERY  = 180,    -- the line moves PUSH_STEP toward the threat every PUSH_EVERY frames while it does not attack
    PUSH_STEP   = 300,
    LINE_OFF    = 400,
    CONTACT_GAP = 350,
    LEAK_R      = 1500,   -- a threat this close to its member and closing is a dive: fight it, pull the line in
    FIGHT_R     = 700,    -- a threat this close to its member: fight it, whatever it does
    ENGAGE_R    = 650,    -- our defenders this close to the threat: in contact, fight
    CLOSING     = 20,     -- elmos/s toward its member = closing
    STILL       = 14,
    SPREAD      = 90,     -- elmos between defenders across the line ...
    SPREAD_MAX  = 600,    -- ... half-width at most
    CONVERT_FWD = 0.35,   -- defenders past this share of the way to the enemy, whose threat is gone, become raiders (click_army Adopt)
    HORIZON     = 20,     -- s: a cutting defender looks this far ahead for a point on the threat's path it can reach first
    CHASE_PAST  = 120,
    CHASE_AHEAD = 3,
    LEAD        = 250,
    STAND_OFF   = 300,
}

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Norm(x, z) local d = math.sqrt(x * x + z * z); if d < 1e-6 then return 0, 0, 0 end; return x / d, z / d, d end

-- where a defender at (px, pz) with speed sp meets an enemy at (ex, ez) moving (vx, vz): the first point of its path in reach, pushed CHASE_PAST
-- along its heading so the defender keeps running with it; out of reach, its position CHASE_AHEAD s on
function M.ChasePoint(C, px, pz, sp, ex, ez, vx, vz)
    for s = 0, 10 do
        local mx, mz = ex + vx * s, ez + vz * s
        if Dist(mx, mz, px, pz) <= sp * s + 40 then
            local ux, uz = Norm(vx, vz)
            return mx + ux * C.CHASE_PAST, mz + uz * C.CHASE_PAST
        end
    end
    return ex + vx * C.CHASE_AHEAD, ez + vz * C.CHASE_AHEAD
end

-- the first point on the threat's path (LEAD ahead of it, toward its member, never closer than STAND_OFF to it) a defender reaches in time
function M.MeetingPoint(C, t, px, pz, sp)
    for s = 0, C.HORIZON do
        local rx, rz = t.x + t.vx * s, t.z + t.vz * s
        local remain = Dist(t.ex, t.ez, rx, rz)
        local lead = C.LEAD
        if remain < lead + C.STAND_OFF then lead = math.max(0, remain - C.STAND_OFF) end
        local mx, mz = rx - t.ux * lead, rz - t.uz * lead
        if Dist(mx, mz, px, pz) <= sp * s + 30 then return mx, mz, s end
    end
    return nil
end

-- the threat's mode from every defender on it (wall, air, army): fight (contact, a dive, or at the member), cut (moving at it), line
function M.Mode(t, defenders, C)
    local contact = false
    if #defenders > 0 then
        local cx, cz = 0, 0
        for _, u in ipairs(defenders) do cx, cz = cx + u.x, cz + u.z end
        contact = Dist(cx / #defenders, cz / #defenders, t.x, t.z) <= C.ENGAGE_R
    end
    local dive = t.dEco <= C.LEAK_R and t.closing >= C.CLOSING
    local mode
    if contact or dive or t.dEco <= C.FIGHT_R then mode = "fight"
    elseif t.speed >= C.STILL and t.closing >= C.CLOSING then mode = "cut"
    else mode = "line" end
    if mode ~= "line" then t.pushF = nil end
    if dive then t.pushD = C.LINE_OFF end
    t.mode = mode
    return mode
end

-- the line push: the line has stood without contact for PUSH_EVERY and is worth the need -> it moves out toward the threat
function M.Push(t, have, frame, C)
    if t.mode ~= "line" then return end
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

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do C[k] = v end
    local ARMY, UQ, MM, CA = o.ARMY, o.UQ, o.MM, o.CA
    local combatUnits, musterPool, responding = o.combatUnits, o.musterPool, o.responding
    local CMD_MOVE = (CMD and CMD.MOVE) or 10
    local spGetUnitDefID, spGetUnitPosition = Spring.GetUnitDefID, Spring.GetUnitPosition
    local army = { cfg = C }

    local function Value(defID)
        local d = UnitDefs[defID]
        return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
    end
    local function Speed(defID) return (UQ.max_speed and UQ.max_speed(defID)) or ((UnitDefs[defID] or {}).speed or 0) end
    local function IsGround(defID) local d = UnitDefs[defID]; return d ~= nil and not d.canFly end
    function army.UnitRec(uid, defID)
        local x, _, z = spGetUnitPosition(uid)
        if not x then return nil end
        return { uid = uid, defID = defID, x = x, z = z, v = Value(defID), sp = math.max(1, Speed(defID)) }
    end

    -- MOVE through the army broker; a chase point that moved 80+ elmos goes out directly (at most every 30 frames), the broker's record follows
    function army.Claim(frame, uid, cmd, x, z, role)
        role = role or "COVER"
        local before = ARMY.OrdersIssued and ARMY.OrdersIssued()
        ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = role, cmd = cmd, x = x, z = z }, frame)
        if not before or ARMY.OrdersIssued() ~= before then return end
        local d = ARMY.Duty and ARMY.Duty(uid)
        if d and d.role == role and d.issuedX and d.lastOrderFrame and frame - d.lastOrderFrame >= 30
           and (d.lastCmd ~= cmd or (x - d.issuedX) ^ 2 + (z - d.issuedZ) ^ 2 > 80 * 80) then
            Spring.GiveOrderToUnit(uid, cmd, { x, Spring.GetGroundHeight(x, z) or 0, z }, {})
            d.lastOrderFrame, d.lastCmd, d.issuedX, d.issuedZ, d.tx, d.tz = frame, cmd, x, z, x, z
        end
    end

    function army.Release(uid)
        responding[uid] = nil
        if ARMY.RoleOf(uid) == "COVER" then ARMY.Release(uid) end
    end

    function army.Take(uid, t) responding[uid] = { cover = true, def = true, id = t.id, x = t.x, z = t.z } end

    -- the borrowed units by threat; a threat that is gone: its units raid from there when far out (CA.Adopt), else go back to the army
    function army.Mine(byId, frame)
        local mine, convert, back = {}, {}, 0
        for uid, r in pairs(responding) do
            if r.def then
                local defID = combatUnits[uid]
                local t = byId[r.id]
                if not defID or not spGetUnitDefID(uid) or ARMY.RoleOf(uid) == "RETREAT" then
                    responding[uid] = nil
                elseif not t then
                    local x, _, z = spGetUnitPosition(uid)
                    if x and MM.Forward(x, z) >= C.CONVERT_FWD * MM.Dist() then convert[#convert + 1] = uid end
                    army.Release(uid)
                    back = back + 1
                else
                    local u = army.UnitRec(uid, defID)
                    if u then mine[t.id] = mine[t.id] or {}; table.insert(mine[t.id], u); r.x, r.z = t.x, t.z else army.Release(uid) end
                end
            end
        end
        if #convert > 0 and CA and CA.Adopt then CA.Adopt(frame, convert) end
        return mine, back, #convert
    end

    -- the free pool: ground combat units in no attack group and on no other job (cover_defence's rule); `owned` = units another squad holds
    function army.Pool(owned)
        local pool = {}
        for uid, defID in pairs(combatUnits) do
            if not responding[uid] and not (owned and owned(uid)) and IsGround(defID) and spGetUnitDefID(uid) and (not UQ.can_hit_ground or UQ.can_hit_ground(defID)) then
                local role = ARMY.RoleOf(uid)
                local ok = role == nil or role == "BLOB" or role == "HOME_GUARD" or role == "HOME_RETURN" or role == "LINE" or musterPool[uid]
                if ok and CA and CA.InGroup and CA.InGroup(uid) then ok = false end
                if ok then local u = army.UnitRec(uid, defID); if u then pool[#pool + 1] = u end end
            end
        end
        return pool
    end

    local chaseOf = {}      -- [our unit] = the enemy unit it runs at (sticky while that one lives and is still in the threat)
    function army.Orders(frame, t, units)
        if #units == 0 then return end
        if t.mode == "fight" then
            local tgts, count, inThreat = {}, {}, {}
            for _, eid in ipairs(t.ids) do
                local ex, _, ez = spGetUnitPosition(eid)
                if ex then
                    local h = o.hist(eid)
                    tgts[#tgts + 1] = { id = eid, x = ex, z = ez, vx = h and h.vx or 0, vz = h and h.vz or 0 }
                    inThreat[eid] = true; count[eid] = 0
                end
            end
            if #tgts == 0 then                                -- nothing to aim at (out of sight): move onto where it was heading
                local fx, fz = MM.Clamp(t.x + t.vx * 3, t.z + t.vz * 3, 50)
                for _, u in ipairs(units) do army.Claim(frame, u.uid, CMD_MOVE, fx, fz) end
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
                local mx, mz = M.ChasePoint(C, u.x, u.z, u.sp, e.x, e.z, e.vx, e.vz)
                mx, mz = MM.Clamp(mx, mz, 50)
                army.Claim(frame, u.uid, CMD_MOVE, mx, mz)
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
            if t.mode == "cut" then
                local mx, mz = M.MeetingPoint(C, t, u.x, u.z, u.sp)
                if mx then bx, bz = mx, mz end
            end
            local tx, tz = MM.Clamp(bx + qx * off, bz + qz * off, 50)
            army.Claim(frame, u.uid, CMD_MOVE, tx, tz)
        end
    end

    function army.Forget(uid) chaseOf[uid] = nil end
    return army
end

return M
