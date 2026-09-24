-- bar_framework/scout_plan.lua
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

M.OUR_HALF_PENALTY  = 0.02   -- soft, never zero (see header)
M.CORNER_BOOST_MAX  = 5      -- up to 5x toward corners, 1x at centre
M.SECTOR_FRESH      = 300    -- frames a visited sector stays "recently seen"
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

local function FindTarget(uid, frame, taken)
    local ux, _, uz = Spring.GetUnitPosition(uid)
    if not ux then return nil end
    local mx, mz   = MM.MapSize()
    local cx, cz   = mx * 0.5, mz * 0.5
    local maxCorner = math.sqrt(cx * cx + cz * cz)

    local bestKey, bestScore = nil, -math.huge
    for key, s in pairs(sectors) do
        if not taken[key] and frame - s.lastScouted > M.SECTOR_FRESH then
            local dist      = math.sqrt((s.x - ux) ^ 2 + (s.z - uz) ^ 2)
            local staleness = frame - s.lastScouted
            -- 1x at the centre rising to CORNER_BOOST_MAX at the corners.  NOTE:
            -- bot.lua's version (:4428) is inverted -- its comment says "up to 5x at
            -- the corners" but it computes `1 - dist/max`, which is 5x at the CENTRE
            -- and 1x at the corners.  This implements the stated intent.  Do not
            -- "restore" the 1 - form when comparing against bot.lua.
            local fromCentre = math.sqrt((s.x - cx) ^ 2 + (s.z - cz) ^ 2)
            local corner    = 1 + math.max(0, fromCentre / math.max(1, maxCorner))
                                  * (M.CORNER_BOOST_MAX - 1)
            local score = staleness * staleness * staleness * corner / (dist + 250)
            if MM.IsOurHalf(s.x, s.z) then score = score * M.OUR_HALF_PENALTY end
            if score > bestScore then bestKey, bestScore = key, score end
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

function M.Forget(unitID) sectorOf[unitID] = nil end

return M
