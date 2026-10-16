-- bar_framework/unit_query.lua
-- Unit classification and querying helpers shared across bot widgets.
--
-- Load in a widget with:
--   local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
--
-- NOTE: Spring.GetTeamUnits() respects visibility.  P0 (fullview=1) can query
-- both teams; P1 can only reliably query its own team.

local M = {}

-- ── Classification helpers ────────────────────────────────────────────────────

function M.is_commander(defID)
    local d = defID and UnitDefs[defID]
    if not d then return false end
    return (d.customParams and
            (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil))
        or (d.name and string.find(string.lower(d.name), "commander") ~= nil)
end

function M.is_factory(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.isFactory == true
end

function M.is_builder(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.isBuilder == true and not d.isFactory
end

-- Metal cost of a unit definition (0 if unknown).
function M.metal_cost(defID)
    local d = defID and UnitDefs[defID]
    return d and (d.metalCost or 0) or 0
end

function M.is_air(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.canFly == true
end

function M.is_mobile(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and (d.speed or 0) > 0
end

-- Top speed in elmos/second (0 for structures).  Pair with map_model.TravelFrames
-- to turn a distance into an arrival frame.
function M.max_speed(defID)
    local d = defID and UnitDefs[defID]
    return d and (d.speed or 0) or 0
end

-- ── Weapon capability ─────────────────────────────────────────────────────────

local capsCache = {}

-- What can this unit shoot at?  Read from the weapons' own targeting restrictions:
--   onlyTargets.vtol      -> anti-air only        onlyTargets.surface -> cannot hit air
--   canAttackGround=false -> cannot hit ground    otherwise           -> both
--
-- EVERY weapon is inspected.  Judging a unit by its first weapon misled this
-- project once, and a unit with a dedicated AA gun plus a main gun reads as
-- ground-only if you stop at weapon 1.  Kept identical to the stats tracker's
-- capsOf() so bot decisions and [TRK] numbers cannot disagree.
local function caps(defID)
    local c = capsCache[defID]
    if c then return c[1], c[2], c[3] end
    local air, gnd = false, false
    local d = defID and UnitDefs[defID]
    if d and d.weapons then
        for i = 1, #d.weapons do
            local w  = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            local only = (w and w.onlyTargets) or {}
            local groundOK = not (wd and wd.canAttackGround == false)
            if only.vtol then
                air = true
            else
                if not only.surface and not only.notair then air = true end
                if groundOK then gnd = true end
            end
        end
    end
    capsCache[defID] = { air, gnd, air and not gnd }
    return air, gnd, air and not gnd
end

function M.can_hit_air(defID)    local a = caps(defID)          return a end
function M.can_hit_ground(defID) local _, g = caps(defID)       return g end

-- Real AA: hits air and cannot hit ground.  This is the test to trust when asking
-- "do we have an answer to bombers" -- a flag saying a weapon MAY target air does
-- not mean it is any good at it.
function M.is_dedicated_aa(defID)
    local _, _, aaOnly = caps(defID)
    return aaOnly
end

function M.has_weapons(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.weapons ~= nil and #d.weapons > 0
end

local rangeCache = {}

-- Longest weapon range, across all weapons (0 if unarmed).
function M.max_weapon_range(defID)
    local r = rangeCache[defID]
    if r then return r end
    r = 0
    local d = defID and UnitDefs[defID]
    if d and d.weapons then
        for i = 1, #d.weapons do
            local w  = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            if wd and (wd.range or 0) > r then r = wd.range end
        end
    end
    rangeCache[defID] = r
    return r
end

-- A bomber: flies and drops bombs.  Read from the weapon type, with the Cortex/Armada
-- names as a fallback in case a def reports something unexpected.  Bombers are one-way
-- strike units -- no repair pads exist in BAR -- so planners treat them apart from the
-- line and never retreat them.
local BOMBER_NAMES = { corshad = true, corhurc = true, armthund = true, armpnix = true }
local bomberCache = {}
function M.is_bomber(defID)
    local b = bomberCache[defID]
    if b ~= nil then return b end
    b = false
    local d = defID and UnitDefs[defID]
    if d and d.canFly then
        if BOMBER_NAMES[d.name] then b = true end
        for i = 1, #(d.weapons or {}) do
            local w  = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            if wd and wd.type == "AircraftBomb" then b = true end
        end
    end
    if defID then bomberCache[defID] = b end
    return b
end

-- Is this def a scout?  Category and name tests first, then the fallback that
-- catches anything fast and unarmed.
function M.is_scout(defID)
    local d = defID and UnitDefs[defID]
    if not d then return false end
    local mc = d.modCategories
    if mc then
        for k in pairs(mc) do
            if string.find(k, "scout") then return true end
        end
    end
    local cat = d.category
    if type(cat) == "string" and string.find(string.lower(cat), "scout") then return true end
    local name  = string.lower(d.name or "")
    local hName = string.lower((d.translatedHumanName or d.humanName) or "")
    if string.find(name,  "scout")  or string.find(hName, "scout")
    or string.find(name,  "peep")   or string.find(name,  "flea")
    or string.find(name,  "fink")   or string.find(name,  "phantom")
    or string.find(name,  "weasel") or string.find(name,  "wheelie") then
        return true
    end
    return (d.speed or 0) > 150 and not M.has_weapons(defID)
end

-- ── Team-wide queries ─────────────────────────────────────────────────────────

-- THE PER-FRAME SNAPSHOT (C5).  `GetTeamUnits` was walked at ~35 places, several of them every few frames, each filtering the same list for its
-- own purpose.  Snapshot(team) walks it once per game frame and every caller shares the result: it is kept on WG.UQSnap (separate VFS.Include
-- instances of this file share it there; without a WG each instance keeps its own).
--   snap = { frame, ids = {uid...}, defOf = {[uid] = defID}, byDef = {[defID] = {uid...}} }  plus, built on first use and kept for the frame:
--   UQ.Structures(team) = { {uid, x, z, defID, cost}... } immobile own units;  UQ.ByRole(team) = get_by_role's result
-- A unit destroyed after the snapshot was built is still in it until the next frame (callers that act on a unit re-check GetUnitDefID).
local localStore = {}
local function Store()
    if WG then
        WG.UQSnap = WG.UQSnap or {}
        return WG.UQSnap
    end
    return localStore
end
local function Frame() return (Spring.GetGameFrame and Spring.GetGameFrame()) or 0 end

function M.snapshot(teamID)
    local store, frame = Store(), Frame()
    local s = store[teamID]
    local count = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(teamID)      -- (a unit made or lost since the walk also ends a snapshot)
    if s and s.frame == frame and s.count == count then
        -- spot check: the first and last unit are still what the walk saw (a unit lost and another made in the same frame keeps the count)
        local first, last = s.ids[1], s.ids[#s.ids]
        if (first == nil or Spring.GetUnitDefID(first) == s.defOf[first]) and (last == nil or Spring.GetUnitDefID(last) == s.defOf[last]) then return s end
    end
    s = { frame = frame, count = count, ids = {}, defOf = {}, byDef = {} }
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID then
            s.ids[#s.ids + 1] = uid
            s.defOf[uid] = defID
            local l = s.byDef[defID]
            if not l then l = {}; s.byDef[defID] = l end
            l[#l + 1] = uid
        end
    end
    store[teamID] = s
    M.snapshots_built = (M.snapshots_built or 0) + 1
    return s
end

-- Units of one def (or any def in a set { [defID] = true }) this frame.
function M.units_of(teamID, defOrSet)
    local s = M.snapshot(teamID)
    if type(defOrSet) == "number" then return s.byDef[defOrSet] or {} end
    local out = {}
    for d in pairs(defOrSet or {}) do for _, uid in ipairs(s.byDef[d] or {}) do out[#out + 1] = uid end end
    return out
end
function M.count_of(teamID, defOrSet) return #M.units_of(teamID, defOrSet) end

-- Immobile own units with their position and metal cost (what perimeter_guard / maneuver_defence ring round the base).
function M.structures(teamID)
    local s = M.snapshot(teamID)
    if not s.structures then
        local out = {}
        for _, uid in ipairs(s.ids) do
            local d = UnitDefs[s.defOf[uid]]
            if d and (d.speed == nil or d.speed == 0) and not d.canFly then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then out[#out + 1] = { uid = uid, x = x, z = z, defID = s.defOf[uid], cost = d.metalCost or 0, w = d.metalCost or 50 } end
            end
        end
        s.structures = out
    end
    return s.structures
end

-- Every non-allied unit once per frame (the enemy scans of threat_map, enemy_intel and the unit controllers share it).
function M.enemies(teamID, allyTeam)
    local store, frame = Store(), Frame()
    local key = "enemies" .. tostring(teamID)
    local s = store[key]
    local total = 0                                      -- (units made or lost on any team since the walk end the cache too)
    for _, t in ipairs(Spring.GetTeamList and Spring.GetTeamList() or {}) do total = total + (Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(t) or 0) end
    if s and s.frame == frame and s.total == total then return s.list end
    local list = {}
    for _, uid in ipairs(Spring.GetAllUnits and Spring.GetAllUnits() or {}) do
        if Spring.GetUnitAllyTeam(uid) ~= allyTeam then list[#list + 1] = uid end
    end
    store[key] = { frame = frame, total = total, list = list }
    return list
end

-- Returns alive non-commander units split by role.
-- result = {combat={uid,...}, builders={uid,...}, factories={uid,...}, commanders={uid,...}}
function M.get_by_role(teamID)
    local s = M.snapshot(teamID)
    if s.roles then return s.roles end
    local result = {combat={}, builders={}, factories={}, commanders={}}
    for _, uid in ipairs(s.ids) do
        local defID = s.defOf[uid]
        if M.is_commander(defID) then
            table.insert(result.commanders, uid)
        elseif M.is_factory(defID) then
            table.insert(result.factories, uid)
        elseif M.is_builder(defID) then
            table.insert(result.builders, uid)
        else
            table.insert(result.combat, uid)
        end
    end
    s.roles = result
    return result
end

-- Total metal value of all alive non-commander units for a team.
function M.army_metal_value(teamID)
    local s = M.snapshot(teamID)
    local mv = 0
    for _, uid in ipairs(s.ids) do
        local defID = s.defOf[uid]
        if not M.is_commander(defID) then mv = mv + M.metal_cost(defID) end
    end
    return mv
end

-- Count of alive non-commander units for a team.
function M.army_count(teamID)
    local s = M.snapshot(teamID)
    local n = 0
    for _, uid in ipairs(s.ids) do
        if not M.is_commander(s.defOf[uid]) then n = n + 1 end
    end
    return n
end

-- Returns the commander unit ID for a team, or nil if dead/not found.
function M.get_commander(teamID)
    local s = M.snapshot(teamID)
    for _, uid in ipairs(s.ids) do
        if M.is_commander(s.defOf[uid]) then return uid end
    end
    return nil
end

-- Returns a list of enemy unitIDs within `radius` elmos of position (x, z).
-- Clamps the cylinder query to map bounds automatically.
function M.enemies_near(x, z, radius, myAllyTeam)
    local msx = Game.mapSizeX
    local msz = Game.mapSizeZ
    local cx  = math.max(radius, math.min(msx - radius, x))
    local cz  = math.max(radius, math.min(msz - radius, z))
    local found = Spring.GetUnitsInCylinder(cx, cz, radius) or {}
    local enemies = {}
    for _, uid in ipairs(found) do
        if Spring.GetUnitAllyTeam(uid) ~= myAllyTeam then
            table.insert(enemies, uid)
        end
    end
    return enemies
end

return M
