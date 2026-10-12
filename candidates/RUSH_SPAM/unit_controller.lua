-- RUSH_SPAM army: every armed mobile unit is sent (attack-move) at the enemy start, forever.  No
-- grouping, no retreat, no scouting.  Idle units are re-sent every few seconds.

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name = "Unit Controller", desc = "RUSH_SPAM: stream units at the enemy start",
        author = "", date = "2026", license = "GNU GPL, v3 or later", layer = 0, enabled = true,
    }
end

local TICK = 60
local CMD_FIGHT = CMD.FIGHT
local myTeam, myAlly
local targetX, targetZ

local function ResolveTarget()
    for _, t in ipairs(Spring.GetTeamList() or {}) do
        if t ~= myTeam then
            local _, _, _, _, _, ally = Spring.GetTeamInfo(t)
            if ally ~= myAlly and Spring.GetTeamStartPosition then
                local x, _, z = Spring.GetTeamStartPosition(t)
                if x and x > 0 and z and z > 0 then return x, z end
            end
        end
    end
    -- fall back to the point mirror of our commander (the maps here are point-symmetric)
    for _, uid in ipairs(Spring.GetTeamUnits(myTeam)) do
        local ud = UnitDefs[Spring.GetUnitDefID(uid)]
        if ud.customParams and ud.customParams.iscommander then
            local x, _, z = Spring.GetUnitPosition(uid)
            return Game.mapSizeX - x, Game.mapSizeZ - z
        end
    end
end

function widget:Initialize()
    myTeam = Spring.GetMyTeamID()
    myAlly = Spring.GetMyAllyTeamID()
end

local function IsSoldier(ud)
    return ud.canMove and not ud.isBuilder and not ud.isFactory
        and ud.weapons and #ud.weapons > 0
end

local function Send(uid)
    Spring.GiveOrderToUnit(uid, CMD_FIGHT, { targetX, Spring.GetGroundHeight(targetX, targetZ), targetZ }, {})
end

function widget:UnitFinished(uid, defID, team)
    if team == myTeam and targetX and IsSoldier(UnitDefs[defID]) then Send(uid) end
end

function widget:GameFrame(f)
    if f % TICK ~= 0 then return end
    if not targetX then
        if f < 30 then return end
        targetX, targetZ = ResolveTarget()
        if targetX then Spring.Echo(string.format("[RUSH] target %d,%d", targetX, targetZ)) end
        return
    end
    for _, uid in ipairs(Spring.GetTeamUnits(myTeam)) do
        local ud = UnitDefs[Spring.GetUnitDefID(uid)]
        if IsSoldier(ud) and (Spring.GetUnitCommands(uid, 0) or 0) == 0 then Send(uid) end
    end
end
