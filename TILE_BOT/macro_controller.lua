-- macro_controller.lua  ─  TILE_BOT: con-bot tile opening, then mex-grid scaling (COR)
--
-- DRAGON_BOT's spiral kick-starter replaced by the pattern a human player used to reach
-- ~30k metal spent by 7:00 without ever banking (see TILE_BOT/GOAL.md):
--   1. The commander builds blueprints/general/bad_com_start.lua (mex, mex, wind, wind,
--      bot lab, winds, nano, mexes, winds, radar) through blueprint_placer's distributed
--      mode.  It cannot build nano turrets, so con #1 joins that queue for the nano and
--      the commander GUARDs it meanwhile.
--   2. Up to 4 con bots, one per row of a 4x4 block of con_bot_grid tiles
--      (bar_framework/tile_crew.lua).  Each walks to its tile's centre and builds the
--      whole tile from there, choosing energy / metal / build power by interrupt.  The
--      next con is queued only when metal reaches CON_BANK_TRIGGER (or a fallback
--      timer), so the lab never starves the opening.
--   3. The commander then assists: the lab while it has a con queued, otherwise the
--      nearest con still building.
--
-- HAND-OFF.  Once metal income passes AIR_LAB_INCOME an air lab goes into the open area
-- of a finished tile (never the one the bot lab exits into), and the grid system takes
-- over: air cons each run a mex_grid_alab blueprint, growing outward from the edges of
-- the tile block (which is exactly 2x2 grid cells).

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID     = Spring.GetMyTeamID
local spGetGroundHeight = Spring.GetGroundHeight
local spGetUnitCommands = Spring.GetUnitCommands
local spGetTeamUnits    = Spring.GetTeamUnits
local spGetFactoryCommands = Spring.GetFactoryCommands

local CMD_GUARD   = (CMD and CMD.GUARD)   or 25
local CMD_REPAIR  = (CMD and CMD.REPAIR)  or 40
local CMD_RECLAIM = (CMD and CMD.RECLAIM) or 90
local CMD_STOP    = 0
local CMD_STOCKPILE = (CMD and CMD.STOCKPILE) or 117

-- Con bots: one per tile row.  Making all four at once slows the opening down, so the
-- next one is queued only once metal is piling up (the opening is spending everything
-- it earns until then) or, failing that, after a fallback delay.
-- (One table: this file is near Lua 5.1's 200-locals-per-chunk limit.)
local CFG = {
    MAX_CONS            = 4,
    CON_BANK_TRIGGER    = 130,       -- metal in the bank that queues the next con
    CON_FALLBACK_FRAMES = 45 * 30,   -- ...or this long after the previous one finished
    CON1_RELEASE_WAIT   = 20 * 30,   -- frames con #1 may finish a com-start item first
    -- Tile interrupts.  Energy (look-ahead) and metal as for the grids, plus "bank": metal
    -- piling up means build power is short, so build a nano next.  It never preempts a
    -- frame in progress (noPreempt), it only picks the next job.
    BANK_NANO_METAL     = 300,       -- metal in the bank...
    BANK_NANO_FRAC      = 0.25,      -- ...and at least this share of storage
    -- Hand-off: an air lab once metal income reaches this, held for BANK_HOLD frames so a
    -- one-tick spike does not trigger it.  Tune from test matches (the reference replay's
    -- income was ~35 m/s at 3-4 min, ~57 at 4-5, ~87 at 5-6).
    AIR_LAB_INCOME      = 40,        -- m/s
    -- Grid pacing (ReleaseGridCandidates): grids "opening" at once, and the bank that
    -- lets one more open (at most every GRID_BANK_GAP frames).  The 30.9k-at-7:30 game had
    -- 1-2 grids open before 6:00; the 23.9k one opened 6 at 4:00.
    GRIDS_OPENING       = 2,
    GRID_BANK           = 500,
    GRID_BANK_GAP       = 15 * 30,
    -- ...and it waits for a finished tile outside row 0 to put it in, unless none is
    -- ready by this frame (then the old ring search outside the block is used).
    AIR_LAB_LATEST      = 7 * 60 * 30,
}
local BANK_HOLD          = 150         -- frames (5 s)
local AIR_LAB_MIN_NANOS = 2   -- nanos that must cover the air lab's spot
-- One air con runs a whole grid, so its travel between sites is the bottleneck.
-- Leave each frame this far along for the grid's nanos to finish, and fly on.
local GRID_HANDOFF      = 0.30
-- Air-con reserve.  A new grid opens the moment a neighbour reaches its nano threshold,
-- but its air con is only queued then, so every grid waited for a con to be built --
-- 32-74 s for the first four (queued together at 3:56, assigned 4:28-5:09), and the
-- growth rate is set by exactly this grid-to-grid latency (lessons_learned, "Scaling").
-- Keeping a couple of cons ready turns that wait into zero for ~110 metal each.
local AIR_CON_RESERVE   = 2

-- CAPSTONE: the one big building a mex grid is crowned with.  The blueprint asks
-- for a T2 air lab; any grid can take something else instead, which is how the
-- bot spends a grid's worth of ground on something other than more air.
--
-- The catch is WHO can build it.  A grid is run by a T1 air con (corca), and that
-- con can only place the T2 air lab -- a nuke needs a T2 con (coraca), a T2 bot
-- lab needs a con bot (corck), and nothing we own can place a T2 vehicle plant.
-- So a capstone the grid's own con cannot build is taken out of the grid's queue
-- and handed to a builder that can, rather than being retried forever.
local CAPSTONE_DEFAULT = "coraap"    -- T2 air lab, as the blueprint has it
local CAPSTONE_PLAN = {
    -- grid number (order assigned) -> what to crown it with
    [4] = "corsilo",                 -- nuke, to exercise the hand-off path
}

-- Retrofit: a finished mex grid is upgraded in place to T2 mexes + fusions by a
-- T2 air con.  The grid's own nanos assist, so build power that would otherwise
-- idle in a finished grid goes back to work, and T2 mexes raise income per unit
-- -- which matters once the unit cap, not metal, is the ceiling.
local UPGRADE_CONS_PER_LAB = 2     -- T2 air cons each advanced air lab builds
-- T2 mexes are LESS metal-efficient than T1, so a retrofit must never compete
-- with a normal grid for metal: while stalling, retrofit builders are stopped.
local RETROFIT_STALL_FRAC  = 0.15  -- stalling below this share of metal storage
local RETROFIT_RESUME_FRAC = 0.30  -- resume once comfortably above it

-- Wind consolidation.  A wind is 25 e/s for one unit slot; four of them in a 2x2
-- block can be replaced by ONE fusion (850 e/s) or one T2 mex (4x a T1 mex), so
-- once the unit cap is the binding constraint the swap is worth ~34x the energy
-- per slot.  Grid wind rows sit 48 elmos apart both inside a grid (216, 168, ...)
-- and ACROSS a grid boundary (216 vs 480-216 = 264), so the whole base is one
-- continuous 48-elmo lattice: the blocks are found centrally here rather than by
-- any one grid, which is what makes the ones straddling two grids anybody's job.
-- Headroom at which the cap counts as "tight".  Must be relative as well as
-- absolute: the DEFAULT cap is 2000, so a flat 2000 would read as tight from the
-- first frame of every game, and even 1000 is half of it.  Games here may be run
-- at 5000.
local CONSOLIDATE_SLACK  = 1000  -- absolute headroom...
local CAP_SLACK_FRAC     = 0.20  -- ...but never more than this share of the cap
local WIND_LATTICE       = 48    -- elmos between adjacent winds
local CONSOLIDATE_SCAN   = 300   -- frames between scans; one scan finds EVERY block,
                                 -- so jobs start every tick from the cached list
local CONSOLIDATE_MAX    = 60    -- blocks tracked at once, to bound the scan's cost

-- Wind reclaim is a plain nano task, not something idle builders drift into: one
-- air con is a few hundred build power against a base full of nanos, and an idle
-- nano near a half-reclaimed wind will happily REPAIR it back up, which is why
-- the old version crawled.  Every nano that can reach a condemned wind is put on
-- it, so none is left to fight over it.
local RECLAIM_TRIGGER_FRAC = 0.20  -- start when unit-cap headroom drops to this share
local RECLAIM_BUDGET_FRAC  = 0.02  -- winds condemned at once, as a share of the cap:
                                   -- enough to free real space, small enough that the
                                   -- energy loss is not a cliff
local RECLAIM_EVERY        = 90    -- frames between passes

-- Spend pressure.  Metal sitting in the bank is build power that was not used,
-- and the interrupts only react once a resource is nearly out -- so the bank
-- hovers at whatever the interrupt thresholds imply.  Rather than react to the
-- bank, watch PULL against INCOME: pull is what the builders are asking for, so
-- income above pull means we are under-spending and will bank, seconds before it
-- shows up in storage.  The response is to open more frames at once by handing
-- them to the nanos sooner.
local SPEND_FAST     = 0.15   -- handoff when under-spending: place more, finish less
local SPEND_SLOW     = 0.60   -- handoff when short: finish what is already started
local BANK_HIGH      = 0.25   -- stored metal share that counts as banking
local BANK_LOW       = 0.08   -- ...and as running dry
local START_FRAME     = 15    -- orders issued at frame 0 are dropped by the engine

-- Headroom below which the unit cap counts as tight (see CapSlack): the spine then puts
-- everything into units and stops opening cells.  (SPINE_BOT: the spine owns the unit/eco
-- split, so DRAGON_BOT's army/eco nano balancer is gone.)
local ARMY_CAP_SLACK  = 1000   -- also clamped by CAP_SLACK_FRAC, see CapSlack

-- Energy look-ahead for the grids.  blueprint_placer's energy interrupt fires once stored
-- energy is under 17% of storage.  With a ~6k energy storage up by ~3:30 that is too late:
-- every grid opens with 12 nano turrets before its first wind, four grids start within a
-- minute, pull outruns income, the storage hides it, and when the interrupt finally fires
-- the winds cannot catch up.  Measured in four mirror runs: energy-stalled 60-90% of
-- 5:00-6:00 while 1.4-2.3k metal sat banked.  So the grids' energy check looks ahead: it
-- fires when stored energy is PROJECTED to cross the same threshold within
-- ENERGY_LOOKAHEAD seconds at the current (smoothed) net drain.
local ENERGY_LOOKAHEAD = 30     -- seconds
local ENERGY_LOW       = 0.17   -- the placer's own threshold (ENERGY_LOW_FRAC)
local NET_SMOOTH       = 0.1    -- EMA weight per 10-frame resource read (~3 s)
local GridInterrupts            -- defined next to ReadResources

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "Con-bot tile opening + mex grids (COR)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local DEBUG = false

-- ── Loaded in Initialize ──────────────────────────────────────────────────────
local BP_PLACER   = nil
local BUILD_ORDER = nil   -- the commander's tile: bad_com_start
local TILE_BP     = nil   -- every other tile: con_bot_grid
local TC          = nil   -- bar_framework/tile_crew
local NANO        = nil   -- nano_broker: single owner of every nano order
local SPINE       = nil   -- bar_framework/spine.lua (from SPINE_BOT), nil if it failed to load
local SPINE_BPS   = {}    -- kind -> blueprint, loaded in Initialize
local NANO_ASSIST_NUM = 1 -- nanos in BUILD_ORDER (the commander guards con #1 through them)

-- ── State ─────────────────────────────────────────────────────────────────────
local myTeamID    = nil
local commanderID = nil
local botLabID    = nil
local baseX, baseZ = nil, nil
local currentFrame = 0

local distState     = nil
local startPending  = false   -- anchor known, waiting for START_FRAME
local conBot1ID     = nil
local conBots       = {}      -- every con bot the build order produced
local conCount      = 0       -- con bots finished
local pendingCons   = {}      -- unitID -> true while still inside the lab
local pendingStops  = {}      -- {unitID, fireFrame}: deferred CMD_STOP orders
local conDefID      = nil
local nanoAssistDone = false
local comGuardTarget = nil    -- unitID the commander is currently guarding
local layout        = nil     -- TC.Layout: where the tile block goes
local crew          = nil     -- TC crew: the con bots building their rows
local TS = {                  -- tile-phase state (a table: see CFG)
    conOrderOpen  = false,    -- a con is queued in the lab and not out yet
    lastConFrame  = nil,      -- frame the previous con finished
    con1Released  = false,    -- con #1 has left the com-start queue for its row
    con1JoinFrame = nil,
    comGuardFrame = 0,        -- when the commander's guard was last (re)chosen
    airLabDone    = false,
    dispatched    = {},       -- con bots sent off to build radar
    reclaiming    = {},       -- unitID -> "con" | "bot lab": being eaten by the nanos
    airLabNanos   = {},       -- nanos we put on guarding the air lab
    gridCands     = {},       -- grid cells found but not opened yet (ReleaseGridCandidates)
    lastBankGrid  = -1e9,
    botLabReclaimed = false,
    botLabName    = nil,      -- the factory in bad_com_start: the con-bot lab
    airLabFailed  = {},       -- "x,z,f" air-lab spots that were queued and never started
}

-- ── Hand-off / grid expansion ────────────────────────────────────────────────
local MEX_GRID_BP     = nil
local GRID_SPACING    = nil
local bankFrames      = 0
local handoffStarted  = false
local airLabDefID     = nil
local airLabID        = nil
local airLabItem      = nil   -- the queue item for the hand-off lab
local airLabFrame     = nil   -- frame it was queued, for the watchdog below
local airLabWarned    = false
local airLabRetries   = 0

-- Vehicle plant (base defence), see "Vehicle plant for base defence" below.  Declared
-- up here because DispatchConBots reserves its builder before that section.
local vpQueued        = false
local vpDefID         = nil
local vpBuilder       = nil   -- a con bot held back from the radar trip to build it
local vpOrderFrame    = nil
local vpBuilt         = false
local airConDefID     = nil
local gridStates      = {}    -- one single-builder placer state per grid
local freeAirCons     = {}    -- air cons waiting for a grid
local pendingGrids    = {}    -- {anchorX, anchorZ, rotation} waiting for an air con
local assignedAnchors = {}    -- "x,z" -> true, every cell ever claimed
local completedAnchors = {}   -- {anchorX, anchorZ} list for FindAllValidPlacements
local completedKeys   = {}
local gridRotation    = {}    -- "x,z" -> rotation the grid was placed with
local allGridAnchors  = {}    -- every grid ever assigned: {anchorX, anchorZ, key}
local gridsAssigned   = 0     -- how many grids have been handed to a con
local airConsOrdered  = 0     -- T1 air cons ordered from the air lab, not yet finished
local lastReserveOrder = -1e9
local pendingSince    = {}    -- grid key -> frame it was queued (for the wait log)
local gridWaitSum, gridWaitN = 0, 0
local pendingCapstones = {}   -- capstones the grid's own con could not build
local capstoneJobs    = {}    -- one-item placer states building those
local UPGRADE_BP      = nil
local upgradeStates   = {}    -- retrofit placer states
local upgradedKeys    = {}    -- grids already assigned a retrofit
local gridFinished    = {}    -- grids whose own build order is COMPLETE
local freeT2Cons      = {}    -- T2 air cons waiting for a grid to upgrade
local retrofitPaused  = false
local consolidateOn   = false   -- unit cap is tight: stop building wind, start eating it
local consolidateJobs = {}      -- placer states replacing a 2x2 wind block
local consolidatedKeys = {}     -- "x,z" block centres already claimed
local windBlocks      = {}      -- found-but-unconverted blocks: {cx,cz,key,winds}
local windDefID       = nil
local reclaimingWinds = {}      -- windID -> true while nanos are eating it

local factories   = {}    -- unitID -> true, every finished factory we own

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsCommander(uDefID)
    local d = uDefID and UnitDefs[uDefID]
    if not d then return false end
    return d.customParams ~= nil
        and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
end

local function IsGroundCon(d)
    return d ~= nil and d.isBuilder and not d.canFly and not d.isFactory
       and d.speed and d.speed > 0
end

local function FindConBotDefID(labDefID)
    local d = UnitDefs[labDefID]
    if not d or not d.buildOptions then return nil end
    local best, bestCost = nil, math.huge
    for _, optID in ipairs(d.buildOptions) do
        local od = UnitDefs[optID]
        if IsGroundCon(od) then
            local cost = od.metalCost or 999999
            if cost < bestCost then bestCost = cost; best = optID end
        end
    end
    return best
end

-- A factory that can build a flying constructor.  Faction-agnostic: ask the unit
-- defs rather than hard-coding "corap".
-- The cheapest air factory that at least one builder we ACTUALLY OWN can place.
-- Asking only the commander (or falling back to a hard-coded name) can pick a def
-- none of our builders can build: the placer then never claims it, and the item
-- sits in the queue forever without a word.
local function FindAirFactoryDefID()
    local candidates = {}
    if commanderID and spGetUnitDefID(commanderID) then
        candidates[#candidates + 1] = commanderID
    end
    for _, b in ipairs((distState and distState.builders) or {}) do
        candidates[#candidates + 1] = b
    end

    local best, bestCost = nil, math.huge
    for _, uid in ipairs(candidates) do
        local bdID = spGetUnitDefID(uid)
        local bd   = bdID and UnitDefs[bdID]
        if bd and bd.buildOptions then
            for _, optID in ipairs(bd.buildOptions) do
                local od = UnitDefs[optID]
                if od and od.isFactory and od.buildOptions then
                    for _, subID in ipairs(od.buildOptions) do
                        local sd = UnitDefs[subID]
                        if sd and sd.isBuilder and sd.canFly and not sd.isFactory then
                            local cost = od.metalCost or math.huge
                            if cost < bestCost then bestCost = cost; best = optID end
                            break
                        end
                    end
                end
            end
        end
    end
    return best
end

local function FindAirConDefID(labDefID)
    local d = labDefID and UnitDefs[labDefID]
    if not d or not d.buildOptions then return nil end
    for _, optID in ipairs(d.buildOptions) do
        local od = UnitDefs[optID]
        if od and od.isBuilder and od.canFly and not od.isFactory then return optID end
    end
    return nil
end

-- Somewhere for the air lab that the nanos we already own can reach: the point is
-- for it to go up immediately, not for a con to fly out and build it alone.
-- Half-extent of a def's footprint in elmos (xsize counts 8-elmo half-cells).
local function HalfExtent(defID)
    local ud = defID and UnitDefs[defID]
    if not ud then return 0 end
    return math.max((ud.xsize or 0) * 8, (ud.zsize or ud.ysize or 0) * 8) / 2
end

-- Does this spot collide with anything the build order still intends to place?
-- The kickstarter is usually still filling in when the hand-off fires, so a spot
-- that is free right now can be built over minutes later -- which is exactly how
-- the air lab ended up skipped.
local function ClashesWithBuildOrder(cx, cz, half)
    if not (BUILD_ORDER and BUILD_ORDER.layout) then return false end
    for _, u in ipairs(BUILD_ORDER.layout) do
        if u.a ~= "reclaim" then
            local ud = UnitDefNames[u.n]
            if ud then
                local h = HalfExtent(ud.id)
                if math.abs(cx - (baseX + u.x)) < half + h
                   and math.abs(cz - (baseZ + u.z)) < half + h then
                    return true
                end
            end
        end
    end
    return false
end

-- The open area of a finished tile (tile-local x -64..80, z 16..128) takes the air lab
-- exactly, long side along the tile's x axis, with the tile's two nanos beside it.
-- Never in row 0: its open areas are the corridor the bot lab's units leave by.
--
-- Orientation: the open area is long along the tile's x axis, which is world x or world z
-- depending on the block's rotation.  Which facing puts the lab's long side along it is
-- worked out from the engine's own footprint (xsize/zsize), not assumed -- the editor's
-- 9x6 may not match the real def, and getting it backwards is exactly what made every
-- hand-off in a rotated block fail.  The position is snapped FOR that facing: a
-- non-square building at facing 1/3 aligns to the build grid the other way round.
local function AirLabFacings()
    local ud = UnitDefs[airLabDefID]
    local xs, zs = (ud.xsize or 0) * 8, (ud.zsize or ud.ysize or 0) * 8
    local lx, _ = TC.Rotate(1, 0, layout.rot)
    local longAlongX = lx ~= 0                     -- open area's long axis in world space
    local base = BP_PLACER.RotateFacing(0, layout.rot)
    local good, rest = {}, {}
    for _, f in ipairs({ base, (base + 2) % 4, (base + 1) % 4, (base + 3) % 4 }) do
        local fx, fz = xs, zs
        if f % 2 == 1 then fx, fz = zs, xs end
        local fits = (longAlongX and fx >= fz) or (not longAlongX and fz >= fx)
        if fits then good[#good + 1] = f else rest[#rest + 1] = f end
    end
    for _, f in ipairs(rest) do good[#good + 1] = f end
    return good, xs, zs, longAlongX
end

local airLabSpotLogged = false
local function TileAirLabSpot()
    if not (crew and airLabDefID) then return nil end
    local facings, xs, zs, longX = AirLabFacings()
    if not airLabSpotLogged then
        airLabSpotLogged = true
        Spring.Echo(string.format("[MC] air lab %s footprint %dx%d elmos (facing 0); open area long along %s; facings to try %s",
            tostring(UnitDefs[airLabDefID].name), xs, zs, longX and "x" or "z", table.concat(facings, ",")))
    end
    local nudges = { {0, 0}, {0, -8}, {0, 8}, {-8, 0}, {8, 0}, {0, -16}, {0, 16}, {-16, 0}, {16, 0} }
    for _, t in ipairs(TC.FinishedTiles(crew)) do
        if t.row ~= TC.LAB_EXIT_ROW then
            local cx, cz = TC.Local(layout, t, TC.AIR_LAB)
            for _, f in ipairs(facings) do
                for _, n in ipairs(nudges) do
                    local x, z = BP_PLACER.SnapToBuildGrid(airLabDefID, cx + n[1], cz + n[2], f)
                    local y = spGetGroundHeight(x, z) or 0
                    local ok = Spring.TestBuildOrder(airLabDefID, x, y, z, f)
                    if ok and ok ~= 0 and not TS.airLabFailed[x .. "," .. z .. "," .. f] then
                        Spring.Echo(string.format("[MC] air lab spot: tile %s (%d, %d) facing %d, test=%s",
                            t.key, x, z, f, tostring(ok)))
                        return x, z, BP_PLACER.CountNanosInRange(x, z), f, t.key
                    end
                end
            end
        end
    end
    return nil
end

local function FindAirLabSpot()
    if not airLabDefID then return nil end
    local tx, tz, tn, tf = TileAirLabSpot()
    if tx then return tx, tz, tn, tf end
    local labHalf = HalfExtent(airLabDefID)
    local bestX, bestZ, bestNanos = nil, nil, -1
    for r = 96, 560, 48 do
        for a = 0, 11 do
            local ang = a * math.pi / 6
            -- Snap through the placer so the lab lands on a legal build position
            -- for ITS footprint, not just a multiple of 16.
            local x, z = BP_PLACER.SnapToBuildGrid(airLabDefID,
                             baseX + r * math.cos(ang), baseZ + r * math.sin(ang))
            local y = spGetGroundHeight(x, z) or 0
            local ok = Spring.TestBuildOrder(airLabDefID, x, y, z, 0)
            -- The spot must also stay reachable for a ground con once the rest of the
            -- kickstart is up: a lab sealed inside the spiral is never built.
            if ok and ok ~= 0 and not ClashesWithBuildOrder(x, z, labHalf)
               and not (layout and TC.InBlock(layout, x, z, labHalf))
               and BP_PLACER.SpotReachable(distState, airLabDefID, x, z) then
                local n = BP_PLACER.CountNanosInRange(x, z)
                if n > bestNanos then bestX, bestZ, bestNanos = x, z, n end
                if n >= AIR_LAB_MIN_NANOS then return x, z, n, 0 end
            end
        end
    end
    return bestX, bestZ, bestNanos, 0
end

local function StopGuard()
    if comGuardTarget and commanderID and spGetUnitDefID(commanderID) then
        spGiveOrderToUnit(commanderID, CMD_STOP, {}, {})
    end
    comGuardTarget = nil
end

local function Guard(targetID)
    if comGuardTarget == targetID then return end
    spGiveOrderToUnit(commanderID, CMD_GUARD, {targetID}, {})
    comGuardTarget = targetID
    if DEBUG then Spring.Echo("[MC] commander guards " .. tostring(targetID)) end
end

-- ── Blueprint start ───────────────────────────────────────────────────────────

local TileInterrupts   -- defined next to ReadResources

local function StartBuildOrder()
    local cx, _, cz = spGetUnitPosition(commanderID)
    if not cx then return end
    layout = TC.Layout(cx, cz, (Game and Game.mapSizeX) or 8192, (Game and Game.mapSizeZ) or 8192)
    baseX, baseZ = layout.anchorX, layout.anchorZ
    startPending = true
    Spring.Echo(string.format("[MC] tile block at (%d, %d), rotation %d, cols (%d, %d), rows (%d, %d)",
        baseX, baseZ, layout.rot, layout.colVec.x, layout.colVec.z, layout.rowVec.x, layout.rowVec.z))
end

local function BeginBuildOrder()
    distState = BP_PLACER.NewDistributed(BUILD_ORDER, baseX, baseZ, layout.rot)
    -- Ground cons can wall themselves in with the kickstart's own buildings; this frees
    -- them and holds back placements that would do it (bar_framework/escape_guard.lua).
    BP_PLACER.EnableEscapeGuard(distState)
    BP_PLACER.AddBuilder(distState, commanderID)
    crew = TC.NewCrew{ BP = BP_PLACER, tileBP = TILE_BP, layout = layout,
                       interrupts = TileInterrupts }
    startPending = false
    if DEBUG then
        Spring.Echo("[MC] build order started, " .. #distState.queue .. " items")
    end
end

-- ── Phase logic ───────────────────────────────────────────────────────────────

local function FactoryBusy(fid)
    if not (fid and spGetUnitDefID(fid)) then return false end
    if not spGetFactoryCommands then return true end
    local cmds = spGetFactoryCommands(fid, -1)
    return cmds ~= nil and #cmds > 0
end

-- What the commander helps when it has nothing of its own to build: the lab while a
-- con is coming out of it, otherwise the nearest con still building its row.
local function AssistTarget()
    -- (Not the air lab: helping the cons finish their rows is worth more -- see
    -- UpdateAirLabAssist.)  Never something being reclaimed: a guarding builder repairs its target.
    local labOk = botLabID and spGetUnitDefID(botLabID) and not TS.reclaiming[botLabID]
    if labOk and TS.conOrderOpen and FactoryBusy(botLabID) then return botLabID end
    local cx, _, cz = spGetUnitPosition(commanderID)
    local con = cx and crew and TC.NearestBuilder(crew, cx, cz, 900)
    if con then return con end
    if labOk then return botLabID end
    return nil
end

local function UpdateCommanderPhase(frame, resources)
    if not commanderID or not spGetUnitDefID(commanderID) then
        commanderID = nil
        return
    end

    -- Whatever we were guarding is gone (con died, lab reclaimed) — GUARD has
    -- already self-terminated, so take the commander back.
    if comGuardTarget and not spGetUnitDefID(comGuardTarget) then
        comGuardTarget = nil
        BP_PLACER.AddBuilder(distState, commanderID)
    elseif comGuardTarget and TS.reclaiming[comGuardTarget] then
        -- It is being reclaimed: guarding it would repair it against the nanos.
        StopGuard()
        BP_PLACER.AddBuilder(distState, commanderID)
    end

    if not nanoAssistDone then
        if BP_PLACER.CountBuilt(distState, "nano") >= NANO_ASSIST_NUM then
            nanoAssistDone = true
            StopGuard()
            BP_PLACER.AddBuilder(distState, commanderID)
            if DEBUG then Spring.Echo("[MC] nano assist done, commander rejoins pool") end
        elseif conBot1ID and spGetUnitDefID(conBot1ID) then
            local claim = BP_PLACER.GetClaim(distState, conBot1ID)
            -- Only hand over between items, so the commander never abandons a
            -- frame that has no nano in range to finish it.
            if claim and claim.cls == "nano"
               and BP_PLACER.GetClaim(distState, commanderID) == nil then
                BP_PLACER.RemoveBuilder(distState, commanderID)
                Guard(conBot1ID)
            end
            return
        end
    end

    if not nanoAssistDone and comGuardTarget == conBot1ID and comGuardTarget ~= nil then
        return
    end

    -- Its own work first (the rest of bad_com_start, the air lab once it is queued).
    local hasWork = BP_PLACER.GetClaim(distState, commanderID) ~= nil
                 or BP_PLACER.HasClaimable(distState, commanderID, frame, resources)
    if hasWork then
        if comGuardTarget ~= nil then
            StopGuard()
            BP_PLACER.AddBuilder(distState, commanderID)
        end
        return
    end
    -- Nothing to place: assist the lab while a con is coming, otherwise the nearest
    -- con still building its tiles.  Re-chosen every few seconds, since both change.
    if comGuardTarget == nil or frame - TS.comGuardFrame >= 150 then
        local target = AssistTarget()
        TS.comGuardFrame = frame
        if target and target ~= comGuardTarget then
            BP_PLACER.RemoveBuilder(distState, commanderID)
            Guard(target)
        end
    end
end

-- ── Con bots ─────────────────────────────────────────────────────────────────

-- Con #1 starts in the com-start queue (the commander cannot build its nano).  Once
-- that nano stands it goes to its row, between items so no frame is left orphaned
-- (or after CON1_RELEASE_WAIT regardless).
local function ReleaseCon1(frame)
    if TS.con1Released or not conBot1ID or not crew then return end
    if not spGetUnitDefID(conBot1ID) then TS.con1Released = true; return end
    if BP_PLACER.CountBuilt(distState, "nano") < NANO_ASSIST_NUM then return end
    if BP_PLACER.GetClaim(distState, conBot1ID) ~= nil
       and frame - (TS.con1JoinFrame or frame) < CFG.CON1_RELEASE_WAIT then
        return
    end
    BP_PLACER.RemoveBuilder(distState, conBot1ID)
    TC.AddCon(crew, conBot1ID, true)   -- row 1: the tiles beside the commander's
    TS.con1Released = true
end

local function AliveCons()
    local n = 0
    for _, cid in ipairs(conBots) do
        if spGetUnitDefID(cid) then n = n + 1 end
    end
    return n
end

-- One con at a time, each once metal is piling up (or after a fallback delay).
local function MaybeQueueNextCon(frame, resources)
    -- Air cons take over from here; the bot lab is about to be reclaimed.
    if TS.airLabDone then return end
    if TS.conOrderOpen or not TS.lastConFrame or not conDefID then return end
    if not (botLabID and spGetUnitDefID(botLabID)) then return end
    if AliveCons() >= CFG.MAX_CONS then return end
    if TC.FreeRows(crew) <= 0 then return end
    if resources.metal >= CFG.CON_BANK_TRIGGER or frame >= TS.lastConFrame + CFG.CON_FALLBACK_FRAMES then
        spGiveOrderToUnit(botLabID, -conDefID, {0}, {})
        TS.conOrderOpen = true
        Spring.Echo(string.format("[MC] con #%d queued at frame %d (metal %.0f)",
            conCount + 1, frame, resources.metal))
    end
end

-- ── Grid expansion (starts once the air lab is up) ──────────────────────────

local TryExpand         -- forward declaration
local StartSpine        -- defined after CapSlack, below
local TryAssignUpgrades -- ditto: the grid onComplete closure below calls it, and a
                        -- local declared later would resolve to a nil global there

local function AnchorKey(ax, az) return tostring(ax) .. "," .. tostring(az) end

local function AddCompletedAnchor(ax, az)
    local key = AnchorKey(ax, az)
    if not completedKeys[key] then
        completedKeys[key] = true
        completedAnchors[#completedAnchors + 1] = {anchorX = ax, anchorZ = az}
    end
end

-- (SPINE_BOT's stash capped air cons at 3 until the first mex grids were built.  Removed in
-- TILE_BOT: it starved the grids -- one waited 77 s for a con while metal floated.)
local SpineMexGridsReady      -- defined with the other spine hooks, below

-- Air cons are the air lab's top priority: inserted at the front of its queue, ahead of
-- whatever fighters the lab controller has queued (they used to come out first), and the
-- lab controller leaves the air lab alone while any are on order (WG.TileAirCons).
-- The insert is BAR's own factory pattern (unit_factory_quota.lua, as lab_controller's
-- InsertNext): numeric option flags, and position 1 while the lab is busy so the unit in
-- progress is not cancelled.  A string-option insert ({"alt"}) was silently ignored by the
-- factory -- three cons "ordered", none built, and the early cap then blocked every grid.
-- (One table: this file is at Lua 5.1's 200-locals-per-chunk limit.)
local AC = {
    INSERT   = (CMD and CMD.INSERT) or 1,
    ALT      = (CMD and CMD.OPT_ALT) or 128,
    CTRL     = (CMD and CMD.OPT_CTRL) or 64,
    INTERNAL = (CMD and CMD.OPT_INTERNAL) or 8,
    TIMEOUT  = 80 * 30,   -- an order with no con this long after is forgotten
    orders   = {},        -- frame of each outstanding order, oldest first
}

local function QueueAirCon()
    if airLabID and spGetUnitDefID(airLabID) and airConDefID then
        local _, busy = Spring.GetUnitWorkerTask(airLabID)
        spGiveOrderToUnit(airLabID, AC.INSERT,
            { busy and 1 or 0, -airConDefID, AC.ALT + AC.INTERNAL }, AC.ALT + AC.CTRL)
        airConsOrdered = airConsOrdered + 1
        AC.orders[#AC.orders + 1] = currentFrame
    end
end

-- A con came out (oldest order done), or an order is clearly lost (dropped by the engine,
-- lab destroyed): keep airConsOrdered honest, or the early cap and the lab hold stick.
local function AirConOrderDone()
    if #AC.orders > 0 then table.remove(AC.orders, 1) end
    airConsOrdered = math.max(0, airConsOrdered - 1)
end

-- Spare build power for the air lab while it owes air cons (SPINE_BOT's version has no
-- factory assist at all, so a bare air lab took 30-110 s per con).  Only nanos with
-- nothing to do: one that is building -- a tile, a frame -- is never taken, and the claim
-- is the lowest priority there is, so any hand-off takes the nano straight back.  (An
-- earlier version took every nano in reach plus the commander, above hand-offs, and the
-- tile rows finished a minute late: 23.9k metal used at 7:30 against 30.9k.)
local function UpdateAirLabAssist(frame)
    if frame % 30 ~= 0 or not (airLabID and TS.airLabDone) then return end
    if airConsOrdered > 0 and spGetUnitDefID(airLabID) then
        local x, _, z = spGetUnitPosition(airLabID)
        for _, n in ipairs(BP_PLACER.NanosInRange(x, z)) do
            local idle = NANO.Assignment(n) == nil
                         and not (Spring.GetUnitIsBuilding and Spring.GetUnitIsBuilding(n))
            if (idle or TS.airLabNanos[n]) and NANO.Guard(NANO.PRIO.BALANCE, n, airLabID) then
                TS.airLabNanos[n] = true
            end
        end
    else
        for n in pairs(TS.airLabNanos) do
            local a = NANO.Assignment(n)
            if a and a.target == airLabID and a.prio == NANO.PRIO.BALANCE then NANO.Release(n) end
            TS.airLabNanos[n] = nil
        end
    end
end

-- Build-power accounting, every 30 s (log only, changes nothing).  Where does every
-- builder's power go, and how many of our frames stand with nobody working on them?
--   [MC] BP m:ss nano <state>=n/bp ... | aircon ... | con ... | com ... | frames open=N worked=N orphan=N orphan_m=M
-- Nano states: eco (building a structure), unit (building a unit / assisting a factory
-- that is producing), lab_idle (guarding a factory that builds nothing), reclaim, park
-- (spine WAIT), idle (no order at all), other.  Mobile builders: build, walk (has orders,
-- builds nothing), idle.
function AC.LogBuildPower(frame)   -- (a table field: this file is at the 200-local limit)
    local nano, mob = {}, {aircon = {}, con = {}, com = {}}
    local worked = {}
    local function add(t, k, bp) local e = t[k] or {0, 0}; e[1], e[2] = e[1] + 1, e[2] + bp; t[k] = e end
    local frames = {}
    for _, uid in ipairs(spGetTeamUnits(myTeamID) or {}) do
        local d = UnitDefs[spGetUnitDefID(uid) or -1]
        if d then
            local beingBuilt, prog = Spring.GetUnitIsBeingBuilt(uid)
            if beingBuilt then
                if not d.canMove then frames[uid] = {d = d, prog = prog or 0} end
            elseif d.isBuilder and not d.isFactory then
                local bp = d.buildSpeed or 0
                local target = Spring.GetUnitIsBuilding and Spring.GetUnitIsBuilding(uid)
                if target then worked[target] = true end
                local cmds = spGetUnitCommands(uid, 2) or {}
                local td = target and UnitDefs[spGetUnitDefID(target) or -1]
                if (d.speed or 0) == 0 then
                    local a = NANO.Assignment(uid)
                    local st
                    if a and a.mode == "park" then st = "park"
                    elseif a and a.mode == "reclaim" then st = "reclaim"
                    elseif target then st = (td and td.canMove) and "unit" or "eco"
                    elseif cmds[1] and cmds[1].id == CMD_GUARD then
                        local g = UnitDefs[spGetUnitDefID(cmds[1].params and cmds[1].params[1] or -1) or -1]
                        st = (g and g.isFactory) and "lab_idle" or "guard"
                    elseif #cmds == 0 then st = "idle"
                    else st = "other" end
                    add(nano, st, bp)
                else
                    local kind = (uid == commanderID) and "com" or (d.canFly and "aircon" or "con")
                    add(mob[kind], target and "build" or (#cmds > 0 and "walk" or "idle"), bp)
                end
            end
        end
    end
    local open, workedN, orphan, orphanM = 0, 0, 0, 0
    for uid, f in pairs(frames) do
        open = open + 1
        if worked[uid] then workedN = workedN + 1
        else
            orphan = orphan + 1
            orphanM = orphanM + (f.d.metalCost or 0) * (1 - f.prog)
        end
    end
    local function fmt(t)
        local parts = {}
        for k, e in pairs(t) do parts[#parts + 1] = string.format("%s=%d/%d", k, e[1], e[2]) end
        table.sort(parts)
        return table.concat(parts, " ")
    end
    Spring.Echo(string.format("[MC] BP %d:%02d nano %s | aircon %s | con %s | com %s | frames open=%d worked=%d orphan=%d orphan_m=%.0f",
        math.floor(frame / 1800), math.floor(frame / 30) % 60, fmt(nano), fmt(mob.aircon), fmt(mob.con),
        fmt(mob.com), open, workedN, orphan, orphanM))
end

local function ExpireAirConOrders()
    while #AC.orders > 0 and currentFrame - AC.orders[1] > AC.TIMEOUT do
        Spring.Echo(string.format("[MC] air con ordered at frame %d never came out; forgetting it",
            AC.orders[1]))
        AirConOrderDone()
    end
    if not (airLabID and spGetUnitDefID(airLabID)) then
        while #AC.orders > 0 do AirConOrderDone() end
    end
end

-- Keep AIR_CON_RESERVE cons beyond what the pending grids need, ready or on order.
-- Counted from our own orders, not read back from the factory queue: that read lags on
-- the client process (lab_controller, LAB_ORDER_GRACE).  Off once the unit cap is tight.
local function KeepAirConReserve()
    if consolidateOn or not airLabID or not airConDefID then return end
    if currentFrame - lastReserveOrder < 90 then return end
    if #freeAirCons + airConsOrdered < #pendingGrids + AIR_CON_RESERVE then
        QueueAirCon()
        lastReserveOrder = currentFrame
    end
end

-- Swap the blueprint's factory entry for this grid's capstone.  Returns nothing;
-- if the grid's con cannot build it, the entry is retired from the grid's queue
-- and queued for a builder that can.
local function ApplyCapstone(st, gridIndex, conID)
    local name = CAPSTONE_PLAN[gridIndex] or CAPSTONE_DEFAULT
    local ud   = UnitDefNames[name]
    if not ud then return end

    for _, item in ipairs(st.queue) do
        if item.cls == "factory" then
            if item.n ~= name then
                item.n     = name
                item.defID = ud.id
                item.wx, item.wz = BP_PLACER.SnapToBuildGrid(ud.id, item.wx, item.wz)
                -- Keep cls as "factory" whatever the capstone actually is: that is
                -- what deferFactories keys off, and a capstone should still be the
                -- last thing a grid builds.
                item.cls = "factory"
            end
            local conDef = spGetUnitDefID(conID)
            if conDef and BP_PLACER.CanBuild(conDef, ud.id) then
                if name ~= CAPSTONE_DEFAULT then
                    Spring.Echo(string.format("[MC] grid %d capstone: %s (own con)",
                        gridIndex, name))
                end
            else
                -- Not this con's job.  Retire it here so the grid can still finish,
                -- and hand the position to whoever can place it.
                item.built  = true
                item.status = "skipped"
                pendingCapstones[#pendingCapstones + 1] =
                    {name = name, x = item.wx, z = item.wz, f = item.f or 0,
                     gridIndex = gridIndex}
                Spring.Echo(string.format(
                    "[MC] grid %d capstone: %s at (%d, %d) needs another builder",
                    gridIndex, name, item.wx, item.wz))
            end
            return
        end
    end
end

-- Hand queued capstones to any free builder that can actually place them.
local function TryAssignCapstones()
    local i = 1
    while i <= #pendingCapstones do
        local job = pendingCapstones[i]
        local ud  = UnitDefNames[job.name]
        local taken = false
        if ud then
            for ci, conID in ipairs(freeT2Cons) do
                local cdef = spGetUnitDefID(conID)
                if not cdef then
                    table.remove(freeT2Cons, ci)
                    break
                elseif BP_PLACER.CanBuild(cdef, ud.id) then
                    table.remove(freeT2Cons, ci)
                    table.remove(pendingCapstones, i)
                    spGiveOrderToUnit(conID, CMD_STOP, {}, {})
                    local st = BP_PLACER.New(
                        {layout = {{n = job.name, x = 0, z = 0, f = job.f}}},
                        conID, job.x, job.z, 0, {})
                    capstoneJobs[#capstoneJobs + 1] = st
                    Spring.Echo(string.format(
                        "[MC] capstone %s started at (%d, %d) by con %d",
                        job.name, job.x, job.z, conID))
                    taken = true
                    break
                end
            end
        end
        if not taken then i = i + 1 end
    end
end

local function TryAssignGrids()
    while #freeAirCons > 0 and #pendingGrids > 0 do
        local conID = table.remove(freeAirCons, 1)
        if spGetUnitDefID(conID) then
            spGiveOrderToUnit(conID, CMD_STOP, {}, {})
            local g  = table.remove(pendingGrids, 1)
            local gkey = AnchorKey(g.anchorX, g.anchorZ)
            if pendingSince[gkey] then
                local wait = currentFrame - pendingSince[gkey]
                gridWaitSum, gridWaitN = gridWaitSum + wait, gridWaitN + 1
                Spring.Echo(string.format("[MC] grid %d at (%d, %d) waited %.1fs for a con "
                    .. "(mean %.1fs)", gridsAssigned + 1, g.anchorX, g.anchorZ, wait / 30,
                    gridWaitSum / gridWaitN / 30))
            end
            gridRotation[gkey] = g.rotation
            allGridAnchors[#allGridAnchors + 1] =
                {anchorX = g.anchorX, anchorZ = g.anchorZ, key = gkey}
            local st = BP_PLACER.New(MEX_GRID_BP, conID, g.anchorX, g.anchorZ,
                                     g.rotation, GridInterrupts())
            -- The grid's own factory is the last thing built, unless metal is piling
            -- up unspent -- that is what the "float" interrupt is for.
            st.deferFactories  = true
            st.handoffProgress = GRID_HANDOFF
            gridsAssigned = gridsAssigned + 1
            ApplyCapstone(st, gridsAssigned, conID)
            if consolidateOn and windDefID then
                st.skipDefIDs = {[windDefID] = true}
            end
            st.onNanoThreshold = function(gs)
                AddCompletedAnchor(gs.anchorX, gs.anchorZ)
                TryExpand()
            end
            -- 70% built is enough to start retrofitting: the grid's nanos are up by
            -- then, and its own con is off finishing the last few outlying items.
            -- Waiting for `done` meant one grid in a whole game qualified.
            st.onMostlyDone = function(gs)
                local key = AnchorKey(gs.anchorX, gs.anchorZ)
                if not gridFinished[key] then
                    gridFinished[key] = true
                    Spring.Echo(string.format(
                        "[MC] grid (%d, %d) mostly built -- retrofit eligible",
                        gs.anchorX, gs.anchorZ))
                    TryAssignUpgrades()
                end
            end
            st.onComplete = function(gs)
                AddCompletedAnchor(gs.anchorX, gs.anchorZ)
                gridFinished[AnchorKey(gs.anchorX, gs.anchorZ)] = true
                local skipped = 0
                for _, it in ipairs(gs.queue) do
                    if it.status == "skipped" then skipped = skipped + 1 end
                end
                Spring.Echo(string.format(
                    "[MC] grid (%d, %d) finished: %d items, %d skipped -- retrofit eligible",
                    gs.anchorX, gs.anchorZ, #gs.queue, skipped))
                TryExpand()
                TryAssignUpgrades()
            end
            gridStates[#gridStates + 1] = st
            if DEBUG then
                Spring.Echo(string.format("[MC] grid assigned to con %d at (%d, %d)",
                    conID, g.anchorX, g.anchorZ))
            end
        end
    end
end

TryExpand = function()
    if not MEX_GRID_BP or #completedAnchors == 0 then return end
    -- Once the cap is the constraint, more grid is the wrong thing to spend it on:
    -- the remaining headroom has to stay free for army.
    if consolidateOn then return end
    for _, r in ipairs(BP_PLACER.FindAllValidPlacements(MEX_GRID_BP, completedAnchors)) do
        local key = AnchorKey(r.anchorX, r.anchorZ)
        if not assignedAnchors[key] then
            -- Not straight to an air con: ReleaseGridCandidates paces how many open.
            assignedAnchors[key] = true
            TS.gridCands[#TS.gridCands + 1] = r
        end
    end
    TryAssignGrids()
end

-- Grid pacing.  Opening every free cell at once (six at 4:00) sank the metal into a dozen
-- slow, one-con grids that added no income for minutes, while the tile rows -- the income
-- that should land at 6-7 min -- lost their help.  So only GRIDS_OPENING grids may be
-- "opening" (waiting for a con, or not yet at their nano threshold) at a time; one more is
-- allowed whenever metal banks above GRID_BANK, at most every GRID_BANK_GAP frames.
local function ReleaseGridCandidates(frame, resources)
    -- Banking with no cell waiting: the next ring is normally only offered once a grid
    -- reaches its nano threshold, which took grids 1.5+ min -- air cons sat idle and the
    -- bank climbed past 2k at 7:00.  So also offer free cells next to ANY assigned grid.
    if #TS.gridCands == 0 and resources.metal >= CFG.GRID_BANK and MEX_GRID_BP
       and not consolidateOn and frame - TS.lastBankGrid >= CFG.GRID_BANK_GAP then
        local sources = {}
        for _, a in ipairs(completedAnchors) do sources[#sources + 1] = a end
        for _, g in ipairs(allGridAnchors) do sources[#sources + 1] = g end
        for _, r in ipairs(BP_PLACER.FindAllValidPlacements(MEX_GRID_BP, sources)) do
            local key = AnchorKey(r.anchorX, r.anchorZ)
            if not assignedAnchors[key] then
                assignedAnchors[key] = true
                TS.gridCands[#TS.gridCands + 1] = r
            end
        end
    end
    if #TS.gridCands == 0 then return end
    local opening = #pendingGrids
    for _, gs in ipairs(gridStates) do
        if not gs.done and not gs.nanoThresholdFired then opening = opening + 1 end
    end
    local why = nil
    if opening < CFG.GRIDS_OPENING then
        why = "pace"
    elseif resources.metal >= CFG.GRID_BANK and frame - TS.lastBankGrid >= CFG.GRID_BANK_GAP then
        why = "bank"
        TS.lastBankGrid = frame
    end
    if not why then return end
    local r = table.remove(TS.gridCands, 1)
    local key = AnchorKey(r.anchorX, r.anchorZ)
    pendingGrids[#pendingGrids + 1] = r
    pendingSince[key] = frame
    QueueAirCon()
    Spring.Echo(string.format("[MC] grid cell (%d, %d) opened (%s: %d opening, bank %.0f, %d waiting)",
        r.anchorX, r.anchorZ, why, opening, resources.metal, #TS.gridCands))
    TryAssignGrids()
end

-- Seed the first ring of grids around the opening cluster.
local function StartGridExpansion()
    airConDefID = FindAirConDefID(spGetUnitDefID(airLabID))
    if not airConDefID then
        Spring.Echo("[MC] air lab has no air constructor to build")
        return
    end
    -- The tile block is exactly 2x2 grid cells: mark them taken, then let the normal
    -- expansion seed every free cell around their edges.  BestRotation faces each new
    -- grid's first nano toward the tiles' nanos, so it goes up in seconds.
    for _, c in ipairs(TC.GridCells(layout)) do
        assignedAnchors[AnchorKey(c.anchorX, c.anchorZ)] = true
        AddCompletedAnchor(c.anchorX, c.anchorZ)
    end
    -- The spine takes the cells in front of the block (and reserves its whole stack and
    -- exit lanes) before the mex grids are seeded around it.
    StartSpine()
    TryExpand()
    Spring.Echo("[MC] grid expansion started around the tile block, " .. #TS.gridCands
        .. " cells available (opened " .. CFG.GRIDS_OPENING .. " at a time)")
end

-- ── Reclaiming the opening's builders ───────────────────────────────────────
-- Once air cons exist, the con bots and the bot lab have served their purpose.  Nothing
-- holds grid cells back for them to walk out by: a con that finishes its row is reclaimed
-- where it stands, and so is the bot lab (walled in by then, and the lab controller would
-- otherwise queue units in it that can never get out).  Every nano in reach does the work.
local RECLAIM_EVERY_FRAMES = 30
local function StartReclaim(uid, what)
    if not uid or TS.reclaiming[uid] or not spGetUnitDefID(uid) then return end
    TS.reclaiming[uid] = what
    spGiveOrderToUnit(uid, CMD_STOP, {}, {})
    Spring.Echo(string.format("[MC] reclaiming %s %d", what, uid))
end

local function UpdateReclaims(frame)
    if frame % RECLAIM_EVERY_FRAMES ~= 0 then return end
    for uid, what in pairs(TS.reclaiming) do
        local x, _, z = spGetUnitPosition(uid)
        if not x then
            TS.reclaiming[uid] = nil
        else
            -- Only nanos with nothing to do (or already on this reclaim): one helping a
            -- tile or a frame through the engine's auto-assist is invisible to the broker,
            -- and taking it stalled that build.  A con or lab is not urgent.
            local nanos = BP_PLACER.NanosInRange(x, z, uid)
            for i = 1, #nanos do
                local n = nanos[i]
                local a = NANO.Assignment(n)
                local onIt = a and a.target == uid
                local busy = Spring.GetUnitIsBuilding and Spring.GetUnitIsBuilding(n)
                if onIt or (not a and not busy) then NANO.Reclaim(NANO.PRIO.CLEAR, n, uid) end
            end
            if #nanos == 0 and what == "con" then
                -- Nothing in reach: walk next to the nearest nano turret so one can eat it.
                local best, bd = nil, math.huge
                for _, n in ipairs(Spring.GetUnitsInCylinder(x, z, 1500, myTeamID) or {}) do
                    local nd = UnitDefs[spGetUnitDefID(n) or -1]
                    if nd and nd.isBuilder and not nd.isFactory and (nd.speed or 0) == 0
                       and not Spring.GetUnitIsBeingBuilt(n) then
                        local nx, _, nz = spGetUnitPosition(n)
                        local d = (nx - x) ^ 2 + (nz - z) ^ 2
                        if d < bd then best, bd = n, d end
                    end
                end
                if best then
                    local nx, ny, nz = spGetUnitPosition(best)
                    spGiveOrderToUnit(uid, (CMD and CMD.MOVE) or 10, {nx, ny, nz}, {})
                end
            end
        end
    end
end

-- Called every tick: from the moment the air lab is up, retire whatever is finished.
local function DispatchConBots()
    if not TS.airLabDone then return end
    if botLabID and not TS.botLabReclaimed and not TS.conOrderOpen then
        TS.botLabReclaimed = true
        StartReclaim(botLabID, "bot lab")
    end
    for _, cid in ipairs(conBots) do
        if spGetUnitDefID(cid) and not TS.dispatched[cid] and TC.RowDone(crew, cid) then
            TS.dispatched[cid] = true
            TC.Release(crew, cid)
            BP_PLACER.RemoveBuilder(distState, cid)
            StartReclaim(cid, "con")
        end
    end
end

-- ── Spend pressure ───────────────────────────────────────────────────────────

-- Under-spending means too few frames are open at once.  Handing a frame to the
-- nanos sooner frees its builder to place the next one, so the whole base has
-- more places to put metal; when metal is short the opposite is wanted.
local function UpdateSpendPressure(resources)
    local mFrac = resources.metalStorage > 0
                  and (resources.metal / resources.metalStorage) or 0
    local underSpending = resources.metalIncome > resources.metalPull * 1.05

    local handoff = GRID_HANDOFF
    if mFrac < BANK_LOW and not underSpending then
        handoff = SPEND_SLOW
    elseif underSpending or mFrac > BANK_HIGH then
        handoff = SPEND_FAST
    end

    for _, st in ipairs(gridStates)      do st.handoffProgress = handoff end
    for _, st in ipairs(upgradeStates)   do st.handoffProgress = handoff end
    for _, st in ipairs(consolidateJobs) do st.handoffProgress = handoff end
end

-- ── Wind consolidation (unit-cap relief) ─────────────────────────────────────

-- Find EVERY unclaimed 2x2 block of finished winds in one pass and cache them.
-- Winds sit on a global 48-elmo lattice, so a block is just a wind plus its
-- neighbours at +WIND_LATTICE in x, z and both.  One scan feeding a list beats
-- rescanning per job: the scan walks every unit we own, so it is the expensive
-- part, while handing blocks out afterwards is free.
local function ScanWindBlocks()
    if not windDefID then return end
    windBlocks = {}
    local at = {}
    for _, uid in ipairs(spGetTeamUnits(myTeamID) or {}) do
        if spGetUnitDefID(uid) == windDefID and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = spGetUnitPosition(uid)
            if x then
                at[math.floor(x + 0.5) .. "," .. math.floor(z + 0.5)] = uid
            end
        end
    end
    local taken = {}
    for key, uid in pairs(at) do
        if #windBlocks >= CONSOLIDATE_MAX then break end
        local sx, sz = key:match("(-?%d+),(-?%d+)")
        local x, z = tonumber(sx), tonumber(sz)
        local k2 = (x + WIND_LATTICE) .. "," .. z
        local k3 = x .. "," .. (z + WIND_LATTICE)
        local k4 = (x + WIND_LATTICE) .. "," .. (z + WIND_LATTICE)
        if at[k2] and at[k3] and at[k4]
           and not (taken[key] or taken[k2] or taken[k3] or taken[k4]) then
            local cx, cz = x + WIND_LATTICE / 2, z + WIND_LATTICE / 2
            local ckey = math.floor(cx) .. "," .. math.floor(cz)
            if not consolidatedKeys[ckey] then
                taken[key], taken[k2], taken[k3], taken[k4] = true, true, true, true
                windBlocks[#windBlocks + 1] = {
                    cx = cx, cz = cz, key = ckey,
                    winds = {uid, at[k2], at[k3], at[k4]},
                }
            end
        end
    end
end

-- Condemn a rationed number of winds and put every nano that can reach each one
-- onto reclaiming it.  Rationing matters: reclaiming the lot at once would drop a
-- large slice of energy income in one go.
local function UpdateWindReclaim()
    if not windDefID then
        windDefID = UnitDefNames["corwin"] and UnitDefNames["corwin"].id
        if not windDefID then return end
    end
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(myTeamID)
    local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(myTeamID)
    if not (maxU and cnt) then return end
    if (maxU - cnt) > maxU * RECLAIM_TRIGGER_FRAC then return end

    local active = 0
    for wid in pairs(reclaimingWinds) do
        if spGetUnitDefID(wid) then active = active + 1 else reclaimingWinds[wid] = nil end
    end
    local budget = math.max(1, math.floor(maxU * RECLAIM_BUDGET_FRAC))
    if active >= budget then return end

    local ordered = 0
    for _, uid in ipairs(spGetTeamUnits(myTeamID) or {}) do
        if active >= budget then break end
        if spGetUnitDefID(uid) == windDefID and not reclaimingWinds[uid]
           and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = spGetUnitPosition(uid)
            if x then
                local nanos = BP_PLACER.NanosInRange(x, z)
                local used = 0
                -- Every nano that can reach it: partly build power, but mainly so
                -- none is left idle nearby to repair what we are removing.  This is
                -- the highest priority there is, so it displaces assist and balance
                -- work without the callers needing to know about each other.
                for _, nid in ipairs(nanos) do
                    if NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, nid, uid) then
                        used = used + 1
                    end
                end
                if used > 0 then
                    reclaimingWinds[uid] = true
                    active  = active + 1
                    ordered = ordered + 1
                end
            end
        end
    end
    if DEBUG and ordered > 0 then
        Spring.Echo(string.format("[MC] wind reclaim: %d condemned (%d active, budget %d)",
            ordered, active, budget))
    end
end

-- Replace the block with whichever resource is scarcer right now.
local function ConsolidationUnit(resources)
    local mFrac = resources.metalStorage  > 0 and (resources.metal  / resources.metalStorage)  or 1
    local eFrac = resources.energyStorage > 0 and (resources.energy / resources.energyStorage) or 1
    if eFrac <= mFrac then return "corfus" end
    return "cormoho"
end

local function StartConsolidation(conID, resources)
    local block = nil
    while #windBlocks > 0 do
        local b = table.remove(windBlocks, 1)
        if not consolidatedKeys[b.key] then block = b; break end
    end
    if not block then return false end
    local cx, cz, ckey = block.cx, block.cz, block.key
    local name = ConsolidationUnit(resources)
    local ud = UnitDefNames[name]
    if not ud or not BP_PLACER.CanBuild(spGetUnitDefID(conID), ud.id) then return false end

    consolidatedKeys[ckey] = true
    spGiveOrderToUnit(conID, CMD_STOP, {}, {})
    -- A one-item blueprint.  clearBlockers does the rest: the new building overlaps
    -- all four winds, so the placer reclaims them (with any nanos in range) and
    -- then builds in the space they leave.
    local bp = {layout = {{n = name, x = 0, z = 0, f = 0}}}
    local st = BP_PLACER.New(bp, conID, cx, cz, 0, {})
    st.clearBlockers = true
    -- ONLY wind.  Anything else in the footprint (a nano, or the fusion we just
    -- placed) must never be reclaimed to make room.
    st.clearOnlyDefIDs = {[windDefID] = true}
    consolidateJobs[#consolidateJobs + 1] = st
    Spring.Echo(string.format("[MC] consolidating 4 winds at (%d, %d) into %s",
        cx, cz, name))
    return true
end

-- ── Retrofit (T2 upgrade of a finished grid) ─────────────────────────────────

-- A T2 con is one that can build what the upgrade blueprint asks for.  Asking the
-- unit defs beats hard-coding "coraca": it is the same question the placer will
-- ask when it tries to claim an item.
local function IsT2Con(defID)
    if not (UPGRADE_BP and UPGRADE_BP.layout and UPGRADE_BP.layout[1]) then return false end
    local ud = UnitDefNames[UPGRADE_BP.layout[1].n]
    return ud and BP_PLACER.CanBuild(defID, ud.id) or false
end

TryAssignUpgrades = function()
    if not UPGRADE_BP then return end
    while #freeT2Cons > 0 do
        local conID = freeT2Cons[1]
        if not spGetUnitDefID(conID) then
            table.remove(freeT2Cons, 1)
        else
            -- Nearest finished grid that has not been retrofitted yet.
            local cx, _, cz = spGetUnitPosition(conID)
            local best, bestD2, bestKey = nil, math.huge, nil
            for _, a in ipairs(completedAnchors) do
                local key = AnchorKey(a.anchorX, a.anchorZ)
                -- Only grids that finished their own blueprint: a grid still
                -- building would be competing with its own retrofit for metal.
                if gridFinished[key] and not upgradedKeys[key]
                   and key ~= AnchorKey(baseX, baseZ) then
                    local dx, dz = (cx or 0) - a.anchorX, (cz or 0) - a.anchorZ
                    local d2 = dx * dx + dz * dz
                    if d2 < bestD2 then best, bestD2, bestKey = a, d2, key end
                end
            end
            if not best then return end          -- nothing ripe; keep the con waiting
            table.remove(freeT2Cons, 1)
            upgradedKeys[bestKey] = true
            spGiveOrderToUnit(conID, CMD_STOP, {}, {})
            local st = BP_PLACER.New(UPGRADE_BP, conID, best.anchorX, best.anchorZ,
                                     gridRotation[bestKey] or 0,
                                     GridInterrupts())
            st.clearBlockers   = true    -- reclaim the mex/winds the fusions need
            -- A retrofit clears exactly what the upgrade layout sits on top of:
            -- the T1 mex it replaces and the corner winds the fusion needs.
            st.clearOnlyDefIDs = {}
            for _, n in ipairs({"corwin", "cormex"}) do
                local ud = UnitDefNames[n]
                if ud then st.clearOnlyDefIDs[ud.id] = true end
            end
            st.handoffProgress = GRID_HANDOFF
            -- Hand the con straight to the next grid instead of retiring it.
            st.onComplete = function(us)
                if us.builderID and spGetUnitDefID(us.builderID) then
                    freeT2Cons[#freeT2Cons + 1] = us.builderID
                    TryAssignUpgrades()
                end
            end
            upgradeStates[#upgradeStates + 1] = st
            Spring.Echo(string.format("[MC] retrofit started at (%d, %d) by con %d",
                best.anchorX, best.anchorZ, conID))
        end
    end
end

-- ── Hand-off ─────────────────────────────────────────────────────────────────

-- Metal is banking: the build order cannot spend what the economy earns any more.
-- Put an air lab up inside the nanos' reach and let the grid system take over.
local function StartHandoff()
    handoffStarted = true
    airLabDefID = FindAirFactoryDefID()
    if not airLabDefID then
        Spring.Echo("[MC] hand-off: no builder we own can place an air factory")
        return
    end
    local x, z, nanos, facing = FindAirLabSpot()
    if not x then
        Spring.Echo("[MC] hand-off: nowhere to put the air lab")
        handoffStarted = false
        return
    end
    local name = UnitDefs[airLabDefID] and UnitDefs[airLabDefID].name
    local item = BP_PLACER.InsertPriorityItem(distState, name, x, z, facing or 0)
    if not item then
        Spring.Echo("[MC] hand-off: could not queue " .. tostring(name))
        handoffStarted = false
        return
    end
    airLabItem  = item
    airLabFrame = currentFrame
    -- Not DEBUG-gated: this is the one event that decides whether the bot scales,
    -- and a silent success is indistinguishable from a silent failure.
    Spring.Echo(string.format(
        "[MC] HAND-OFF frame=%d: %s at (%d, %d), %d nanos in range, %d builders",
        currentFrame, tostring(name), x, z, nanos or 0, #distState.builders))
end

-- ── Vehicle plant for base defence ───────────────────────────────────────────

-- The one army-driven change to the economy: a T1 vehicle plant, whose output is the
-- bot's ground defence.  corvp, not the T2 bot lab -- ~16k energy for a T2 lab at
-- ~3 min is out of reach, and the lab is only the start; the defenders still have to
-- be built after it.
--
-- WHEN is derived, not hardcoded.  Raid arrival times measured in one match carry
-- that match's spawn distance: in-line spawns land a ground raid ~28 s sooner than
-- the cross-position runs they were measured on.  So we store the part that does
-- not depend on spawns -- how long an early ground raid spends BUILDING -- and add
-- this match's actual travel time.  From GROUND_RAIDER_BOT's ~6:30 arrival (frame
-- 11700) across 12,968 elmos at corgator speed 85: 11700 - 4577 = ~7120 frames.
local VP_NAME           = "corvp"
local GROUND_RAID_BUILD = 7120   -- frames, spawn-independent
local GROUND_RAID_SPEED = 85     -- elmos/s, the early raider
local VP_LEAD_FRAMES    = 3600   -- lab + first defenders need this long before arrival
local VP_WATCHDOG       = 1800   -- ordered but no plant this long later: try again
-- (vpQueued / vpDefID / vpBuilder / vpOrderFrame / vpBuilt are declared with the
--  air-lab state near the top: DispatchConBots needs them, and a second `local`
--  here would silently create separate variables for everything below.)

-- Can any builder we actually own place this def?  Queueing one nobody can build
-- sits in the placer forever without a word (the air-lab lesson above).
local function OwnedBuilderCanBuild(defID)
    local candidates = {}
    if commanderID and spGetUnitDefID(commanderID) then candidates[1] = commanderID end
    for _, b in ipairs((distState and distState.builders) or {}) do
        candidates[#candidates + 1] = b
    end
    for _, uid in ipairs(candidates) do
        local bd = UnitDefs[spGetUnitDefID(uid) or -1]
        for _, optID in ipairs((bd and bd.buildOptions) or {}) do
            if optID == defID then return true end
        end
    end
    return false
end

-- Frame to start the plant by: estimated ground-raid arrival minus the lead needed.
local function VehicleLabDeadline()
    local mb   = WG and WG.MetalBot
    local dist = mb and mb.foeDist
    if (not dist or dist <= 0) and baseX then
        -- Symmetric-map mirror, the same fallback map_model uses.
        local ex, ez = (Game.mapSizeX or 0) - baseX, (Game.mapSizeZ or 0) - baseZ
        dist = math.sqrt((ex - baseX) ^ 2 + (ez - baseZ) ^ 2)
    end
    local arrival = GROUND_RAID_BUILD + ((dist or 0) / GROUND_RAID_SPEED) * 30
    return arrival - VP_LEAD_FRAMES
end

-- Ground factories need room for what they build to leave, so search further out
-- than the air lab (which spawns aircraft and can sit anywhere) and away from the
-- dense kickstart spiral around the commander.
local function FindVehicleLabSpot()
    local half = HalfExtent(vpDefID)
    for r = 400, 1000, 60 do
        for a = 0, 11 do
            local ang = a * math.pi / 6
            local x, z = BP_PLACER.SnapToBuildGrid(vpDefID,
                             baseX + r * math.cos(ang), baseZ + r * math.sin(ang))
            local y  = spGetGroundHeight(x, z) or 0
            local ok = Spring.TestBuildOrder(vpDefID, x, y, z, 0)
            if ok and ok ~= 0 and not ClashesWithBuildOrder(x, z, half)
               and not TC.InBlock(layout, x, z, half)
               and BP_PLACER.SpotReachable(distState, vpDefID, x, z) then
                return x, z
            end
        end
    end
    return nil
end

local function CanBuild(builderID, defID)
    local bd = builderID and UnitDefs[spGetUnitDefID(builderID) or -1]
    for _, optID in ipairs((bd and bd.buildOptions) or {}) do
        if optID == defID then return true end
    end
    return false
end

local function MaybeQueueVehicleLab(frame)
    -- The T1 spine cell carries its own corvp (and corlab) in the reserved stack with exit
    -- lanes, so this whole path is off while the spine is loaded (as in SPINE_BOT).
    if SPINE and SPINE_BPS.T1 then return end
    if vpBuilt or not distState or not baseX then return end
    vpDefID = vpDefID or (UnitDefNames[VP_NAME] and UnitDefNames[VP_NAME].id)
    if not vpDefID then return end

    -- Already ordered: watch for the plant to appear, and retry if it never does
    -- (builder killed on the way, spot taken, order dropped).
    if vpQueued then
        local have = Spring.GetTeamUnitsByDefs and Spring.GetTeamUnitsByDefs(myTeamID, vpDefID)
        if have and #have > 0 then
            vpBuilt = true
        elseif vpOrderFrame and frame - vpOrderFrame > VP_WATCHDOG then
            Spring.Echo(string.format("[MC] vehicle lab: no plant %d frames after ordering, retrying",
                frame - vpOrderFrame))
            vpQueued, vpBuilder = false, nil
        end
        return
    end

    -- Three reasons to start: a ground threat we cannot answer, the derived deadline,
    -- or a con bot freed by the hand-off.  The last is usually first, and it is the
    -- right time anyway: hand-off happens BECAUSE metal is banking, so the plant is
    -- paid for out of surplus, and a ground con left idle among the growing grids
    -- risks being walled in.
    local mb      = WG and WG.MetalBot
    local pulled  = mb and (mb.urgency == "rush" or mb.urgency == "build")
                    and mb.urgencyChannel ~= "air"
    local due     = frame >= VehicleLabDeadline()
    local conFree = vpBuilder and spGetUnitDefID(vpBuilder) and CanBuild(vpBuilder, vpDefID)
    if not (pulled or due or conFree) then return end

    local x, z = FindVehicleLabSpot()
    if not x then return end   -- try again next tick

    local how
    if conFree then
        local y = spGetGroundHeight(x, z) or 0
        spGiveOrderToUnit(vpBuilder, -vpDefID, { x, y, z, 0 }, {})
        how = "reserved con bot"
    elseif OwnedBuilderCanBuild(vpDefID)
           and BP_PLACER.InsertPriorityItem(distState, VP_NAME, x, z, 0) then
        how = "build queue"
    else
        return
    end
    vpQueued, vpOrderFrame = true, frame
    Spring.Echo(string.format(
        "[MC] VEHICLE LAB frame=%d via %s (%s, deadline %d): %s at (%d, %d)",
        frame, how, pulled and "threat" or (conFree and "hand-off" or "timer"),
        math.floor(VehicleLabDeadline()), VP_NAME, x, z))
end

-- ── Nano army/eco balance ────────────────────────────────────────────────────

-- Effective headroom threshold for this game's unit cap.
local function CapSlack(absolute)
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(myTeamID)
    if not maxU or maxU <= 0 then return absolute end
    return math.min(absolute, math.floor(maxU * CAP_SLACK_FRAC))
end

-- ── Spine (from SPINE_BOT) ───────────────────────────────────────────────────
-- What the spine borrows from this file: constructors, a way to reserve grid cells,
-- and the unit-cap test.  Everything else lives in bar_framework/spine.lua.

-- A free con able to place defID.  t1Only keeps T2 air cons (the retrofit crew) out of
-- nano top-ups.
local function SpineTakeCon(defID, t1Only)
    local lists = t1Only and {freeAirCons} or {freeAirCons, freeT2Cons}
    for _, list in ipairs(lists) do
        local i = 1
        while i <= #list do
            local cid  = list[i]
            local cdef = spGetUnitDefID(cid)
            if not cdef then
                table.remove(list, i)
            elseif not defID or BP_PLACER.CanBuild(cdef, defID) then
                table.remove(list, i)
                return cid
            else
                i = i + 1
            end
        end
    end
    return nil
end

local function SpineReturnCon(uid)
    local def = spGetUnitDefID(uid)
    if not def then return end
    spGiveOrderToUnit(uid, CMD_STOP, {}, {})
    if IsT2Con(def) then freeT2Cons[#freeT2Cons + 1] = uid
    else freeAirCons[#freeAirCons + 1] = uid; TryAssignGrids() end
end

local function SpineCapPressure()
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(myTeamID)
    local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(myTeamID)
    return (maxU and cnt and (maxU - cnt) <= CapSlack(ARMY_CAP_SLACK)) and true or false
end

-- Metal value of our finished ground army: armed, mobile, non-air, non-builder units.  Gates
-- the T2 labs (a lab that costs more than the army we have is one we cannot feed).  Cached
-- for a few frames: the spine asks once per held lab per control tick.
local groundAV, groundAVFrame = 0, -1e9
local function SpineGroundArmyValue()
    if currentFrame - groundAVFrame < 15 then return groundAV end
    local total = 0
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        local d = UnitDefs[spGetUnitDefID(uid) or -1]
        if d and not d.isBuilder and not d.isFactory and not d.canFly
           and (d.speed or 0) > 0 and d.weapons and #d.weapons > 0
           and not (Spring.GetUnitIsBeingBuilt(uid)) then
            total = total + (d.metalCost or 0)
        end
    end
    groundAV, groundAVFrame = total, currentFrame
    return total
end

-- What the unit controller sees: production urgency and how many enemy groups are inside
-- the line.  The spine lifts army_share on either.
local function SpineThreat()
    local mb = WG and WG.MetalBot
    if not mb then return nil, 0 end
    return mb.urgency, mb.threats and #mb.threats or 0
end

-- The first three mex grids are at least 60% built: from here the spine releases nanos for
-- 100% army spend, because keeping a few spare nanos is cheap next to the economy.
SpineMexGridsReady = function()
    if #gridStates < 3 then return false end
    for i = 1, 3 do
        local n, done = 0, 0
        for _, it in ipairs(gridStates[i].queue) do
            n = n + 1
            if it.status == "built" or it.status == "skipped" then done = done + 1 end
        end
        if n == 0 or done / n < 0.6 then return false end
    end
    return true
end

-- The spine stacks its cells one grid cell in front of its "base" (toward the enemy) and
-- sideways from there.  Our base is a 2x2-cell tile block, so the spine's base is the
-- block cell whose stack lands wholly outside the block, nearest the enemy.
local function SpineBase(mapX, mapZ)
    local ex, ez = mapX - baseX, mapZ - baseZ        -- the point mirror of our start
    local best, bestD = nil, math.huge
    for _, c in ipairs(TC.GridCells(layout)) do
        local geo = SPINE.Geometry(c.anchorX, c.anchorZ, mapX, mapZ)
        local ok = true
        for i = 1, 4 do
            local ax, az = SPINE.CellAnchor(geo, c.anchorX, c.anchorZ, i)
            local lx, lz = SPINE.LaneAnchor(geo, c.anchorX, c.anchorZ, i)
            if TC.InBlock(layout, ax, az, 200) or TC.InBlock(layout, lx, lz, 200) then ok = false end
        end
        local d = (c.anchorX - ex) ^ 2 + (c.anchorZ - ez) ^ 2
        if ok and d < bestD then best, bestD = c, d end
    end
    return best
end

-- Called from StartGridExpansion, BEFORE the mex-grid cells are seeded, so the spine's
-- cells and exit lanes are already reserved when they are.
StartSpine = function()
    if not (SPINE and SPINE_BPS.T1) then return end
    local mapX = (Game and Game.mapSizeX) or 8192
    local mapZ = (Game and Game.mapSizeZ) or 8192
    local sb = SpineBase(mapX, mapZ)
    if not sb then
        Spring.Echo("[MC] spine: no block cell has room in front of it; spine disabled")
        SPINE = nil
        return
    end
    SPINE.Init{
        BP_PLACER  = BP_PLACER,
        NANO       = NANO,
        blueprints = SPINE_BPS,
        baseX = sb.anchorX, baseZ = sb.anchorZ,
        mapX  = mapX, mapZ = mapZ,
        AnchorKey   = AnchorKey,
        Reserve     = function(key) assignedAnchors[key] = true end,
        TakeCon     = SpineTakeCon,
        ReturnCon   = SpineReturnCon,
        QueueAirCon = QueueAirCon,
        DeferStop   = function(uid)
            pendingStops[#pendingStops + 1] = {unitID = uid, fireFrame = currentFrame + 30}
        end,
        CapPressure = SpineCapPressure,
        Threat      = SpineThreat,
        MexGridsReady = SpineMexGridsReady,
        GroundArmyValue = SpineGroundArmyValue,
    }
    WG.Spine = SPINE          -- lab_controller reads this
    SPINE.Start(currentFrame)
    Spring.Echo(string.format("[MC] spine based on block cell (%d, %d)", sb.anchorX, sb.anchorZ))
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    local ok1, r1 = pcall(VFS.Include, "LuaUI/Widgets/blueprint_placer.lua")
    local ok2, r2 = pcall(VFS.Include,
        "LuaUI/Widgets/blueprints/general/bad_com_start.lua")
    if not ok1 then Spring.Echo("[MC] ERROR loading blueprint_placer: " .. tostring(r1)); return end
    if not ok2 then Spring.Echo("[MC] ERROR loading bad_com_start: "    .. tostring(r2)); return end
    local ok5, r5 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/con_bot_grid.lua")
    if not ok5 then Spring.Echo("[MC] ERROR loading con_bot_grid: " .. tostring(r5)); return end
    local ok6, r6 = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/tile_crew.lua")
    if not ok6 then Spring.Echo("[MC] ERROR loading tile_crew: " .. tostring(r6)); return end
    TILE_BP, TC = r5, r6
    -- Labs the lab controller must leave alone: the air lab while it owes us air cons, and
    -- the opening bot lab for good once the air lab is up (it is being reclaimed, and is
    -- walled in by the tiles: nothing it built could get out).
    WG.TileLabHold = function(labID)
        if labID == nil then return false end
        if labID == airLabID and airConsOrdered > 0 then return true end
        return labID == botLabID and TS.airLabDone
    end

    -- The spine (SPINE_BOT's unit production).  If any of it fails to load the bot still
    -- plays, just with no army production beyond what the hand-off lab makes.
    local okS, rS = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/spine.lua")
    if okS and rS then
        local all = true
        for kind, file in pairs(rS.BLUEPRINT) do
            local okB, rB = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/" .. file .. ".lua")
            if okB and rB then SPINE_BPS[kind] = rB
            else all = false; Spring.Echo("[MC] ERROR loading spine blueprint " .. file
                                          .. ": " .. tostring(rB)) end
        end
        if all then SPINE = rS else Spring.Echo("[MC] spine disabled: blueprint missing") end
    else
        Spring.Echo("[MC] ERROR loading spine: " .. tostring(rS))
    end
    NANO_ASSIST_NUM = 0
    for _, u in ipairs(r2.layout) do
        if u.n == "cornanotc" then NANO_ASSIST_NUM = NANO_ASSIST_NUM + 1 end
        local ud = UnitDefNames[u.n]
        if ud and ud.isFactory and not TS.botLabName then TS.botLabName = u.n end
    end
    local ok3, r3 = pcall(VFS.Include,
        "LuaUI/Widgets/blueprints/general/mex_grid_alab.lua")
    if not ok3 then Spring.Echo("[MC] ERROR loading mex_grid_alab: " .. tostring(r3)); return end
    local ok4, r4 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/upgrade.lua")
    if ok4 then UPGRADE_BP = r4
    else Spring.Echo("[MC] no upgrade blueprint (" .. tostring(r4) .. "); retrofits disabled") end
    BP_PLACER    = r1
    BUILD_ORDER  = r2
    NANO         = r1.NANO
    MEX_GRID_BP  = r3
    GRID_SPACING = BP_PLACER.GRID_SPACING

    if DEBUG then
        -- Real footprints, to check them against the sizes blueprint_gen assumed.
        for _, n in ipairs({"corwin", "cormex", "cornanotc", "corlab", "corck"}) do
            local ud = UnitDefNames[n]
            if ud then
                Spring.Echo(string.format("[MC] def %s xsize=%s zsize=%s buildDist=%s",
                    n, tostring(ud.xsize), tostring(ud.zsize), tostring(ud.buildDistance)))
            end
        end
    end

    myTeamID = spGetMyTeamID()
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        if IsCommander(spGetUnitDefID(uid)) then
            commanderID = uid
            break
        end
    end
    if commanderID then StartBuildOrder() end
end

function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if not myTeamID then myTeamID = spGetMyTeamID() end
    if teamID ~= myTeamID then return end

    -- Must come first: the corlab is itself a queue item, and so is anything
    -- else that would hit an early return below.
    if distState then
        BP_PLACER.OnUnitCreated(distState, unitID, unitDefID, builderID)
    end
    if SPINE then SPINE.OnUnitCreated(unitID, unitDefID, builderID) end

    local d = UnitDefs[unitDefID]
    if not d then return end

    if d.isFactory then
        if airLabDefID and unitDefID == airLabDefID and not airLabID then
            airLabID = unitID
            if DEBUG then Spring.Echo("[MC] air lab frame " .. unitID) end
        elseif not botLabID and not airLabID and d.name == TS.botLabName then
            -- The lab bad_com_start places, not just the first factory: a vehicle plant
            -- rushed in for defence must not become the con-bot factory.
            botLabID = unitID
            if DEBUG then Spring.Echo("[MC] bot lab " .. unitID) end
        end
        return
    end

    -- Con bots start life inside the lab; they are only usable once finished.  Only the
    -- con def itself: the lab controller also makes rez bots here (ground builders too).
    if builderID and builderID == botLabID and unitDefID == conDefID then
        pendingCons[unitID] = true
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]

    if IsCommander(unitDefID) and not commanderID then
        commanderID = unitID
        StartBuildOrder()
    end

    -- Lab done → queue con bot #1.  The rest follow one at a time (MaybeQueueNextCon).
    if unitID == botLabID then
        conDefID = FindConBotDefID(unitDefID)
        if conDefID then
            spGiveOrderToUnit(botLabID, -conDefID, {0}, {})
            TS.conOrderOpen = true
        end
        if DEBUG then Spring.Echo("[MC] lab finished, con #1 queued") end
    end

    if d and d.isFactory then
        factories[unitID] = true
        -- An advanced air lab can make the T2 con that does retrofits.
        if UPGRADE_BP and unitID ~= airLabID then
            local t2 = FindAirConDefID(unitDefID)
            if t2 and IsT2Con(t2) then
                for _ = 1, UPGRADE_CONS_PER_LAB do
                    spGiveOrderToUnit(unitID, -t2, {0}, {})
                end
            end
        end
    end

    -- Air lab finished -> the grid system takes over from here.
    if unitID == airLabID then
        TS.airLabDone = true
        StartGridExpansion()
        DispatchConBots()
    end

    -- Air cons roll out.  The factory gives them a guard order on itself as they
    -- leave, which arrives AFTER this callback -- so stopping only here leaves them
    -- assisting the lab forever, permanently "busy", and they never take a grid.
    -- Stop now and again once that order has landed.
    if airLabID and d and d.isBuilder and d.canFly and not d.isFactory then
        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
        pendingStops[#pendingStops + 1] = {unitID = unitID, fireFrame = currentFrame + 30}
        if IsT2Con(unitDefID) then
            freeT2Cons[#freeT2Cons + 1] = unitID
            TryAssignUpgrades()
        else
            AirConOrderDone()
            -- Mex grids first (starting them fast is what scales the economy); the spine
            -- gets a new con only when no grid is waiting for one.
            if not (#pendingGrids == 0 and SPINE and SPINE.OfferCon(unitID)) then
                freeAirCons[#freeAirCons + 1] = unitID
                TryAssignGrids()
            end
        end
    end

    if pendingCons[unitID] then
        pendingCons[unitID] = nil
        conCount = conCount + 1
        conBots[#conBots + 1] = unitID
        TS.conOrderOpen = false
        TS.lastConFrame = currentFrame
        if not conBot1ID and not TS.con1Released then
            -- Con #1 builds the com-start nano first (the commander cannot).
            conBot1ID = unitID
            TS.con1JoinFrame = currentFrame
            BP_PLACER.AddBuilder(distState, unitID)
        elseif crew then
            TC.AddCon(crew, unitID)
        end
        Spring.Echo(string.format("[MC] con #%d out at frame %d (%d)", conCount, currentFrame, unitID))
    end

    local x, _, z = spGetUnitPosition(unitID)
    if distState then
        BP_PLACER.OnUnitFinished(distState, unitID, unitDefID, x, z)
    end
    if crew then TC.OnUnitFinished(crew, unitID, unitDefID, x, z) end
    if SPINE then SPINE.OnUnitFinished(unitID, unitDefID, x, z) end
    for _, gs in ipairs(gridStates) do
        if not gs.done then
            BP_PLACER.OnUnitFinished(gs, unitID, unitDefID, x, z)
        end
    end
    for _, us in ipairs(upgradeStates) do
        if not us.done then
            BP_PLACER.OnUnitFinished(us, unitID, unitDefID, x, z)
        end
    end
    for _, cs in ipairs(consolidateJobs) do
        if not cs.done then
            BP_PLACER.OnUnitFinished(cs, unitID, unitDefID, x, z)
        end
    end
    for _, cs in ipairs(capstoneJobs) do
        if not cs.done then
            BP_PLACER.OnUnitFinished(cs, unitID, unitDefID, x, z)
        end
    end
    -- A nuke silo is a stockpiling weapon, not a factory, so nothing else will
    -- ever tell it to build a missile.  Ask for a few; firing them is not wired up.
    if d and d.canStockpile then
        for _ = 1, 3 do
            spGiveOrderToUnit(unitID, CMD_STOCKPILE, {}, {})
        end
        Spring.Echo("[MC] " .. (d.name or "?") .. " finished: stockpiling")
    end
end

-- Fires when a finished unit actually leaves the factory: the last moment the
-- engine's auto-guard can be applied, so clear it here too.
function widget:UnitFromFactory(unitID, unitDefID, teamID, factID)
    if teamID ~= myTeamID then return end
    if factID and factID == airLabID then
        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
    end
    if SPINE then SPINE.OnUnitFromFactory(unitID, unitDefID, factID) end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    if DEBUG then
        local x, _, z = spGetUnitPosition(unitID)
        Spring.Echo(string.format("[MC] lost %s id=%s at (%s,%s) f=%d beingBuilt=%s",
            UnitDefs[unitDefID] and UnitDefs[unitDefID].name or "?", tostring(unitID),
            tostring(x and math.floor(x)), tostring(z and math.floor(z)),
            currentFrame, tostring(Spring.GetUnitIsBeingBuilt(unitID))))
    end
    if distState then BP_PLACER.OnUnitDestroyed(distState, unitID) end
    pendingCons[unitID] = nil
    factories[unitID]   = nil
    if SPINE then SPINE.OnUnitDestroyed(unitID) end
    if unitID == commanderID then commanderID = nil end
    if unitID == conBot1ID   then conBot1ID   = nil end
    if unitID == botLabID    then botLabID    = nil end
    if unitID == comGuardTarget then comGuardTarget = nil end
end

-- ── GameFrame, split up ──────────────────────────────────────────────────────
-- Lua 5.1 allows a function at most 60 UPVALUES -- every file-level local it
-- mentions is one.  GameFrame grew past that and the widget silently failed to
-- load ("function at line N has more than 60 upvalues").  Each block below is a
-- separate function so the references are spread across several budgets.

local function FirePendingStops(frame)
    local i = 1
    while i <= #pendingStops do
        local ps = pendingStops[i]
        if frame >= ps.fireFrame then
            if spGetUnitDefID(ps.unitID) then
                spGiveOrderToUnit(ps.unitID, CMD_STOP, {}, {})
            end
            table.remove(pendingStops, i)
        else
            i = i + 1
        end
    end
end

local function UpdateHandoff(frame, resources)
    -- Trigger: metal income at AIR_LAB_INCOME for BANK_HOLD frames -- the tiles have
    -- built a decent economy and the grids take over from here.
    if not handoffStarted then
        local tileReady = false
        for _, t in ipairs(crew and TC.FinishedTiles(crew) or {}) do
            if t.row ~= TC.LAB_EXIT_ROW then tileReady = true; break end
        end
        if resources.metalIncome >= CFG.AIR_LAB_INCOME
           and (tileReady or frame >= CFG.AIR_LAB_LATEST) then
            bankFrames = bankFrames + 10
            if bankFrames >= BANK_HOLD then StartHandoff() end
        else
            bankFrames = 0
        end
    end

    -- Watchdog: queued but nothing has begun building it.
    if airLabItem and not airLabID and airLabFrame and (frame - airLabFrame) > 900 then
        local st = airLabItem.status
        if st == "skipped" or st == "pending" then
            -- The spot was taken (usually by the build order itself).  Try again
            -- elsewhere: without this lab there is no army and no expansion, so
            -- giving up once is giving up for the whole game.
            airLabRetries = (airLabRetries or 0) + 1
            local it = airLabItem
            local test = Spring.TestBuildOrder(it.defID, it.wx, spGetGroundHeight(it.wx, it.wz) or 0,
                                               it.wz, it.f)
            local holder = BP_PLACER.GetClaim and commanderID
                           and BP_PLACER.GetClaim(distState, commanderID)
            Spring.Echo(string.format(
                "[MC] hand-off retry %d: %s at (%d, %d) facing %d not started (status=%s, "
                .. "test now=%s, testFails=%s, builders=%d, commander claim=%s), picking a new spot",
                airLabRetries, tostring(it.n), it.wx, it.wz, it.f or -1, tostring(st), tostring(test),
                tostring(it.testFails), #distState.builders, tostring(holder and holder.n)))
            TS.airLabFailed[it.wx .. "," .. it.wz .. "," .. (it.f or 0)] = true
            airLabItem.status = "skipped"
            airLabItem.built  = true
            airLabItem = nil
            if airLabRetries <= 5 then
                handoffStarted = false     -- StartHandoff runs again next tick
                bankFrames     = BANK_HOLD -- and fires immediately
            elseif not airLabWarned then
                airLabWarned = true
                Spring.Echo("[MC] hand-off GAVE UP after 5 attempts")
            end
        end
    end
end

local function UpdateGrids(frame, resources)
    local i = 1
    while i <= #gridStates do
        local gs = gridStates[i]
        if gs.done then
            -- Reuse the con: for a new grid, or as a demolition crew once the cap
            -- is tight.  It used to simply vanish from the pool here.
            if gs.builderID and spGetUnitDefID(gs.builderID) then
                freeAirCons[#freeAirCons + 1] = gs.builderID
            end
            table.remove(gridStates, i)
        else
            BP_PLACER.Update(gs, frame, resources)
            i = i + 1
        end
    end
    ReleaseGridCandidates(frame, resources)
    if #freeAirCons > 0 and #pendingGrids > 0 then TryAssignGrids() end
    ExpireAirConOrders()
    UpdateAirLabAssist(frame)
    if frame % 900 == 0 and frame > 0 then AC.LogBuildPower(frame) end
    KeepAirConReserve()
end

local function CheckCapPressure()
    if consolidateOn then
        if windDefID then
            for _, gs in ipairs(gridStates) do
                gs.skipDefIDs = gs.skipDefIDs or {}
                gs.skipDefIDs[windDefID] = true
            end
        end
        return
    end
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(myTeamID)
    local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(myTeamID)
    if not (maxU and cnt) or (maxU - cnt) > CapSlack(CONSOLIDATE_SLACK) then return end

    consolidateOn = true
    windDefID = UnitDefNames["corwin"] and UnitDefNames["corwin"].id
    -- Every grid becomes retrofit-eligible right now, finished or not.  From here
    -- they stop building wind, so their remaining T1 eco is all they will ever
    -- have -- and a T1->T2 mex upgrade costs no unit cap, so there is nothing to
    -- gain by waiting for a completion that can no longer happen.
    local marked = 0
    for _, g in ipairs(allGridAnchors) do
        if not gridFinished[g.key] then
            gridFinished[g.key] = true
            AddCompletedAnchor(g.anchorX, g.anchorZ)
            marked = marked + 1
        end
    end
    Spring.Echo(string.format(
        "[MC] unit cap tight: grids stop building wind, consolidation on, "
        .. "%d more grids marked for retrofit", marked))
    TryAssignUpgrades()
end

local function UpdateRetrofits(frame, resources)
    -- Retrofits yield to everything else when metal is short: a T2 mex earns less
    -- per metal than a T1, so competing with a normal grid during a stall is
    -- strictly bad.  Stop the builders rather than pausing, or they sit holding a
    -- half-issued order.
    local mFrac = resources.metalStorage > 0
                  and (resources.metal / resources.metalStorage) or 1
    if not retrofitPaused and mFrac < RETROFIT_STALL_FRAC then
        retrofitPaused = true
        for _, us in ipairs(upgradeStates) do
            if us.builderID and spGetUnitDefID(us.builderID) then
                spGiveOrderToUnit(us.builderID, CMD_STOP, {}, {})
                us.currentTask = nil
            end
        end
        if DEBUG then Spring.Echo("[MC] retrofits paused (metal stall)") end
    elseif retrofitPaused and mFrac > RETROFIT_RESUME_FRAC then
        retrofitPaused = false
        if DEBUG then Spring.Echo("[MC] retrofits resumed") end
    end

    if not retrofitPaused then
        local i = 1
        while i <= #upgradeStates do
            local us = upgradeStates[i]
            if us.done then table.remove(upgradeStates, i)
            else
                BP_PLACER.Update(us, frame, resources)
                i = i + 1
            end
        end
    end
    local reserve = consolidateOn and 1 or 0
    if #freeT2Cons > reserve then TryAssignUpgrades() end
end

local function UpdateConsolidation(frame, resources)
    if consolidateOn then
        if frame % CONSOLIDATE_SCAN == 0 or #windBlocks == 0 then
            ScanWindBlocks()
        end
        -- Converting wind beats upgrading another grid at the cap, so every free
        -- T2 con starts a job immediately rather than one per scan.
        while #freeT2Cons > 0 and #windBlocks > 0 do
            local conID = freeT2Cons[1]
            if not spGetUnitDefID(conID) then
                table.remove(freeT2Cons, 1)
            elseif StartConsolidation(conID, resources) then
                table.remove(freeT2Cons, 1)
            else
                break
            end
        end
    end

    local i = 1
    while i <= #consolidateJobs do
        local cs = consolidateJobs[i]
        if cs.done then
            if cs.builderID and spGetUnitDefID(cs.builderID) then
                freeT2Cons[#freeT2Cons + 1] = cs.builderID
            end
            table.remove(consolidateJobs, i)
        else
            BP_PLACER.Update(cs, frame, resources)
            i = i + 1
        end
    end
end

local function UpdateCapstones(frame, resources)
    if #pendingCapstones > 0 and #freeT2Cons > 0 then TryAssignCapstones() end
    local i = 1
    while i <= #capstoneJobs do
        local cs = capstoneJobs[i]
        if cs.done then
            if cs.builderID and spGetUnitDefID(cs.builderID) then
                freeT2Cons[#freeT2Cons + 1] = cs.builderID
            end
            table.remove(capstoneJobs, i)
        else
            BP_PLACER.Update(cs, frame, resources)
            i = i + 1
        end
    end
end

local energyNet = nil   -- smoothed energy income - pull, e/s

local function ReadResources()
    local _, m,  ms,  mp, mi = pcall(Spring.GetTeamResources, myTeamID, "metal")
    local _, em, ems, ep, ei = pcall(Spring.GetTeamResources, myTeamID, "energy")
    local net = (ei or 0) - (ep or 0)
    energyNet = energyNet and (energyNet + NET_SMOOTH * (net - energyNet)) or net
    return {
        metal  = m  or 0, metalStorage  = ms  or 1000,
        energy = em or 0, energyStorage = ems or 1000,
        metalIncome = mi or 0, metalPull = mp or 0,
        energyIncome = ei or 0, energyPull = ep or 0,
        energyNet = energyNet,
    }
end

-- Grid interrupts: the placer's metal interrupt, and an energy interrupt that fires on the
-- projected level instead of the current one (see ENERGY_LOOKAHEAD).  Same name and
-- priority as the placer's, so interrupt episodes behave exactly as before.
local earlyEnergyChecks = 0   -- checks that fired only because of the look-ahead
local function EnergyLookahead(state, res, frame)
    local st = res.energyStorage
    if not st or st <= 0 then return false end
    -- Ready for a rush: energy income has to cover eco plus part of full army spend.
    if SPINE and SPINE.EnergyShort(res) then return true end
    local projected = res.energy + math.min(0, res.energyNet or 0) * ENERGY_LOOKAHEAD
    local fires = projected / st < ENERGY_LOW
    if fires and res.energy / st >= ENERGY_LOW then earlyEnergyChecks = earlyEnergyChecks + 1 end
    return fires
end

GridInterrupts = function()
    return {
        {name = "energy", priority = 2, buildType = "energy", check = EnergyLookahead},
        BP_PLACER.GRID_INTERRUPTS[2],          -- metal, unchanged
    }
end

-- Tiles: the grid pair, plus "bank": metal piling up means build power is what is
-- short, so the next job is a nano.  Lowest priority, and never preempts.
local function BankCheck(state, res, frame)
    return res.metal >= CFG.BANK_NANO_METAL and res.metalStorage > 0
       and res.metal / res.metalStorage >= CFG.BANK_NANO_FRAC
end

-- None of them preempts: a tile has no nanos to take over a half-built frame, so pulling
-- the con off it leaves the frame to decay and its metal is lost (seen in the first
-- match: wind frames dying while their con ran off to an energy interrupt).  A tile item
-- takes seconds, so choosing the NEXT job is soon enough.
-- Tiles are metal-bound early (stall_m 0.6-0.9 around 3-5 min while energy floated 0.4-0.9),
-- so metal outranks a merely PROJECTED energy shortfall.  Energy that is actually low still
-- comes first: a mex with no energy behind it earns nothing.  SPINE's "energy short" test
-- (stock for a rush) is a grid concern and stays out of the tiles.
local function TileEnergyNow(state, res, frame)
    local st = res.energyStorage
    return st ~= nil and st > 0 and res.energy / st < ENERGY_LOW
end
local function TileEnergySoon(state, res, frame)
    local st = res.energyStorage
    if not st or st <= 0 then return false end
    local projected = res.energy + math.min(0, res.energyNet or 0) * ENERGY_LOOKAHEAD
    return projected / st < ENERGY_LOW
end

TileInterrupts = function()
    local metal = BP_PLACER.GRID_INTERRUPTS[2]
    return {
        {name = "energy_now",  priority = 3, buildType = "energy", check = TileEnergyNow,  noPreempt = true},
        {name = metal.name,    priority = 2, buildType = metal.buildType, check = metal.check, noPreempt = true},
        {name = "energy_soon", priority = 1, buildType = "energy", check = TileEnergySoon, noPreempt = true},
        -- No "bank -> nano" interrupt for tiles.  When metal banked (grids opening ~4:00)
        -- every tile con switched to its tile's nanos, which a lone con builds slowly, and
        -- the rows stalled; whether a run tipped into that decided the result.  Mirror
        -- runs, metal used at 7:30, n=8 each: with it 22.6k (sd 1.25k, 21.1-25.1k),
        -- without it 23.9k (sd 1.10k, 7 of 8 in 23.3-24.8k).  BankCheck stays for reuse.
    }
end

function widget:GameFrame(frame)
    currentFrame = frame
    if not myTeamID or not BP_PLACER then return end

    if startPending and frame >= START_FRAME then BeginBuildOrder() end
    if not distState then return end

    FirePendingStops(frame)

    if frame % 10 ~= 0 then return end

    local resources = ReadResources()
    MaybeQueueNextCon(frame, resources)
    ReleaseCon1(frame)
    TC.Update(crew, frame, resources)
    DispatchConBots()
    UpdateReclaims(frame)
    if frame % 1800 == 0 and earlyEnergyChecks > 0 then
        Spring.Echo(string.format("[MC] energy look-ahead: %d grid checks fired early this minute "
            .. "(net %.0f e/s, stored %.0f)", earlyEnergyChecks, energyNet or 0, resources.energy))
        earlyEnergyChecks = 0
    end

    -- Retire finished and dead nano assignments first, so freed nanos are
    -- available to everything that asks for one later in this same tick.
    NANO.Sweep()

    UpdateHandoff(frame, resources)
    MaybeQueueVehicleLab(frame)
    UpdateGrids(frame, resources)
    CheckCapPressure()
    UpdateRetrofits(frame, resources)
    UpdateConsolidation(frame, resources)
    UpdateCapstones(frame, resources)

    if frame % RECLAIM_EVERY == 0 then UpdateWindReclaim() end
    UpdateSpendPressure(resources)

    -- Phases before the placer runs: the commander must be out of the builder pool
    -- before Update hands it a claim it is about to abandon.
    UpdateCommanderPhase(frame, resources)
    if SPINE then SPINE.Update(frame, resources) end

    if not distState.done then
        BP_PLACER.Update(distState, frame, resources)
    end
end
