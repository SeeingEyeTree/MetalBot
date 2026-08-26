-- blueprint_placer.lua
-- Modular system for directing an air constructor to build a blueprint.
-- VFS.Include this file in any widget.
--
-- Usage:
--   local BP_PLACER = VFS.Include("LuaUI/Widgets/blueprint_placer.lua")
--   local bp        = VFS.Include("LuaUI/Widgets/blueprints/general/mex_grid_aa_corner.lua")
--
--   local state = BP_PLACER.New(bp, airConID, anchorX, anchorZ, rotation)
--   -- each frame:
--   BP_PLACER.Update(state, frame, resources)   -- resources={metal,metalStorage,energy,energyStorage}
--   -- on UnitFinished:
--   BP_PLACER.OnUnitFinished(state, unitID, unitDefID, x, z)
--   -- when enemies cleared:
--   BP_PLACER.HandleEnemyClear(state)

local M = {}

-- ── Constants (public so callers can reference them) ──────────────────────────

M.ENEMY_ALERT_RADIUS = 800    -- build LLT when enemy within this radius
M.ENEMY_CLEAR_RADIUS = 1020   -- nanos reclaim LLTs when all enemies outside this
M.GRID_SPACING       = 480    -- anchor-to-anchor between adjacent blueprints

local GRID_SPACING       = M.GRID_SPACING
local ENEMY_ALERT_RADIUS = M.ENEMY_ALERT_RADIUS
local ENEMY_CLEAR_RADIUS = M.ENEMY_CLEAR_RADIUS
local METAL_LOW_FRAC     = 0.15   -- metal interrupt threshold
local ENERGY_LOW_FRAC    = 0.15   -- energy interrupt threshold
local CORRL_UNIT         = "corrl"
local LLT_NAMES          = {"corhllt", "corlt", "armhllt", "armlt"}  -- LLT candidates
local LLT_SEARCH_RADIUS  = 200    -- world-unit radius to try placing LLT around anchor
local CMD_STOP           = 0
local CMD_RECLAIM        = 90
local TASK_MATCH_RADIUS2 = 48 * 48  -- sq-distance for UnitFinished → task matching

-- ── Classification ────────────────────────────────────────────────────────────

-- Returns "nano","metal","energy","defense","corrl","other".
-- Add new branches here to extend classification.
local function ClassifyUnit(name)
    if name == CORRL_UNIT then return "corrl" end
    local ud = UnitDefNames and UnitDefNames[name]
    if not ud then return "other" end

    if ud.extractsMetal and ud.extractsMetal > 0 then return "metal" end

    if ud.isBuilder and not ud.isFactory then return "nano" end

    local eMake  = (ud.energyMake and ud.energyMake > 0)
                or (ud.windGenerator and (
                        (type(ud.windGenerator) == "number"  and ud.windGenerator > 0) or
                        (type(ud.windGenerator) == "boolean" and ud.windGenerator)
                   ))
    local eStore = ud.energyStorage and ud.energyStorage > 0
    if eMake or eStore then return "energy" end

    -- NOTE: defense classification (buildings with weapons but not corrl) is a
    -- future extension.  They currently fall through to "other".
    -- To enable: uncomment below and add them to queue after "other".
    -- if ud.weapons and #ud.weapons > 0 then return "defense" end

    return "other"
end

-- ── Rotation ──────────────────────────────────────────────────────────────────

-- Rotate blueprint-space offset (x,z) by r = 0..3 (CW steps in Spring coords).
-- Spring: X=east, Z=south, facing 0=south.
-- R=1 (90° CW): x'=-z, z'=x
local function RotateOffset(x, z, r)
    if     r == 0 then return  x,  z
    elseif r == 1 then return -z,  x
    elseif r == 2 then return -x, -z
    elseif r == 3 then return  z, -x
    end
    return x, z
end

-- ── Blueprint helpers ─────────────────────────────────────────────────────────

-- Find the corrl entry in a blueprint layout.  Returns corrX, corrZ (offsets).
local function FindCorrl(layout)
    for _, u in ipairs(layout) do
        if u.n == CORRL_UNIT then return u.x, u.z end
    end
    return nil, nil
end

-- Resolve the def-ID for an LLT that actually exists in this game.
local lltDefIDCache = nil
local function GetLLTDefID()
    if lltDefIDCache then return lltDefIDCache end
    for _, name in ipairs(LLT_NAMES) do
        local ud = UnitDefNames and UnitDefNames[name]
        if ud then lltDefIDCache = ud.id; return lltDefIDCache end
    end
    return nil
end

-- Build a flat queue from the blueprint layout (rotated to world space).
-- Order: nano → metal → energy → other → corrl
-- Items only need a `built` flag; no `dispatched` field.
local function BuildQueue(blueprint, anchorX, anchorZ, rotation)
    local nano, metal, energy, other, corrl_items = {}, {}, {}, {}, {}
    for _, u in ipairs(blueprint.layout) do
        local rx, rz = RotateOffset(u.x, u.z, rotation)
        local rf = (u.f + rotation) % 4
        local ud = UnitDefNames and UnitDefNames[u.n]
        local defID = ud and ud.id
        local item = {
            n     = u.n,
            defID = defID,
            wx    = anchorX + rx,
            wz    = anchorZ + rz,
            f     = rf,
            cls   = ClassifyUnit(u.n),
            built = false,
        }
        if     item.cls == "corrl"  then corrl_items[#corrl_items+1] = item
        elseif item.cls == "nano"   then nano[#nano+1]   = item
        elseif item.cls == "metal"  then metal[#metal+1] = item
        elseif item.cls == "energy" then energy[#energy+1] = item
        else                             other[#other+1]  = item
        end
    end
    local queue = {}
    for _, t in ipairs(nano)        do queue[#queue+1] = t end
    for _, t in ipairs(metal)       do queue[#queue+1] = t end
    for _, t in ipairs(energy)      do queue[#queue+1] = t end
    for _, t in ipairs(other)       do queue[#queue+1] = t end
    for _, t in ipairs(corrl_items) do queue[#queue+1] = t end
    return queue
end

-- ── Interrupt table ───────────────────────────────────────────────────────────
-- Each entry: {name, priority, check(state,res,frame), buildType, isExternal?}
-- Higher priority overrides lower.  Add new entries to extend the interrupt system.

M.DEFAULT_INTERRUPTS = {
    {
        name       = "enemy",
        priority   = 3,
        buildType  = "defense",
        isExternal = true,  -- build an LLT externally, not from the blueprint queue
        check      = function(state, res, frame)
            local myAlly = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
            local units  = Spring.GetUnitsInCylinder(state.anchorX, state.anchorZ, ENEMY_ALERT_RADIUS)
            if not units then return false end
            for i = 1, #units do
                local ally = Spring.GetUnitAllyTeam and Spring.GetUnitAllyTeam(units[i])
                if ally and ally ~= myAlly then return true end
            end
            return false
        end,
    },
    {
        name      = "energy",
        priority  = 2,
        buildType = "energy",
        check     = function(state, res, frame)
            if not res.energyStorage or res.energyStorage <= 0 then return false end
            return (res.energy / res.energyStorage) < ENERGY_LOW_FRAC
        end,
    },
    {
        name      = "metal",
        priority  = 1,
        buildType = "metal",
        check     = function(state, res, frame)
            if not res.metalStorage or res.metalStorage <= 0 then return false end
            return (res.metal / res.metalStorage) < METAL_LOW_FRAC
        end,
    },
}

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function EvalInterrupts(state, res, frame)
    local best = nil
    for _, intr in ipairs(state.interrupts) do
        local ok, fires = pcall(intr.check, state, res, frame)
        if ok and fires then
            if not best or intr.priority > best.priority then
                best = intr
            end
        end
    end
    return best
end

-- Find the first unbuilt task of a given class.
local function FindNextOfClass(queue, cls)
    for _, item in ipairs(queue) do
        if item.cls == cls and not item.built then
            return item
        end
    end
    return nil
end

-- Issue a build order for a task item.
local function IssueBuildTask(airConID, item)
    if not item.defID then return false end
    local wy = Spring.GetGroundHeight(item.wx, item.wz) or 0
    Spring.GiveOrderToUnit(airConID, -item.defID, {item.wx, wy, item.wz, item.f}, {})
    return true
end

-- Find a valid world position to place an LLT near the blueprint anchor.
local function FindLLTSpot(anchorX, anchorZ)
    local defID = GetLLTDefID()
    if not defID then return nil end
    local candidates = {
        {anchorX + LLT_SEARCH_RADIUS, anchorZ},
        {anchorX - LLT_SEARCH_RADIUS, anchorZ},
        {anchorX, anchorZ + LLT_SEARCH_RADIUS},
        {anchorX, anchorZ - LLT_SEARCH_RADIUS},
        {anchorX + LLT_SEARCH_RADIUS, anchorZ + LLT_SEARCH_RADIUS},
        {anchorX - LLT_SEARCH_RADIUS, anchorZ + LLT_SEARCH_RADIUS},
        {anchorX + LLT_SEARCH_RADIUS, anchorZ - LLT_SEARCH_RADIUS},
        {anchorX - LLT_SEARCH_RADIUS, anchorZ - LLT_SEARCH_RADIUS},
    }
    for _, pos in ipairs(candidates) do
        local wy = Spring.GetGroundHeight(pos[1], pos[2]) or 0
        local ok = Spring.TestBuildOrder(defID, pos[1], wy, pos[2], 0)
        if ok and ok ~= 0 then
            return {wx=pos[1], wy=wy, wz=pos[2], f=0, defID=defID}
        end
    end
    return nil
end

-- Check if a world position (x, z) is close enough to a task to count as a match.
local function PosMatchesTask(item, x, z)
    if not x or not z then return false end
    local dx = item.wx - x
    local dz = item.wz - z
    return (dx*dx + dz*dz) <= TASK_MATCH_RADIUS2
end

-- Check if unit definition matches the LLT.
local function IsLLT(defID)
    local lltID = GetLLTDefID()
    return lltID and defID == lltID
end

local function IsNano(defID)
    local ud = defID and UnitDefs and UnitDefs[defID]
    if not ud then return false end
    return ud.isBuilder and not ud.isFactory and not ud.canFly
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Create a new placer session.
-- interrupts: optional list of interrupt definitions; defaults to M.DEFAULT_INTERRUPTS.
function M.New(blueprint, airConID, anchorX, anchorZ, rotation, interrupts)
    rotation = rotation or 0
    local queue = BuildQueue(blueprint, anchorX, anchorZ, rotation)
    return {
        blueprint       = blueprint,
        airConID        = airConID,
        anchorX         = anchorX,
        anchorZ         = anchorZ,
        rotation        = rotation,
        queue           = queue,
        currentTask     = nil,   -- item currently being built; nil when idle
        interrupts      = interrupts or M.DEFAULT_INTERRUPTS,
        activeInterrupt = nil,
        nanoUnitIDs     = {},
        lltUnitIDs      = {},
        lltPending      = false,
        done            = false,
        paused          = false,
        onComplete      = nil,
    }
end

-- Call from widget:UnitFinished.  Marks the matching task as built and tracks
-- nanos / LLTs built in this square (for the defense-reclaim system).
function M.OnUnitFinished(state, unitID, unitDefID, x, z)
    if state.done then return end

    -- Check if this unit matches the task the air con was working on.
    -- Also scan all unbuilt items in case UnitFinished arrives slightly late.
    for _, item in ipairs(state.queue) do
        if not item.built and item.defID == unitDefID then
            if PosMatchesTask(item, x, z) then
                item.built = true
                if state.currentTask == item then
                    state.currentTask = nil
                end
                break
            end
        end
    end

    -- Track nanos built inside the blueprint footprint (for future reclaim orders)
    if IsNano(unitDefID) then
        local dx = (x or 0) - state.anchorX
        local dz = (z or 0) - state.anchorZ
        if math.abs(dx) <= 240 and math.abs(dz) <= 240 then
            state.nanoUnitIDs[#state.nanoUnitIDs+1] = unitID
        end
    end

    -- Track LLTs built near this blueprint (spawned by enemy interrupt)
    if IsLLT(unitDefID) then
        local dx = (x or 0) - state.anchorX
        local dz = (z or 0) - state.anchorZ
        if math.abs(dx) <= 300 and math.abs(dz) <= 300 then
            state.lltUnitIDs[#state.lltUnitIDs+1] = unitID
        end
    end
end

-- Call every ~10 frames.
-- resources = {metal, metalStorage, energy, energyStorage}
function M.Update(state, frame, resources)
    if state.done then return end

    local airConID = state.airConID
    if not Spring.GetUnitDefID(airConID) then
        state.done = true
        return
    end

    local cmds   = Spring.GetUnitCommands(airConID, 1)
    local isBusy = cmds and #cmds > 0

    if isBusy then
        -- Air con is working.  Only interrupt for an incoming enemy threat.
        local intr = EvalInterrupts(state, resources, frame)
        if intr and intr.isExternal and state.activeInterrupt ~= intr.name then
            Spring.GiveOrderToUnit(airConID, CMD_STOP, {}, {})
            state.activeInterrupt = intr.name
            -- currentTask was cancelled; it will be retried when idle
        end
        return
    end

    -- ── Air con is now idle ───────────────────────────────────────────────────

    -- If we had a task in flight and the unit didn't appear, the build command
    -- was silently dropped.  Clear currentTask so it gets retried this frame.
    if state.currentTask and not state.currentTask.built then
        state.currentTask = nil
    elseif state.currentTask then
        state.currentTask = nil  -- built successfully; just tidy up
    end

    -- If an LLT order was outstanding but no LLT was actually built, retry.
    if state.lltPending and #state.lltUnitIDs == 0 then
        state.lltPending = false
    end

    state.paused = false

    -- Evaluate interrupts now that we know what to build next.
    local intr = EvalInterrupts(state, resources, frame)

    if intr then
        state.activeInterrupt = intr.name

        if intr.isExternal then
            -- Build one LLT if none is up yet; then hold until enemies clear.
            if #state.lltUnitIDs > 0 then
                -- LLT is already standing — stay idle until HandleEnemyClear.
                state.paused = true
            elseif not state.lltPending then
                local spot = FindLLTSpot(state.anchorX, state.anchorZ)
                if spot then
                    Spring.GiveOrderToUnit(airConID, -spot.defID, {spot.wx, spot.wy, spot.wz, spot.f}, {})
                    state.lltPending = true
                else
                    state.paused = true
                end
            else
                -- Order issued but LLT not confirmed built yet — wait one cycle.
                state.paused = true
            end
            return
        end

        -- Resource interrupt: jump to next unbuilt task of required class.
        local task = FindNextOfClass(state.queue, intr.buildType)
        if task then
            IssueBuildTask(airConID, task)
            state.currentTask = task
        else
            -- Nothing of this class left — pause until resource recovers.
            state.paused = true
        end
        return
    end

    -- No interrupt — build the next unbuilt item in default order.
    state.activeInterrupt = nil
    for _, item in ipairs(state.queue) do
        if not item.built then
            IssueBuildTask(airConID, item)
            state.currentTask = item
            return
        end
    end

    -- Everything is built.
    state.done = true
    if state.onComplete then
        pcall(state.onComplete, state)
    end
end

-- Call when no enemies are within ENEMY_CLEAR_RADIUS.
-- Orders all known nanos in this blueprint square to reclaim any LLTs that were built.
function M.HandleEnemyClear(state)
    if #state.lltUnitIDs == 0 then return end
    for _, nanoID in ipairs(state.nanoUnitIDs) do
        if Spring.GetUnitDefID(nanoID) then  -- still alive
            for _, lltID in ipairs(state.lltUnitIDs) do
                if Spring.GetUnitDefID(lltID) then
                    Spring.GiveOrderToUnit(nanoID, CMD_RECLAIM, {lltID}, {"shift"})
                end
            end
        end
    end
    -- Reset so a new enemy event can trigger a fresh LLT build.
    state.lltUnitIDs = {}
    state.lltPending = false
end

-- ── Placement finder ──────────────────────────────────────────────────────────

-- Find a valid anchor+rotation for a new blueprint adjacent to existing grids.
-- existingGrids: list of {anchorX, anchorZ}
-- Returns {anchorX, anchorZ, rotation} or nil.
function M.FindValidPlacement(blueprint, existingGrids)
    local corrX, corrZ = FindCorrl(blueprint.layout)
    if not corrX then return nil end

    -- Cardinal directions (new blueprint relative to existing)
    local DIRS = {
        { GRID_SPACING, 0},  -- new is east of existing
        {-GRID_SPACING, 0},  -- new is west
        {0,  GRID_SPACING},  -- new is south
        {0, -GRID_SPACING},  -- new is north
    }

    for _, grid in ipairs(existingGrids) do
        local gx, gz = grid.anchorX, grid.anchorZ
        for _, dir in ipairs(DIRS) do
            local newX = gx + dir[1]
            local newZ = gz + dir[2]

            for r = 0, 3 do
                local rcx, rcz = RotateOffset(corrX, corrZ, r)

                -- The corrl must be on the side of the new blueprint that faces the
                -- existing grid (opposite of the direction we stepped in).
                local ok = false
                if dir[1] > 0 and rcx < 0 then ok = true end  -- new is east, corrl faces west
                if dir[1] < 0 and rcx > 0 then ok = true end  -- new is west, corrl faces east
                if dir[2] > 0 and rcz < 0 then ok = true end  -- new is south, corrl faces north
                if dir[2] < 0 and rcz > 0 then ok = true end  -- new is north, corrl faces south

                if ok then
                    -- Validate: test the corrl build position.
                    local corrWorldX = newX + rcx
                    local corrWorldZ = newZ + rcz
                    local corrY      = Spring.GetGroundHeight(corrWorldX, corrWorldZ) or 0
                    local corrUD     = UnitDefNames and UnitDefNames[CORRL_UNIT]
                    local corrDefID  = corrUD and corrUD.id
                    local valid      = true
                    if corrDefID then
                        local res = Spring.TestBuildOrder(corrDefID, corrWorldX, corrY, corrWorldZ, (0 + r) % 4)
                        valid = res and res ~= 0
                    end
                    if valid then
                        return {anchorX = newX, anchorZ = newZ, rotation = r}
                    end
                end
            end
        end
    end
    return nil
end

return M
