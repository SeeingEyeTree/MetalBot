-- nano_broker.lua
-- Single owner of every order given to a nano turret.
--
-- WHY THIS EXISTS
-- ---------------
-- Nanos are the bulk of the bot's build power, so what they are pointed at IS the
-- bot's behaviour.  Six separate systems used to order them directly -- the placer's
-- build handoff, its reclaim entries, its blocker clearing, the enemy-clear reclaim,
-- the army/eco balancer and the wind reclaim -- each calling GiveOrderToUnit with no
-- idea what the others had just told the same nano.  Last writer won.  Two bugs came
-- straight out of that: nanos repairing a building another system was reclaiming, and
-- the balancer pulling nanos off reclaim work every 30 frames.
--
-- Every nano order now goes through here.  A request only displaces an existing
-- assignment if it is strictly more important, so a nano cannot be stolen by lower
-- priority work while it is mid-job.
--
-- USAGE
--   local NANO = VFS.Include("LuaUI/Widgets/bar_framework/nano_broker.lua")
--   NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, nanoID, targetID)
--   NANO.Assist (NANO.PRIO.HANDOFF,      nanoID, frameID)
--   NANO.Guard  (NANO.PRIO.BALANCE,      nanoID, factoryID)
--   NANO.Release(nanoID)              -- back to the engine's own auto-assist
--   NANO.Sweep()                      -- once per update tick

local M = {}

-- Lower number wins.  The order is deliberate:
--   WIND_RECLAIM  freeing unit cap is the scarcest resource late game, and a
--                 half-reclaimed wind that gets abandoned is pure waste.
--   HANDOFF       a frame left at handoff progress is already paid for and decays
--                 if nobody finishes it.
--   CLEAR         retrofits and consolidation: useful, but they can wait.
--   BALANCE       army/eco allocation is a steady-state preference, not a job.
M.PRIO = {
    WIND_RECLAIM = 1,
    HANDOFF      = 2,
    CLEAR        = 3,
    BALANCE      = 4,
}

local CMD_STOP    = 0
local CMD_GUARD   = 25
local CMD_REPAIR  = 40
local CMD_RECLAIM = 90

-- nanoID -> {prio, cmd, target, mode}
local assign = {}

local function Alive(unitID)
    return unitID ~= nil and Spring.GetUnitDefID(unitID) ~= nil
end

-- Has this assignment finished on its own?
local function Expired(a)
    if not Alive(a.target) then return true end
    -- An assist ends when the thing stops being a nanoframe; the unitID lives on as
    -- the finished building, so "target still exists" is not enough to tell.
    if a.mode == "assist" and not Spring.GetUnitIsBeingBuilt(a.target) then
        return true
    end
    return false
end

local function Claim(nanoID, prio, cmd, target, mode, opts)
    if not Alive(nanoID) or not Alive(target) then return false end
    local cur = assign[nanoID]
    if cur and not Expired(cur) then
        -- Already doing this exact job: leave it alone rather than re-issuing every
        -- tick, which resets the unit's command and loses its progress.
        if cur.cmd == cmd and cur.target == target then return true end
        if cur.prio <= prio then return false end
    end
    Spring.GiveOrderToUnit(nanoID, cmd, {target}, opts or {})
    assign[nanoID] = {prio = prio, cmd = cmd, target = target, mode = mode}
    return true
end

function M.Reclaim(prio, nanoID, target)
    return Claim(nanoID, prio, CMD_RECLAIM, target, "reclaim")
end

function M.Assist(prio, nanoID, target)
    return Claim(nanoID, prio, CMD_REPAIR, target, "assist")
end

function M.Guard(prio, nanoID, target)
    return Claim(nanoID, prio, CMD_GUARD, target, "guard")
end

-- Hand the nano back to the engine's auto-assist behaviour.
function M.Release(nanoID)
    if assign[nanoID] then
        assign[nanoID] = nil
        if Alive(nanoID) then Spring.GiveOrderToUnit(nanoID, CMD_STOP, {}, {}) end
        return true
    end
    return false
end

-- What is this nano on?  Returns {prio, cmd, target, mode} or nil.
function M.Assignment(nanoID)
    local a = assign[nanoID]
    if a and Expired(a) then assign[nanoID] = nil; return nil end
    return a
end

-- True when the nano is busy with work at least as important as `prio`, i.e. when a
-- request at `prio` would be refused.
function M.IsBusy(nanoID, prio)
    local a = M.Assignment(nanoID)
    return a ~= nil and a.prio <= prio
end

function M.Count()
    local n = 0
    for _ in pairs(assign) do n = n + 1 end
    return n
end

-- Drop finished and dead assignments.  Call once per update tick, before handing
-- out new work, so freed nanos are available in the same pass.
function M.Sweep()
    for nanoID, a in pairs(assign) do
        if not Alive(nanoID) or Expired(a) then assign[nanoID] = nil end
    end
end

return M
