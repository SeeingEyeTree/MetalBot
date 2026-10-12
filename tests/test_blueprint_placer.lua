-- test_blueprint_placer.lua
-- Minimal standalone test widget for blueprint_placer.lua.
-- Does NOT depend on bot.lua or new_bot.lua.
--
-- Behaviour:
--   1. Detects the commander (to anchor the first blueprint).
--   2. Waits for the first air constructor to be created.
--   3. Directs that air con to build blueprints/general/mex_grid_aa_corner.lua
--      at commander position + (500, 0) east.
--   4. When the first blueprint is done, finds a valid adjacent position and
--      places a second copy next to it.

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name    = "Blueprint Placer Test",
        desc    = "Tests blueprint_placer.lua: places mex_grid_aa_corner twice",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 10,
        enabled = true,
    }
end

-- ── Load dependencies ─────────────────────────────────────────────────────────

local BP_PLACER = VFS.Include("LuaUI/Widgets/blueprint_placer.lua")
local BLUEPRINT = VFS.Include("LuaUI/Widgets/blueprints/general/mex_grid_aa_corner.lua")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local myTeamID = nil
local myAllyID = nil

local function IsAirCon(unitDefID)
    local ud = unitDefID and UnitDefs and UnitDefs[unitDefID]
    if not ud then return false end
    return ud.isBuilder and ud.canFly and not ud.isFactory
end

local function IsCommander(unitDefID)
    local ud = unitDefID and UnitDefs and UnitDefs[unitDefID]
    if not ud then return false end
    local cp = ud.customParams
    return cp and (cp.iscommander ~= nil or cp.is_commander ~= nil)
end

local function GetResources()
    local ok,  m,  ms  = pcall(Spring.GetTeamResources, myTeamID, "metal")
    local ok2, e,  es  = pcall(Spring.GetTeamResources, myTeamID, "energy")
    return {
        metal         = (ok  and m)  or 0,
        metalStorage  = (ok  and ms) or 1000,
        energy        = (ok2 and e)  or 0,
        energyStorage = (ok2 and es) or 1000,
    }
end

local function EnemiesNear(anchorX, anchorZ, radius)
    if not anchorX then return false end
    local units = Spring.GetUnitsInCylinder(anchorX, anchorZ, radius)
    if not units then return false end
    for i = 1, #units do
        local ally = Spring.GetUnitAllyTeam and Spring.GetUnitAllyTeam(units[i])
        if ally and ally ~= myAllyID then return true end
    end
    return false
end

local function FindAvailableAirCon()
    local units = Spring.GetTeamUnits(myTeamID)
    if not units then return nil end
    for _, uid in ipairs(units) do
        if IsAirCon(Spring.GetUnitDefID(uid)) then return uid end
    end
    return nil
end

-- ── State ─────────────────────────────────────────────────────────────────────

local phase       = "waiting"   -- waiting | placing1 | placing2 | done
local commanderID = nil
local airConID    = nil
local placer1     = nil
local placer2     = nil
local anchor1     = nil         -- {anchorX, anchorZ} of first blueprint

local FIRST_OFFSET_X = 500     -- east offset from commander for first blueprint
local FIRST_OFFSET_Z = 0

-- ── Internal logic ────────────────────────────────────────────────────────────

local function TryStartPlacing1()
    if not commanderID or not airConID then return end
    if phase ~= "waiting" then return end
    local cx, _, cz = Spring.GetUnitPosition(commanderID)
    if not cx then return end

    local anchorX = cx + FIRST_OFFSET_X
    local anchorZ = cz + FIRST_OFFSET_Z
    anchor1 = {anchorX = anchorX, anchorZ = anchorZ}

    placer1 = BP_PLACER.New(BLUEPRINT, airConID, anchorX, anchorZ, 0)
    placer1.onComplete = function()
        Spring.Echo("[BPTest] First blueprint done — searching for second placement.")
        phase = "placing2"
    end

    phase = "placing1"
    Spring.Echo("[BPTest] First blueprint started at "
        .. math.floor(anchorX) .. ", " .. math.floor(anchorZ))
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = Spring.GetMyTeamID()
    myAllyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()

    -- Scan for units that already exist (widget enabled mid-game).
    local units = Spring.GetTeamUnits(myTeamID) or {}
    for _, uid in ipairs(units) do
        local dID = Spring.GetUnitDefID(uid)
        if IsCommander(dID) and not commanderID then commanderID = uid end
        if IsAirCon(dID)    and not airConID    then airConID    = uid end
    end
    TryStartPlacing1()
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam ~= myTeamID then return end

    if IsCommander(unitDefID) and not commanderID then
        commanderID = unitID
        TryStartPlacing1()
    end

    if IsAirCon(unitDefID) and not airConID then
        airConID = unitID
        TryStartPlacing1()
    end

    -- Notify active placers so they can mark tasks built.
    local x, _, z = Spring.GetUnitPosition(unitID)
    if placer1 and not placer1.done then
        BP_PLACER.OnUnitFinished(placer1, unitID, unitDefID, x, z)
    end
    if placer2 and not placer2.done then
        BP_PLACER.OnUnitFinished(placer2, unitID, unitDefID, x, z)
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
    if unitTeam ~= myTeamID then return end
    if unitID == commanderID then commanderID = nil end
    if unitID == airConID then
        airConID = nil
        -- Try to find another air con immediately.
        airConID = FindAvailableAirCon()
        if not airConID and (phase == "placing1" or phase == "placing2") then
            Spring.Echo("[BPTest] Air con lost — waiting for a new one.")
        end
    end
end

function widget:GameFrame(frame)
    if phase == "done" then return end

    -- Main update every 10 frames
    if frame % 10 == 0 then
        -- If we lost the air con mid-placement, try to reclaim one.
        if not airConID then
            airConID = FindAvailableAirCon()
            if airConID and phase == "waiting" then
                TryStartPlacing1()
            end
        end

        local res = GetResources()

        if phase == "placing1" and placer1 then
            if not airConID or not Spring.GetUnitDefID(airConID) then
                airConID = FindAvailableAirCon()
                return
            end
            BP_PLACER.Update(placer1, frame, res)

        elseif phase == "placing2" then
            -- Re-assign the same air con to the second blueprint.
            if not airConID then
                airConID = FindAvailableAirCon()
                return
            end

            if not placer2 and anchor1 then
                local placement = BP_PLACER.FindValidPlacement(BLUEPRINT, {anchor1})
                if placement then
                    placer2 = BP_PLACER.New(
                        BLUEPRINT, airConID,
                        placement.anchorX, placement.anchorZ, placement.rotation
                    )
                    placer2.onComplete = function()
                        phase = "done"
                        Spring.Echo("[BPTest] Both blueprints complete.")
                    end
                    Spring.Echo("[BPTest] Second blueprint started at "
                        .. math.floor(placement.anchorX) .. ", " .. math.floor(placement.anchorZ)
                        .. "  rotation=" .. placement.rotation)
                else
                    Spring.Echo("[BPTest] Could not find valid placement for second blueprint.")
                end
            end

            if placer2 then
                BP_PLACER.Update(placer2, frame, res)
            end
        end
    end

    -- Enemy-clear check every 30 frames; trigger nano reclaim of LLTs.
    if frame % 30 == 0 then
        local clearR = BP_PLACER.ENEMY_CLEAR_RADIUS
        if placer1 and anchor1 then
            if not EnemiesNear(anchor1.anchorX, anchor1.anchorZ, clearR) then
                BP_PLACER.HandleEnemyClear(placer1)
            end
        end
        if placer2 and placer2.anchorX then
            if not EnemiesNear(placer2.anchorX, placer2.anchorZ, clearR) then
                BP_PLACER.HandleEnemyClear(placer2)
            end
        end
    end
end
