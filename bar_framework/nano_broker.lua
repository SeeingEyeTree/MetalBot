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
    DEFEND       = 0,     -- an enemy unit in reach (reclaim it) or a con under attack (repair it): beats everything (home_defence.lua)
    RUSH         = 0.3,   -- spine nanos guarding a lab while it rushes units out (slot_spine RUSH_NANOS): above the energy guard, hand-offs and clears
    VP           = 0.25,  -- the vehicle lab frame while it is built with an enemy about (line_transition VP_RUSH): every nano in reach, ahead of the energy guard
    ENERGY       = 0.5,   -- energy is stalling: nanos in reach of a fusion job guard its builder (line_transition ENERGY_PRIORITY)
    WIND_RECLAIM = 1,
    HANDOFF      = 2,
    SPINE        = 2.5,   -- spine lab guard/park: beats CLEAR/BALANCE, yields to hand-offs
    CLEAR        = 3,
    BALANCE      = 4,
}

local CMD_STOP    = 0
local CMD_WAIT    = 5
local CMD_ONOFF   = (CMD and CMD.ONOFF) or 85
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
    if a.mode == "park" then return false end   -- a park has no target
    if not Alive(a.target) then return true end
    if a.keep and not a.keep(a.target) then return true end     -- a "defend" job ends when its own test says so (enemy left reach, con healed)
    -- An assist ends when the thing stops being a nanoframe; the unitID lives on as
    -- the finished building, so "target still exists" is not enough to tell.
    if a.mode == "assist" and not Spring.GetUnitIsBeingBuilt(a.target) then
        return true
    end
    return false
end

-- Parked nanos are paused (on/off command = off): a nano that only has a WAIT queued still auto-assists nearby
-- builds (measured: 27 of 28 parked spine nanos building at 15:28).  A paused nano builds nothing, so every
-- order that gives it work switches it back on first.
local paused = {}

local function SetActive(nanoID, on)
    if on then
        if paused[nanoID] then
            paused[nanoID] = nil
            if Alive(nanoID) then Spring.GiveOrderToUnit(nanoID, CMD_ONOFF, {1}, {}) end
        end
    else
        paused[nanoID] = true
        Spring.GiveOrderToUnit(nanoID, CMD_ONOFF, {0}, {})
    end
end

local function Claim(nanoID, prio, cmd, target, mode, opts)
    if not Alive(nanoID) or not Alive(target) then return false end
    local cur = assign[nanoID]
    if cur and not Expired(cur) then
        -- Already doing this exact job: leave it alone rather than re-issuing every
        -- tick, which resets the unit's command and loses its progress.
        if cur.cmd == cmd and cur.target == target then
            if prio < cur.prio then cur.prio = prio end          -- the same job asked for again more urgently: it keeps the higher priority
            return true
        end
        if cur.prio <= prio then return false end
    end
    SetActive(nanoID, true)
    Spring.GiveOrderToUnit(nanoID, cmd, {target}, opts or {})
    assign[nanoID] = {prio = prio, cmd = cmd, target = target, mode = mode}
    return true
end

function M.Reclaim(prio, nanoID, target)
    return Claim(nanoID, prio, CMD_RECLAIM, target, "reclaim")
end

-- Defence jobs (home_defence.lua): like Reclaim / repair, but the job carries `keep(target)`; when it returns false the nano is
-- stopped (Sweep) and handed back.  Repair of a finished unit is CMD.REPAIR, which Expired would read as an assist, so it has its own mode.
function M.Defend(nanoID, target, keep, mode)
    if not Alive(nanoID) or not Alive(target) then return false end
    local cmd = mode == "repair" and CMD_REPAIR or CMD_RECLAIM
    local cur = assign[nanoID]
    if cur and not Expired(cur) then
        if cur.cmd == cmd and cur.target == target then cur.keep = keep; return true end
        if cur.prio < M.PRIO.DEFEND or (cur.prio == M.PRIO.DEFEND and cur.mode == "defend-reclaim" and mode == "repair") then return false end
    end
    SetActive(nanoID, true)
    Spring.GiveOrderToUnit(nanoID, cmd, {target}, {})
    assign[nanoID] = {prio = M.PRIO.DEFEND, cmd = cmd, target = target, mode = mode == "repair" and "defend-repair" or "defend-reclaim", keep = keep}
    return true
end

function M.Assist(prio, nanoID, target)
    return Claim(nanoID, prio, CMD_REPAIR, target, "assist")
end

function M.Guard(prio, nanoID, target)
    return Claim(nanoID, prio, CMD_GUARD, target, "guard")
end

-- Stop the nano building at all: clear its orders and pause it (on/off = off).  Held until Release (or a
-- higher-priority claim).
function M.Park(prio, nanoID)
    if not Alive(nanoID) then return false end
    local cur = assign[nanoID]
    if cur and not Expired(cur) then
        if cur.mode == "park" then
            if not paused[nanoID] then SetActive(nanoID, false) end     -- re-pause if something switched it back on
            return true
        end
        if cur.prio <= prio then return false end
    end
    Spring.GiveOrderToUnit(nanoID, CMD_STOP, {}, {})
    SetActive(nanoID, false)
    assign[nanoID] = {prio = prio, cmd = CMD_ONOFF, target = nil, mode = "park"}
    return true
end

-- Hand the nano back to the engine's auto-assist behaviour.
function M.Release(nanoID)
    local was = paused[nanoID]
    SetActive(nanoID, true)
    if assign[nanoID] then
        assign[nanoID] = nil
        if Alive(nanoID) then Spring.GiveOrderToUnit(nanoID, CMD_STOP, {}, {}) end
        return true
    end
    return was and true or false
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
        if not Alive(nanoID) then assign[nanoID] = nil
        elseif Expired(a) then
            -- a defence job whose target is still alive (enemy out of reach, con healed): the engine would leave the nano on the order
            if a.keep and Alive(a.target) then Spring.GiveOrderToUnit(nanoID, CMD_STOP, {}, {}) end
            assign[nanoID] = nil
        end
    end
    for nanoID in pairs(paused) do
        if not Alive(nanoID) then paused[nanoID] = nil end
    end
end

return M
