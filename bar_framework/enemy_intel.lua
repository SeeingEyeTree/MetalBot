-- bar_framework/enemy_intel.lua
-- What we have learned about the enemy, remembered for longer than one glance.
--
-- WHY THIS EXISTS
-- ---------------
-- game_mechanics 6.2: the map is static and known, so scouting is not about terrain.
-- It is about finding the enemy and tracking their army and production.  The threat
-- map already keeps contacts, but only for 40 s and only to answer "is something
-- attacking us right now".  Several decisions need a longer memory:
--
--   * AA posture (7.3): "scale up reactively once the enemy is seen investing in air".
--     A bomber wing seen three minutes ago is still out there.
--   * Raiders (7): where is their economy, and what defends it?
--   * Endgame (9): when did we last see anything that can fight, and where was their
--     commander?
--
-- Nothing here gives orders.  It is a memory with queries on top.
--
-- A unit is forgotten when it is seen to die, when it has not been seen for a while
-- (mobile units move, so their memory is short), or -- for buildings -- when the spot
-- it stood on is in line of sight and it is not there.
--
-- USAGE
--   local EI = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
--   EI.Init{ UQ = UQ, MM = MM, allyID = myAllyID }
--   EI.Scan(frame)                    -- every ~90 frames
--   EI.OnDestroyed(unitID)            -- from widget:UnitDestroyed, enemy units only
--   local v = EI.AirValue(frame)

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.MOBILE_MEMORY    = 9000    -- 5 min, the stats tracker's MEMORY_FRAMES
M.STATIC_MEMORY    = 54000   -- 30 min: buildings do not walk away
M.POSITION_FRESH   = 900     -- a mobile unit's position is only trusted for 30 s
M.NONSPECIALIST_AA = 0.35    -- same discount the threat map uses for weapons that
                             -- merely may shoot upward
M.MOBILE_REACH     = 400     -- a mobile unit threatens its weapon range plus this
M.STATIC_REACH     = 150     -- ...a turret only its range plus this

-- ── State ─────────────────────────────────────────────────────────────────────

local UQ, MM
local myAllyID

local seen      = {}      -- [unitID] = record, see Note()
local classes   = {}      -- [defID]  = class table, see Class()
local lastArmed = -1e9    -- last frame an armed mobile enemy was actually in view
local commander = nil     -- record of the enemy commander, if ever seen
local firsts    = {}      -- once-only events: air, t2, airlab, t2airlab

function M.Init(opts)
    UQ, MM   = opts.UQ, opts.MM
    myAllyID = opts.allyID
end

-- ── Classification ────────────────────────────────────────────────────────────

local function TechLevel(d)
    local t = d.customParams and tonumber(d.customParams.techlevel)
    return t or 1
end

-- The metal + energy/70 cost game_mechanics 2.3 uses to put both on one scale.
local function Value(d)
    return (d.metalCost or 0) + (d.energyCost or 0) / 70
end

local function Class(defID)
    local c = classes[defID]
    if c then return c end
    local d = UnitDefs[defID]
    if not d then return nil end
    local armed  = UQ.has_weapons(defID)
    local mobile = (d.speed or 0) > 0
    c = {
        mobile    = mobile,
        air       = d.canFly == true,
        armed     = armed,
        commander = UQ.is_commander(defID),
        factory   = d.isFactory == true,
        builder   = d.isBuilder == true and not d.isFactory,
        scout     = UQ.is_scout(defID),
        hitsAir   = armed and UQ.can_hit_air(defID),
        hitsGnd   = armed and UQ.can_hit_ground(defID),
        aaOnly    = armed and UQ.is_dedicated_aa(defID),
        range     = UQ.max_weapon_range(defID),
        value     = Value(d),
        tech      = TechLevel(d),
        interceptor = 0,
    }
    for i = 1, #(d.weapons or {}) do
        local w  = d.weapons[i]
        local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
        if wd and wd.interceptor and wd.interceptor ~= 0 then
            c.interceptor = math.max(c.interceptor, wd.coverageRange or wd.range or 2000)
        end
    end
    -- An air factory is one that builds anything that flies.
    if c.factory then
        for _, opt in ipairs(d.buildOptions or {}) do
            local od = UnitDefs[opt]
            if od and od.canFly then c.airFactory = true; break end
        end
    end
    classes[defID] = c
    return c
end
M.Class = Class

-- ── Observation ───────────────────────────────────────────────────────────────

local function Firsts(c, frame)
    if c.air and c.armed and not firsts.air then firsts.air = frame end
    if c.tech >= 2 and not firsts.t2 then firsts.t2 = frame end
    if c.airFactory and not firsts.airlab then firsts.airlab = frame end
    if c.airFactory and c.tech >= 2 and not firsts.t2airlab then firsts.t2airlab = frame end
end

local function Note(uid, defID, x, z, frame)
    local rec = seen[uid]
    local c = defID and Class(defID)
    if not rec then
        if not c then return end          -- an unidentified blip we never saw up close
        rec = { uid = uid, defID = defID, c = c, firstFrame = frame }
        seen[uid] = rec
        Firsts(c, frame)
    elseif c and rec.defID ~= defID then
        rec.defID, rec.c = defID, c
    end
    rec.x, rec.z, rec.frame = x, z, frame
    if rec.c.commander then commander = rec end
    -- The commander is armed, but it is not an army: seeing it is exactly what the
    -- endgame wants, and counting it would keep "an armed enemy was just seen" true
    -- for as long as it is in view.
    if rec.c.mobile and rec.c.armed and not rec.c.scout and not rec.c.commander and defID then
        lastArmed = frame
    end
end

-- Remember everything we can see now.  Radar-only blips report no def; for a unit we
-- already know that is still enough to say it is alive and roughly where.
function M.Scan(frame)
    local all = Spring.GetAllUnits and Spring.GetAllUnits()
    if not all or not myAllyID then return end
    local visible = {}
    for i = 1, #all do
        local uid = all[i]
        if Spring.GetUnitAllyTeam(uid) ~= myAllyID then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                Note(uid, Spring.GetUnitDefID(uid), x, z, frame)
                visible[uid] = true
            end
        end
    end
    M.Expire(frame, visible)
end

-- Forget what is too old to trust, and buildings whose spot we can see is empty.
function M.Expire(frame, visible)
    local los = Spring.IsPosInLos
    for uid, rec in pairs(seen) do
        local age = frame - rec.frame
        if rec.c.mobile then
            if age > M.MOBILE_MEMORY then seen[uid] = nil end
        elseif age > M.STATIC_MEMORY then
            seen[uid] = nil
        elseif visible and not visible[uid] and los and myAllyID
               and los(rec.x, 0, rec.z, myAllyID) then
            seen[uid] = nil
        end
    end
    if commander and not seen[commander.uid] then commander = nil end
end

function M.OnDestroyed(unitID)
    seen[unitID] = nil
    if commander and commander.uid == unitID then commander = nil end
end

-- ── Queries ───────────────────────────────────────────────────────────────────

function M.Records() return seen end
function M.First(kind) return firsts[kind] end
function M.LastArmedFrame() return lastArmed end

-- The enemy commander's last known position: x, z, frame, unitID -- or nil.
function M.Commander()
    if not commander then return nil end
    return commander.x, commander.z, commander.frame, commander.uid
end

-- Remembered value of armed enemy units in a channel.  Scouts are left out: they are
-- not something an army has to be built against.
function M.ArmyValue(frame, channel, maxAge)
    maxAge = maxAge or M.MOBILE_MEMORY
    local v = 0
    for _, rec in pairs(seen) do
        local c = rec.c
        if c.mobile and c.armed and not c.scout and not c.commander
           and frame - rec.frame <= maxAge
           and (channel == nil or (channel == "air") == c.air) then
            v = v + c.value
        end
    end
    return v
end

function M.AirValue(frame)    return M.ArmyValue(frame, "air") end
function M.GroundValue(frame) return M.ArmyValue(frame, "ground") end

-- Enemy factories we know about.
function M.Labs()
    local out = { total = 0, air = 0, ground = 0, t2 = 0, t2air = 0 }
    for _, rec in pairs(seen) do
        local c = rec.c
        if c.factory then
            out.total = out.total + 1
            if c.airFactory then out.air = out.air + 1 else out.ground = out.ground + 1 end
            if c.tech >= 2 then
                out.t2 = out.t2 + 1
                if c.airFactory then out.t2air = out.t2air + 1 end
            end
        end
    end
    return out
end

-- How dangerous is this spot, in value, for a unit of the given channel?  Turrets
-- count within their weapon range; mobile units only if seen recently, since their
-- remembered position goes stale fast.
function M.ThreatAt(frame, x, z, channel)
    local total = 0
    for _, rec in pairs(seen) do
        local c = rec.c
        if c.armed then          -- the commander included: it defends its base
            local w = 0
            if channel == "air" then
                if c.aaOnly then w = 1 elseif c.hitsAir then w = M.NONSPECIALIST_AA end
            elseif c.hitsGnd then
                w = 1
            end
            if w > 0 then
                local reach
                if c.mobile then
                    if frame - rec.frame <= M.POSITION_FRESH then reach = c.range + M.MOBILE_REACH end
                else
                    reach = c.range + M.STATIC_REACH
                end
                if reach then
                    local dx, dz = rec.x - x, rec.z - z
                    if dx * dx + dz * dz <= reach * reach then total = total + c.value * w end
                end
            end
        end
    end
    return total
end

-- Would an enemy anti-nuke intercept a missile aimed here?
function M.AntiNukeCovers(x, z)
    for _, rec in pairs(seen) do
        local r = rec.c.interceptor
        if r and r > 0 then
            local dx, dz = rec.x - x, rec.z - z
            if dx * dx + dz * dz <= r * r then return true end
        end
    end
    return false
end

-- Things worth raiding: unarmed structures, factories and builders.  Returns a list
-- of {uid, x, z, value, factory, builder}.
function M.RaidTargets(frame)
    local out = {}
    for uid, rec in pairs(seen) do
        local c = rec.c
        local isEco = (not c.mobile and not c.armed) or c.factory or c.builder
        if isEco and not c.commander
           and (not c.mobile or frame - rec.frame <= M.POSITION_FRESH) then
            out[#out + 1] = { uid = uid, x = rec.x, z = rec.z, value = c.value,
                              factory = c.factory, builder = c.builder }
        end
    end
    return out
end

-- Value-weighted centre of the enemy army seen within maxAge frames: x, z, value.
function M.ArmyCentroid(frame, maxAge)
    maxAge = maxAge or 1800
    local sx, sz, v = 0, 0, 0
    for _, rec in pairs(seen) do
        local c = rec.c
        if c.mobile and c.armed and not c.scout and frame - rec.frame <= maxAge then
            sx, sz, v = sx + rec.x * c.value, sz + rec.z * c.value, v + c.value
        end
    end
    if v <= 0 then return nil end
    return sx / v, sz / v, v
end

function M.Count()
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return n
end

-- Plain numbers for other widgets (WG.MetalBot.intel); tables of unit records stay here.
function M.Summary(frame)
    local labs = M.Labs()
    local cx, cz, cf = M.Commander()
    return {
        airValue     = M.AirValue(frame),
        groundValue  = M.GroundValue(frame),
        labs         = labs.total,
        airLabs      = labs.air,
        t2Labs       = labs.t2,
        t2AirLabs    = labs.t2air,
        firstAir     = firsts.air,
        firstT2      = firsts.t2,
        lastArmed    = lastArmed,
        commanderX   = cx, commanderZ = cz, commanderFrame = cf,
        known        = M.Count(),
        frame        = frame,
    }
end

return M
