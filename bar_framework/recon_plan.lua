-- bar_framework/recon_plan.lua
-- Scouting after the enemy has been found: keep looking at what they are doing.
--
-- WHY THIS EXISTS
-- ---------------
-- scout_plan.lua answers "where did they spawn" (FIND) and then parks every scout on
-- a picket ring for early warning (PICKET).  After that nobody ever looks at the
-- enemy base again.  game_mechanics 6.2 says scouting is "purely about finding the
-- enemy and tracking their army/production state" -- and an air lab going up, a T2
-- lab, or the commander wandering off are exactly the things that only a look at
-- their side of the map can tell us.
--
-- This module adds two duties on top of scout_plan:
--
--   RECON  -- one or two scouts keep refreshing the enemy half, weighted toward their
--             base and toward sectors where we remember buildings.  Sectors covered
--             by known anti-air are skipped until they have been dark long enough
--             that the information is worth risking a scout for.
--   HUNT   -- game_mechanics 9: once the game is won, sweep the whole map for the
--             commander.  No half-penalty, and the commander's last known position is
--             the most interesting place on the map once that sighting goes stale.
--
-- It uses its own sector grid so scout_plan's picket/find bookkeeping is untouched.
--
-- USAGE
--   local RP = VFS.Include("LuaUI/Widgets/bar_framework/recon_plan.lua")
--   RP.Init{ MM = MM, EI = EI, UQ = UQ, allyID = myAllyID }
--   RP.Observe(frame, allOwnMobileUnitIDs)
--   for uid, spec in pairs(RP.Plan(frame, reconScoutIDs, hunting)) do
--       ARMY.Claim(ARMY.PRIO.SCOUT, uid, spec, frame)
--   end

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.RECON_FRESH      = 1800   -- a sector seen within 60 s is not worth a recon trip
M.ENEMY_BASE_R     = 2500   -- the tracker's ZONE_R: "the enemy base"
M.ENEMY_BASE_BOOST = 4
M.STRUCTURE_BOOST  = 0.5    -- per remembered structure in the sector, capped below
M.STRUCTURE_CAP    = 6
M.OUR_HALF_WEIGHT  = 0.1    -- the pickets already watch our half
M.AA_AVOID         = 150    -- EI.ThreatAt value above which a sector is avoided...
M.AA_RISK_AGE      = 5400   -- ...unless it has been dark for 3 min
M.TARGET_TIMEOUT   = 1800   -- give up on a target not reached in 60 s
M.STALE_CAP        = 5400   -- staleness stops growing after 3 min, so one ancient
                            -- corner cannot outweigh the enemy base forever
M.COMMANDER_BOOST  = 10     -- hunt: the commander's last known sector
M.DIST_SOFTEN      = 3000   -- see SectorScore

-- ── State ─────────────────────────────────────────────────────────────────────

local MM, EI, UQ
local myAllyID
local sectors, sectorSize = nil, nil
local targetOf = {}   -- [unitID] = {key, since}

function M.Init(opts)
    MM, EI, UQ = opts.MM, opts.EI, opts.UQ
    myAllyID = opts.allyID
end

local function EnsureSectors()
    if sectors or not (MM and MM.Ready()) then return end
    sectors, sectorSize = MM.BuildSectors(nil, 200)
end

-- Same rule as scout_plan: anything standing in a sector, or a sector centre in LOS,
-- counts as seen.
function M.Observe(frame, unitIDs)
    EnsureSectors()
    if not sectors then return end
    for i = 1, #unitIDs do
        local x, _, z = Spring.GetUnitPosition(unitIDs[i])
        if x then
            local s = sectors[MM.SectorKey(x, z, sectorSize)]
            if s then s.lastScouted = frame end
        end
    end
    if Spring.IsPosInLos and myAllyID then
        for _, s in pairs(sectors) do
            if Spring.IsPosInLos(s.x, 0, s.z, myAllyID) then s.lastScouted = frame end
        end
    end
end

-- Remembered enemy structures per sector: where their economy and production is.
local function StructureCounts()
    local counts = {}
    if not EI then return counts end
    for _, rec in pairs(EI.Records()) do
        if not rec.c.mobile then
            local key = MM.SectorKey(rec.x, rec.z, sectorSize)
            counts[key] = (counts[key] or 0) + 1
        end
    end
    return counts
end

-- How much is a look at this sector worth right now?  nil = not worth going.
function M.SectorScore(frame, s, key, counts, channel, hunting, cx, cz, ux, uz)
    local stale = frame - s.lastScouted
    if stale < M.RECON_FRESH then return nil end
    stale = math.min(stale, M.STALE_CAP)

    local w = 1
    local fx, fz = MM.Foe()
    if not hunting then
        if MM.IsOurHalf(s.x, s.z) then w = w * M.OUR_HALF_WEIGHT end
        if fx and (s.x - fx) ^ 2 + (s.z - fz) ^ 2 <= M.ENEMY_BASE_R ^ 2 then
            w = w * M.ENEMY_BASE_BOOST
        end
    elseif cx and MM.SectorKey(cx, cz, sectorSize) == key then
        w = w * M.COMMANDER_BOOST
    end
    local n = counts[key] or 0
    if n > 0 then w = w * (1 + M.STRUCTURE_BOOST * math.min(n, M.STRUCTURE_CAP)) end

    if EI and stale < M.AA_RISK_AGE
       and EI.ThreatAt(frame, s.x, s.z, channel) > M.AA_AVOID then
        return nil
    end

    -- A soft distance term: an air scout crosses the whole map in under a minute, so
    -- a far but important sector (their base) should beat a near, empty one.
    local dist = math.sqrt((s.x - ux) ^ 2 + (s.z - uz) ^ 2)
    return stale * stale * w / (dist + M.DIST_SOFTEN)
end

local function PickTarget(frame, uid, taken, counts, hunting)
    local ux, _, uz = Spring.GetUnitPosition(uid)
    if not ux then return nil end
    local defID = Spring.GetUnitDefID(uid)
    local channel = (UQ and defID and UQ.is_air(defID)) and "air" or "ground"
    local cx, cz, cf = nil, nil, nil
    if EI then cx, cz, cf = EI.Commander() end
    -- A fresh commander sighting needs no search; only a stale one does.
    if cf and frame - cf < 900 then cx, cz = nil, nil end

    local bestKey, bestScore = nil, 0
    for key, s in pairs(sectors) do
        if not taken[key] then
            local score = M.SectorScore(frame, s, key, counts, channel, hunting, cx, cz, ux, uz)
            if score and score > bestScore then bestKey, bestScore = key, score end
        end
    end
    return bestKey
end

-- Targets for the scouts handed to recon.  Returns {[unitID] = claim spec}.
function M.Plan(frame, scoutIDs, hunting)
    EnsureSectors()
    if not sectors then return {} end
    local counts = StructureCounts()

    -- Drop targets that are done (seen by anyone), timed out, or whose scout is gone.
    local mine = {}
    for _, uid in ipairs(scoutIDs) do mine[uid] = true end
    local taken = {}
    for uid, t in pairs(targetOf) do
        local s = sectors[t.key]
        if not mine[uid] or not s or frame - s.lastScouted < M.RECON_FRESH
           or frame - t.since > M.TARGET_TIMEOUT then
            targetOf[uid] = nil
        else
            taken[t.key] = true
        end
    end

    local out = {}
    for _, uid in ipairs(scoutIDs) do
        local t = targetOf[uid]
        if not t then
            local key = PickTarget(frame, uid, taken, counts, hunting)
            if key then
                t = { key = key, since = frame }
                targetOf[uid] = t
                taken[key] = true
            end
        end
        if t then
            local s = sectors[t.key]
            out[uid] = { role = "SCOUT", cmd = 10, x = s.x, z = s.z }
        end
    end
    return out
end

function M.Forget(unitID) targetOf[unitID] = nil end

-- Most recent frame any sector within `radius` of (x, z) was seen; nil if unknown.
function M.LastSeenNear(x, z, radius)
    if not (sectors and x) then return nil end
    local best = nil
    for _, s in pairs(sectors) do
        if (s.x - x) ^ 2 + (s.z - z) ^ 2 <= radius * radius and s.lastScouted > 0
           and (not best or s.lastScouted > best) then
            best = s.lastScouted
        end
    end
    return best
end

return M
