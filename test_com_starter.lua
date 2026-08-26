-- test_com_starter.lua
-- Queues all com_starter build orders on the commander at game start.
-- Does NOT depend on blueprint_placer.lua.

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name    = "Com Starter Test",
        desc    = "Commander queues com_starter build orders at game start",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 10,
        enabled = true,
    }
end

-- ── Load blueprint ─────────────────────────────────────────────────────────────

local BLUEPRINT = VFS.Include("LuaUI/Widgets/blueprints/general/com_starter.lua")

-- ── Config ────────────────────────────────────────────────────────────────────

local ANCHOR_OFFSET_X = 300   -- east of commander start position
local ANCHOR_OFFSET_Z = 0

-- ── Helpers ───────────────────────────────────────────────────────────────────

local myTeamID    = nil
local commanderID = nil
local ordered     = false

-- Same customParams check as bot.lua lines 3315 / 4475.
local function IsCommander(unitDefID)
    local ud = unitDefID and UnitDefs and UnitDefs[unitDefID]
    if not ud then return false end
    local cp = ud.customParams
    return cp ~= nil and (cp.iscommander ~= nil or cp.is_commander ~= nil)
end

-- Queue every blueprint item on the commander in layout order.
-- First order has no flags; subsequent use "shift" to append to the queue.
local function QueueBlueprint(cmdID, anchorX, anchorZ)
    local count = 0
    local first = true
    for _, u in ipairs(BLUEPRINT.layout) do
        local ud = UnitDefNames and UnitDefNames[u.n]
        if ud then
            local wx = anchorX + u.x
            local wz = anchorZ + u.z
            local wy = Spring.GetGroundHeight(wx, wz) or 0
            local opts = first and {} or {"shift"}
            Spring.GiveOrderToUnit(cmdID, -ud.id, {wx, wy, wz, u.f}, opts)
            first = false
            count = count + 1
        end
    end
    Spring.Echo("[ComTest] Queued " .. count .. " orders on commander at "
        .. math.floor(anchorX) .. ", " .. math.floor(anchorZ))
end

local function TryOrder()
    if ordered or not commanderID then return end
    local cx, _, cz = Spring.GetUnitPosition(commanderID)
    if not cx then return end
    ordered = true
    QueueBlueprint(commanderID, cx + ANCHOR_OFFSET_X, cz + ANCHOR_OFFSET_Z)
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = Spring.GetMyTeamID()
    local units = Spring.GetTeamUnits(myTeamID) or {}
    for _, uid in ipairs(units) do
        if IsCommander(Spring.GetUnitDefID(uid)) then
            commanderID = uid
            break
        end
    end
    TryOrder()
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam ~= myTeamID or ordered then return end
    if IsCommander(unitDefID) then
        commanderID = unitID
        TryOrder()
    end
end
