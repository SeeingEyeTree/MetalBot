-- bar_framework/scout_lanes.lua   (LINE_CLICK only; scout_plan.lua is untouched and shared by the other bots)
-- scout_plan.lua with a different FIND mode: a lane sweep of the ENEMY half (see "FIND is a lane
-- sweep" below) instead of a nearest-stale-sector walk.  Same API as scout_plan (Init, Observe, Plan,
-- Mode, FoeFound, Forget), plus LaneOf / Corner for tests.  PICKET mode is unchanged.
--
-- Where scouts should be, in two distinct phases.
--
-- WHY TWO MODES
-- -------------
-- Scouting answers two different questions at two different points in the game,
-- and a single sweep does neither well:
--
--   FIND   -- early.  Where did they spawn?  Spawns sit anywhere along a strip on
--             each side, so the symmetric-mirror guess can be well off along that
--             strip.  Knowing the real spawn tells us which direction to watch and
--             where to send attackers.  This is exploration: cover ground, fast.
--
--   PICKET -- once found, and once the economy can carry it.  Now the question is
--             "is something coming?", and the answer is worth more the earlier it
--             arrives.  This is not exploration: scouts park on the approach
--             corridor, as far forward as they can survive, to maximise warning time.
--             The tracker's first_enemy_near_base lead_frames is the number this
--             mode exists to move -- it was ~0 before this module.
--
-- The find-mode scoring is ported from bot.lua's AssignScoutOrder (:4349), which
-- already worked: staleness^3, a corner boost, and a SOFT penalty on our own half.
-- Keep the penalty soft.  bot.lua's own comment: a hard exclusion is cheesable, and
-- a turtling enemy on our side would never be found.
--
-- USAGE
--   local SP = VFS.Include("LuaUI/Widgets/bar_framework/scout_plan.lua")
--   SP.Init{ MM = MM, UQ = UQ, TM = TM }
--   SP.Observe(frame, allOwnMobileUnitIDs)     -- marks sectors fresh
--   local targets = SP.Plan(frame, scoutIDs, metalIncome)
--   for uid, t in pairs(targets) do ARMY.Claim(ARMY.PRIO.SCOUT, uid, t, frame) end

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.OUR_HALF_PENALTY  = 0.02   -- (old scoring, unused by the lane sweep below)
M.CORNER_BOOST_MAX  = 5      -- (old scoring, unused by the lane sweep below)
M.SECTOR_FRESH      = 300    -- frames a visited sector stays "recently seen" (a scout has arrived)
-- FIND is a lane sweep, not a nearest-sector walk.  The enemy spawns on the other side of the map
-- (the engine's spawn boxes would say no more than that), never in the corners, so:
--   * scout 1 goes to one far corner of the ENEMY half and scout 2 to the other, and each sweeps
--     inward toward the middle, nearest unseen sector first, preferring to move toward the centre line;
--   * only when the enemy half is swept (3 min between visits) does a scout look at our half.
-- (A hard exclusion of our half would let a turtling enemy on our side hide for ever, so our half is
-- the last tier, not never.)
M.FIND_FRESH        = 5400   -- frames before the sweep revisits a sector it has already seen
M.CORNER_MARGIN     = 500    -- the corner a scout is sent to, this far in from the map edge
M.INWARD_BIAS       = 0.6    -- up to +60% score for sectors nearer the middle of the enemy's spawn region
-- Pickets sit on an ARC around our own base, not a line across the midline.
-- The first version put a straight line at 42% of the way to the enemy, and it was
-- worse on every warning metric than having no pickets at all (warned_dist 522 vs
-- ~1900, lead_frames 0 vs 90): scouts parked in contested ground died, and a short
-- line on a flat 12k-wide map with no chokepoints is simply walked around.  Every
-- attacker has to cross a ring around the base eventually, whatever direction it
-- comes from, so a ring cannot be bypassed -- and inside our own half the pickets
-- live.  Less lead than a far picket in theory; far more than a dead one in practice.
M.PICKET_RADIUS     = 0.24   -- ring radius as a fraction of home->foe distance
M.PICKET_ARC        = 1.22   -- half-width of the watched arc, radians (~70 deg)
M.PICKET_MIN_INCOME = 40     -- metal/s before pickets are worth their upkeep

-- ── State ─────────────────────────────────────────────────────────────────────

local MM, UQ, TM
local myAllyID = nil
local sectors, sectorSize = nil, nil
local sectorOf  = {}   -- [unitID] = sector key it is heading for
local foeFound  = false
local mode      = "find"

-- The ally ID is passed in rather than read from Spring.GetMyAllyTeamID(): the test
-- harness patches team IDs in bot files only, and bar_framework is copied unpatched.
function M.Init(opts)
    MM, UQ, TM = opts.MM, opts.UQ, opts.TM
    myAllyID = opts.allyID
end

local function EnsureSectors()
    if sectors or not (MM and MM.Ready()) then return end
    sectors, sectorSize = MM.BuildSectors(nil, 200)
end

function M.Mode() return mode end
function M.FoeFound() return foeFound end

-- ── Observation ───────────────────────────────────────────────────────────────

-- Any own unit standing in a sector has seen it, and so has anything whose centre is
-- in line of sight -- a scout never needs to walk into the middle of a sector to
-- clear it.  Counting every mobile unit, not just scouts, means the army maintains
-- the map for free as it moves.
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

-- Has a scout found the enemy base?  A building or commander pins it; mobile units
-- do not, since raiders are exactly the things that are NOT at home.
local function CheckFoe()
    if foeFound or not TM then return end
    local sx, sz, n = 0, 0, 0
    for _, c in pairs(TM.Contacts()) do
        local d = c.defID and UnitDefs[c.defID]
        if d and (d.isBuilding or d.isFactory or UQ.is_commander(c.defID)
                  or (d.speed or 0) == 0) then
            sx, sz, n = sx + c.x, sz + c.z, n + 1
        end
    end
    if n > 0 then
        foeFound = true
        MM.SetFoe(sx / n, sz / n, "sighted")
    end
end

-- ── Planning ──────────────────────────────────────────────────────────────────

local function Dist2(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end
local laneOf      = {}   -- [unitID] = -1 | +1: which enemy-side corner (by lateral side) it sweeps from
local cornerDone  = {}   -- [unitID] = true once it has been to its corner

-- The enemy-half map corner on one lateral side (lane -1 = the most negative lateral, +1 = the most
-- positive).  nil if no corner is on the enemy side.
local function LaneCorner(lane)
    local mx, mz = MM.MapSize()
    local m = M.CORNER_MARGIN
    local best
    for _, c in ipairs({ { m, m }, { mx - m, m }, { m, mz - m }, { mx - m, mz - m } }) do
        if not MM.IsOurHalf(c[1], c[2]) then
            local lat = MM.Lateral(c[1], c[2])
            if not best or (lane < 0 and lat < best.lat) or (lane > 0 and lat > best.lat) then
                best = { x = c[1], z = c[2], lat = lat }
            end
        end
    end
    return best
end

-- The sector whose centre is nearest a point (corner sectors can have their centre trimmed off by the
-- grid margin, so a plain key lookup would miss them).
local function NearestSector(x, z)
    local bestKey, bestD
    for key, s in pairs(sectors) do
        local d = (s.x - x) ^ 2 + (s.z - z) ^ 2
        if not bestD or d < bestD then bestKey, bestD = key, d end
    end
    return bestKey
end

-- Give a new scout a lane: -1 if free, else +1, else alternate.
local function AssignLane(uid, scoutIDs)
    if laneOf[uid] then return end
    local used = { [-1] = 0, [1] = 0 }
    for _, other in ipairs(scoutIDs) do
        if other ~= uid and laneOf[other] then used[laneOf[other]] = used[laneOf[other]] + 1 end
    end
    laneOf[uid] = (used[-1] <= used[1]) and -1 or 1
end

-- Worth a look: never seen, or not seen for FIND_FRESH.  (lastScouted starts at 0, so "frame - 0 >
-- FIND_FRESH" alone would leave every sector off limits for the first three minutes.)
local function Unseen(s, frame)
    return s.lastScouted == 0 or frame - s.lastScouted > M.FIND_FRESH
end

local function FindTarget(uid, frame, taken)
    local ux, _, uz = Spring.GetUnitPosition(uid)
    if not ux then return nil end
    local lane = laneOf[uid]

    -- 1. its corner first: the far end of the enemy half, where the sweep starts
    if lane and not cornerDone[uid] then
        local c = LaneCorner(lane)
        local key = c and NearestSector(c.x, c.z)
        local s = key and sectors[key]
        if s and not taken[key] and Unseen(s, frame) then return key end
        cornerDone[uid] = true
    end

    -- 2. then inward: the nearest unseen sector on the enemy half, its own lane before the other,
    --    leaning toward the centre line; our half only when the enemy half is done.
    -- "inward" = toward the middle of where the enemy can spawn: the symmetric (mirror) spawn estimate
    local mx, mz = MM.MapSize()
    local span = math.max(mx, mz)
    local ex, ez = MM.Foe()
    local bestKey, bestTier, bestScore = nil, 99, -1
    for key, s in pairs(sectors) do
        if not taken[key] and Unseen(s, frame) then
            local lat = MM.Lateral(s.x, s.z)
            local tier
            if MM.IsOurHalf(s.x, s.z) then tier = 3
            elseif not lane or (lat < 0) == (lane < 0) then tier = 1
            else tier = 2 end
            local dist = math.sqrt((s.x - ux) ^ 2 + (s.z - uz) ^ 2)
            local inward = 1 + M.INWARD_BIAS * (1 - math.min(1, Dist2(s.x, s.z, ex, ez) / span))
            local score = inward / (dist + 250)
            if tier < bestTier or (tier == bestTier and score > bestScore) then
                bestKey, bestTier, bestScore = key, tier, score
            end
        end
    end
    return bestKey
end

-- Picket posts spread evenly across the arc of the ring that faces the enemy.
-- Centred on the real home->foe axis, so the watched side is wherever they actually
-- spawned rather than a compass direction.
local function PicketPosts(count)
    local posts = {}
    if count <= 0 then return posts end
    local hx, hz = MM.Home()
    local ax, az = MM.Axis()
    local radius = MM.Dist() * M.PICKET_RADIUS
    local centre = math.atan2(az, ax)
    for i = 1, count do
        local t = (count == 1) and 0 or ((i - 1) / (count - 1)) * 2 - 1
        local a = centre + t * M.PICKET_ARC
        local x, z = MM.Clamp(hx + math.cos(a) * radius, hz + math.sin(a) * radius, 200)
        posts[#posts + 1] = { x = x, z = z }
    end
    return posts
end

-- Decide each scout's target.  Returns {[unitID] = claim spec} for the caller to
-- hand to the army broker; this module never issues orders itself.
function M.Plan(frame, scoutIDs, metalIncome)
    EnsureSectors()
    if not sectors then return {} end
    CheckFoe()

    if mode == "find" and foeFound and (metalIncome or 0) >= M.PICKET_MIN_INCOME then
        mode = "picket"
        sectorOf = {}
        Spring.Echo(string.format("[SP] foe located, switching to picket ring r=%d (%d%% of %d)",
            math.floor(MM.Dist() * M.PICKET_RADIUS), math.floor(M.PICKET_RADIUS * 100), MM.Dist()))
    end

    local out = {}

    if mode == "picket" then
        local posts = PicketPosts(#scoutIDs)
        -- Nearest-post assignment, each post taken once.  Stable enough in
        -- practice: posts only move when the foe estimate does.
        local used = {}
        for _, uid in ipairs(scoutIDs) do
            local ux, _, uz = Spring.GetUnitPosition(uid)
            if ux then
                local best, bestD = nil, math.huge
                for i, p in ipairs(posts) do
                    if not used[i] then
                        local d = (p.x - ux) ^ 2 + (p.z - uz) ^ 2
                        if d < bestD then best, bestD = i, d end
                    end
                end
                if best then
                    used[best] = true
                    out[uid] = { role = "SCOUT", cmd = 10,
                                 x = posts[best].x, z = posts[best].z }
                end
            end
        end
        return out
    end

    -- FIND: one scout per sector, re-targeting only when the current sector has
    -- been seen (by anyone) or was never assigned.
    local taken = {}
    for uid, key in pairs(sectorOf) do
        if sectors[key] and frame - sectors[key].lastScouted > M.SECTOR_FRESH then
            taken[key] = true
        else
            sectorOf[uid] = nil
        end
    end
    for _, uid in ipairs(scoutIDs) do AssignLane(uid, scoutIDs) end
    for _, uid in ipairs(scoutIDs) do
        local key = sectorOf[uid]
        if not key then
            key = FindTarget(uid, frame, taken)
            if key then sectorOf[uid] = key; taken[key] = true end
        end
        if key then
            local s = sectors[key]
            out[uid] = { role = "SCOUT", cmd = 10, x = s.x, z = s.z }
        end
    end
    return out
end

function M.Forget(unitID)
    sectorOf[unitID], laneOf[unitID], cornerDone[unitID] = nil, nil, nil
end

-- For tests and logs: the lane a scout sweeps (-1 / +1) and its corner.
function M.LaneOf(unitID) return laneOf[unitID] end
function M.Corner(lane) return LaneCorner(lane) end

return M
