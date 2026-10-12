-- unit_controller.lua  --  ARMY_BENCH: the army sink of the eco bench.
-- Every mobile non-builder unit this team finishes is counted (metal cost, cumulative) and then walked away from the base
-- and self-destructed, so the sim stays light and nothing stands in the grids' way.  No scouting, no fighting, no threat
-- signal (WG.MetalBot.urgency stays "none"), so the only thing that decides the army share is the lab / spine side.
-- Log: "[TRK] bench frame=F team=T army_spent=<cumulative metal> army_n=<units>" every 5 s of game time, which the
-- harness parses into result["tracker_timeline"] (kind "bench").  eco_scaling.py `shares` compares it with the schedule.

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "ARMY_BENCH: counts army metal spent, walks units off and self-destructs them",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local WALK_FRAMES  = 25 * 30     -- walk this long, then self-destruct
local WALK_DIST    = 1800        -- elmos away from the base, opposite the map centre
local LOG_EVERY    = 150
local CMD_MOVE, CMD_SELFD = CMD.MOVE, CMD.SELFD

local myTeam
local spent, count = 0, 0
local pending = {}               -- uid -> frame to self-destruct
local target                     -- {x, z}

local function IsArmy(ud)
    return ud and ud.canMove and not ud.isBuilder and not ud.isFactory and not ud.isBuilding
end

function widget:Initialize()
    myTeam = Spring.GetMyTeamID()
    WG.MetalBot = WG.MetalBot or {}
    WG.MetalBot.urgency = "none"
    WG.MetalBot.bench = true
end

function widget:UnitFinished(uid, defID, teamID)
    if teamID ~= myTeam then return end
    local ud = UnitDefs[defID]
    if not IsArmy(ud) then return end
    spent = spent + (ud.metalCost or 0)
    count = count + 1
    local x, _, z = Spring.GetUnitPosition(uid)
    if not x then return end
    if not target then
        local cx, cz = Game.mapSizeX / 2, Game.mapSizeZ / 2
        local dx, dz = x - cx, z - cz
        local d = math.max(math.sqrt(dx * dx + dz * dz), 1)
        target = { dx / d, dz / d }
    end
    local tx = math.max(100, math.min(Game.mapSizeX - 100, x + target[1] * WALK_DIST))
    local tz = math.max(100, math.min(Game.mapSizeZ - 100, z + target[2] * WALK_DIST))
    Spring.GiveOrderToUnit(uid, CMD_MOVE, { tx, Spring.GetGroundHeight(tx, tz), tz }, {})
    pending[uid] = Spring.GetGameFrame() + WALK_FRAMES
end

function widget:GameFrame(n)
    if n % 30 == 0 then
        for uid, due in pairs(pending) do
            if n >= due then
                if Spring.GetUnitDefID(uid) then Spring.GiveOrderToUnit(uid, CMD_SELFD, {}, {}) end
                pending[uid] = nil
            end
        end
    end
    if n % LOG_EVERY == 0 and myTeam then
        Spring.Echo(string.format("[TRK] bench frame=%d team=%d army_spent=%d army_n=%d", n, myTeam, spent, count))
    end
end

function widget:UnitDestroyed(uid) pending[uid] = nil end
