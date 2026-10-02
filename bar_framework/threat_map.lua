-- bar_framework/threat_map.lua
-- What is threatening us, how badly, and where.
--
-- WHY THIS EXISTS
-- ---------------
-- Until now the bot had no way to know it was under attack.  No widget implemented
-- UnitDamaged and nothing called GetUnitLastAttacker, so "respond to a raid" was not
-- a behaviour that could be written -- the information never arrived.  The only
-- enemy knowledge was a centroid of everything visible, which is not a threat model:
-- it cannot tell a lone scout from a bomber wing, and it averages the two into a
-- point where neither is.
--
-- THE MODEL: a piece-square table
-- -------------------------------
-- Borrowed from chess engines.  A unit's danger is not a property of the unit alone,
-- it is the unit crossed with where it is standing:
--
--     threat = metalCost * speedFactor(speed) * posWeight[channel][distance from home]
--
--   * cost      -- a Leveler matters more than a scout
--   * speed     -- a fast cheap raider is more urgent than a slow expensive one,
--                  because the slow one can be ignored or outmanoeuvred
--   * position  -- the same unit is an emergency in our mex grid and irrelevant in
--                  their base
--
-- Air and ground get SEPARATE position tables, for two reasons.  The responder has
-- to match the channel (fighters answer bombers, vehicles answer vehicles), and air
-- falls off far more slowly with distance: at ~300 elmos/s a bomber at mid-map is
-- seconds away, while an 85-speed Incisor at the same spot is minutes away.
--
-- Every number here is a hand-tuned guess.  There is no unit-matchup data in this
-- project to derive them from, so they are grouped at the top to be tuned against
-- RAIDER_BOT and GROUND_RAIDER_BOT rather than scattered through the logic.
--
-- USAGE
--   local TM = VFS.Include("LuaUI/Widgets/bar_framework/threat_map.lua")
--   TM.Init{ MM = MM, UQ = UQ, teamID = t, allyID = a }
--   -- from the widget callins:
--   TM.OnDamaged(unitID, unitDefID, damage, weaponDefID, projectileID,
--                attackerID, attackerDefID, frame)
--   TM.OnUnitDestroyed(unitID, defID, isMine, frame)
--   -- once per tick:
--   TM.ScanContacts(frame); TM.Update(frame)
--   local inc = TM.TopIncident()

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.CONTACT_TTL    = 1200  -- frames a sighting stays believable once out of sight
M.INCIDENT_MERGE = 700   -- damage events within this distance are one attack
M.INCIDENT_TTL   = 600   -- frames after the last damage before an attack is over
M.SCAN_PERIOD    = 150

-- Faster units are more urgent at equal cost: they choose the engagement and can
-- leave it.  A very slow expensive unit is often best ignored -- you cannot be
-- forced to fight it, and the metal is better spent killing what it is guarding.
M.SPEED_BANDS = {
    {  50, 0.5 },   -- siege speed: shows up eventually
    { 100, 1.0 },   -- ground raiders
    { 200, 1.4 },   -- fast vehicles
    { math.huge, 1.8 },  -- air
}

-- Weight by distance from the home anchor, as a fraction of the home->enemy
-- distance.  Ground falls off hard; air barely does, because air closes that
-- distance in seconds.
M.POS_GROUND = {
    { 0.08, 1.00 },  -- in the base
    { 0.20, 0.70 },  -- in the mex grid
    { 0.50, 0.30 },  -- our half
    { 0.65, 0.10 },  -- around the midline
    { math.huge, 0.02 },
}
M.POS_AIR = {
    { 0.08, 1.00 },
    { 0.20, 0.90 },
    { 0.50, 0.70 },
    { 0.65, 0.45 },
    { math.huge, 0.25 },
}

-- Response bands, in the same units as the threat score (roughly "effective metal
-- pointed at us").  Calibrate against real raids before trusting them.
--
-- These drive DISPATCH ONLY, and dispatch is deliberately absolute: if something is
-- attacking us we send units, whether we have three or thirty.  There is never a
-- reason to let a raider eat mexes unopposed because we feel comfortable.
M.BAND_IGNORE  = 150   -- below: no army response; nanos and turrets cope
M.BAND_RESPOND = 400   -- above: dispatch from the matching channel
M.BAND_ALARM   = 1200  -- above: a serious attack, not a harasser

-- PRODUCTION urgency is a different question and needs a different signal: not
-- "how big is this" but "how big is this compared to what we already have".  Three
-- Incisors in our base is routine if ten defenders are standing there and an
-- emergency if nothing is.  Only this ratio may interrupt the economy -- the macro
-- is exponential and the whole point of the army is to buy it time, so we do not
-- tax it for a threat we can already answer.
--
-- Deficit = threat / our answer in that channel.  >1 means outmatched.
M.DEFICIT_RUSH = 1.0   -- outmatched: build defenders now, below the float gate
M.DEFICIT_BUILD = 0.5  -- thin cover: build when metal allows, do not interrupt

-- A unit that is not a specialist still helps, but not as much.  `can_hit_air` is
-- permissive -- almost every weapon reads as air-capable unless it explicitly says
-- otherwise -- so counting those at full value would claim we have air cover when
-- we have none.  Dedicated AA counts fully; everything else that merely may shoot
-- upward counts at this fraction.
M.NONSPECIALIST_AA_WEIGHT = 0.35

-- A defender only counts toward "are we covered here" if it can arrive within this
-- many frames (30s).  Anything slower is not defending that spot, whatever the
-- army total says.
M.RESPONSE_HORIZON = 900

-- ── State ─────────────────────────────────────────────────────────────────────

local MM, UQ
local myTeamID, myAllyID

local contacts  = {}   -- [enemyUnitID] = {x, z, defID, v, air, frame}
local incidents = {}   -- array of attack incidents
local pending   = {}   -- [victimID] = frame, for the GetUnitLastAttacker retry

function M.Init(opts)
    MM, UQ   = opts.MM, opts.UQ
    myTeamID = opts.teamID
    myAllyID = opts.allyID
end

-- ── Scoring ───────────────────────────────────────────────────────────────────

local function BandLookup(bands, value)
    for i = 1, #bands do
        if value <= bands[i][1] then return bands[i][2] end
    end
    return bands[#bands][2]
end

function M.SpeedFactor(speed)
    return BandLookup(M.SPEED_BANDS, speed or 0)
end

-- Cost crossed with speed: what this unit is worth as a threat, before position.
function M.Intrinsic(defID)
    if not defID then return 0 end
    return UQ.metal_cost(defID) * M.SpeedFactor(UQ.max_speed(defID))
end

function M.PosWeight(channel, x, z)
    if not (MM and MM.Ready()) then return 1 end
    local hx, hz = MM.Home()
    local frac = MM.DistBetween(hx, hz, x, z) / math.max(1, MM.Dist())
    return BandLookup(channel == "air" and M.POS_AIR or M.POS_GROUND, frac)
end

function M.ThreatOf(defID, x, z)
    local channel = (defID and UQ.is_air(defID)) and "air" or "ground"
    return M.Intrinsic(defID) * M.PosWeight(channel, x, z), channel
end

function M.Band(score)
    if score >= M.BAND_ALARM   then return "alarm"   end
    if score >= M.BAND_RESPOND then return "respond" end
    if score >= M.BAND_IGNORE  then return "watch"   end
    return "ignore"
end

local BAND_RANK = { ignore = 0, watch = 1, respond = 2, alarm = 3 }

-- An incident's band only ever climbs.  Its score depends on what is visible right
-- now, so a raider stepping out of LOS made the same attack oscillate
-- respond -> watch -> respond; committing and recalling units on that flicker would
-- be worse than not responding at all.  Attacks end by expiring (INCIDENT_TTL),
-- not by looking calmer for a moment.
function M.IncidentBand(inc, score)
    local band = M.Band(score or M.IncidentScore(inc))
    if not inc.band or BAND_RANK[band] > BAND_RANK[inc.band] then
        inc.band = band
    end
    return inc.band
end

-- ── Contacts ──────────────────────────────────────────────────────────────────

-- Remember a sighting.  "Not visible" is not "dead": contacts age out on a timer
-- so a raider that ducks out of LOS does not instantly stop existing.
function M.Note(enemyID, x, z, defID, frame)
    if not enemyID or not x then return end
    contacts[enemyID] = {
        x = x, z = z, defID = defID, frame = frame,
        v   = M.Intrinsic(defID),
        air = defID ~= nil and UQ.is_air(defID) or false,
    }
end

function M.ScanContacts(frame)
    local all = Spring.GetAllUnits and Spring.GetAllUnits()
    if not all or not myAllyID then return end
    for i = 1, #all do
        local uid = all[i]
        if Spring.GetUnitAllyTeam(uid) ~= myAllyID then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then M.Note(uid, x, z, Spring.GetUnitDefID(uid), frame) end
        end
    end
end

function M.Contacts() return contacts end

-- Total live threat in a channel, and where its weight sits.
function M.ChannelScore(channel)
    local total, sx, sz = 0, 0, 0
    for _, c in pairs(contacts) do
        local ch = c.air and "air" or "ground"
        if ch == channel then
            local t = c.v * M.PosWeight(ch, c.x, c.z)
            total = total + t
            sx, sz = sx + c.x * t, sz + c.z * t
        end
    end
    if total <= 0 then return 0, nil, nil end
    return total, sx / total, sz / total
end

-- ── Our own answer ────────────────────────────────────────────────────────────

-- Does this unit count as an answer to this channel, and for how much?
local function ChannelValue(defID, channel)
    local v = M.Intrinsic(defID)
    if channel == "air" then
        if UQ.is_dedicated_aa(defID) then return v end
        if UQ.can_hit_air(defID) then return v * M.NONSPECIALIST_AA_WEIGHT end
        return 0
    end
    return UQ.can_hit_ground(defID) and v or 0
end

local function IsOwnCombatant(defID)
    return defID and UQ.is_mobile(defID) and UQ.has_weapons(defID)
       and not UQ.is_builder(defID) and not UQ.is_factory(defID)
       and not UQ.is_commander(defID)
end

-- What we could bring against a channel anywhere on the map, ignoring distance.
-- Context only -- never use it to decide whether to build, because an army on the
-- far side of the map is not defending anything.
function M.OwnStrength(channel)
    local total = 0
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if IsOwnCombatant(defID) then total = total + ChannelValue(defID, channel) end
    end
    return total
end

-- What can actually GET THERE in time.  A defender that arrives after the raid has
-- left was never an answer, so it must not count against the decision to build one.
--
-- This is also what makes the ETA horizon do the air/ground split for free: a
-- 297-speed fighter covers ~8900 elmos within the horizon and can respond from
-- almost anywhere, while an 85-speed Incisor covers ~2550 and is only ever local.
function M.AvailableStrength(channel, x, z)
    local total = 0
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if IsOwnCombatant(defID) then
            local v = ChannelValue(defID, channel)
            if v > 0 then
                local ux, _, uz = Spring.GetUnitPosition(uid)
                if ux then
                    local d = math.sqrt((ux - x) ^ 2 + (uz - z) ^ 2)
                    local eta = (d / math.max(1, UQ.max_speed(defID))) * 30
                    if eta <= M.RESPONSE_HORIZON then total = total + v end
                end
            end
        end
    end
    return total
end

-- How outmatched are we AT THIS SPOT?  >1 means the threat is bigger than what can
-- reach it.  An unknown channel is scored against whichever side is weaker, so an
-- unattributed hit cannot hide behind cover we might not have.
function M.Deficit(score, channel, x, z)
    if channel == "unknown" then
        return math.max(M.Deficit(score, "air", x, z),
                        M.Deficit(score, "ground", x, z))
    end
    return score / math.max(1, M.AvailableStrength(channel, x, z))
end

-- Should production interrupt the economy?  "rush" is the only state allowed to
-- spend below the float gate.
--
-- Note this is a question about PRODUCTION, not dispatch.  Whatever exists is
-- always sent (see the band comments above); this only decides whether to buy more.
-- Building is a valid answer to a local deficit because units appear at the
-- factory, which is in the base -- exactly where a raid that got this far is.
-- Mobile, armed enemies only, position-weighted: what is actually coming at us.
-- Structures are excluded on purpose -- once a scout has seen the enemy base, dozens
-- of buildings would otherwise sit in the contact list inflating the score and
-- triggering a permanent false rush.
function M.ApproachScore(channel)
    local total = 0
    for _, c in pairs(contacts) do
        local ch = c.air and "air" or "ground"
        if ch == channel and c.defID and UQ.is_mobile(c.defID) and UQ.has_weapons(c.defID) then
            total = total + c.v * M.PosWeight(ch, c.x, c.z)
        end
    end
    return total
end

function M.ProductionUrgency()
    local worst, worstChannel = 0, nil
    for i = 1, #incidents do
        local inc = incidents[i]
        local d = M.Deficit(M.IncidentScore(inc), inc.channel, inc.x, inc.z)
        if d > worst then worst, worstChannel = d, inc.channel end
    end

    -- Threats still on their way.  Without this, urgency only rose once something
    -- was already being shot -- so every frame of warning the pickets bought was
    -- wasted until the first hit.  Observed vs GROUND_RAIDER_BOT from the weaker
    -- slot: the raid landed at 6:20, the rush only fired at 6:22, and the commander
    -- died at base outnumbered 7 to 2.  Scored against what could meet it at HOME,
    -- and the position table does the escalation: a raid at the midline weighs 0.10
    -- of its value, in our half 0.30, in the mex grid 0.70.
    if MM and MM.Ready() then
        local hx, hz = MM.Home()
        for _, ch in ipairs({ "ground", "air" }) do
            local score = M.ApproachScore(ch)
            if score > 0 then
                local d = score / math.max(1, M.AvailableStrength(ch, hx, hz))
                if d > worst then worst, worstChannel = d, ch end
            end
        end
    end
    if worst >= M.DEFICIT_RUSH  then return "rush",  worst, worstChannel end
    if worst >= M.DEFICIT_BUILD then return "build", worst, worstChannel end
    return "none", worst, worstChannel
end

-- ── Incidents ─────────────────────────────────────────────────────────────────

local function MergeEvent(x, z, dmg, valueLost, channel, frame)
    local best, bestD = nil, M.INCIDENT_MERGE
    for i = 1, #incidents do
        local inc = incidents[i]
        local d = math.sqrt((inc.x - x) ^ 2 + (inc.z - z) ^ 2)
        if d < bestD then best, bestD = inc, d end
    end

    if not best then
        incidents[#incidents + 1] = {
            x = x, z = z, lastX = x, lastZ = z,
            firstFrame = frame, lastFrame = frame,
            dmg = dmg, valueLost = valueLost, channel = channel,
            n = 1, vx = 0, vz = 0,
        }
        return incidents[#incidents], true
    end

    -- Track where the attack is drifting: successive hits trace the raider's path,
    -- which is what tells us whether it is leaving (do not chase) and what it is
    -- likely to hit next.
    local dt = frame - best.lastFrame
    if dt > 0 then
        local nvx, nvz = (x - best.lastX) / dt, (z - best.lastZ) / dt
        best.vx = best.vx * 0.6 + nvx * 0.4
        best.vz = best.vz * 0.6 + nvz * 0.4
    end
    best.lastX, best.lastZ = x, z
    best.x = best.x * 0.7 + x * 0.3
    best.z = best.z * 0.7 + z * 0.3
    best.lastFrame = frame
    best.dmg       = best.dmg + dmg
    best.valueLost = best.valueLost + valueLost
    best.n         = best.n + 1
    if best.channel == "unknown" and channel ~= "unknown" then best.channel = channel end
    return best, false
end

-- Estimate where a shot came from when the shooter itself is not visible.
-- Walks back up the projectile's velocity by the weapon's range.
local function BackTrace(projectileID, weaponDefID)
    if not projectileID or not Spring.GetProjectilePosition then return nil end
    local px, _, pz = Spring.GetProjectilePosition(projectileID)
    if not px then return nil end
    local vx, _, vz = Spring.GetProjectileVelocity(projectileID)
    if not vx or (vx == 0 and vz == 0) then return px, pz end
    local wd    = weaponDefID and WeaponDefs and WeaponDefs[weaponDefID]
    local range = (wd and wd.range) or 600
    local vlen  = math.sqrt(vx * vx + vz * vz)
    if vlen <= 0.001 then return px, pz end
    return px - (vx / vlen) * range, pz - (vz / vlen) * range
end

-- Called from widget:UnitDamaged for our own units.
--
-- NOTE: the equivalent in bot.lua (:879) opens with `if not attackerID then return
-- end`, which throws away exactly the case its own back-trace below was written for.
-- An invisible attacker is the normal situation for a bomber run, so here a nil
-- attacker still raises an incident -- at the VICTIM's position, which we always
-- know, rather than the attacker's, which we may not.
function M.OnDamaged(victimID, victimDefID, damage, weaponDefID, projectileID,
                     attackerID, attackerDefID, frame)
    local vx, _, vz = Spring.GetUnitPosition(victimID)
    if not vx then return end

    local channel = "unknown"
    local ax, az

    if attackerID then
        ax, _, az = Spring.GetUnitPosition(attackerID)
        if attackerDefID then
            channel = UQ.is_air(attackerDefID) and "air" or "ground"
            if ax then M.Note(attackerID, ax, az, attackerDefID, frame) end
        end
    end

    if not ax then
        ax, az = BackTrace(projectileID, weaponDefID)
        -- Ask again shortly: the engine often knows the last attacker a moment
        -- after the hit, once the unit resolves.
        pending[victimID] = frame
    end

    -- An unattributed hit still tells us the channel if something of that channel
    -- was recently seen nearby -- the contact memory is doing the identification.
    if channel == "unknown" then
        local bestD = M.INCIDENT_MERGE
        for _, c in pairs(contacts) do
            if frame - c.frame < M.CONTACT_TTL then
                local d = math.sqrt((c.x - vx) ^ 2 + (c.z - vz) ^ 2)
                if d < bestD then bestD, channel = d, c.air and "air" or "ground" end
            end
        end
    end

    MergeEvent(vx, vz, damage or 0, 0, channel, frame)
end

-- Own losses are the loudest signal we get: something killed this and we may never
-- have seen it.  Enemy deaths clear the contact so we stop reacting to a ghost.
--
-- But most of our units that "die" are not killed: the bot reclaims its own starter
-- lab, retrofits grids, and recycles wind. Counting those as attacks raised a
-- "respond"-band threat at 2:34, long before any enemy could physically arrive.
-- A real kill leaves one of two traces -- an ENEMY attacker, or damage we already
-- logged at that spot.  A reclaim leaves neither.
--
-- The attacker check has to test the attacker's ally team, not just its existence:
-- Spring names the reclaiming unit as the attacker, so our own nano eating the
-- starter lab arrives here looking exactly like a kill.  That one reclaim was
-- raising a 470-point "respond" threat at 2:38 -- minutes before an Incisor could
-- cross the map.
function M.OnUnitDestroyed(unitID, defID, isMine, frame, attackerID)
    if not isMine then
        contacts[unitID] = nil
        return
    end
    pending[unitID] = nil
    local x, _, z = Spring.GetUnitPosition(unitID)
    if not x then return end

    if attackerID and Spring.GetUnitAllyTeam(attackerID) == myAllyID then
        attackerID = nil
    end

    if not attackerID then
        local nearby = false
        for i = 1, #incidents do
            local inc = incidents[i]
            if (inc.x - x) ^ 2 + (inc.z - z) ^ 2 < M.INCIDENT_MERGE ^ 2 then
                nearby = true
                break
            end
        end
        if not nearby then return end
    end

    MergeEvent(x, z, 0, UQ.metal_cost(defID), "unknown", frame)
end

-- Retry attacker attribution for recent hits, then expire stale state.
function M.Update(frame)
    for victimID, hitFrame in pairs(pending) do
        if frame - hitFrame >= 15 then
            pending[victimID] = nil
            local att = Spring.GetUnitLastAttacker and Spring.GetUnitLastAttacker(victimID)
            if att then
                local ax, _, az = Spring.GetUnitPosition(att)
                if ax then M.Note(att, ax, az, Spring.GetUnitDefID(att), frame) end
            end
        end
    end

    for id, c in pairs(contacts) do
        if frame - c.frame > M.CONTACT_TTL then contacts[id] = nil end
    end

    for i = #incidents, 1, -1 do
        if frame - incidents[i].lastFrame > M.INCIDENT_TTL then
            table.remove(incidents, i)
        end
    end
end

-- Score an incident: what is actually standing there now, plus what it has already
-- cost us.  Damage alone under-rates a raider that is eating undefended mexes.
function M.IncidentScore(inc)
    local live = 0
    for _, c in pairs(contacts) do
        local d = math.sqrt((c.x - inc.x) ^ 2 + (c.z - inc.z) ^ 2)
        if d <= M.INCIDENT_MERGE then
            live = live + c.v * M.PosWeight(c.air and "air" or "ground", c.x, c.z)
        end
    end
    return live + inc.valueLost * M.PosWeight(inc.channel, inc.x, inc.z)
end

-- Is the attack moving away from the point it is attacking?  Used for the
-- no-chase rule: a faster raider on its way out cannot be caught.
function M.IsLeaving(inc)
    if not (MM and MM.Ready()) then return false end
    local hx, hz = MM.Home()
    local toHomeX, toHomeZ = hx - inc.x, hz - inc.z
    return (inc.vx * toHomeX + inc.vz * toHomeZ) < 0
end

function M.Incidents() return incidents end

function M.TopIncident()
    local best, bestScore = nil, 0
    for i = 1, #incidents do
        local s = M.IncidentScore(incidents[i])
        if s > bestScore then best, bestScore = incidents[i], s end
    end
    return best, bestScore
end

return M
