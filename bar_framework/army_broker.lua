-- bar_framework/army_broker.lua
-- Single owner of every order given to a mobile combat unit.
--
-- WHY THIS EXISTS
-- ---------------
-- Same problem nano_broker.lua solved for build power, now for the army.  Once
-- scouting, base defence, raid response and the contact line all want to move the
-- same units, "last writer wins" produces a unit that is recalled and re-sent every
-- tick and never arrives anywhere.  Planners therefore do not issue orders: they
-- state what they want via Claim(), and this module decides who wins and whether an
-- order actually needs to go out.
--
-- It also replaces the old gate on issuing orders.  The previous controller only
-- ordered a unit when Spring.GetUnitCommands() said it was idle, which meant a
-- moving unit ignored everything -- new threats, a shifted front, its own death --
-- until it arrived.  Reading command queues back is also the known host/client
-- desync trap in this engine (asymmetric lag, the bug that forced ORDER_GRACE_FRAMES
-- from 30 to 90), so this module never reads them.  Instead it remembers what it
-- last told each unit and re-issues only on a real change.
--
-- USAGE
--   local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
--   ARMY.Sweep(frame)                              -- once per tick, first
--   ARMY.Claim(ARMY.PRIO.LINE, unitID, {           -- then plan
--       role = "LINE", cmd = ARMY.CMD_FIGHT, x = nx, z = nz, slot = nodeIdx,
--   }, frame)

local M = {}

M.CMD_MOVE   = 10
M.CMD_PATROL = 15
M.CMD_FIGHT  = 16
M.CMD_ATTACK = 20
M.CMD_GUARD  = 25

-- Lower number wins.  The order is doctrine:
--   RETREAT     a unit below its HP floor is worth more alive; nothing may steal it.
--   RAID        raid units are committed by design and must never be recalled
--               (game_mechanics 7.2) -- a retreating raider is a wasted raider.
--   RESPOND     something is being destroyed right now.
--   HOME_GUARD  standing cover for the base.
--   SCOUT       information is cheap but not free.
--   MUSTER      new units waiting to mass rather than trickling forward alone.
--   LINE        the default for everything not otherwise claimed.
M.PRIO = {
    RETREAT    = 1,
    RAID       = 2,
    RESPOND    = 3,
    HOME_GUARD = 4,
    SCOUT      = 5,
    MUSTER     = 6,
    LINE       = 7,
}

-- Orders are network packets and the engine applies them with latency, so issuing
-- one per unit per tick is both wasteful and counterproductive.
M.ORDER_MIN_INTERVAL    = 90   -- floor between orders to the same unit
M.ORDER_URGENT_INTERVAL = 30   -- RETREAT/RESPOND may preempt this fast
M.ORDER_HEARTBEAT       = 300  -- re-state a standing order this often
M.ORDER_MOVE_EPS        = 250  -- target must move this far to be worth re-issuing
M.STUCK_FRAMES          = 150  -- no progress for this long ...
M.STUCK_DIST            = 40   -- ... measured as less than this much movement

local duty = {}   -- [unitID] = {role, prio, cmd, tx, tz, targetID, slot, since,
                  --             expires, prevRole, lastOrderFrame, lastCmd,
                  --             lastX, lastZ, lastMoveFrame}

local function Alive(unitID)
    return unitID ~= nil and Spring.GetUnitDefID(unitID) ~= nil
end

local function Dist2(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return dx * dx + dz * dz
end

-- Has this unit stopped making progress?  Measured from our own cached position,
-- never from the engine's command queue.
local function Stuck(d, unitID, frame)
    local x, _, z = Spring.GetUnitPosition(unitID)
    if not x then return false end
    if not d.lastX then
        d.lastX, d.lastZ, d.lastMoveFrame = x, z, frame
        return false
    end
    if Dist2(x, z, d.lastX, d.lastZ) > M.STUCK_DIST * M.STUCK_DIST then
        d.lastX, d.lastZ, d.lastMoveFrame = x, z, frame
        return false
    end
    return (frame - (d.lastMoveFrame or frame)) > M.STUCK_FRAMES
end

-- Does this claim require an order to actually be sent?
local function NeedsOrder(d, spec, unitID, frame)
    if not d.lastOrderFrame then return true end
    if d.lastCmd ~= spec.cmd then return true end
    if d.targetID ~= spec.targetID then return true end
    -- Compare against what the unit was actually TOLD, not what we last wanted.
    -- Comparing against the desired target lost every repositioning that arrived
    -- while the rate limit was active: the desired target updated, so the next tick
    -- saw no difference and the order was never sent at all.
    if spec.x and d.issuedX and Dist2(spec.x, spec.z, d.issuedX, d.issuedZ)
       > M.ORDER_MOVE_EPS * M.ORDER_MOVE_EPS then
        return true
    end
    if frame - d.lastOrderFrame > M.ORDER_HEARTBEAT then return true end
    if Stuck(d, unitID, frame) then return true end
    return false
end

local ordersIssued = 0
function M.OrdersIssued() return ordersIssued end

local function Issue(unitID, spec, frame)
    ordersIssued = ordersIssued + 1
    if spec.targetID then
        Spring.GiveOrderToUnit(unitID, spec.cmd, { spec.targetID }, spec.opts or {})
    else
        local y = spec.y or Spring.GetGroundHeight(spec.x, spec.z) or 0
        Spring.GiveOrderToUnit(unitID, spec.cmd, { spec.x, y, spec.z }, spec.opts or {})
    end
    local d = duty[unitID]
    d.lastOrderFrame     = frame
    d.lastCmd            = spec.cmd
    d.issuedX, d.issuedZ = spec.x, spec.z
end

-- Request a unit for a duty.  Returns true if this planner owns the unit after the
-- call -- whether or not an order was actually sent, because owning a unit that is
-- already doing the right thing is success, not failure.
--
-- Call it every tick.  Repeating an unchanged claim is free.
function M.Claim(prio, unitID, spec, frame)
    if not Alive(unitID) or not spec then return false end
    local d = duty[unitID]

    if d then
        -- A less important job cannot take a unit that is already busy.
        if prio > d.prio then return false end

        -- Same planner, same priority: re-slotting is allowed, but not immediately.
        -- Without this the line reassigns every unit to a different node whenever
        -- anything is built or dies, and the army walks sideways forever.
        if prio == d.prio and d.role == spec.role then
            local moved = spec.x and d.tx
                and Dist2(spec.x, spec.z, d.tx, d.tz) > M.ORDER_MOVE_EPS * M.ORDER_MOVE_EPS
            if moved then
                if spec.minHold and (frame - d.since) < spec.minHold then
                    return true   -- ours, but keep the current target
                end
                -- Restart the hold on every accepted re-slot.  `since` otherwise only
                -- resets on a role change, so any unit older than minHold could be
                -- moved every single tick -- the hold only protected new units.
                d.since = frame
            end
        else
            -- Genuine role change: remember where to fall back to.
            d.prevRole = d.role
            d.since    = frame
        end
    else
        duty[unitID] = {
            since = frame, lastX = nil, lastZ = nil, lastMoveFrame = frame,
        }
        d = duty[unitID]
    end

    local interval = (prio <= M.PRIO.RESPOND)
        and M.ORDER_URGENT_INTERVAL or M.ORDER_MIN_INTERVAL
    local needs = NeedsOrder(d, spec, unitID, frame)
    local rateOK = (not d.lastOrderFrame) or (frame - d.lastOrderFrame) >= interval

    d.role     = spec.role
    d.prio     = prio
    d.cmd      = spec.cmd
    d.tx, d.tz = spec.x, spec.z
    d.targetID = spec.targetID
    d.slot     = spec.slot
    d.expires  = spec.expires

    if needs and rateOK then Issue(unitID, spec, frame) end
    return true
end

-- Give the unit up so a lower-priority planner can have it.
function M.Release(unitID)
    duty[unitID] = nil
end

function M.Duty(unitID)   return duty[unitID] end
function M.Slot(unitID)   local d = duty[unitID]; return d and d.slot end
function M.RoleOf(unitID) local d = duty[unitID]; return d and d.role end

-- Units currently holding a role.
function M.Roster(role)
    local out = {}
    for unitID, d in pairs(duty) do
        if d.role == role then out[#out + 1] = unitID end
    end
    return out
end

function M.Count(role)
    local n = 0
    for _, d in pairs(duty) do
        if d.role == role then n = n + 1 end
    end
    return n
end

-- Drop dead units and expired duties.  Call once per tick BEFORE planning, so a
-- unit freed this frame can be re-tasked in the same pass.
function M.Sweep(frame)
    for unitID, d in pairs(duty) do
        if not Alive(unitID) then
            duty[unitID] = nil
        elseif d.expires and frame >= d.expires then
            -- Fall back rather than going idle: an expired duty means the job is
            -- over, not that the unit should stand still.
            d.role, d.prio = d.prevRole or "LINE", M.PRIO.LINE
            d.expires, d.prevRole = nil, nil
            d.since = frame
        end
    end
end

function M.Stats()
    local n, byRole = 0, {}
    for _, d in pairs(duty) do
        n = n + 1
        byRole[d.role] = (byRole[d.role] or 0) + 1
    end
    return n, byRole
end

return M
