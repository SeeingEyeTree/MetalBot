-- blueprint_placer.lua
-- Modular system for directing a constructor to build a blueprint.
-- VFS.Include this file in any widget.
--
-- Usage:
--   local BP_PLACER = VFS.Include("LuaUI/Widgets/blueprint_placer.lua")
--   local bp        = VFS.Include("LuaUI/Widgets/blueprints/general/mex_grid_aa_corner.lua")
--
--   local state = BP_PLACER.New(bp, builderID, anchorX, anchorZ, rotation)
--   -- each frame:
--   BP_PLACER.Update(state, frame, resources)   -- resources={metal,metalStorage,energy,energyStorage}
--   -- on UnitFinished:
--   BP_PLACER.OnUnitFinished(state, unitID, unitDefID, x, z)
--   -- when enemies cleared:
--   BP_PLACER.HandleEnemyClear(state)
--
-- Distributed mode (several builders share one ordered queue):
--   local state = BP_PLACER.NewDistributed(bp, anchorX, anchorZ, rotation)
--   BP_PLACER.AddBuilder(state, unitID)
--   -- each frame: BP_PLACER.Update(state, frame, resources)   (same call)
--   -- on UnitCreated:   BP_PLACER.OnUnitCreated(state, unitID, unitDefID, builderID)
--   -- on UnitDestroyed: BP_PLACER.OnUnitDestroyed(state, unitID)

local M = {}

local DEBUG = false  -- set true to enable verbose logging

-- ── Constants (public so callers can reference them) ──────────────────────────

M.ENEMY_ALERT_RADIUS = 800    -- build LLT when enemy within this radius
M.ENEMY_CLEAR_RADIUS = 1020   -- nanos reclaim LLTs when all enemies outside this
M.GRID_SPACING       = 480    -- anchor-to-anchor between adjacent blueprints

-- Registry of every building successfully placed by any placer state.
-- Each entry: {n=unitName, wx=worldX, wz=worldZ}
M.registry = {}

local GRID_SPACING       = M.GRID_SPACING
local ENEMY_ALERT_RADIUS = M.ENEMY_ALERT_RADIUS
local ENEMY_CLEAR_RADIUS = M.ENEMY_CLEAR_RADIUS
local METAL_LOW_FRAC     = 0.17   -- metal interrupt threshold
local ENERGY_LOW_FRAC    = 0.17   -- energy interrupt threshold
local CORRL_UNIT         = "corrl"
local LLT_NAMES          = {"corhllt", "corlt", "armhllt", "armlt"}  -- LLT candidates
local LLT_SEARCH_RADIUS  = 200    -- world-unit radius to try placing LLT around anchor
local CMD_STOP           = 0
local CMD_RECLAIM        = 90
local CMD_REPAIR         = 40
local CMD_MOVE           = 10
local TASK_MATCH_RADIUS2 = 32 * 32  -- sq-distance for UnitFinished → task matching

-- ── Distributed-mode tuning ───────────────────────────────────────────────────
local HANDOFF_PROGRESS   = 0.85  -- leave a frame at this progress if a finished nano can
                                 -- finish it.  0.30 was tried, on the theory that nanos
                                 -- hold most of the build power so a mobile builder is
                                 -- worth more placing the next frame: measurably worse
                                 -- in game.  See lessons_learned.md.
local HANDOFF_MIN_NANOS  = 3     -- until this many nanos stand, a builder finishes what
                                 -- it starts: its own build power is still a large share
                                 -- of the total, so walking away from a frame wastes it
local RECLAIM_STEP_OUT   = 144   -- elmos a builder backs off after reclaiming, so it is
                                 -- not left standing where the building used to be
local OPENING_ITEMS      = 20    -- The opening is executed literally: the first N items
                                 -- are built in blueprint order, one at a time, to
                                 -- completion.  No nearest-first reordering (builders
                                 -- end up boxing each other in) and no 85% handoff (the
                                 -- bot is metal-starved here, and a frame nobody can
                                 -- pour metal into decays and dies).
local CLAIM_LOOKAHEAD    = 5     -- items considered when the builder must travel;
                                 -- the nearest of them wins
local REACH_LOOKAHEAD    = 15    -- ...but look this much further ahead for something
                                 -- already inside build range, which costs no walk at all
local STALL_FRAMES       = 300   -- frames of zero progress before an item is up for grabs
local ORDER_GRACE_FRAMES = 30    -- unsynced orders land a frame late; don't judge before this
local ORDER_MAX_FRAMES   = 900   -- builder wedged on pathing
local MAX_RETRIES        = 3     -- dropped orders / impossible positions before skipping
local BLOCKED_DEFER      = 150   -- frames to wait out a blocked position
local LOW_RES_FRAC       = 0.15  -- below this share of storage, treat the bot as stalling:
                                 -- no 85% handoff (an unworked frame decays) and no stall
                                 -- rescue (nothing is progressing anywhere)
local PROGRESS_EPS       = 1e-3

-- ── Classification ────────────────────────────────────────────────────────────

-- Returns "nano","metal","energy","factory","defense","corrl","other".
-- Add new branches here to extend classification.
local function ClassifyUnit(name)
    if name == CORRL_UNIT then return "corrl" end
    local ud = UnitDefNames and UnitDefNames[name]
    if not ud then return "other" end

    if ud.extractsMetal and ud.extractsMetal > 0 then return "metal" end

    -- Before the builder test: a factory is a builder too.
    if ud.isFactory then return "factory" end

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
-- Preserves blueprint layout order. cls is set for interrupt lookups only.
local function BuildQueue(blueprint, anchorX, anchorZ, rotation)
    local queue = {}
    for _, u in ipairs(blueprint.layout) do
        local rx, rz = RotateOffset(u.x, u.z, rotation)
        local rf = (u.f + rotation) % 4
        local ud = UnitDefNames and UnitDefNames[u.n]
        local defID = ud and ud.id
        queue[#queue+1] = {
            n       = u.n,
            defID   = defID,
            wx      = anchorX + rx,
            wz      = anchorZ + rz,
            f       = rf,
            cls     = ClassifyUnit(u.n),
            act     = u.a or "build",   -- "build" | "reclaim"
            idx     = #queue + 1,
            status  = "pending",        -- distributed mode only; single-builder ignores it
            built   = false,
            retries = 0,
        }
    end
    return queue
end

-- ── Interrupt table ───────────────────────────────────────────────────────────
-- Each entry: {name, priority, check(state,res,frame), buildType, isExternal?}
-- Higher priority overrides lower.  Add new entries to extend the interrupt system.

local M_DEFAULT_ENERGY_INTERRUPT, M_DEFAULT_METAL_INTERRUPT

M.DEFAULT_INTERRUPTS = {
    -- TODO: re-enable enemy interrupt once placement & reclaim logic is stable
    -- {
    --     name       = "enemy",
    --     priority   = 3,
    --     buildType  = "defense",
    --     isExternal = true,
    --     check      = function(state, res, frame)
    --         local myAlly = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    --         local units  = Spring.GetUnitsInCylinder(state.anchorX, state.anchorZ, ENEMY_ALERT_RADIUS)
    --         if not units then return false end
    --         for i = 1, #units do
    --             local ally = Spring.GetUnitAllyTeam and Spring.GetUnitAllyTeam(units[i])
    --             if ally and ally ~= myAlly then return true end
    --         end
    --         return false
    --     end,
    -- },
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
M_DEFAULT_ENERGY_INTERRUPT = M.DEFAULT_INTERRUPTS[1]
M_DEFAULT_METAL_INTERRUPT  = M.DEFAULT_INTERRUPTS[2]

-- Interrupts for mex-grid blueprints, where the layout order does not matter much:
-- build what the economy is short of.  Nanos and mexes come from the blueprint order;
-- these only redirect when a resource actually runs dry.  There is deliberately no
-- "metal is piling up, start the factory" interrupt: it fired at the wrong moments
-- and started a T2 lab when the real problem was elsewhere.  The grid's factory is
-- held to last by deferFactories instead.
M.GRID_INTERRUPTS = {
    M_DEFAULT_ENERGY_INTERRUPT,
    M_DEFAULT_METAL_INTERRUPT,
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
        if item.cls == cls and not item.built and not item.released then
            return item
        end
    end
    return nil
end

-- Can this item be placed at all?  TestBuildOrder: 0 = impossible, 1 = a mobile unit
-- is in the way (it will move), 2 = free.  Only 0 counts against the item.
local function SpotIsBlocked(item)
    if not item.defID then return false end
    local wy  = Spring.GetGroundHeight(item.wx, item.wz) or 0
    local res = Spring.TestBuildOrder(item.defID, item.wx, wy, item.wz, item.f)
    return res == 0
end

-- Issue a build order for a task item.
local function IssueBuildTask(builderID, item)
    if not item.defID then return false end
    local wy = Spring.GetGroundHeight(item.wx, item.wz) or 0
    Spring.GiveOrderToUnit(builderID, -item.defID, {item.wx, wy, item.wz, item.f}, {})
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

-- A nano TURRET: an immobile builder.  The speed test matters — without it this
-- also matches the commander and every con bot, which would make CountNanosInRange
-- count the builder standing on its own nanoframe.
local function IsNano(defID)
    local ud = defID and UnitDefs and UnitDefs[defID]
    if not ud then return false end
    if not (ud.isBuilder and not ud.isFactory and not ud.canFly) then return false end
    return ud.speed == nil or ud.speed == 0
end

-- Finished friendly nano turrets (from any grid, not just this one) that can
-- physically reach world position (wx, wz).  Searches within 500 units so
-- nanos from adjacent completed grids are included.  Returns a list of unitIDs.
local NANO_RANGE_FALLBACK = 380   -- only if a unitdef has no buildDistance

local function NanosInRange(wx, wz, excludeUnitID)
    local out    = {}
    local myAlly = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    if not myAlly then return out end
    -- Wide enough that no nano whose own build range reaches (wx,wz) is missed.
    local units = Spring.GetUnitsInCylinder(wx, wz, 700)
    if not units then return out end
    for _, uid in ipairs(units) do
        if uid ~= excludeUnitID and Spring.GetUnitAllyTeam(uid) == myAlly then
            local defID = Spring.GetUnitDefID(uid)
            -- A half-built nano has the same defID as a finished one but no build power.
            if IsNano(defID) and not Spring.GetUnitIsBeingBuilt(uid) then
                local ud = UnitDefs[defID]
                -- buildDistance IS the in-game build range (cornanotc: 400).
                local reach = (ud and ud.buildDistance) or NANO_RANGE_FALLBACK
                local ux, _, uz = Spring.GetUnitPosition(uid)
                if ux then
                    local dx, dz = ux - wx, uz - wz
                    if dx*dx + dz*dz <= reach * reach then
                        out[#out + 1] = uid
                    end
                end
            end
        end
    end
    return out
end
M.NanosInRange = NanosInRange

local function CountNanosInRange(wx, wz, excludeUnitID)
    return #NanosInRange(wx, wz, excludeUnitID)
end
M.CountNanosInRange = CountNanosInRange

-- Pick and issue the builder's next order (interrupt-aware). Shared by the
-- polled Update() and by OnUnitFinished() so a completed building is
-- followed up immediately instead of waiting for the next ~10-frame poll.
-- Build progress of a nanoframe.  Returns nil when the unit no longer exists.
local function GetProgress(unitID)
    if not unitID or not Spring.GetUnitDefID(unitID) then return nil end
    if Spring.GetUnitIsBeingBuilt then
        local beingBuilt, prog = Spring.GetUnitIsBeingBuilt(unitID)
        if beingBuilt ~= nil then
            return prog or (beingBuilt and 0 or 1)
        end
    end
    local _, _, _, _, prog = Spring.GetUnitHealth(unitID)
    return prog
end

-- The nanoframe standing at an item's position, if any.  The single-builder path
-- has no UnitCreated hook, so it finds its own frame by looking at the spot.
local function FindFrameAt(item)
    if item.frameID and GetProgress(item.frameID) then return item.frameID end
    local units = Spring.GetUnitsInCylinder(item.wx, item.wz, 48)
    if not units then return nil end
    for _, uid in ipairs(units) do
        if Spring.GetUnitDefID(uid) == item.defID and Spring.GetUnitIsBeingBuilt(uid) then
            item.frameID = uid
            return uid
        end
    end
    return nil
end

local function AdvanceQueue(state, res, frame)
    local builderID = state.builderID
    if not Spring.GetUnitDefID(builderID) then
        state.done = true
        return
    end

    state.paused = false
    local intr = EvalInterrupts(state, res, frame)

    if intr then
        state.activeInterrupt = intr.name

        if intr.isExternal then
            if #state.lltUnitIDs > 0 then
                state.paused = true
            elseif not state.lltPending then
                local spot = FindLLTSpot(state.anchorX, state.anchorZ)
                if spot then
                    Spring.GiveOrderToUnit(builderID, -spot.defID, {spot.wx, spot.wy, spot.wz, spot.f}, {})
                    state.lltPending = true
                else
                    state.paused = true
                end
            else
                state.paused = true
            end
            return
        end

        local task = FindNextOfClass(state.queue, intr.buildType)
        if task and CountNanosInRange(task.wx, task.wz) >= 2 then
            IssueBuildTask(builderID, task)
            state.currentTask = task
            return
        end
    end

    state.activeInterrupt = nil
    -- Normal order.  With deferFactories the grid's factory is skipped until it is
    -- all that is left (the "float" interrupt above is what starts it early).
    local deferred, released = nil, nil
    for _, item in ipairs(state.queue) do
        if not item.built and item.act ~= "reclaim" then
            if item.released then
                -- Handed to the nanos at handoffProgress.  If the frame is gone
                -- (decayed or killed) it is ours again; otherwise remember it in
                -- case we run out of new work.
                if FindFrameAt(item) then
                    released = released or item
                else
                    item.released = false
                    item.frameID  = nil
                    IssueBuildTask(builderID, item)
                    state.currentTask = item
                    return
                end
            elseif state.deferFactories and item.cls == "factory" then
                deferred = deferred or item
            elseif SpotIsBlocked(item) then
                -- Permanently occupied (this grid overlaps something already built).
                -- Give up on it after a few looks rather than flying back forever.
                item.testFails = (item.testFails or 0) + 1
                if item.testFails >= 3 then
                    item.built = true
                    item.status = "skipped"
                    if DEBUG then
                        Spring.Echo(string.format("[BP] grid skip %s at (%.0f, %.0f) - blocked",
                            tostring(item.n), item.wx, item.wz))
                    end
                end
            else
                IssueBuildTask(builderID, item)
                state.currentTask = item
                return
            end
        end
    end
    if deferred then
        IssueBuildTask(builderID, deferred)
        state.currentTask = deferred
        return
    end
    -- Nothing new to place: help finish what was handed over.
    if released then
        Spring.GiveOrderToUnit(builderID, CMD_REPAIR, {released.frameID}, {})
        state.currentTask = released
        return
    end

    state.done = true
    if state.onComplete then
        pcall(state.onComplete, state)
    end
end

-- Mark a queue item complete.  Shared by both modes.  Returns true when the
-- item was the single-builder currentTask, which is the caller's cue to issue
-- the builder's next order immediately.
local function MarkItemBuilt(state, item, unitID)
    if item.status == "built" then return false end
    item.built  = true
    item.status = "built"
    if unitID then item.frameID = unitID end
    if state.claimOf and item.claimedBy then
        state.claimOf[item.claimedBy] = nil
        item.claimedBy = nil
    end
    M.registry[#M.registry + 1] = {n = item.n, wx = item.wx, wz = item.wz}
    local wasCurrent = false
    if state.currentTask == item then
        state.currentTask = nil
        wasCurrent = true
    end
    state.builtCount = state.builtCount + 1
    if not state.mostlyDone and state.onMostlyDone then
        if state.builtCount >= math.floor(#state.queue * 0.7) then
            state.mostlyDone = true
            pcall(state.onMostlyDone, state)
        end
    end
    return wasCurrent
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Create a new placer session.
-- interrupts: optional list of interrupt definitions; defaults to M.DEFAULT_INTERRUPTS.
--
-- Options the caller may set on the returned state:
--   handoffProgress  0..1, off by default.  Leave a frame at this build progress
--                    and move to the next site, provided a finished nano turret is
--                    in range to complete it and the bot is not resource-starved.
--   deferFactories   true: build factory entries last, unless an interrupt asks
--                    for one earlier.
function M.New(blueprint, builderID, anchorX, anchorZ, rotation, interrupts)
    rotation = rotation or 0
    local queue = BuildQueue(blueprint, anchorX, anchorZ, rotation)
    local totalNanos = 0
    for _, u in ipairs(blueprint.layout) do
        if ClassifyUnit(u.n) == "nano" then totalNanos = totalNanos + 1 end
    end
    return {
        blueprint          = blueprint,
        builderID          = builderID,
        anchorX            = anchorX,
        anchorZ            = anchorZ,
        rotation           = rotation,
        queue              = queue,
        currentTask        = nil,
        interrupts         = interrupts or M.DEFAULT_INTERRUPTS,
        activeInterrupt    = nil,
        nanoUnitIDs        = {},
        lltUnitIDs         = {},
        lltPending         = false,
        done               = false,
        paused             = false,
        onComplete         = nil,
        totalNanos         = totalNanos,
        nanoThresholdFired = false,
        onNanoThreshold    = nil,   -- fires when ≥7/12 of nanos are built
        builtCount         = 0,     -- running count of queue items marked built
        mostlyDone         = false, -- true once builtCount/total >= 0.7
        onMostlyDone       = nil,   -- fires once when mostlyDone flips
        -- Cached from the last Update() poll so OnUnitFinished can issue the
        -- next order immediately without waiting for the next poll tick.
        lastResources      = {metal=0, metalStorage=0, energy=0, energyStorage=0},
        lastFrame          = 0,
    }
end

-- Call from widget:UnitFinished.  Marks the matching task as built and tracks
-- nanos / LLTs built in this square (for the defense-reclaim system).
function M.OnUnitFinished(state, unitID, unitDefID, x, z)
    if state.done then return end

    local finishedCurrentTask = false

    -- Distributed fast path: the nanoframe's unitID already identifies the item.
    local known = state.itemByFrame and state.itemByFrame[unitID]
    if known then
        MarkItemBuilt(state, known, unitID)
        state.itemByFrame[unitID] = nil
    else
        -- Check if this unit matches the task the air con was working on.
        -- Also scan all unbuilt items in case UnitFinished arrives slightly late.
        for _, item in ipairs(state.queue) do
            if not item.built and item.defID == unitDefID and item.act ~= "reclaim" then
                if PosMatchesTask(item, x, z) then
                    finishedCurrentTask = MarkItemBuilt(state, item, unitID)
                    break
                end
            end
        end
    end

    -- Track nanos built inside the blueprint footprint (for future reclaim orders)
    if IsNano(unitDefID) then
        local dx = (x or 0) - state.anchorX
        local dz = (z or 0) - state.anchorZ
        if math.abs(dx) <= 240 and math.abs(dz) <= 240 then
            state.nanoUnitIDs[#state.nanoUnitIDs+1] = unitID
            if not state.nanoThresholdFired and state.onNanoThreshold and state.totalNanos > 0 then
                local thresh = math.ceil(state.totalNanos * 7 / 12)
                if #state.nanoUnitIDs >= thresh then
                    state.nanoThresholdFired = true
                    pcall(state.onNanoThreshold, state)
                end
            end
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

    -- Builder just went idle — issue its next order now rather than waiting
    -- for the next ~10-frame Update() poll (that gap was a visible stall).
    if finishedCurrentTask and not state.distributed then
        AdvanceQueue(state, state.lastResources, state.lastFrame)
    end
end

-- Call every ~10 frames.
-- resources = {metal, metalStorage, energy, energyStorage}
function M.Update(state, frame, resources)
    if state.done then return end
    if state.distributed then return M.UpdateDistributed(state, frame, resources) end

    local builderID = state.builderID
    if not Spring.GetUnitDefID(builderID) then
        state.done = true
        return
    end

    state.lastResources = resources
    state.lastFrame      = frame

    local cmds   = Spring.GetUnitCommands(builderID, 1)
    local isBusy = cmds and #cmds > 0

    if isBusy then
        local intr = EvalInterrupts(state, resources, frame)
        if not intr then
            -- Episode over; a later one is allowed to preempt again.
            state.activeInterrupt = nil
        elseif intr.isExternal and state.activeInterrupt ~= intr.name then
            Spring.GiveOrderToUnit(builderID, CMD_STOP, {}, {})
            state.activeInterrupt = intr.name
            -- currentTask was cancelled; it will be retried when idle
            return
        elseif state.activeInterrupt ~= intr.name then
            -- A resource interrupt fired while the builder is mid-job.  Waiting for
            -- it to go idle can take a whole fly-out-and-build cycle, by which time
            -- the stall it was meant to answer is long over — so switch now.  Once
            -- per episode: activeInterrupt keeps it from re-targeting every tick.
            local task = FindNextOfClass(state.queue, intr.buildType)
            if task and CountNanosInRange(task.wx, task.wz) >= 2 then
                local cur = state.currentTask
                if cur and not cur.built and not cur.released then
                    -- Don't strand a part-built frame: hand it to the nanos if any
                    -- can reach it, otherwise leave it to be reclaimed as a task
                    -- later (AdvanceQueue revives items whose frame has gone).
                    local frameID = FindFrameAt(cur)
                    if frameID then
                        local nanos = NanosInRange(cur.wx, cur.wz, builderID)
                        for i = 1, #nanos do
                            Spring.GiveOrderToUnit(nanos[i], CMD_REPAIR, {frameID}, {"shift"})
                        end
                        cur.released = true
                    end
                end
                IssueBuildTask(builderID, task)
                state.currentTask     = task
                state.activeInterrupt = intr.name
                if DEBUG then
                    Spring.Echo(string.format("[BP] interrupt '%s' preempts builder %d -> %s",
                        intr.name, builderID, tostring(task.n)))
                end
                return
            end
        end

        -- Hand-over: with one builder per grid, the walk between sites is the
        -- bottleneck, so leave a frame once it is far enough along for the nanos
        -- to finish and go place the next one.  Opt-in per state via
        -- state.handoffProgress; nothing happens unless it is set.
        local task = state.currentTask
        if state.handoffProgress and task and not task.built and not task.released
           and #state.nanoUnitIDs >= HANDOFF_MIN_NANOS then
            local starved =
                   (resources.metalStorage  and resources.metalStorage  > 0
                    and (resources.metal  / resources.metalStorage)  < LOW_RES_FRAC)
                or (resources.energyStorage and resources.energyStorage > 0
                    and (resources.energy / resources.energyStorage) < LOW_RES_FRAC)
            local frameID = (not starved) and FindFrameAt(task) or nil
            local prog    = frameID and GetProgress(frameID)
            if prog and prog >= state.handoffProgress then
                local nanos = NanosInRange(task.wx, task.wz, builderID)
                if #nanos > 0 then
                    for i = 1, #nanos do
                        Spring.GiveOrderToUnit(nanos[i], CMD_REPAIR, {frameID}, {"shift"})
                    end
                    task.released     = true
                    state.currentTask = nil
                    AdvanceQueue(state, resources, frame)   -- straight to the next site
                end
            end
        end
        return
    end

    -- ── Air con is now idle ───────────────────────────────────────────────────

    -- If we had a task in flight and the unit didn't appear, the build command
    -- was silently dropped.  Clear currentTask so it gets retried this frame.
    if state.currentTask and not state.currentTask.built then
        local t = state.currentTask
        t.retries = t.retries + 1
        if DEBUG and t.retries >= 1 then
            Spring.Echo(string.format("[BP] STUCK builder=%d %s at (%.0f, %.0f) retry#%d",
                builderID, t.n or "?", t.wx, t.wz, t.retries))
            local nearby = {}
            local r2 = 320 * 320
            for _, b in ipairs(M.registry) do
                local dx = b.wx - t.wx
                local dz = b.wz - t.wz
                local d2 = dx * dx + dz * dz
                if d2 <= r2 then
                    nearby[#nearby + 1] = {n = b.n, wx = b.wx, wz = b.wz, d = math.floor(math.sqrt(d2) + 0.5)}
                end
            end
            table.sort(nearby, function(a, b) return a.d < b.d end)
            if #nearby > 0 then
                Spring.Echo("[BP]   nearby registry (within 320):")
                for _, b in ipairs(nearby) do
                    Spring.Echo(string.format("[BP]     %s at (%.0f, %.0f)  dist=%d", b.n, b.wx, b.wz, b.d))
                end
            else
                Spring.Echo("[BP]   no registry entries within 320 units")
            end
        end
        state.currentTask = nil
    elseif state.currentTask then
        state.currentTask = nil  -- built successfully; just tidy up
    end

    -- If an LLT order was outstanding but no LLT was actually built, retry.
    if state.lltPending and #state.lltUnitIDs == 0 then
        state.lltPending = false
    end

    AdvanceQueue(state, resources, frame)
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

-- Find ALL valid anchors+rotations adjacent to existing grids.
-- Returns a list of {anchorX, anchorZ, rotation}; deduplicates by position.
-- The first nano in build order: the one whose speed of completion decides how fast
-- a new grid gets its own build power.
local function FirstNanoOffset(layout)
    for _, u in ipairs(layout) do
        if u.a ~= "reclaim" and ClassifyUnit(u.n) == "nano" then return u.x, u.z end
    end
    return nil, nil
end

-- Which rotation puts that first nano where nanos we already own can reach it?  That
-- is what the old corrl marker was really for: start each grid on the side facing the
-- base, so its first nano goes up fast instead of being built by one con alone.
local function BestRotation(blueprint, anchorX, anchorZ, fromX, fromZ)
    local nx, nz = FirstNanoOffset(blueprint.layout)
    if not nx then return 0 end
    local bestR, bestScore = 0, -math.huge
    for r = 0, 3 do
        local rx, rz = RotateOffset(nx, nz, r)
        local wx, wz = anchorX + rx, anchorZ + rz
        -- Reachable existing nanos first; ties go to whichever sits nearest the
        -- grid we grew out of.
        local dx, dz = wx - fromX, wz - fromZ
        local score = #NanosInRange(wx, wz) * 1e6 - math.sqrt(dx * dx + dz * dz)
        if score > bestScore then bestScore, bestR = score, r end
    end
    return bestR
end

M.BestRotation = function(blueprint, anchorX, anchorZ, fromX, fromZ)
    return BestRotation(blueprint, anchorX, anchorZ, fromX, fromZ)
end

-- Probe a candidate anchor by test-building the blueprint's first real entry there.
local function ProbeAnchor(blueprint, anchorX, anchorZ, rotation)
    for _, u in ipairs(blueprint.layout) do
        if u.a ~= "reclaim" then
            local ud = UnitDefNames and UnitDefNames[u.n]
            if ud then
                local rx, rz = RotateOffset(u.x, u.z, rotation or 0)
                local wx, wz = anchorX + rx, anchorZ + rz
                local wy  = Spring.GetGroundHeight(wx, wz) or 0
                local res = Spring.TestBuildOrder(ud.id, wx, wy, wz,
                                                  ((u.f or 0) + (rotation or 0)) % 4)
                return res and res ~= 0
            end
        end
    end
    return true
end

function M.FindAllValidPlacements(blueprint, existingGrids)
    local corrX, corrZ = FindCorrl(blueprint.layout)

    -- No corrl marker: the blueprint has no side that must face the existing base,
    -- so every free neighbouring cell is a candidate at rotation 0.
    if not corrX then
        local DIRS = {
            { GRID_SPACING, 0}, {-GRID_SPACING, 0},
            {0,  GRID_SPACING}, {0, -GRID_SPACING},
        }
        local results, seen = {}, {}
        for _, grid in ipairs(existingGrids) do
            for _, dir in ipairs(DIRS) do
                local nx, nz = grid.anchorX + dir[1], grid.anchorZ + dir[2]
                local key = tostring(nx) .. "," .. tostring(nz)
                if not seen[key] then
                    seen[key] = true
                    local rot = BestRotation(blueprint, nx, nz, grid.anchorX, grid.anchorZ)
                    if ProbeAnchor(blueprint, nx, nz, rot) then
                        results[#results + 1] = {anchorX = nx, anchorZ = nz, rotation = rot}
                    end
                end
            end
        end
        return results
    end

    local DIRS = {
        { GRID_SPACING, 0},
        {-GRID_SPACING, 0},
        {0,  GRID_SPACING},
        {0, -GRID_SPACING},
    }

    local results = {}
    local seen    = {}

    for _, grid in ipairs(existingGrids) do
        local gx, gz = grid.anchorX, grid.anchorZ
        for _, dir in ipairs(DIRS) do
            local newX = gx + dir[1]
            local newZ = gz + dir[2]
            local key  = tostring(newX) .. "," .. tostring(newZ)
            if not seen[key] then
                for r = 0, 3 do
                    local rcx, rcz = RotateOffset(corrX, corrZ, r)
                    local ok = false
                    if dir[1] > 0 and rcx < 0 then ok = true end
                    if dir[1] < 0 and rcx > 0 then ok = true end
                    if dir[2] > 0 and rcz < 0 then ok = true end
                    if dir[2] < 0 and rcz > 0 then ok = true end
                    if ok then
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
                            seen[key] = true
                            results[#results + 1] = {anchorX = newX, anchorZ = newZ, rotation = r}
                            break  -- correct rotation found for this position; move on
                        end
                    end
                end
            end
        end
    end
    return results
end

-- ══ Distributed mode ══════════════════════════════════════════════════════════
--
-- Several builders share one ordered queue.  Every idle builder claims the
-- LOWEST-INDEX item it is itself able to build, so the commander (which cannot
-- build nano turrets) runs ahead to n+1/n+2 while a con bot picks the skipped
-- nano up afterwards — it is then the lowest claimable index.  A builder leaves
-- a frame at HANDOFF_PROGRESS as soon as a finished nano turret can complete it,
-- and immediately places the next one, so there is always a fresh nanoframe
-- standing for the nanos to pour build power into.

-- Which defIDs a builder def can actually place.
local canBuildCache = {}
local function CanBuild(builderDefID, defID)
    if not builderDefID or not defID then return false end
    local set = canBuildCache[builderDefID]
    if not set then
        set = {}
        local ud = UnitDefs[builderDefID]
        if ud and ud.buildOptions then
            for _, optID in ipairs(ud.buildOptions) do set[optID] = true end
        end
        canBuildCache[builderDefID] = set
    end
    return set[defID] == true
end
M.CanBuild = CanBuild

-- Half-extent of a unit's footprint in elmos.  UnitDef.xsize counts 8-elmo
-- half-cells, so a 3x3 building (48 elmos) has xsize 6.
local function HalfExtents(defID)
    local ud = defID and UnitDefs and UnitDefs[defID]
    if not ud then return 0, 0 end
    return ((ud.xsize or 0) * 8) / 2, ((ud.zsize or ud.ysize or 0) * 8) / 2
end

-- Can this builder place that item from exactly where it stands?  Range is measured
-- to the building's edge, so a bigger footprint reaches further: a commander
-- (buildDistance 128) covers a wind centred ~152 elmos away.
local function InBuildRange(builderDefID, bx, bz, item)
    local ud = builderDefID and UnitDefs and UnitDefs[builderDefID]
    local reach = ((ud and ud.buildDistance) or 128)
                + math.max(HalfExtents(item.defID))
    local dx, dz = item.wx - bx, item.wz - bz
    return (dx * dx + dz * dz) <= reach * reach
end

-- The live unit another entry already put at this position: used by "reclaim"
-- entries, and by a build entry resuming a frame left standing at that spot.
local function FindReclaimTarget(state, item)
    for i = 1, #state.queue do
        local other = state.queue[i]
        if other ~= item and other.defID == item.defID and other.frameID then
            local dx, dz = other.wx - item.wx, other.wz - item.wz
            if dx*dx + dz*dz <= TASK_MATCH_RADIUS2 and Spring.GetUnitDefID(other.frameID) then
                return other.frameID
            end
        end
    end
    return nil
end

local function DropClaim(state, item, newStatus)
    if item.claimedBy then
        state.claimOf[item.claimedBy] = nil
        item.claimedBy = nil
    end
    if newStatus then item.status = newStatus end
end

-- An unclaimed frame that has not progressed in a long while.  A global resource
-- stall is NOT a stuck frame — during one, nothing in the base progresses.
local function ItemIsStalled(state, item, frame, res)
    if item.claimedBy then return false end
    if item.status ~= "started" and item.status ~= "released" then return false end
    if not item.lastProgressFrame then return false end
    if (frame - item.lastProgressFrame) < STALL_FRAMES then return false end
    if res then
        if res.metalStorage and res.metalStorage > 0
           and (res.metal / res.metalStorage) < LOW_RES_FRAC then return false end
        if res.energyStorage and res.energyStorage > 0
           and (res.energy / res.energyStorage) < LOW_RES_FRAC then return false end
    end
    return true
end

-- The build order is a time sequence, not a route: consecutive items can sit on
-- opposite sides of the base, and the walk between them is dead time.  Priority:
--   1. anything already inside build range — placed without the builder moving;
--   2. otherwise the nearest of the next CLAIM_LOOKAHEAD items.
local function FindClaimable(state, builderID, frame, res)
    local bDefID = Spring.GetUnitDefID(builderID)
    if not bDefID then return nil end
    local bx, _, bz = Spring.GetUnitPosition(builderID)

    local best, bestD2, seen = nil, nil, 0
    for i = 1, #state.queue do
        local item = state.queue[i]
        local blocked = item.waitsFor ~= nil and item.waitsFor.status ~= "built"
        if not blocked and not item.claimedBy
           and item.status ~= "built" and item.status ~= "skipped" then
            local ready = (item.status == "pending"
                           and (not item.deferUntil or frame >= item.deferUntil))
                          or ItemIsStalled(state, item, frame, res)
            -- Reclaims need no buildOptions entry; assisting/reclaiming is not gated by it.
            if ready and (item.act == "reclaim" or CanBuild(bDefID, item.defID)) then
                if not bx then return item end   -- no position: keep strict order
                -- The opening runs in blueprint order, full stop.  Reordering it by
                -- distance puts builders on each other's sites and boxes them in.
                if (item.idx or 0) <= OPENING_ITEMS then return item end
                if InBuildRange(bDefID, bx, bz, item) then return item end
                if seen < CLAIM_LOOKAHEAD then
                    local dx, dz = item.wx - bx, item.wz - bz
                    local d2 = dx * dx + dz * dz
                    if not best or d2 < bestD2 then best, bestD2 = item, d2 end
                end
                seen = seen + 1
                if seen >= REACH_LOOKAHEAD then break end
            end
        end
    end
    return best
end

local function SkipItem(state, item)
    -- A standing nanoframe is metal already spent; abandoning it to decay is
    -- strictly worse than letting the nanos (or stall rescue) finish it.
    if item.frameID and Spring.GetUnitDefID(item.frameID) then
        DropClaim(state, item, "released")
        return
    end
    DropClaim(state, item, "skipped")
    state.skippedCount = (state.skippedCount or 0) + 1
    if DEBUG then
        Spring.Echo(string.format("[BP] SKIP %s #%d at (%.0f, %.0f)",
            tostring(item.n), item.idx or 0, item.wx, item.wz))
    end
end

local function IssueDistTask(state, builderID, item, frame)
    item.claimedBy           = builderID
    state.claimOf[builderID] = item
    item.orderFrame          = frame

    -- Reclaim step: put the builder AND every nano in range on it, so the refund
    -- lands at roughly the build power the sim assumed.
    if item.act == "reclaim" then
        local target = FindReclaimTarget(state, item)
        if not target then
            MarkItemBuilt(state, item)   -- nothing standing there; nothing to do
            return
        end
        item.targetID = target
        Spring.GiveOrderToUnit(builderID, CMD_RECLAIM, {target}, {})
        -- Then walk clear.  Whatever is reclaimed leaves a hole that later items
        -- build over, and a builder standing in it ends up walled in.  Step outward,
        -- away from the middle of the blueprint, where there is more open ground.
        local dx, dz = item.wx - state.anchorX, item.wz - state.anchorZ
        local len = math.sqrt(dx * dx + dz * dz)
        if len < 1 then dx, dz, len = 1, 0, 1 end
        local ox = item.wx + (dx / len) * RECLAIM_STEP_OUT
        local oz = item.wz + (dz / len) * RECLAIM_STEP_OUT
        Spring.GiveOrderToUnit(builderID, CMD_MOVE,
            {ox, Spring.GetGroundHeight(ox, oz) or 0, oz}, {"shift"})
        local nanos = NanosInRange(item.wx, item.wz, builderID)
        for i = 1, #nanos do
            Spring.GiveOrderToUnit(nanos[i], CMD_RECLAIM, {target}, {})
        end
        item.status = "started"
        return
    end

    -- Resume an existing frame rather than re-placing it: our own after a stall
    -- rescue, or an orphan left standing at this position.
    if not item.frameID then
        local existing = FindReclaimTarget(state, item)
        if existing and Spring.GetUnitIsBeingBuilt(existing) then
            item.frameID = existing
            item.lastProgress      = 0
            item.lastProgressFrame = frame
        end
    end
    if item.frameID and Spring.GetUnitDefID(item.frameID) then
        state.itemByFrame[item.frameID] = item
        Spring.GiveOrderToUnit(builderID, CMD_REPAIR, {item.frameID}, {})
        item.status = "started"
        return
    end

    -- TestBuildOrder: 0 = impossible, 1 = a mobile unit is in the way (it will
    -- move; issuing the order is what makes it move), 2 = free.
    local wy = Spring.GetGroundHeight(item.wx, item.wz) or 0
    local ok = Spring.TestBuildOrder(item.defID, item.wx, wy, item.wz, item.f)
    if ok == 0 then
        item.testFails = (item.testFails or 0) + 1
        if item.testFails >= MAX_RETRIES then
            SkipItem(state, item)
        else
            DropClaim(state, item, "pending")
            item.deferUntil = frame + BLOCKED_DEFER
        end
        return
    end

    IssueBuildTask(builderID, item)
    item.status = "claimed"
    if DEBUG then
        local bx, _, bz = Spring.GetUnitPosition(builderID)
        if bx then
            Spring.Echo(string.format("[BP] claim item#%d %s dist=%d",
                item.idx or 0, tostring(item.n),
                math.floor(math.sqrt((item.wx-bx)^2 + (item.wz-bz)^2))))
        end
    end
end

-- Returns true while the builder is still usefully occupied with its claim.
local function ServiceBuilder(state, builderID, frame, res)
    local item = state.claimOf[builderID]
    if not item then return false end

    if item.act == "reclaim" then
        if not item.targetID or not Spring.GetUnitDefID(item.targetID) then
            MarkItemBuilt(state, item)   -- target gone: the reclaim is done
            return false
        end
        return true
    end

    if item.status == "claimed" then
        -- No nanoframe yet: the builder is either still walking there, or the
        -- order was silently dropped.  Unsynced orders land a frame late, so
        -- nothing is judged before ORDER_GRACE_FRAMES.
        if (frame - (item.orderFrame or frame)) >= ORDER_GRACE_FRAMES then
            -- The engine pushes a MOVE command in front of the build order while
            -- the builder walks to the site, so the build order is not always
            -- cmds[1]; checking only the first command reads as "order dropped".
            local cmds   = Spring.GetUnitCommands(builderID, 4)
            local onTask = false
            if cmds then
                for ci = 1, #cmds do
                    if cmds[ci].id == -item.defID then onTask = true; break end
                end
            end
            if (frame - (item.orderFrame or frame)) > ORDER_MAX_FRAMES then
                -- Never arrived: most likely walled in by its own buildings.  The
                -- item is fine, so release it for another builder rather than
                -- burning one of its retries.
                if DEBUG then
                    Spring.Echo(string.format("[BP] builder %d cannot reach item#%d %s",
                        builderID, item.idx or 0, tostring(item.n)))
                end
                DropClaim(state, item, "pending")
                return false
            end
            if not onTask then
                -- The nanoframe is already standing: the order clearly landed.
                if item.frameID and Spring.GetUnitDefID(item.frameID) then
                    item.status               = "started"
                    item.lastProgress         = 0
                    item.lastProgressFrame    = frame
                    state.itemByFrame[item.frameID] = item
                    return true
                end
                if DEBUG then
                    Spring.Echo(string.format(
                        "[BP] retry item#%d %s builder=%d cmd=%s want=%d age=%d frameID=%s",
                        item.idx or 0, tostring(item.n), builderID,
                        tostring(cmds and cmds[1] and cmds[1].id or "none"), -item.defID,
                        frame - (item.orderFrame or frame), tostring(item.frameID)))
                end
                item.retries = (item.retries or 0) + 1
                if item.retries >= MAX_RETRIES then
                    SkipItem(state, item)
                else
                    DropClaim(state, item, "pending")
                end
                return false
            end
        end
        return true
    end

    if item.status == "started" then
        local prog = GetProgress(item.frameID)
        if prog == nil then
            item.frameID = nil                  -- frame died under construction
            DropClaim(state, item, "pending")
            return false
        end
        -- Handing a frame over only works if someone can actually finish it.
        -- While stalling, no build power is applied to ANY frame, assigned nanos
        -- included, and an unworked frame decays away.
        local starved = res ~= nil
            and ((res.metalStorage  and res.metalStorage  > 0
                  and (res.metal  / res.metalStorage)  < LOW_RES_FRAC)
              or (res.energyStorage and res.energyStorage > 0
                  and (res.energy / res.energyStorage) < LOW_RES_FRAC))
        if prog >= (state.handoffProgress or HANDOFF_PROGRESS)
           and (item.idx or 0) > OPENING_ITEMS
           and #state.nanoUnitIDs >= HANDOFF_MIN_NANOS
           and not starved then
            local nanos = NanosInRange(item.wx, item.wz, builderID)
            if #nanos > 0 then
                for i = 1, #nanos do
                    Spring.GiveOrderToUnit(nanos[i], CMD_REPAIR, {item.frameID}, {"shift"})
                end
                DropClaim(state, item, "released")
                return false   -- free to place the next item on this same tick
            end
        end
        return true
    end

    return true
end

local function ProgressSweep(state, frame)
    for i = 1, #state.queue do
        local item = state.queue[i]
        if item.frameID and (item.status == "started" or item.status == "released") then
            local prog = GetProgress(item.frameID)
            if prog == nil then
                item.frameID = nil
                DropClaim(state, item, "pending")
            elseif prog > (item.lastProgress or 0) + PROGRESS_EPS then
                item.lastProgress      = prog
                item.lastProgressFrame = frame
            end
        end
    end
end

-- blueprint_gen reuses the ground a reclaimed building stood on (nano #3 sits
-- where the bot lab was).  Those items are unbuildable until the reclaim step
-- that frees the ground has run, and TestBuildOrder cannot tell "blocked
-- forever" from "blocked until we reclaim it" — so without this, a builder
-- burns its retries on them and the placer skips them permanently.
--
local function FootprintsOverlap(a, b)
    local ahx, ahz = HalfExtents(a.defID)
    local bhx, bhz = HalfExtents(b.defID)
    return math.abs(a.wx - b.wx) < (ahx + bhx)
       and math.abs(a.wz - b.wz) < (ahz + bhz)
end

-- For every item, the reclaim step (if any) that must finish before its ground
-- is free.  Stored as item.waitsFor.
local function ComputeBlockers(queue)
    for i = 2, #queue do
        local b = queue[i]
        if b.act ~= "reclaim" and b.defID then
            for j = 1, i - 1 do
                local a = queue[j]
                local samePlace = a.defID == b.defID and a.wx == b.wx and a.wz == b.wz
                if a.act ~= "reclaim" and a.defID and not samePlace
                   and FootprintsOverlap(a, b) then
                    for k = j + 1, i - 1 do
                        local r = queue[k]
                        if r.act == "reclaim" and r.defID == a.defID
                           and r.wx == a.wx and r.wz == a.wz then
                            b.waitsFor = r
                        end
                    end
                    if DEBUG and not b.waitsFor then
                        Spring.Echo(string.format(
                            "[BP] blueprint overlap with no reclaim: item %d (%s) over item %d (%s)",
                            i, tostring(b.n), j, tostring(a.n)))
                    end
                end
            end
        end
    end
end

-- \u2500\u2500 Distributed public API \u2500\u2500──────────────────────────────────────────────────

function M.NewDistributed(blueprint, anchorX, anchorZ, rotation, interrupts)
    local state = M.New(blueprint, nil, anchorX, anchorZ, rotation, interrupts)
    state.distributed  = true
    state.builders     = {}
    state.claimOf      = {}   -- builderID -> item
    state.itemByFrame  = {}   -- nanoframe unitID -> item
    state.skippedCount = 0
    state.lastFrame    = 0
    ComputeBlockers(state.queue)
    return state
end

function M.AddBuilder(state, unitID)
    if not state.distributed or not unitID then return false end
    if not Spring.GetUnitDefID(unitID) then return false end
    for i = 1, #state.builders do
        if state.builders[i] == unitID then return false end
    end
    state.builders[#state.builders + 1] = unitID
    -- A leftover command (factory guard, CMD_GUARD, an old build) would make the
    -- builder look busy forever, so it never gets a claim.
    Spring.GiveOrderToUnit(unitID, CMD_STOP, {}, {})
    return true
end

function M.RemoveBuilder(state, unitID)
    if not state.distributed or not unitID then return false end
    local item = state.claimOf[unitID]
    if item then
        state.claimOf[unitID] = nil
        item.claimedBy = nil
        if item.status == "claimed" then item.status = "pending" end
    end
    for i = 1, #state.builders do
        if state.builders[i] == unitID then
            table.remove(state.builders, i)
            return true
        end
    end
    return false
end

-- Call from widget:UnitCreated.  Turns a claim into a live nanoframe.
function M.OnUnitCreated(state, unitID, unitDefID, builderID)
    if not state.distributed or state.done or not builderID then return end
    local item = state.claimOf[builderID]
    if not item or item.defID ~= unitDefID then
        -- The claim may have been dropped between the order and the frame
        -- appearing; fall back to matching the frame's position to an item.
        local x, _, z = Spring.GetUnitPosition(unitID)
        item = nil
        if x then
            for i = 1, #state.queue do
                local it = state.queue[i]
                if it.defID == unitDefID and it.act ~= "reclaim"
                   and not it.frameID and it.status ~= "built" then
                    local dx, dz = it.wx - x, it.wz - z
                    if dx*dx + dz*dz <= 64 * 64 then item = it; break end
                end
            end
        end
        if not item then return end
    end

    item.status            = "started"
    item.frameID           = unitID
    item.lastProgress      = 0
    item.lastProgressFrame = state.lastFrame
    state.itemByFrame[unitID] = item

    -- Adopt the engine's snapped position so range and finish matching are exact.
    local x, _, z = Spring.GetUnitPosition(unitID)
    if x then item.wx, item.wz = x, z end
end

-- Call from widget:UnitDestroyed.  Handles both a dead builder and a dead frame.
function M.OnUnitDestroyed(state, unitID)
    if not state.distributed or not unitID then return end

    local item = state.itemByFrame[unitID]
    if item then
        state.itemByFrame[unitID] = nil
        if item.status ~= "built" then
            item.frameID = nil
            DropClaim(state, item, "pending")
        end
    end

    if state.claimOf[unitID] then M.RemoveBuilder(state, unitID) end
    for i = 1, #state.builders do
        if state.builders[i] == unitID then
            table.remove(state.builders, i)
            break
        end
    end
end

function M.UpdateDistributed(state, frame, resources)
    state.lastFrame = frame

    -- UnitDestroyed does not fire for a unit that was taken/given away.
    local i = 1
    while i <= #state.builders do
        if not Spring.GetUnitDefID(state.builders[i]) then
            M.RemoveBuilder(state, state.builders[i])
        else
            i = i + 1
        end
    end

    ProgressSweep(state, frame)

    for bi = 1, #state.builders do
        local bid = state.builders[bi]
        if not ServiceBuilder(state, bid, frame, resources) then
            local item = FindClaimable(state, bid, frame, resources)
            if item then IssueDistTask(state, bid, item, frame) end
        end
    end

    -- Done only when nothing is outstanding; "skipped" counts, "released" does not.
    for qi = 1, #state.queue do
        local st = state.queue[qi].status
        if st ~= "built" and st ~= "skipped" then return end
    end
    state.done = true
    if state.onComplete then pcall(state.onComplete, state) end
end

-- ── Distributed queries (for phase logic in the macro controller) ────────────

-- Put a one-off building at the front of a distributed queue, so the next builder
-- to come free takes it.  Used for the hand-off air lab, which is not part of the
-- generated build order but needs to go up as soon as metal starts banking.
function M.InsertPriorityItem(state, unitName, wx, wz, facing)
    if not state.distributed then return nil end
    local ud = UnitDefNames and UnitDefNames[unitName]
    if not ud then return nil end
    local item = {
        n       = unitName,
        defID   = ud.id,
        wx      = wx,
        wz      = wz,
        f       = facing or 0,
        cls     = ClassifyUnit(unitName),
        act     = "build",
        idx     = 1,          -- treated as opening work: strict order, no 85% handoff
        status  = "pending",
        built   = false,
        retries = 0,
    }
    table.insert(state.queue, 1, item)
    -- The queue may already have run dry; wake it so a builder picks this up.
    state.done = false
    return item
end

function M.GetItem(state, index)
    return state.queue[index]
end

function M.IsBuilt(state, index)
    local item = state.queue[index]
    return item ~= nil and (item.status == "built" or item.status == "skipped")
end

function M.GetClaim(state, builderID)
    return state.claimOf and state.claimOf[builderID] or nil
end

-- How many items of a class are finished (e.g. "nano") — drives phase changes.
function M.CountBuilt(state, cls)
    local n = 0
    for i = 1, #state.queue do
        local item = state.queue[i]
        if item.cls == cls and item.status == "built" then n = n + 1 end
    end
    return n
end

-- True when this builder has something it could start right now.
function M.HasClaimable(state, builderID, frame, resources)
    return FindClaimable(state, builderID, frame or state.lastFrame, resources) ~= nil
end


return M
