-- line_fight.lua -- SPINE_BOT only.  What the army does once it is on, or leaves, the line.
--
--   PUSH   Once ~PUSH_START_UNITS ground units exist, most of the line's units gather at a
--          rally point, then attack-move toward the enemy as one ball, advancing freely until
--          they find the enemy.  Once they see PULL_RATIO x their own value in armed enemy
--          units/defences they pull back to the rally point, take in new units, and push again.
--   RAID   A pushing unit that damages an enemy eco building becomes a raider: it never
--          retreats and runs around the enemy base hitting eco.
--   FOCUS  At a fight (an engaged node, or the push) a target is picked and just enough units
--          are ordered to attack it to kill it: its HP against each unit's damage per volley.
--          Everything else keeps the default fight behaviour.
--
-- All state is the caller's tables, passed to Init (never reassigned there).  Orders go through
-- army_broker; this module outranks the line (PUSH uses the HOME_GUARD priority, RAID its own,
-- FOCUS the RESPOND priority) and is outranked by RETREAT and RESPOND.
--
--   LF.Init{ MM, UQ, EI, TM, ARMY, teamID, allyID,
--            combat = combatUnits, guards = homeGuards, muster = musterPool, scouts = lineScouts }
--   LF.Update(frame)                       -- push + raiders, every ~60 frames
--   LF.UpdateFocus(frame, hotspots)        -- every ~30 frames; hotspots = { {x=, z=}, ... }
--   LF.OnEnemyDamaged(attackerID, victimDefID)
--   LF.IsRaider(uid)  LF.InPush(uid)  LF.OnDestroyed(uid)  LF.Stage()  LF.Count()

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.PUSH_START_UNITS = 50     -- ground combat units needed before the first push
M.KEEP_BACK_EVERY  = 5      -- every Nth unit stays on the line (vision, local defence)
M.PULL_RATIO       = 2.0    -- pull back when armed enemies seen >= this x our value
M.REPUSH_RATIO     = 0.6    -- push again once we are worth this share of what made us pull back
M.SEE_RADIUS       = 1400   -- enemies this close to the group count as "seen"
M.CONTACT_FRESH    = 300    -- frames a sighting counts as current
M.RALLY_DIST       = 1500   -- rally point, forward of home along the axis
M.GATHER_RADIUS    = 700
M.GATHER_MAX       = 900    -- frames to wait for stragglers before pushing anyway
M.PUSH_STEP        = 700    -- how far ahead of the ball the push order points
M.AHEAD_MAX        = 450    -- a unit this far ahead of the ball waits for it
M.MIN_GROUP        = 8      -- a group this small is disbanded back to the line
M.FOCUS_RANGE      = 800    -- enemies this close to a hotspot are focus candidates
M.FOCUS_MAX_UNITS  = 10
M.FOCUS_OVERKILL   = 1.15   -- order this much damage over the target's HP
M.FOCUS_MAX_ARMED  = 6      -- hotspots handled per pass

local MM, UQ, EI, TM, ARMY
local myTeamID, myAllyID
local combat, guards, muster, scouts = {}, {}, {}, {}

local CMD_MOVE, CMD_FIGHT, CMD_ATTACK = 10, 16, 20

local push     = {}        -- [unitID] = true
local raiders  = {}        -- [unitID] = true
local focusOf  = {}        -- [unitID] = target unitID
local stage    = "idle"    -- idle | gather | push | pullback
local stageSince = 0
local lastEnemyValue = 0
local lastPushTarget = nil

function M.Init(opts)
    MM, UQ, EI, TM, ARMY = opts.MM, opts.UQ, opts.EI, opts.TM, opts.ARMY
    myTeamID, myAllyID = opts.teamID, opts.allyID
    combat, guards, muster, scouts = opts.combat, opts.guards, opts.muster, opts.scouts
end

function M.IsRaider(uid) return raiders[uid] == true end
function M.InPush(uid)   return push[uid] == true end
function M.Stage()       return stage end
function M.Count()
    local n = 0
    for _ in pairs(push) do n = n + 1 end
    return n
end

function M.OnDestroyed(uid)
    push[uid], raiders[uid], focusOf[uid] = nil, nil, nil
end

local function Log(frame, msg)
    Spring.Echo(string.format("[UC/push] %d:%02d %s", math.floor(frame / 1800),
        math.floor(frame / 30) % 60, msg))
end

local function Cost(defID) return defID and UQ.metal_cost(defID) or 0 end

local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end

-- ── Push ──────────────────────────────────────────────────────────────────────

local function GroundArmed(defID)
    return defID and not UQ.is_air(defID) and UQ.has_weapons(defID)
end

-- Ground combat units that exist at all, and those free to be recruited.
local function CountGround()
    local n = 0
    for uid, defID in pairs(combat) do
        if Alive(uid) and GroundArmed(defID) then n = n + 1 end
    end
    return n
end

local function Recruitable()
    local out = {}
    for uid, defID in pairs(combat) do
        if Alive(uid) and GroundArmed(defID) and not push[uid] and not raiders[uid]
           and not guards[uid] and not muster[uid] and not scouts[uid] then
            local role = ARMY.RoleOf(uid)
            if role == nil or role == "LINE" then out[#out + 1] = uid end
        end
    end
    table.sort(out)
    return out
end

local function GroupCentroid()
    local sx, sz, n, v = 0, 0, 0, 0
    for uid in pairs(push) do
        local x, _, z = Spring.GetUnitPosition(uid)
        if x then
            local c = Cost(combat[uid])
            sx, sz, n, v = sx + x, sz + z, n + 1, v + c
        end
    end
    if n == 0 then return nil end
    return sx / n, sz / n, n, v
end

-- Armed enemy value we can currently see near (x, z): units and defences alike.
local function EnemyValueNear(frame, x, z)
    local v = 0
    for _, c in pairs(TM.Contacts()) do
        if c.defID and frame - c.frame <= M.CONTACT_FRESH and UQ.has_weapons(c.defID)
           and (c.x - x) ^ 2 + (c.z - z) ^ 2 <= M.SEE_RADIUS ^ 2 then
            v = v + Cost(c.defID)
        end
    end
    return v
end

local function RallyPoint()
    local x, z = MM.PointAt(M.RALLY_DIST, 0)
    return MM.Clamp(x, z, 300)
end

local function Disband(frame, why)
    for uid in pairs(push) do
        if ARMY.RoleOf(uid) == "PUSH" then ARMY.Release(uid) end
    end
    push = {}
    stage, lastEnemyValue = "idle", 0
    Log(frame, "disband: " .. why)
end

local function Recruit(frame)
    local free = Recruitable()
    local added = 0
    for _, uid in ipairs(free) do
        -- Stable by unit id, so the same units are the ones left on the line every pass.
        if uid % M.KEEP_BACK_EVERY ~= 0 then push[uid] = true; added = added + 1 end
    end
    return added
end

local function ClaimPush(frame, uid, cmd, x, z)
    ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, { role = "PUSH", cmd = cmd, x = x, z = z }, frame)
end

local function UpdatePush(frame)
    for uid in pairs(push) do
        if not Alive(uid) or raiders[uid] then push[uid] = nil end
    end

    if stage == "idle" then
        if CountGround() >= M.PUSH_START_UNITS then
            local n = Recruit(frame)
            if n >= M.MIN_GROUP then
                stage, stageSince = "gather", frame
                Log(frame, string.format("gather: %d units", M.Count()))
            else
                push = {}
            end
        end
        return
    end

    local cx, cz, n, value = GroupCentroid()
    if not cx or n < M.MIN_GROUP then
        Disband(frame, "group down to " .. (n or 0))
        return
    end

    local rx, rz = RallyPoint()

    if stage == "gather" or stage == "pullback" then
        -- Reinforcements join while the ball is regrouping.
        Recruit(frame)
        local near, total = 0, 0
        for uid in pairs(push) do
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                total = total + 1
                if (x - rx) ^ 2 + (z - rz) ^ 2 <= M.GATHER_RADIUS ^ 2 then near = near + 1 end
            end
        end
        local gathered = total > 0 and near >= total * 0.8
        local waited = frame - stageSince >= M.GATHER_MAX
        local strong = lastEnemyValue <= 0 or value >= lastEnemyValue * M.REPUSH_RATIO
        if (gathered or waited) and strong then
            stage, stageSince = "push", frame
            Log(frame, string.format("push: %d units, value %.0f (last enemy %.0f)",
                total, value, lastEnemyValue))
        else
            for uid in pairs(push) do ClaimPush(frame, uid, CMD_MOVE, rx, rz) end
            return
        end
    end

    if stage == "push" then
        local seen = EnemyValueNear(frame, cx, cz)
        if seen >= value * M.PULL_RATIO then
            lastEnemyValue = seen
            stage, stageSince = "pullback", frame
            Log(frame, string.format("pull back: saw %.0f vs our %.0f", seen, value))
            for uid in pairs(push) do ClaimPush(frame, uid, CMD_MOVE, rx, rz) end
            return
        end
        -- Advance freely toward the enemy as a ball: the order points a step ahead of the
        -- centroid, and a unit already well ahead of the others waits at the centroid.
        local fx, fz = MM.Foe()
        local dx, dz = fx - cx, fz - cz
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist < 1 then dist = 1 end
        local ux, uz = dx / dist, dz / dist
        local step = math.min(M.PUSH_STEP, dist)
        local tx, tz = cx + ux * step, cz + uz * step
        lastPushTarget = { x = tx, z = tz }
        for uid in pairs(push) do
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local ahead = (x - cx) * ux + (z - cz) * uz
                if ahead > M.AHEAD_MAX then ClaimPush(frame, uid, CMD_FIGHT, cx, cz)
                else ClaimPush(frame, uid, CMD_FIGHT, tx, tz) end
            end
        end
    end
end

-- ── Raiders ───────────────────────────────────────────────────────────────────

local ecoCache = {}
local function IsEcoDef(defID)
    local r = ecoCache[defID]
    if r ~= nil then return r end
    local d = UnitDefs[defID]
    r = d ~= nil and d.isBuilding and (not d.weapons or #d.weapons == 0) or false
    ecoCache[defID] = r
    return r
end

-- A pushing unit that damages an eco building leaves the ball and raids.
function M.OnEnemyDamaged(attackerID, victimDefID)
    if not attackerID or not push[attackerID] or raiders[attackerID] then return end
    if not victimDefID or not IsEcoDef(victimDefID) then return end
    raiders[attackerID] = true
    push[attackerID] = nil
    if ARMY.RoleOf(attackerID) == "PUSH" then ARMY.Release(attackerID) end
    Spring.Echo(string.format("[UC/raid] unit %d hit eco, now a raider (%d raiders)",
        attackerID, (function() local n = 0 for _ in pairs(raiders) do n = n + 1 end return n end)()))
end

local function UpdateRaiders(frame)
    local any = false
    for uid in pairs(raiders) do
        if not Alive(uid) then raiders[uid] = nil else any = true end
    end
    if not any or not EI then return end

    local targets = EI.RaidTargets(frame)
    local fx, fz = MM.Foe()
    for uid in pairs(raiders) do
        local ux, _, uz = Spring.GetUnitPosition(uid)
        if ux then
            local best, bestD = nil, math.huge
            for _, t in ipairs(targets) do
                if not t.factory and not t.builder then
                    local d = (t.x - ux) ^ 2 + (t.z - uz) ^ 2
                    if d < bestD then best, bestD = t, d end
                end
            end
            local x, z = fx, fz
            if best then x, z = best.x, best.z end
            ARMY.Claim(ARMY.PRIO.RAID, uid, { role = "RAID", cmd = CMD_FIGHT, x = x, z = z }, frame)
        end
    end
end

function M.Update(frame)
    if not (ARMY and MM and MM.Ready() and UQ and TM) then return end
    UpdatePush(frame)
    UpdateRaiders(frame)
end

-- ── Focus fire ────────────────────────────────────────────────────────────────

-- Damage one volley from this unit type does against the default armour class.
local volleyCache = {}
local function VolleyDamage(defID)
    local v = volleyCache[defID]
    if v ~= nil then return v end
    v = 0
    local d = UnitDefs[defID]
    if d and d.weapons then
        for _, w in ipairs(d.weapons) do
            local wd = w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            if wd and wd.damages then
                local dmg = (wd.damages[0] or wd.damages[1] or 0)
                    * math.max(1, wd.projectiles or 1) * math.max(1, wd.salvoSize or 1)
                if dmg > v then v = dmg end
            end
        end
    end
    volleyCache[defID] = v
    return v
end

local function Release(uid)
    if ARMY.RoleOf(uid) == "FOCUS" then ARMY.Release(uid) end
    focusOf[uid] = nil
end

-- True while this unit is under a focus order, so the line does not overwrite it.
function M.IsFocused(uid) return focusOf[uid] ~= nil end

function M.UpdateFocus(frame, hotspots)
    if not (ARMY and MM and MM.Ready() and UQ) then return end

    -- Drop focus on anything whose target is gone, or that has died itself.
    for uid, tgt in pairs(focusOf) do
        local hp = Spring.GetUnitHealth(tgt)
        if not Alive(uid) or not Alive(tgt) or not hp or hp <= 0 then Release(uid) end
    end

    local extra = {}
    local cx, cz = GroupCentroid()
    if cx and stage == "push" then extra[1] = { x = cx, z = cz } end
    local spots = {}
    for _, h in ipairs(hotspots or {}) do spots[#spots + 1] = h end
    for _, h in ipairs(extra) do spots[#spots + 1] = h end

    local busy = {}
    local handled = 0
    for _, h in ipairs(spots) do
        if handled >= M.FOCUS_MAX_ARMED then break end
        -- Pick the visible enemy closest to dying: fewest volleys' worth of HP, armed first.
        local best, bestScore, bestHP
        for _, eid in ipairs(Spring.GetUnitsInCylinder(h.x, h.z, M.FOCUS_RANGE) or {}) do
            if Spring.GetUnitAllyTeam(eid) ~= myAllyID then
                local hp = Spring.GetUnitHealth(eid)
                local edef = Spring.GetUnitDefID(eid)
                if hp and hp > 0 and edef then
                    local score = hp / math.max(1, Cost(edef))
                    if UQ.has_weapons(edef) then score = score * 0.5 end
                    if not best or score < bestScore then best, bestScore, bestHP = eid, score, hp end
                end
            end
        end
        if best then
            handled = handled + 1
            local ex, _, ez = Spring.GetUnitPosition(best)
            local edef = Spring.GetUnitDefID(best)
            local air = UQ.is_air(edef)
            local pool = {}
            for uid, defID in pairs(combat) do
                local role = ARMY.RoleOf(uid)
                if not busy[uid] and (role == "LINE" or role == "PUSH" or role == "FOCUS")
                   and (air and UQ.can_hit_air(defID) or (not air and UQ.can_hit_ground(defID))) then
                    local ux, _, uz = Spring.GetUnitPosition(uid)
                    if ux then
                        local d2 = (ux - ex) ^ 2 + (uz - ez) ^ 2
                        if d2 <= (M.FOCUS_RANGE + 400) ^ 2 then
                            pool[#pool + 1] = { uid = uid, d2 = d2, dmg = VolleyDamage(defID) }
                        end
                    end
                end
            end
            table.sort(pool, function(a, b) return a.d2 < b.d2 end)
            local dealt, used = 0, 0
            for _, p in ipairs(pool) do
                if dealt >= bestHP * M.FOCUS_OVERKILL or used >= M.FOCUS_MAX_UNITS then break end
                if p.dmg > 0 then
                    busy[p.uid] = true
                    focusOf[p.uid] = best
                    ARMY.Claim(ARMY.PRIO.RESPOND, p.uid, {
                        role = "FOCUS", cmd = CMD_ATTACK, targetID = best,
                    }, frame)
                    dealt, used = dealt + p.dmg, used + 1
                end
            end
        end
    end

    -- Units that were focused last pass but not assigned this pass go back to their duty.
    for uid in pairs(focusOf) do
        if not busy[uid] then Release(uid) end
    end
end

return M
