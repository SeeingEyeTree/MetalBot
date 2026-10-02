-- bar_framework/rez_crew.lua
-- Graverobbers: battlefield repair, resurrection and reclaim (game_mechanics 1.4).
--
-- WHY
-- ---
-- 1.4 calls rez bots required for a "fully functional" bot, and gives the reasons:
--   * healing a damaged unit costs only time, no resources -- always worth doing;
--   * a wreck is ~70% of the unit's metal, and resurrecting one puts the unit back
--     near the front instead of making a replacement walk there from base;
--   * reclaim near the front is a real metal windfall.
-- They travel a bit BEHIND the main army (7: support units are fragile and should not
-- work in the line of fire).
--
-- Each tick, per rez bot, in order:
--   1. badly hurt itself          -> back to the nearest nano cluster
--   2. a damaged friend nearby    -> repair it (mobile units first: they fight)
--   3. a wreck nearby             -> resurrect it if it was an armed unit worth having,
--                                    else reclaim it
--   4. nothing to do              -> follow the army, TRAIL elmos behind its front
--
-- Also answers "where should a wounded unit go to be healed" for the retreat pass
-- (HealPoint): the nearest rez bot, else the nearest nano turret, else home.
--
-- USAGE
--   local RC = VFS.Include("LuaUI/Widgets/bar_framework/rez_crew.lua")
--   RC.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, teamID = t, allyID = a }
--   RC.Add(unitID)                               -- from UnitFinished
--   RC.Update(frame, frontX, frontZ)             -- every ~60 frames
--   local x, z = RC.HealPoint(ux, uz)

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.REPAIR_RADIUS   = 900
M.REPAIR_BELOW    = 0.95   -- hp share below which a friend is worth repairing
M.WRECK_RADIUS    = 900
M.REZ_MIN_COST    = 80     -- resurrect only armed units at least this expensive
M.RECLAIM_MIN     = 15     -- metal left in a wreck before it is worth the walk
M.TRAIL           = 700    -- elmos behind the front the crew follows at
M.TRAIL_SPREAD    = 250    -- lateral spacing between crew members
M.SELF_RETREAT    = 0.40   -- a rez bot below this hp goes home to be fixed
M.HEAL_REZ_RANGE  = 3000   -- a wounded unit is sent to a rez bot this close...
M.HEAL_NANO_RANGE = 5000   -- ...else to a nano turret this close
M.NANO_REFRESH    = 300    -- frames between nano position scans
M.UNSAFE_THREAT   = 1      -- EI ground threat above this makes a wreck not worth it
M.SAFETY_CHECKS   = 4      -- best candidates tested for that, per kind

local CMD_MOVE      = 10
local CMD_REPAIR    = 40
local CMD_RECLAIM   = 90
local CMD_RESURRECT = (CMD and CMD.RESURRECT) or 125

-- ── State ─────────────────────────────────────────────────────────────────────

local MM, UQ, EI, ARMY
local myTeamID, myAllyID
local crew   = {}          -- [unitID] = true
local nanos  = {}          -- list of {x, z}
local lastNanoScan = -1e9
local busyWreck = {}       -- [featureID] = unitID working it, so two do not share one

function M.Init(opts)
    MM, UQ, EI, ARMY = opts.MM, opts.UQ, opts.EI, opts.ARMY
    myTeamID, myAllyID = opts.teamID, opts.allyID
end

function M.IsRezDef(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.canResurrect == true and (d.speed or 0) > 0
end

function M.Add(unitID)    crew[unitID] = true end
function M.Remove(unitID)
    crew[unitID] = nil
    for fid, uid in pairs(busyWreck) do
        if uid == unitID then busyWreck[fid] = nil end
    end
end
function M.IsCrew(unitID) return crew[unitID] == true end
function M.Count()
    local n = 0
    for uid in pairs(crew) do
        if Spring.GetUnitDefID(uid) then n = n + 1 else crew[uid] = nil end
    end
    return n
end

local function IsNanoDef(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.isBuilder and not d.isFactory and not d.canFly
       and (d.speed == nil or d.speed == 0)
end

local function RefreshNanos(frame)
    if frame - lastNanoScan < M.NANO_REFRESH then return end
    lastNanoScan = frame
    nanos = {}
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        if IsNanoDef(Spring.GetUnitDefID(uid)) and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then nanos[#nanos + 1] = { x = x, z = z } end
        end
    end
end

-- Where should a wounded unit at (x, z) go to be healed?  Returns x, z, kind.
function M.HealPoint(x, z, exclude)
    local best, bestD2, kind = nil, M.HEAL_REZ_RANGE ^ 2, nil
    for uid in pairs(crew) do
        if uid ~= exclude then
            local hp, maxHP = Spring.GetUnitHealth(uid)
            if hp and maxHP and maxHP > 0 and hp / maxHP >= M.SELF_RETREAT then
                local rx, _, rz = Spring.GetUnitPosition(uid)
                if rx then
                    local d2 = (rx - x) ^ 2 + (rz - z) ^ 2
                    if d2 < bestD2 then best, bestD2, kind = { rx, rz }, d2, "rez" end
                end
            end
        end
    end
    if best then return best[1], best[2], kind end

    bestD2 = M.HEAL_NANO_RANGE ^ 2
    for _, n in ipairs(nanos) do
        local d2 = (n.x - x) ^ 2 + (n.z - z) ^ 2
        if d2 < bestD2 then best, bestD2 = n, d2 end
    end
    if best then return best.x, best.z, "nano" end

    local hx, hz = MM and MM.Home()
    return hx, hz, "home"
end

-- The most worthwhile damaged friend near (x, z): mobile units before structures,
-- then by missing value.
local function DamagedFriend(uid, x, z)
    local best, bestScore = nil, 0
    for _, fid in ipairs(Spring.GetUnitsInCylinder(x, z, M.REPAIR_RADIUS, myTeamID) or {}) do
        if fid ~= uid and not Spring.GetUnitIsBeingBuilt(fid) then
            local hp, maxHP = Spring.GetUnitHealth(fid)
            if hp and maxHP and maxHP > 0 and hp / maxHP < M.REPAIR_BELOW then
                local defID = Spring.GetUnitDefID(fid)
                local missing = (1 - hp / maxHP) * UQ.metal_cost(defID)
                if UQ.is_mobile(defID) then missing = missing * 3 end
                if missing > bestScore then best, bestScore = fid, missing end
            end
        end
    end
    return best
end

-- The best wreck near (x, z): resurrect an armed unit if it is worth it, else reclaim
-- the richest one.  Returns featureID, command.
-- The first candidate (best first) that is not under a known enemy gun.  The safety
-- test walks the whole intel memory, so it is only run on the few best candidates
-- rather than on every wreck of a big fight.
local function FirstSafe(frame, list)
    table.sort(list, function(a, b) return a.v > b.v end)
    for i = 1, math.min(#list, M.SAFETY_CHECKS) do
        local c = list[i]
        if not (EI and EI.ThreatAt(frame, c.x, c.z, "ground") > M.UNSAFE_THREAT) then
            return c.fid
        end
    end
    return nil
end

local function BestWreck(frame, uid, x, z)
    if not Spring.GetFeaturesInCylinder then return nil end
    local rez, rec = {}, {}
    for _, fid in ipairs(Spring.GetFeaturesInCylinder(x, z, M.WRECK_RADIUS) or {}) do
        if not busyWreck[fid] or busyWreck[fid] == uid then
            local fx, _, fz = Spring.GetFeaturePosition(fid)
            if fx then
                local name = Spring.GetFeatureResurrect and Spring.GetFeatureResurrect(fid)
                local ud = name and name ~= "" and UnitDefNames and UnitDefNames[name]
                local cost = ud and ud.metalCost or 0
                if ud and UQ.has_weapons(ud.id) and UQ.is_mobile(ud.id)
                   and cost >= M.REZ_MIN_COST then
                    rez[#rez + 1] = { fid = fid, v = cost, x = fx, z = fz }
                end
                local metal = Spring.GetFeatureResources(fid) or 0
                if metal >= M.RECLAIM_MIN then
                    rec[#rec + 1] = { fid = fid, v = metal, x = fx, z = fz }
                end
            end
        end
    end
    local fid = FirstSafe(frame, rez)
    if fid then return fid, CMD_RESURRECT end
    fid = FirstSafe(frame, rec)
    if fid then return fid, CMD_RECLAIM end
    return nil
end

local function Claim(frame, uid, spec)
    ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, spec, frame)
end

-- One pass.  (frontX, frontZ) is where the army's front is; nil means stay home.
function M.Update(frame, frontX, frontZ)
    if not (ARMY and MM and MM.Ready()) then return end
    RefreshNanos(frame)
    for fid, uid in pairs(busyWreck) do
        if not crew[uid] or not Spring.GetUnitDefID(uid)
           or (Spring.ValidFeatureID and not Spring.ValidFeatureID(fid)) then
            busyWreck[fid] = nil
        end
    end

    local hx, hz = MM.Home()
    local ax, az = MM.Axis()
    local px, pz = MM.Perp()
    local tx, tz = hx, hz
    if frontX then tx, tz = frontX - ax * M.TRAIL, frontZ - az * M.TRAIL end

    local ids = {}
    for uid in pairs(crew) do
        if Spring.GetUnitDefID(uid) then ids[#ids + 1] = uid else M.Remove(uid) end
    end
    table.sort(ids)

    local maxUnits = Game and Game.maxUnits or 32000
    for i, uid in ipairs(ids) do
        -- Whatever wreck this bot held is released; it re-claims below if it keeps it.
        for fid, owner in pairs(busyWreck) do
            if owner == uid then busyWreck[fid] = nil end
        end
        local x, _, z = Spring.GetUnitPosition(uid)
        local hp, maxHP = Spring.GetUnitHealth(uid)
        if x and hp and maxHP and maxHP > 0 then
            if hp / maxHP < M.SELF_RETREAT then
                local rx, rz = M.HealPoint(x, z, uid)
                Claim(frame, uid, { role = "REZ", cmd = CMD_MOVE, x = rx or hx, z = rz or hz })
            else
                local friend = DamagedFriend(uid, x, z)
                if friend then
                    Claim(frame, uid, { role = "REZ", cmd = CMD_REPAIR, targetID = friend })
                else
                    local fid, cmd = BestWreck(frame, uid, x, z)
                    if fid then
                        busyWreck[fid] = uid
                        Claim(frame, uid, { role = "REZ", cmd = cmd, targetID = fid + maxUnits })
                    else
                        local k = (i - 1) - (#ids - 1) / 2
                        local wx, wz = MM.Clamp(tx + px * k * M.TRAIL_SPREAD,
                                                tz + pz * k * M.TRAIL_SPREAD, 200)
                        Claim(frame, uid, { role = "REZ", cmd = CMD_MOVE, x = wx, z = wz })
                    end
                end
            end
        end
    end
end

return M
