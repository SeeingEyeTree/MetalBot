-- bar_framework/commander_guard.lua
-- Keeping the commander alive (game_mechanics 1.5).
--
-- 1.5: the commander only matters economically in the opening; after that the rest of
-- the economy dwarfs its ~300 BP.  It does not fight.  And losing it is an instant
-- loss -- so once the opening is done, keeping it safe "(cloak + stay near a jammer)
-- matters far more than using it for anything active".
--
-- What this does, once the commander is retired from the build order:
--   * walks it to a safe spot BEHIND the base (away from the enemy), next to a nano
--     turret if one is close, so it is repaired if something reaches it;
--   * has it build a radar jammer there, and a couple of static anti-air turrets
--     (7.3: "getting caught with zero AA against a bomber run is an instant loss", and
--     the commander is the one unit whose loss ends the game);
--   * cloaks it whenever energy comfortably covers the cost;
--   * and at any time -- retired or not -- moves it away from armed enemies or an
--     attack in progress nearby, then back once the area has been quiet for a while.
--
-- Everything the commander can build is looked up from its own build options, so a
-- def it cannot place is simply skipped.
--
-- USAGE (from the macro, which owns the commander)
--   local CG = VFS.Include("LuaUI/Widgets/bar_framework/commander_guard.lua")
--   CG.Init{ UQ = UQ, teamID = t, allyID = a }
--   local state = CG.Update(frame, comID, resources, {
--       retire = bool, homeX =, homeZ =, foeX =, foeZ =, threats = {{x, z}, ...} })
--   -- state: "free" (the macro may use it), "retired" or "evading" (hands off)

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.BACK_DIST      = 700    -- safe spot this far behind home, away from the foe
M.NANO_SNAP      = 600    -- ...moved next to a nano turret this close to it
M.DANGER_RADIUS  = 1100   -- armed enemies this close -> evade
M.THREAT_RADIUS  = 1500   -- a reported attack this close -> evade
M.BLIP_GROUP     = 3      -- unidentified radar blips that count as danger
M.FLEE_DIST      = 1000
M.CLEAR_HOLD     = 600    -- quiet frames before returning
M.ORDER_EVERY    = 90
M.ARRIVE_DIST    = 200
M.RETURN_DIST    = 700
M.AA_TURRETS     = 2
M.CLOAK_ON_FRAC  = 0.40   -- energy storage share needed to cloak...
M.CLOAK_OFF_FRAC = 0.15   -- ...and below which it decloaks
M.BUILD_RETRY    = 1800   -- re-issue the safe-spot builds if nothing appeared
M.MAP_MARGIN     = 400

local CMD_MOVE  = 10
local CMD_CLOAK = (CMD and CMD.CLOAK) or 37382
local OPT_SHIFT = (CMD and CMD.OPT_SHIFT) or 32

-- ── State ─────────────────────────────────────────────────────────────────────

local UQ
local myTeamID, myAllyID
local retired    = false
local evading    = false
local lastDanger = -1e9
local lastOrder  = -1e9
local safeX, safeZ = nil, nil
local buildsIssued = nil    -- frame the safe-spot builds were ordered
local cloaked    = nil

function M.Init(opts)
    UQ = opts.UQ
    myTeamID, myAllyID = opts.teamID, opts.allyID
end

function M.Retired() return retired end
function M.SafeSpot() return safeX, safeZ end

local function Clock(frame)
    return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60)
end

local function Clamp(x, z)
    local mx, mz = Game.mapSizeX or 12288, Game.mapSizeZ or 12288
    return math.max(M.MAP_MARGIN, math.min(mx - M.MAP_MARGIN, x)),
           math.max(M.MAP_MARGIN, math.min(mz - M.MAP_MARGIN, z))
end

local function IsNanoDef(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and d.isBuilder and not d.isFactory and not d.canFly
       and (d.speed == nil or d.speed == 0)
end

-- Behind home, away from the foe; snapped next to the nearest nano turret if close.
function M.PickSafeSpot(homeX, homeZ, foeX, foeZ)
    local dx, dz = (homeX - (foeX or homeX)), (homeZ - (foeZ or homeZ))
    local d = math.sqrt(dx * dx + dz * dz)
    if d < 1 then dx, dz, d = 0, 0, 1 end
    local x, z = Clamp(homeX + dx / d * M.BACK_DIST, homeZ + dz / d * M.BACK_DIST)
    local best, bestD2 = nil, M.NANO_SNAP ^ 2
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        if IsNanoDef(Spring.GetUnitDefID(uid)) then
            local nx, _, nz = Spring.GetUnitPosition(uid)
            if nx then
                local d2 = (nx - x) ^ 2 + (nz - z) ^ 2
                if d2 < bestD2 then best, bestD2 = { nx, nz }, d2 end
            end
        end
    end
    if best then
        -- Stand beside the nano on the far side from the enemy, not on top of it.
        x, z = Clamp(best[1] + dx / d * 96, best[2] + dz / d * 96)
    end
    return x, z
end

-- Armed enemies near the commander, and reported attacks near it.  Returns the
-- centre of the danger, or nil.
local function Danger(cx, cz, threats)
    local sx, sz, n = 0, 0, 0
    local bx, bz, blips = 0, 0, 0
    for _, uid in ipairs(Spring.GetUnitsInCylinder(cx, cz, M.DANGER_RADIUS) or {}) do
        if Spring.GetUnitAllyTeam(uid) ~= myAllyID then
            local defID = Spring.GetUnitDefID(uid)
            local x, _, z = Spring.GetUnitPosition(uid)
            if x and not defID then
                bx, bz, blips = bx + x, bz + z, blips + 1
            elseif x and UQ.has_weapons(defID) and not UQ.is_scout(defID) then
                sx, sz, n = sx + x, sz + z, n + 1
            end
        end
    end
    -- Radar blips have no def.  One is usually a scout passing over, and dodging it
    -- would pull the commander off the opening for nothing; a group is a raid.
    if blips >= M.BLIP_GROUP then sx, sz, n = sx + bx, sz + bz, n + blips end
    for _, t in ipairs(threats or {}) do
        if (t.x - cx) ^ 2 + (t.z - cz) ^ 2 <= M.THREAT_RADIUS ^ 2 then
            sx, sz, n = sx + t.x, sz + t.z, n + 1
        end
    end
    if n == 0 then return nil end
    return sx / n, sz / n
end

-- Cheapest static def the commander can build that passes `test(def)`.
local function CheapestBuildable(comDefID, test)
    local bd = UnitDefs[comDefID]
    local best, bestCost = nil, math.huge
    for _, opt in ipairs((bd and bd.buildOptions) or {}) do
        local od = UnitDefs[opt]
        if od and (od.speed or 0) == 0 and not od.isFactory and test(od) then
            local c = (od.metalCost or 0) + (od.energyCost or 0) / 70
            if c < bestCost then best, bestCost = opt, c end
        end
    end
    return best
end

local function FindSpot(defID, x, z, skip)
    for r = 64, 320, 64 do
        for a = 0, 7 do
            local ang = (a + r / 64 * 0.5) * math.pi / 4
            local bx, bz = x + r * math.cos(ang), z + r * math.sin(ang)
            if Spring.Pos2BuildPos then
                local px, _, pz = Spring.Pos2BuildPos(defID, bx, 0, bz)
                if px then bx, bz = px, pz end
            end
            local key = math.floor(bx) .. "," .. math.floor(bz)
            local y = Spring.GetGroundHeight(bx, bz) or 0
            local ok = Spring.TestBuildOrder(defID, bx, y, bz, 0)
            if ok and ok ~= 0 and not skip[key] then
                skip[key] = true
                return bx, y, bz
            end
        end
    end
    return nil
end

local function OwnCount(defID, x, z, radius)
    local n = 0
    for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, radius, myTeamID) or {}) do
        if Spring.GetUnitDefID(uid) == defID then n = n + 1 end
    end
    return n
end

-- Jammer + AA at the safe spot, shift-queued so the commander does them in turn.
local function IssueBuilds(frame, comID)
    local comDef = Spring.GetUnitDefID(comID)
    if not comDef then return end
    local jam = CheapestBuildable(comDef, function(od)
        return (od.jammerRadius or 0) > 0 and not (od.weapons and #od.weapons > 0)
    end)
    local aa = CheapestBuildable(comDef, function(od)
        return UQ.is_dedicated_aa(od.id)
    end)
    local skip, n = {}, 0
    if jam and OwnCount(jam, safeX, safeZ, 500) == 0 then
        local x, y, z = FindSpot(jam, safeX, safeZ, skip)
        if x then
            Spring.GiveOrderToUnit(comID, -jam, { x, y, z, 0 }, n > 0 and OPT_SHIFT or 0)
            n = n + 1
        end
    end
    if aa then
        for _ = OwnCount(aa, safeX, safeZ, 500) + 1, M.AA_TURRETS do
            local x, y, z = FindSpot(aa, safeX, safeZ, skip)
            if x then
                Spring.GiveOrderToUnit(comID, -aa, { x, y, z, 0 }, n > 0 and OPT_SHIFT or 0)
                n = n + 1
            end
        end
    end
    buildsIssued = frame
    if n > 0 then
        Spring.Echo(string.format("[CG] %s commander builds %d defences at its safe spot (%s%s)",
            Clock(frame), n, jam and UnitDefs[jam].name or "no jammer",
            aa and (", " .. UnitDefs[aa].name) or ", no AA"))
    end
end

local function UpdateCloak(comID, res)
    local d = UnitDefs[Spring.GetUnitDefID(comID) or -1]
    if not (d and d.canCloak) then return end
    local frac = (res.energyStorage or 0) > 0 and res.energy / res.energyStorage or 0
    local spare = (res.energyIncome or 0) - (res.energyPull or 0)
    local want = cloaked
    if frac >= M.CLOAK_ON_FRAC and spare >= (d.cloakCost or 0) then want = true
    elseif frac < M.CLOAK_OFF_FRAC then want = false end
    if want ~= nil and want ~= cloaked then
        Spring.GiveOrderToUnit(comID, CMD_CLOAK, { want and 1 or 0 }, 0)
        cloaked = want
    end
end

function M.Update(frame, comID, res, opts)
    if not comID or not Spring.GetUnitDefID(comID) then return "free" end
    local cx, _, cz = Spring.GetUnitPosition(comID)
    if not cx then return "free" end

    local dx, dz = Danger(cx, cz, opts.threats)
    if dx then
        lastDanger = frame
        if not evading or frame - lastOrder >= M.ORDER_EVERY then
            local ax, az = cx - dx, cz - dz
            local d = math.sqrt(ax * ax + az * az)
            if d < 1 then
                ax, az = (opts.homeX or cx) - (opts.foeX or cx), (opts.homeZ or cz) - (opts.foeZ or cz)
                d = math.max(1, math.sqrt(ax * ax + az * az))
            end
            local fx, fz = Clamp(cx + ax / d * M.FLEE_DIST, cz + az / d * M.FLEE_DIST)
            Spring.GiveOrderToUnit(comID, CMD_MOVE, { fx, Spring.GetGroundHeight(fx, fz) or 0, fz }, 0)
            lastOrder = frame
            if not evading then
                Spring.Echo(string.format("[CG] %s commander evading threat at %d,%d",
                    Clock(frame), dx, dz))
            end
            evading = true
        end
        return "evading"
    end
    if evading and frame - lastDanger < M.CLEAR_HOLD then return "evading" end
    if evading then
        evading = false
        lastOrder = -1e9
        buildsIssued = nil     -- anything half-built at the safe spot may be gone
    end

    if not retired and opts.retire then
        retired = true
        Spring.Echo(string.format("[CG] %s commander retired from the build order", Clock(frame)))
    end
    if not retired then return "free" end

    if not safeX and opts.homeX then
        safeX, safeZ = M.PickSafeSpot(opts.homeX, opts.homeZ, opts.foeX, opts.foeZ)
    end
    if not safeX then return "retired" end

    -- RETURN_DIST is wider than the build spiral plus build range, so walking to its
    -- own build sites never reads as having strayed (a MOVE would cancel the builds).
    local d2 = (cx - safeX) ^ 2 + (cz - safeZ) ^ 2
    if d2 > M.RETURN_DIST ^ 2 or (d2 > M.ARRIVE_DIST ^ 2 and not buildsIssued) then
        if frame - lastOrder >= M.ORDER_EVERY then
            Spring.GiveOrderToUnit(comID, CMD_MOVE,
                { safeX, Spring.GetGroundHeight(safeX, safeZ) or 0, safeZ }, 0)
            lastOrder = frame
        end
    elseif not buildsIssued or frame - buildsIssued >= M.BUILD_RETRY then
        IssueBuilds(frame, comID)
    end
    UpdateCloak(comID, res)
    return "retired"
end

return M
