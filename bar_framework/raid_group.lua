-- bar_framework/raid_group.lua
-- The raider role from game_mechanics 7: "fast units probing for weakly-defended
-- points; harass economy, force a response.  Not meant to punch through a real
-- defense."
--
-- HOW
-- ---
-- A slice of the army's fastest ground-attack units (Shurikens, at 280 speed) is
-- peeled off the line once the army is big enough to spare it, capped at a share of
-- army value so it never hollows out the main force.  The group:
--
--   GATHER    masses at a rally point first -- raiders that trickle out one at a time
--             die one at a time;
--   APPROACH  flies to a waypoint off to the side of the target, on the flank away
--             from the enemy army, so it does not cross the army on the way in;
--   STRIKE    fight-moves onto the target, then picks the next weakly defended
--             target from wherever it is.
--
-- Raiders do not retreat (game_mechanics 7.2): once sent they are committed, which is
-- also why the broker ranks RAID above everything but RETREAT and why the unit
-- controller must leave them out of its retreat pass.  The group disbands only when it
-- is too small to matter, and its survivors go back to the line.
--
-- Targets come from enemy_intel: remembered unarmed structures, factories and
-- builders, bucketed into cells, scored by value against the defence remembered
-- around them, and preferring cells far from the enemy army.
--
-- USAGE
--   local RG = VFS.Include("LuaUI/Widgets/bar_framework/raid_group.lua")
--   RG.Init{ MM = MM, EI = EI, UQ = UQ, ARMY = ARMY }
--   local recruited = RG.Update(frame, combatUnits)   -- {[unitID] = defID}
--   if RG.IsRaider(uid) then ... end

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.RAID_SHARE     = 0.20   -- at most this share of army value is on raid duty
M.MIN_ARMY       = 10     -- the unit controller's ADVANCE_MIN_UNITS
M.MIN_GROUP      = 4      -- never launch fewer than this
M.DISBAND_AT     = 2      -- a group this small goes back to the line
M.MIN_SPEED      = 200    -- raiders are fast; a Wasp (159) is main-army material
M.GATHER_DIST    = 1200   -- rally point, forward of home along the axis
M.GATHER_MAX     = 900    -- frames to wait for stragglers before going anyway
M.GATHER_RADIUS  = 600
M.FLANK_OFFSET   = 1800   -- how far to the side of the target the waypoint sits
M.FLANK_BACK     = 900    -- ...and how far back toward our side
M.ARRIVE_DIST    = 600
M.CELL           = 800    -- target bucketing
M.CLEAR_RADIUS   = 500    -- a target cell with nothing remembered this close is done
M.MAX_DEFENCE    = 0.5    -- skip targets defended by more than this share of our value
M.ARMY_FAR       = 3000   -- targets this far from the enemy army get full score
M.APPROACH_MAX   = 1800   -- strike from wherever the group is after this long
M.STRIKE_MAX     = 2700   -- re-pick a target after this long on it
M.REPLAN_EVERY   = 300    -- frames between target re-evaluations while idle

-- ── State ─────────────────────────────────────────────────────────────────────

local MM, EI, UQ, ARMY
local raiders = {}        -- [unitID] = true
local stage   = "idle"    -- idle | gather | approach | strike
local stageSince = 0
local target  = nil       -- {x, z, value}
local waypoint = nil      -- {x, z}
local lastPlan = -1e9
local CMD_MOVE, CMD_FIGHT = 10, 16

function M.Init(opts)
    MM, EI, UQ, ARMY = opts.MM, opts.EI, opts.UQ, opts.ARMY
end

-- A unit that can be a raider: fast, armed, hits ground, not a pure fighter, not a
-- bomber (bombers are one-way strike weapons with their own planner) and not a scout.
local raiderCache = {}
function M.IsRaiderDef(defID)
    local r = raiderCache[defID]
    if r ~= nil then return r end
    r = defID ~= nil and UQ.has_weapons(defID) and UQ.can_hit_ground(defID)
        and not UQ.is_dedicated_aa(defID) and not UQ.is_scout(defID)
        and not UQ.is_commander(defID) and not UQ.is_builder(defID)
        and UQ.max_speed(defID) >= M.MIN_SPEED
        and not (UQ.is_bomber and UQ.is_bomber(defID))
    raiderCache[defID] = r
    return r
end

function M.IsRaider(unitID) return raiders[unitID] == true end
function M.Stage() return stage end
function M.Count()
    local n = 0
    for _ in pairs(raiders) do n = n + 1 end
    return n
end

function M.OnDestroyed(unitID) raiders[unitID] = nil end

-- metal + energy/70, the scale enemy_intel prices defences on (game_mechanics 2.3).
local function Value(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end

local function Centroid()
    local sx, sz, n = 0, 0, 0
    for uid in pairs(raiders) do
        local x, _, z = Spring.GetUnitPosition(uid)
        if x then sx, sz, n = sx + x, sz + z, n + 1 end
    end
    if n == 0 then return nil end
    return sx / n, sz / n, n
end

local function Disband()
    for uid in pairs(raiders) do
        if ARMY.RoleOf(uid) == "RAID" then ARMY.Release(uid) end
    end
    raiders, stage, target, waypoint = {}, "idle", nil, nil
end

-- Best cell to raid from (fromX, fromZ), given the group's value.  nil if nothing
-- known is weak enough to be worth it.
function M.PickTarget(frame, fromX, fromZ, groupValue, channel)
    if not EI then return nil end
    local cells = {}
    for _, t in ipairs(EI.RaidTargets(frame)) do
        local key = math.floor(t.x / M.CELL) .. "_" .. math.floor(t.z / M.CELL)
        local c = cells[key]
        if not c then c = { sx = 0, sz = 0, v = 0 }; cells[key] = c end
        c.sx, c.sz, c.v = c.sx + t.x * t.value, c.sz + t.z * t.value, c.v + t.value
    end

    local ax, az = EI.ArmyCentroid(frame)
    local best, bestScore = nil, 0
    for _, c in pairs(cells) do
        if c.v > 0 then
            local x, z = c.sx / c.v, c.sz / c.v
            local defence = EI.ThreatAt(frame, x, z, channel)
            if defence <= groupValue * M.MAX_DEFENCE then
                local far = 1
                if ax then
                    local d = math.sqrt((x - ax) ^ 2 + (z - az) ^ 2)
                    far = 0.2 + 0.8 * math.min(1, d / M.ARMY_FAR)
                end
                local trip = math.sqrt((x - fromX) ^ 2 + (z - fromZ) ^ 2)
                local score = c.v * far / (1 + defence) / (1 + trip / 4000)
                if score > bestScore then best, bestScore = { x = x, z = z, value = c.v }, score end
            end
        end
    end
    return best
end

-- Waypoint beside the target on the side away from the enemy army, pulled back
-- toward our half, so the approach does not fly over their main force.
function M.FlankPoint(tx, tz, armyX, armyZ)
    if not (MM and MM.Ready()) then return tx, tz end
    local ax, az = MM.Axis()
    local px, pz = MM.Perp()
    local side = 1
    if armyX then
        local lat = (armyX - tx) * px + (armyZ - tz) * pz
        side = lat > 0 and -1 or 1
    end
    local x = tx - ax * M.FLANK_BACK + px * side * M.FLANK_OFFSET
    local z = tz - az * M.FLANK_BACK + pz * side * M.FLANK_OFFSET
    return MM.Clamp(x, z, 300)
end

local function ClaimAll(frame, cmd, x, z)
    for uid in pairs(raiders) do
        if not ARMY.Claim(ARMY.PRIO.RAID, uid, { role = "RAID", cmd = cmd, x = x, z = z }, frame) then
            raiders[uid] = nil   -- something more important has it (a retreat)
        end
    end
end

local function TargetCleared(frame)
    if not target then return true end
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if (t.x - target.x) ^ 2 + (t.z - target.z) ^ 2 <= M.CLEAR_RADIUS ^ 2 then return false end
    end
    return true
end

local function Recruit(frame, combatUnits)
    local armyValue, count, cands = 0, 0, {}
    for uid, defID in pairs(combatUnits) do
        if Spring.GetUnitDefID(uid) then
            armyValue, count = armyValue + Value(defID), count + 1
            local role = ARMY.RoleOf(uid)
            if M.IsRaiderDef(defID) and (role == nil or role == "LINE" or role == "MUSTER") then
                cands[#cands + 1] = { uid = uid, v = Value(defID) }
            end
        end
    end
    if count < M.MIN_ARMY or #cands < M.MIN_GROUP then return nil end
    table.sort(cands, function(a, b) return a.uid < b.uid end)
    local budget, picked, v = armyValue * M.RAID_SHARE, {}, 0
    for _, c in ipairs(cands) do
        if v + c.v > budget and #picked >= M.MIN_GROUP then break end
        picked[#picked + 1] = c.uid
        v = v + c.v
    end
    if #picked < M.MIN_GROUP then return nil end
    return picked, v
end

-- One planning pass.  Returns the units recruited this pass (so the caller can drop
-- them from its muster pool), or nil.
function M.Update(frame, combatUnits)
    if not (ARMY and EI and MM and MM.Ready()) then return nil end
    for uid in pairs(raiders) do
        if not Spring.GetUnitDefID(uid) then raiders[uid] = nil end
    end

    local recruited = nil
    local cx, cz, n = Centroid()

    if stage ~= "idle" and (n or 0) <= M.DISBAND_AT then
        Spring.Echo(string.format("[RAID] %d:%02d group down to %d, disbanding",
            math.floor(frame / 1800), math.floor(frame / 30) % 60, n or 0))
        Disband()
        return nil
    end

    if stage == "idle" then
        if frame - lastPlan < M.REPLAN_EVERY then return nil end
        lastPlan = frame
        local picked, v = Recruit(frame, combatUnits)
        if not picked then return nil end
        local hx, hz = MM.Home()
        local t = M.PickTarget(frame, hx, hz, v, "air")
        if not t then return nil end
        recruited = {}
        for _, uid in ipairs(picked) do raiders[uid] = true; recruited[uid] = true end
        target, stage, stageSince = t, "gather", frame
        local ax, az = EI.ArmyCentroid(frame)
        waypoint = {}
        waypoint.x, waypoint.z = M.FlankPoint(t.x, t.z, ax, az)
        Spring.Echo(string.format("[RAID] %d:%02d %d raiders (value %.0f) -> target %d,%d worth %.0f",
            math.floor(frame / 1800), math.floor(frame / 30) % 60, #picked, v,
            t.x, t.z, t.value))
        cx, cz = Centroid()
    end

    if stage == "gather" then
        local gx, gz = MM.PointAt(M.GATHER_DIST, 0)
        gx, gz = MM.Clamp(gx, gz, 300)
        local all = true
        for uid in pairs(raiders) do
            local x, _, z = Spring.GetUnitPosition(uid)
            if x and (x - gx) ^ 2 + (z - gz) ^ 2 > M.GATHER_RADIUS ^ 2 then all = false; break end
        end
        if all or frame - stageSince >= M.GATHER_MAX then
            stage, stageSince = "approach", frame
        else
            ClaimAll(frame, CMD_MOVE, gx, gz)
            return recruited
        end
    end

    if stage == "approach" then
        if (cx and (cx - waypoint.x) ^ 2 + (cz - waypoint.z) ^ 2 <= M.ARRIVE_DIST ^ 2)
           or frame - stageSince >= M.APPROACH_MAX then
            stage, stageSince = "strike", frame
        else
            ClaimAll(frame, CMD_MOVE, waypoint.x, waypoint.z)
            return recruited
        end
    end

    if stage == "strike" then
        if TargetCleared(frame) or frame - stageSince > M.STRIKE_MAX then
            local v = 0
            for uid in pairs(raiders) do v = v + Value(Spring.GetUnitDefID(uid)) end
            local t = cx and M.PickTarget(frame, cx, cz, v, "air")
            if t then
                target, stageSince = t, frame
            else
                -- Nothing known left to hit: keep the pressure on their base, which is
                -- also where new targets will be found.
                local fx, fz = MM.Foe()
                target, stageSince = { x = fx, z = fz, value = 0 }, frame
            end
        end
        ClaimAll(frame, CMD_FIGHT, target.x, target.z)
    end
    return recruited
end

return M
