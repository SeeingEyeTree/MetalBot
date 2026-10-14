-- bar_framework/line_transition.lua  (economy line; used by LINE_CLICK_v16)
-- The line's transition: an air lab, two nanos beside it, then air cons running mex grids.
--
--   1. WAIT.  The line builds as usual; no slot is reserved.  Each tick the closest 6 open slots (3x2) to an outer
--      lane's con (lane 4, else 3) are the candidate site.
--   2. TRIGGER.  The air lab goes down when it can be built flat out, not limited by metal:
--          T = lab buildTime / (build power that can reach it)         seconds
--          metal bank + metal income * T  >=  lab metal cost
--      (BP = that con + every nano in range of the spot.)  A latest-frame fallback forces it.
--   3. LAB.  The site's 6 slots are taken (the line stops using them) and the lab is a line_crew job on that con.
--   4. NANOS.  Two nanos on open slots beside the lab, then idle nanos in reach guard the lab while it owes air cons.
--   5. GRIDS.  Air cons run mex_grid_alab blueprints.  The first grid sits GAP elmos (48 = 3 cells) beyond the
--      line's outer edge, centred on the lab; the rest follow the normal adjacency expansion, minus any cell
--      that would overlap the line.  From here it is TILE_BOT's grid system: spend-pressure hand-off, the T2 air
--      lab capstone, and T2 retrofits of finished grids (not ported: wind consolidation, the spine, the silo capstone).
--
-- Log lines: "[LT] ...".

local LT = {}
local CB = VFS.Include("LuaUI/Widgets/bar_framework/con_broker.lua")   -- every air con's owner: jobs ask it for cons (see the header there)
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")   -- Apply(): merge overrides + one [CFG] log row
local RegisterJobs                                                       -- defined below the jobs it registers

LT.NIL_OPTIONS = { "ANTINUKE_GRIDS", "BANK_LOW", "CAPSTONE_MAX", "CAP_SLACK_FRAC", "CONSOLIDATE_MAX", "CON_HOLD", "EARLY_CAPSTONES", "EARLY_CAPSTONE_NANOS", "FAST_OPEN_CAP", "HELP_ANY", "HELP_MAX", "HELP_NANOS", "NANO_CREW_NANOS", "PLANNER_CFG", "PLANNER_NEW_CELLS", "PLANNER_ONLY", "RECLAIM_BUDGET_FRAC", "RECLAIM_EVERY", "RETROFIT_FLOAT_BATCH", "RETROFIT_FLOAT_FRAC", "SPEND_SLOW", "STACK_HALF", "TIGHT_FLOAT_FRAC", "TIGHT_FLOAT_FRAMES", "TIGHT_FLOAT_START", "WIND_LATTICE", "EP_RATIO", "EP_BANK_SECONDS" }   -- options whose default is nil on purpose (bot_config.lua does not warn about them)
LT.CFG = {
    GAP            = 48,          -- elmos between the line's outer edge and the first grid
    LATEST_FRAME   = 6 * 60 * 30, -- build the lab by now whatever the bank says
    EARLIEST_FRAME = 10 * 30,     -- the bank test is the real gate; this only waits for the outer con to exist
    CLAIM_WHEN_OPEN = 14,         -- hold the site once the lane has this few open slots (6 lab + 2 nano + spare)
    LOG_EVERY      = 450,
    GRIDS_OPENING  = 3,           -- grids "opening" at once; all there is while the line is unfinished
    GRIDS_OPENING_MAX = 8,        -- ceiling for the bank / fast triggers once the line is built (a 6:00 log had 13 open)
    GRID_BANK      = 500,
    GRID_BANK_GAP  = 15 * 30,
    GRID_FAST_INCOME = 90,        -- metal income (M/s, smoothed) at which an idle air con opens a grid at once, bank or not:
                                  -- once units soak up the income the bank sits near 0 and the bank triggers never fire
                                  -- (20:02 match: 750-890 M/s at 14-16 min, bank ~200, one grid opening, 8-10 cells waiting)
    GRID_BANK_FAST = 3000,        -- ...or the bank at which it does so (no 15 s gap)...
    GRID_FAST_ENERGY = 0.05,      -- ...provided the energy bank is at least this share of storage
    GRID_HANDOFF   = 0.30,
    AIR_CON_RESERVE = 2,          -- T1 air cons kept ready beyond what the jobs want (con_broker reserve; the labs make up the shortfall)
    HELPER_CAP      = nil,        -- most air cons that may sit on the two helper jobs (grid helpers + fusion helpers) at once; nil = every open slot
                                  -- (3 per grid: 40-120 helpers by 15 min, and the labs kept ordering cons to fill them).  Free cons beyond it stay in
                                  -- the pool (the reserve), so production stops once helpers + jobs + reserve are covered.
    T2_CON_RESERVE  = 0,          -- same for T2 cons (0: they are made when an energy / retrofit job has none)
    T2_CONS_PER_GRID = false,     -- number: keep this many T2 cons per retrofit-eligible grid (extra builders on the retrofits; demand alone stalled at ~36 T2 cons while metal floated)
    T2_TOPUP_METAL_FRAC = 0.10,   -- ...ordered only while the metal bank holds at least this share of its storage
    RETROFIT_HOLD_FRAC = false,   -- number: while the metal bank holds this share of storage, retrofits may take the T2 cons the hold keeps for fusions / consolidation
    -- NO_IDLE (user, 2026-10-14, replay review): an air con must never stand doing nothing.
    IDLE_CON_SWEEP = false,       -- true: every IDLE_CON_FRAMES a con that is not building or moving gets an unfinished structure to assist; and while more than
    IDLE_CON_FRAMES = 240,        --   IDLE_CON_MAX cons have nothing to assist, no new air cons are ordered
    IDLE_CON_MAX = 3,
    CREW_CHAIN = false,           -- true: the nano crew builds the nanos finished nanos can reach (so they get assisted), grid after grid
    LAB_NANOS_FIRST_GRID = false, -- true: until the first grid's nanos stand, the air lab's nanos help that grid instead of guarding the lab
    T2_LAB_DEPTH = 3,             -- retrofit T2 cons: at most this many queued per advanced air lab (orders go to the least loaded lab)
    UPGRADE_CONS_PER_LAB = 2,     -- T2 cons each finished advanced air lab orders at once, when T2_CONS_UP_FRONT (else they are built only on demand)
    T2_CONS_UP_FRONT = false,     -- true: the pre-2026-10-14 rule (a finished advanced air lab orders UPGRADE_CONS_PER_LAB T2 cons straight away)
    RETROFIT_STALL_FRAC  = 0.15,  -- retrofit builders stop below this share of metal storage...
    RETROFIT_RESUME_FRAC = 0.30,  -- ...and resume above this
    SPEND_FAST = 0.15, SPEND_SLOW = 0.60,   -- grid hand-off progress: under-spending / short of metal
    BANK_HIGH = 0.25, BANK_LOW = 0.08,
    -- Unit-cap relief (TILE_BOT's values).  "Tight" = headroom under 1000 units, but never more than 20% of the cap.
    CONSOLIDATE_SLACK = 1000, CAP_SLACK_FRAC = 0.20, WIND_LATTICE = 48,
    CONSOLIDATE_SCAN = 300, CONSOLIDATE_MAX = 60,
    RECLAIM_TRIGGER_FRAC = 0.20, RECLAIM_BUDGET_FRAC = 0.02, RECLAIM_EVERY = 90,
    -- ENERGY PUSH (2026-10-08): from ~16:00 of a mirror game metal sat at
    -- its 30k cap and was wasted (pull 380 of 635 M/s) while energy ran at 93% of income -- army units cost ~15 E per
    -- metal, so energy, not metal, capped spending.  When metal floats and energy is the binding resource, free T2 cons
    -- turn 2x2 blocks of winds into fusions (the consolidation job, before the unit cap), up to EP_INFLIGHT at once;
    -- with no free T2 con an idle advanced air lab makes one.
    -- GRID EXPANSION (2026-10-08).  In a 30-minute game v12 sat at 2
    -- grids from 4:00 to 7:40 and at 7-8 from 9:30 to 15:00 with 2-4 air cons idle and 0 cells waiting:
    --   COLLECT_ALWAYS: new cells were only looked for while the bank held GRID_BANK metal, and the army spends the
    --     bank -- look whenever the list is empty;
    --   GRID_ENEMY_SIDE: cells were never allowed past the line's enemy-facing edge, i.e. toward the map interior; with
    --     the base ~850 from the map edge that left one row of grids.  Allow cells this many elmos past that edge (0 = old).
    COLLECT_ALWAYS = true,
    GRID_ENEMY_SIDE = 1500,
    --   LINE_GATE: while the line is unbuilt only GRIDS_OPENING grids may open (v13 run: 3 grids from 5:00 to 7:30 with 2
    --     air cons idle and cells waiting).  false = the bank / fast rules apply while the line is still being built.
    LINE_GATE = false,
    --   GRID_BALANCE / GRID_INTR_MIN_NANOS (user, watching v13): grids were built in blueprint order -- nanos first --
    --     while metal was short.  The metal interrupt only fires under 150 metal banked AND needs 2 nanos in reach of
    --     the mex.  GRID_BALANCE adds the placer's utilisation interrupts (mex when metal is the pressed resource, wind
    --     when energy is, a nano only when neither is used); GRID_INTR_MIN_NANOS = 0 lets an air con place a mex with
    --     no nano in reach yet.  false / nil = the old behaviour.
    GRID_BALANCE = true,
    GRID_INTR_MIN_NANOS = 0,
    ENERGY_PUSH = true,
    SHARE_GOV = false,            -- bar_framework/spend_governor.lua: make the spine army share bind (pauses grids / tunes the spine)
    FAST_OPEN_CAP = nil,          -- max grids opening at once in the fast-income path (nil = no cap)
    COLLECT_DONE_ONLY = false,    -- new cells only next to grids whose nanos are up (DRAGON_BOT's rule), not next to every assigned grid
    ANTINUKE_GRIDS = nil,   -- grids crowned with an anti-nuke (corfmd) the same way, e.g. { [4] = true, [9] = true }; nil = none
    SILO_GRIDS = { [6] = true, [12] = true },   -- grids crowned with a nuke silo (built by a T2 con once the grid is up)
    CAPSTONE_MAX = nil,           -- grids numbered above this skip their T2 lab capstone
    ENERGY_BUILDING = nil,        -- what a wind block becomes under energy push / consolidation (default corfus; corafus = 3000 E in the same 96x96)
    EARLY_CAPSTONES = nil, EARLY_CAPSTONE_NANOS = 4,   -- the first N grids build their T2 lab once this many nanos stand
    RETROFIT_FLOAT_CONS = false, RETROFIT_FLOAT_FRAC = 0.2, RETROFIT_FLOAT_BATCH = 2,   -- idle T2 labs make cons while metal floats and grids wait
    GRID_PLANNER = false, PLANNER_CFG = nil,   -- bar_framework/eco_planner.lua: simulate the next 90 s to pick mex / wind / nano
    GRID_STALL_RULE = false,      -- grid builders: metal stalling -> mex, energy stalling -> wind, neither -> nano (blueprint_placer.StallRuleInterrupts)
    -- NANO_CREW (user, 2026-10-12): once NANO_CREW_AFTER grids are open, the next NANO_CREW_SIZE air cons are a crew that builds NANOS in
    --   grids with fewer than NANO_CREW_NANOS finished nanos: each idle member goes to the grid nearest it and takes NANO_CREW_NANOS of that
    --   grid's unbuilt nano items (build orders on the same spots the grid's own builder uses, so the two assist each other).
    --   The crew works TOGETHER: all idle members on one grid at a time, ALL on one nano first and then the next (a finished nano adds its BP to the next), until it has NANO_CREW_NANOS
    --   finished, then the whole crew moves to the next nearest grid.
    --   NANO_CREW_GRIDS = a number makes the count follow demand: one crew per that many open grids that still have fewer than
    --   NANO_CREW_NANOS nanos (and nano spots left), at least NANO_CREW_MIN and at most NANO_CREW_SIZE, a surplus idle member
    --   going back to the grid pool.  false (default, 2026-10-12: the 4-con crew measured better than 5 grids per crew, one game each)
    --   = a fixed crew of NANO_CREW_SIZE.
    -- GRID_UNITS / GRID_CAP_FRAC (user, 2026-10-12): grids are counted by what they LEAVE once retrofitted and
    --   consolidated -- the mexes and fusions that belong to the grid (GRID_UNITS = 32; the nanos can help a lab or self-destruct and the
    --   winds go) -- not by their 73 blueprint items.  A new grid opens only while (grids opened + pending + 1) x GRID_UNITS fits under
    --   cap x GRID_CAP_FRAC.  (A limit on how many grids may be unfinished at once froze the economy: tried and removed.)  false = no limit.
    GRID_UNITS = 32, GRID_CAP_FRAC = false,
    -- FUSION_HELPERS (user, 2026-10-12): energy is priority #1 once wind consolidation starts (income falls as winds go).  The
    --   consolidation keeps T2 cons back from retrofits for fusions, makes T2 cons when none is free, always builds fusions while
    --   energy binds or its income is falling (below CONSOL_FALLING of its peak), and every available air con (FUSION_HELPERS = true; a number caps each job) guards a fusion job's
    --   builder, spread evenly (false = none).  CONSOL_FUSION_CONS = T2 cons kept back from retrofits for fusion jobs.
    FUSION_HELPERS = false, CONSOL_FALLING = 0.9, CONSOL_FUSION_CONS = 4,
    -- ENERGY_PRIORITY (user, 2026-10-12): while energy is stalling (the energy push / consolidation / energy cell wants energy), every
    --   builder that can help puts energy buildings first: nano turrets in reach of a fusion job guard its builder at the broker's top
    --   priority (NANO.PRIO.ENERGY), and idle air cons come from the free pool, the grid helpers and the idle nano crew.  false = off.
    ENERGY_PRIORITY = false,
    -- AUDIT_EVERY (frames, false = off): a "[AUDIT]" row per interval -- over every grid box (GRID_SPACING square round each anchor):
    --   nanos / T1 and T2 mexes / fusions, how many grids have fewer than 2 nanos, and how many are FULLY upgraded (AUDIT_FULL_MOHO T2
    --   mexes and AUDIT_FULL_FUS fusions of the upgrade blueprint, 12 nanos).
    -- RETROFIT_MEX_DONE (user, 2026-10-12): a grid may be retrofitted as soon as every mex of it stands (the winds trail for minutes and
    --   are consolidated anyway) -- before, only a fully built grid (73 items) could be, and with 56 grids open that was one grid at 14:00.
    --   Such a grid stops building winds.
    RETROFIT_MEX_DONE = false,
    AUDIT_EVERY = false, AUDIT_FULL_MOHO = 18, AUDIT_FULL_FUS = 4, AUDIT_FULL_NANOS = 12,
    NANO_CREW = false, NANO_CREW_AFTER = 6, NANO_CREW_SIZE = 4, NANO_CREW_NANOS = 2, NANO_CREW_GRIDS = false, NANO_CREW_MIN = 1,
    NANO_CREW_GROUP = 4,      -- the crew works in groups of this many cons, each group on its OWN grid
    NANO_CREW_SIZE_FULL = false,   -- a number (16): once every grid is open (no new grid can open) the crew grows to this many, so new air cons go to nanos
    NANO_CREW_FULL = false,   -- a number (12): once every open grid has NANO_CREW_NANOS, the crew works grids up to this many nanos
    GRID_HELPERS = false, HELP_NANOS = 2, HELP_MAX = 2, HELP_ANY = false,   -- HELP_ANY: idle air cons guard the builder of ANY unfinished grid (oldest first, HELP_MAX each), not only one short of nanos
       -- idle air cons guard the builder of a grid with fewer than HELP_NANOS nanos up
    GRID_COMPACT = false,         -- open the candidate cell nearest the line's centre first
    TIGHT_ON_FLOAT = false, TIGHT_FLOAT_FRAC = 0.5, TIGHT_FLOAT_FRAMES = 20 * 30, TIGHT_FLOAT_START = 9 * 60 * 30,   -- see CheckCapPressure
    RETROFIT_EARLY = true,       -- grids are retrofit-eligible once their nanos are up (not at 70% built / the unit cap going tight)
    EP_START = 10 * 60 * 30, EP_MFRAC = 0.30, EP_MIN_METAL = 3000,   -- "metal floats"
    EP_EFRAC = 0.50, EP_EPULL = 0.85,                                -- "energy binds": bank under half, pull >= 85% of income
    ECELL_FIRST = false,      -- an energy cell does not wait for the wind blocks to be consolidated first (a cell is 16 fusions, a block 1)
    ECELL_MAKE_CON = false,   -- an energy cell with no free T2 con asks an advanced air lab for one
    EP_CON_FORCE = false,   -- make the T2 con in any advanced air lab, not only one with an empty queue
    EP_RATIO = nil, EP_RATIO_MIN_INCOME = 300,   -- look-ahead: energy income under EP_RATIO x metal income counts as binding (nil = off)
    EP_BANK_SECONDS = nil,   -- also "energy binds" when the bank holds fewer than this many seconds of pull (nil = only the EP_EFRAC share)
    EP_INFLIGHT = 2, EP_EVERY = 300, EP_CON_EVERY = 1800, EP_CON_BATCH = 1,
    -- ENERGY CELLS (2026-10-09): the mex grids have no room for more fusions, and wind blocks
    -- run out.  When energy binds while metal floats (the ENERGY PUSH test) a free T2 con opens a whole lattice cell for
    -- fusions -- blueprints/general/energy_cell.lua, 12 nanos + 16 fusions, derived from fussion_grid_60x60 -- next to the
    -- grids, on our side of the map.  Prefers wind blocks while some are left, unless T2 cons are idle.
    ECELL = true, ECELL_MAX_ACTIVE = 2, ECELL_TOTAL = 8, ECELL_EVERY = 300, ECELL_PROBE_MIN = 9,
    ECELL_ALWAYS_BELOW = 0.35,     -- also when the energy bank is under this share of storage and pull >= income (no metal test)
    AIR_CON_TIMEOUT = 80 * 30,
    -- Vehicle lab (the spine's seed): finished by ~4:30 (the human reference had its lab done at 3:57 and its
    -- units arrived at ~5:30); it is queued backwards from that deadline.  4 slots (2x2) on the other outer lane.
    VP_DONE_FRAME = 3 * 60 * 30 + 30 * 30,
    VP_MARGIN     = 10 * 30,
    VP_COLS       = 2,
    VP_NAME       = "corvp",
    SPINE_GAP     = 0,            -- elmos between the line's outer edge and spine cell 1 (in front of the vehicle lab)
    VP_CONS       = 1,            -- ground cons the vehicle lab makes first: they build the spine (no air cons do)
    SPINE_EARLY_CONS = 1,         -- ground cons the spine may have (alive + ordered) until its cell 1 is built
    AIR_CON_AT_BACK = false,      -- true: an air con goes on the END of the air lab's queue, so a defence insert (Shuriken) ahead of it
                                  -- is built first; false: it is inserted ahead of the queue (after the unit in progress)
    AIR_CON_CAP_EARLY = 3,        -- air cons allowed (alive + ordered) until the air lab's two nanos stand (or, as a
    AIR_CON_CAP_UNTIL = 0.30,     -- fallback, the first grid is this share built)
    -- CON_HOLD (RAID_BOT): function() -> true while no air lab should make constructors (a ground raid on the base: the air
    -- labs make Shurikens / Wasps instead).  Holds new air-con / T2-con orders; the air-con reserve catches up afterwards.
    CON_HOLD      = nil,
    -- GRID_RECOVER (RAID_BOT, user 2026-10-13: "the mex grids died early and did not recover"): a finished grid used to be
    -- forgotten.  Now its mex spots are watched; once a spot has stood empty for two looks in a row (and no raid cluster
    -- is within RECOVER_SAFE_R), a plain grid is re-run through the normal grid pipeline (standing items are skipped), and a
    -- retrofitted one is opened for retrofit again (a T2 con rebuilds the moho mexes straight away).
    GRID_RECOVER      = false,
    RESERVE_COUNT_IDLE = false,   -- RAID_BOT: idle air cons (any book) count toward the air-con reserve (it re-ordered 2 forever; 38 sat idle)
    RECOVER_EVERY     = 300,      -- frames between looks
    RECOVER_MIN_MEX   = 1,        -- empty mex spots in a grid that trigger a rebuild
    RECOVER_SAFE_R    = 1500,     -- no raid cluster (WG.MetalBot.threats) this close to the grid
    -- SECOND_AIR_LAB (RAID_BOT): once the line is built, a second T1 air lab on it -- a 3x2 block of wind (or free) slots
    -- is reserved, the winds reclaimed, and the lab built with nanos on the slots beside it.  It is not the macro's air
    -- lab (no air-con hold), so the lab controller keeps it on Shurikens / fighters.
    SECOND_AIR_LAB    = false,
    LAB2_FRAME        = 7 * 60 * 30,   -- not before this
    LAB2_LATEST       = 10 * 60 * 30,  -- ...and from here even if the line still has open slots
    LAB2_NANOS        = 4,             -- nano slots beside the lab
    LINE_RECOVER      = false,         -- rebuild destroyed line nanos near the T1 air labs (a free air con, two looks, no raid near)
    LINE_RECOVER_R    = 700,           -- ...within this of an air lab
    LAB2_NANO_HELP    = false,         -- every nano in reach reclaims what stands on the site, then builds the lab frame
}

local HALF_GRID = 240
local LINE_BOX  = { x0 = -176, x1 = 1152, z0 = -432, z1 = 320 }   -- b-frame: starter + all slot rows

local CMD_STOP   = 0
local CMD_INSERT = (CMD and CMD.INSERT) or 1
local OPT_ALT, OPT_CTRL, OPT_INTERNAL = (CMD and CMD.OPT_ALT) or 128, (CMD and CMD.OPT_CTRL) or 64, (CMD and CMD.OPT_INTERNAL) or 8
local CMD_GUARD  = (CMD and CMD.GUARD) or 25

local function Clock(frame)
    return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60)
end

local function Key(ax, az) return ax .. "," .. az end

function LT.New(o)
    local T = { BP = o.BP, LC = o.LC, crew = o.crew, L = o.layout, gridBP = o.gridBP, teamID = o.teamID,
                CFG = LT.CFG, phase = "wait", frame = 0,
                gridStates = {}, pendingGrids = {}, assigned = {}, completed = {}, completedKeys = {},
                allAnchors = {}, gridCands = {}, pendingSince = {}, gridsAssigned = 0, nanoCrew = {},
                airConsOrdered = 0, orders = {}, lastReserve = -1e9, lastBankGrid = -1e9,
                pendingStops = {}, airLabNanos = {}, labNanoIDs = {}, labTries = 0,
                spineMod = o.spine, spineBPs = o.spineBPs, spineOn = false, WG = o.WG,
                airConsAlive = {}, firstGridOK = false, helpers = {}, fusHelpers = {},
                vpPhase = o.spine and "wait" or "off", vpTries = 0,
                upgradeBP = o.upgradeBP, upgradeStates = {}, upgradedKeys = {}, gridFinished = {}, gridRotation = {},
                retrofitPaused = false, siloPending = {}, siloJobs = {}, lab2Sessions = {}, lineRecQueue = {},
                consolidateOn = false, consolidateJobs = {}, consolidatedKeys = {}, windBlocks = {}, reclaimingWinds = {},
                ecellBP = o.ecellBP, ecellStates = {}, ecellStarted = 0 }
    -- Which outer lane faces the enemy (the map centre): the vehicle lab and the spine go there; the air lab and the
    -- mex grids go on the other side.  b-z outward is lane 4 (north), b+z outward is lane 3 (south).
    local ex, ez = o.layout.mapX / 2 - o.layout.anchorX, o.layout.mapZ / 2 - o.layout.anchorZ
    for _, id in ipairs({ 3, 4 }) do
        local ox, oz = o.LC.Rotate(0, id == 3 and 1 or -1, o.layout.rot)
        if ox * ex + oz * ez > 0 then T.enemyLane = id else T.awayLane = T.awayLane or id end
    end
    T.enemyLane = T.enemyLane or 3
    T.awayLane = T.awayLane or (T.enemyLane == 3 and 4 or 3)
    -- Is world point (ax, az) past the line's enemy-facing edge (the half-plane the grids must stay out of)?
    T.OnEnemySide = function(self, ax, az)
        local bx, bz = self.LC.Rotate(ax - self.L.anchorX, az - self.L.anchorZ, (4 - self.L.rot) % 4)
        local out = (self.enemyLane == 3) and 1 or -1
        local edge = (out > 0) and LINE_BOX.z1 or LINE_BOX.z0
        return out * (bz - edge) > (self.CFG.GRID_ENEMY_SIDE or 0)
    end
    -- Does a grid cell at (ax, az) overlap any cell or exit lane of the spine's stack?  (480-elmo cells.)
    T.OverlapsSpine = function(self, ax, az)
        for _, b in ipairs(self.spineBoxes or {}) do
            if math.abs(ax - b.x) < 480 and math.abs(az - b.z) < 480 then return true end
        end
        return false
    end
    if o.cfg then                       -- per-bot overrides of LT.CFG (A/B variants differ only by these flags)
        T.CFG = {}
        for k, v in pairs(LT.CFG) do T.CFG[k] = v end
        BC.Apply("line_transition", T.CFG, o.cfg, o.label, LT.NIL_OPTIONS)
    end
    -- The air-con broker: one owner per con; every job below registers with it.
    T.CB = CB.New{ isT2 = function(defID) return T.IsT2(defID) end,
                   updateSession = function(st, frame, res) T.BP.Update(st, frame, res) end,
                   echo = Spring.Echo, clock = Clock }
    RegisterJobs(T)
    if o.WG then o.WG.ConBroker = T.CB end              -- tests / other widgets can read who owns which con
    -- The line's footprint in world coordinates (rotations are multiples of 90 degrees: the box stays a box).
    local xs, zs = {}, {}
    for _, bx in ipairs({ LINE_BOX.x0, LINE_BOX.x1 }) do
        for _, bz in ipairs({ LINE_BOX.z0, LINE_BOX.z1 }) do
            local wx, wz = o.LC.World(T.L, bx, bz)
            xs[#xs + 1], zs[#zs + 1] = wx, wz
        end
    end
    T.lineBox = { x0 = math.min(unpack(xs)), x1 = math.max(unpack(xs)), z0 = math.min(unpack(zs)), z1 = math.max(unpack(zs)) }
    return T
end

-- ── Air lab ──────────────────────────────────────────────────────────────────

-- Cheapest factory the builder can place that makes a flying constructor.
local function FindAirLabDef(builderID)
    local bd = UnitDefs[Spring.GetUnitDefID(builderID) or -1]
    local best, bestCost = nil, math.huge
    for _, optID in ipairs((bd and bd.buildOptions) or {}) do
        local od = UnitDefs[optID]
        if od and od.isFactory and od.buildOptions then
            for _, subID in ipairs(od.buildOptions) do
                local sd = UnitDefs[subID]
                if sd and sd.isBuilder and sd.canFly and not sd.isFactory then
                    if (od.metalCost or math.huge) < bestCost then best, bestCost = optID, od.metalCost or math.huge end
                    break
                end
            end
        end
    end
    return best
end

local function FindAirConDef(labDefID)
    local d = labDefID and UnitDefs[labDefID]
    for _, optID in ipairs((d and d.buildOptions) or {}) do
        local od = UnitDefs[optID]
        if od and od.isBuilder and od.canFly and not od.isFactory then return optID end
    end
    return nil
end

-- Site: the 6 open slots (3 columns x 2 rows of one lane's section) closest to an outer lane's builder, plus
-- up to 2 more open slots beside them for the nanos.  Nothing is reserved until the lab is queued.
-- opts (all optional): lanes = lane ids to look in, cols = columns of the block (default 3; 2 rows each).
function LT.PickSite(T, opts)
    local LC, best = T.LC, nil
    opts = opts or {}
    local cols = opts.cols or 3
    for _, laneID in ipairs(opts.lanes or LC.TRANS_LANES) do
        local b = LC.LaneBuilder(T.crew, laneID)
        local bxw, _, bzw = nil, nil, nil
        if b then bxw, _, bzw = Spring.GetUnitPosition(b.id) end
        if bxw then
            local lane = T.L.lanes[laneID]
            local at = {}                       -- at[row][k] = slot, open ones only
            for _, s in ipairs(lane.slots) do
                if s.state == "free" then at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
            end
            for k0 = LC.K_FIRST, LC.K_LAST - (cols - 1) do
                local slots, ok = {}, true
                for row = 1, 2 do
                    for k = k0, k0 + cols - 1 do
                        local s = at[row] and at[row][k]
                        if s then slots[#slots + 1] = s else ok = false end
                    end
                end
                if ok then
                    local wx, wz, bx, bz = 0, 0, 0, 0
                    for _, s in ipairs(slots) do wx, wz, bx, bz = wx + s.wx, wz + s.wz, bx + s.bx, bz + s.bz end
                    wx, wz, bx, bz = wx / #slots, wz / #slots, bx / #slots, bz / #slots
                    local d = math.sqrt((wx - bxw) ^ 2 + (wz - bzw) ^ 2)
                    if not best or d < best.d then
                        best = { d = d, lane = laneID, builder = b.id, slots = slots, wx = wx, wz = wz, bx = bx, bz = bz, k0 = k0 }
                    end
                end
            end
        end
    end
    if not best then return nil end
    -- Nano slots: open slots of that lane beside the block (columns k0-1 and k0+3 first), nearest to it.
    local inLab = {}
    for _, s in ipairs(best.slots) do inLab[s] = true end
    local cands = {}
    for _, s in ipairs(T.L.lanes[best.lane].slots) do
        if s.state == "free" and not inLab[s] then
            local beside = (s.k == best.k0 - 1 or s.k == best.k0 + cols) and 0 or 1
            cands[#cands + 1] = { s = s, beside = beside, d = math.sqrt((s.wx - best.wx) ^ 2 + (s.wz - best.wz) ^ 2) }
        end
    end
    table.sort(cands, function(a, b) if a.beside ~= b.beside then return a.beside < b.beside end return a.d < b.d end)
    best.nanos = {}
    for i = 1, math.min(2, #cands) do best.nanos[i] = cands[i].s end
    return best
end

-- Spot: the middle of the site, facing with the lab's long side along the line.
function LT.LabSpot(T, site)
    local LC = T.LC
    local wx, wz = site.wx, site.wz
    local ud = UnitDefs[T.labDefID]
    local xs, zs = (ud.xsize or 0) * 8, (ud.zsize or ud.ysize or 0) * 8
    local lx = LC.Rotate(1, 0, T.L.rot)                     -- the line's long axis in world space
    local base = T.BP.RotateFacing(0, T.L.rot)
    local good, rest = {}, {}
    for _, f in ipairs({ base, (base + 2) % 4, (base + 1) % 4, (base + 3) % 4 }) do
        local fx, fz = xs, zs
        if f % 2 == 1 then fx, fz = zs, xs end
        local fits = (lx ~= 0 and fx >= fz) or (lx == 0 and fz >= fx)
        if fits then good[#good + 1] = f else rest[#rest + 1] = f end
    end
    for _, f in ipairs(rest) do good[#good + 1] = f end
    if not T.spotLogged then
        T.spotLogged = true
        Spring.Echo(string.format("[LT] air lab %s footprint %dx%d elmos (facing 0), slot rectangle 192x128; facings %s",
            ud.name, xs, zs, table.concat(good, ",")))
    end
    for _, f in ipairs(good) do
        local x, z = T.BP.SnapToBuildGrid(T.labDefID, wx, wz, f)
        local y = Spring.GetGroundHeight(x, z) or 0
        local ok = Spring.TestBuildOrder(T.labDefID, x, y, z, f)
        if ok and ok ~= 0 then return x, z, f end
    end
    return nil
end

-- Seconds to build the lab with everything that can reach it, and whether the bank covers it by then.
function LT.LabPlan(T, res, x, z, builderID, defID)
    local lab = UnitDefs[defID or T.labDefID]
    local bp = (UnitDefs[Spring.GetUnitDefID(builderID) or -1] or {}).buildSpeed or 0
    local nanos = 0
    for _, n in ipairs(T.BP.NanosInRange(x, z) or {}) do
        local nd = UnitDefs[Spring.GetUnitDefID(n) or -1]
        if nd then bp = bp + (nd.buildSpeed or 0); nanos = nanos + 1 end
    end
    bp = math.max(bp, 1)
    local t = (lab.buildTime or lab.metalCost or 1000) / bp
    local cost = lab.metalCost or 0
    local avail = res.metal + res.metalIncome * t
    return { t = t, bp = bp, nanos = nanos, cost = cost, avail = avail, ok = avail >= cost,
             energyOk = (res.energy + res.energyIncome * t) >= (lab.energyCost or 0) }
end

local function UpdateWait(T, frame, res)
    local LC = T.LC
    if frame < T.CFG.EARLIEST_FRAME then return end
    if T.site and not LC.LaneBuilder(T.crew, T.site.lane) then       -- its builder died: give the slots back
        for _, s in ipairs(T.site.slots) do s.state = "free" end
        for _, s in ipairs(T.site.nanos) do s.state = "free" end
        T.site = nil
    end
    -- The air lab (and with it the mex grids) goes on the outer lane AWAY from the enemy; the vehicle lab and the
    -- spine take the enemy-facing one.
    local site = T.site or LT.PickSite(T, { lanes = { T.awayLane } })
    if not site then
        if frame % 300 == 0 then Spring.Echo("[LT] " .. Clock(frame) .. " no 6 open slots (3x2) left in an outer lane") end
        return
    end
    local b = { id = site.builder }
    if not T.labDefID then
        T.labDefID = FindAirLabDef(b.id)
        if not T.labDefID then
            Spring.Echo("[LT] the outer con cannot place an air factory; transition off")
            T.phase = "off"
            return
        end
    end
    local x, z, f = LT.LabSpot(T, site)
    if not x then
        if frame % 300 == 0 then Spring.Echo("[LT] " .. Clock(frame) .. " no legal spot for the air lab yet") end
        return
    end
    local p = LT.LabPlan(T, res, x, z, b.id)
    if frame % T.CFG.LOG_EVERY == 0 then
        Spring.Echo(string.format("[LT] %s lab plan: BP %.0f (%d nanos) -> %.0fs; bank %d + %.1f/s x %.0fs = %.0f vs cost %d (%s)%s",
            Clock(frame), p.bp, p.nanos, p.t, res.metal, res.metalIncome, p.t, p.avail, p.cost,
            p.ok and "enough" or "short", p.energyOk and "" or "; energy short"))
    end
    local late = frame >= T.CFG.LATEST_FRAME
    -- Before the bank is ready the site is only a candidate, re-picked every tick near the con.  It is claimed
    -- early only when the lane is about to run out of open slots (the line would eat the site otherwise).
    if not T.site then
        local open = 0
        for _, s in ipairs(T.L.lanes[site.lane].slots) do if s.state == "free" then open = open + 1 end end
        if p.ok or late or open <= T.CFG.CLAIM_WHEN_OPEN then
            for _, s in ipairs(site.slots) do s.state = "reserved" end
            for _, s in ipairs(site.nanos) do s.state = "reserved" end
            T.site = site
            if not (p.ok or late) then
                Spring.Echo(string.format("[LT] %s lane %d is down to %d open slots: site held (6 + %d nano) until the bank is ready",
                    Clock(frame), site.lane, open, #site.nanos))
            end
        end
    end
    if not (p.ok or late) then return end
    local ud = UnitDefs[T.labDefID]
    LC.QueueJob(T.crew, b.id, { name = ud.name, x = x, z = z, f = f, tag = "lab" })
    T.phase, T.labFrame = "lab", frame
    Spring.Echo(string.format("[LT] %s AIR LAB queued (%s) at (%d, %d) facing %d: %s; BP %.0f, %.0fs, bank %d income %.1f",
        Clock(frame), ud.name, x, z, f, late and "latest-frame fallback" or "bank covers the build", p.bp, p.t,
        res.metal, res.metalIncome))
end

-- ── Air cons ─────────────────────────────────────────────────────────────────

-- Until the first grid is ~30% built the bot keeps at most AIR_CON_CAP_EARLY air cons (alive + ordered): more
-- compete with that grid for metal and nanos.
local function LiftAirConCap(T, why)
    if T.firstGridOK then return end
    T.firstGridOK = true
    Spring.Echo(string.format("[LT] %s air con cap (%d) lifted: %s", Clock(T.frame), T.CFG.AIR_CON_CAP_EARLY, why))
end

local function AirConsEarlyFull(T)
    if T.firstGridOK then return false end
    local alive = 0
    for id in pairs(T.airConsAlive) do
        if Spring.GetUnitDefID(id) then alive = alive + 1 else T.airConsAlive[id] = nil end
    end
    return alive + T.airConsOrdered >= T.CFG.AIR_CON_CAP_EARLY
end

-- CON_HOLD: true while the bot wants no constructors from its air labs (logged at most every 30 s).
local function ConHold(T, frame, what)
    local h = T.CFG.CON_HOLD
    if not h then return false end
    local ok, v = pcall(h)
    if not (ok and v == true) then return false end
    if frame - (T.conHoldLogF or -1e9) >= 900 then
        T.conHoldLogF = frame
        Spring.Echo(string.format("[LT] %s CON HOLD: %s skipped (the air labs answer a ground raid)", Clock(frame), what))
    end
    return true
end

-- Every constructor order to a lab goes through here.  With a lab controller that publishes WG.LabBroker the order is the lab
-- broker's (so its grace / pending gates know about it and two systems never stack orders on one queue); without one (other
-- bots) it is given directly.  ahead = in front of a busy queue (after the unit in production), else at the tail.
local function OrderCon(T, labID, defID, frame, ahead)
    CB.OrderCon(T.WG, labID, defID, frame or T.frame or 0, ahead)
end

-- The bot's macro orders its starter-lab cons the same way (LT.OrderCon(WG, lab, def, frame)).
LT.OrderCon = CB.OrderCon

-- T2 cons ordered and not out yet (frames; a lost order times out after AIR_CON_TIMEOUT), so the shortfall counts them as coming.
local function T2Ordered(T, frame)
    T.t2Orders = T.t2Orders or {}
    while #T.t2Orders > 0 and (frame or 0) - T.t2Orders[1] > T.CFG.AIR_CON_TIMEOUT do table.remove(T.t2Orders, 1) end
    return #T.t2Orders
end

-- One T2 con ordered from an advanced lab.  Every T2 order goes through here so the in-flight count is right.
local function OrderT2Con(T, labID, defID, frame, ahead)
    T2Ordered(T, frame)
    T.t2Orders[#T.t2Orders + 1] = frame or 0
    OrderCon(T, labID, defID, frame, ahead)
end

-- How many T2 cons the broker says are still missing (jobs' demand + reserve - ready - ordered).
local function T2Shortfall(T, frame)
    if not T.CB then return math.huge end          -- (a bare T in a unit test)
    return CB.Shortfall(T.CB, 2, T2Ordered(T, frame), true, frame or 0, T.lastRes)
end

local function QueueAirCon(T, frame)
    if AirConsEarlyFull(T) or ConHold(T, frame or 0, "air con") then return end
    if T.CFG.IDLE_CON_SWEEP and (T.idleSurplus or 0) > T.CFG.IDLE_CON_MAX then return end     -- cons stand idle with nothing to assist: no more
    local lab = T.airLabID
    if lab and Spring.GetUnitDefID(lab) and T.airConDefID then
        OrderCon(T, lab, T.airConDefID, frame, not T.CFG.AIR_CON_AT_BACK)
        T.airConsOrdered = T.airConsOrdered + 1
        T.orders[#T.orders + 1] = frame
    end
end

local function AirConOrderDone(T)
    if #T.orders > 0 then table.remove(T.orders, 1) end
    T.airConsOrdered = math.max(0, T.airConsOrdered - 1)
end

-- Grids a nano crew could help: open, fewer than NANO_CREW_NANOS finished nanos, a nano spot still unbuilt.
local function NanoCrewDemand(T)
    local need, n = T.CFG.NANO_CREW_NANOS, 0
    for _, gs in ipairs(T.gridStates) do
        if not gs.done then
            local built, open = 0, 0
            for _, it in ipairs(gs.queue) do
                if it.cls == "nano" and it.act ~= "reclaim" then
                    if it.built or it.status == "built" then built = built + 1
                    elseif it.status ~= "skipped" and not it.crewTried then open = open + 1 end
                end
            end
            if built < need and open > 0 then n = n + 1 end
        end
    end
    return n
end

-- Crew size wanted now (0 until NANO_CREW_AFTER grids are open); cached for 15 frames.
local function NanoCrewTarget(T, frame)
    local K = T.CFG
    if not K.NANO_CREW or T.consolidateOn or T.gridsAssigned < K.NANO_CREW_AFTER then return 0 end
    if K.NANO_CREW_SIZE_FULL and T.gridsFull then T.crewTarget = K.NANO_CREW_SIZE_FULL; return T.crewTarget end
    if not K.NANO_CREW_GRIDS then T.crewTarget = K.NANO_CREW_SIZE; return T.crewTarget end
    if not T.crewTargetAt or frame - T.crewTargetAt >= 15 then
        T.crewTargetAt = frame
        T.crewDemand = NanoCrewDemand(T)
        T.crewTarget = math.min(K.NANO_CREW_SIZE, math.max(K.NANO_CREW_MIN, math.ceil(T.crewDemand / K.NANO_CREW_GRIDS - 1e-9)))
    end
    return T.crewTarget
end

-- Before every hand-out: the reserve (cons the labs keep ready, T1 and T2) and the T2 HOLD -- free T2 cons the retrofits must leave
-- for the fusion jobs: the energy push keeps EP_INFLIGHT, the fusion consolidation CONSOL_FUSION_CONS, an energy cell one, and once
-- the cap is tight one is always left for the wind blocks (converting wind beats retrofitting another grid at the cap).
local function SetReserves(T)
    local C = T.CFG
    local keep = 0
    if C.ENERGY_PUSH and T.epBound then keep = math.max(0, C.EP_INFLIGHT - #T.consolidateJobs) end
    if T.consolidateOn and T.epBound and C.FUSION_HELPERS then keep = math.max(keep, C.CONSOL_FUSION_CONS - #T.consolidateJobs) end
    if T.ecellWant then keep = math.max(keep, 1) end
    if T.consolidateOn then keep = math.max(keep, 1) end
    CB.SetReserve(T.CB, 1, C.AIR_CON_RESERVE)
    CB.SetReserve(T.CB, 2, C.T2_CON_RESERVE or 0)
    CB.SetHold(T.CB, 2, keep)
end

-- The reserve: T1 air cons ready beyond what the jobs want (con_broker: Unmet + reserve - ready - ordered > 0 -> the lab makes one).
-- RESERVE_COUNT_IDLE: cons that are only helping (preemptable jobs, idle crew members) count as ready, so idle cons stop being
-- re-ordered forever; without it only free ones count.
local function KeepAirConReserve(T, frame, res)
    if T.consolidateOn or not T.airLabID or not T.airConDefID or frame - T.lastReserve < 90 then return end
    if CB.Shortfall(T.CB, 1, T.airConsOrdered, T.CFG.RESERVE_COUNT_IDLE, frame, res) > 0 then
        QueueAirCon(T, frame)
        T.lastReserve = frame
    end
end

-- Idle nanos in reach of the lab guard it while it owes air cons (lowest priority; any hand-off takes them back).
-- While the line is unfinished only the lab's own two nanos do: the line's nanos stay free to help its builders
-- (a guarding nano builds nothing but the lab's air cons; a 6:00 log had every nano on the lab and 40% of the line open).
local function UpdateLabAssist(T, frame)
    if frame % 30 ~= 0 or not T.airLabID then return end
    local NANO = T.BP.NANO
    if not NANO then return end
    -- LAB_NANOS_FIRST_GRID: the lab's nanos are there to stand the first grid's nanos sooner, not to speed the air cons out
    local gridFirst = false
    if T.CFG.LAB_NANOS_FIRST_GRID and T.firstGrid and not T.firstGrid.done then
        for _, it in ipairs(T.firstGrid.queue) do
            if it.cls == "nano" and it.act ~= "reclaim" and not (it.built or it.status == "built" or it.status == "skipped") then gridFirst = true; break end
        end
    end
    if T.airConsOrdered > 0 and not gridFirst and Spring.GetUnitDefID(T.airLabID) then
        local x, _, z = Spring.GetUnitPosition(T.airLabID)
        local lineBuilt = T.LC.SlotsRemaining(T.L) == 0
        for _, n in ipairs(T.BP.NanosInRange(x, z) or {}) do
            if lineBuilt or T.labNanoIDs[n] then
                local idle = NANO.Assignment(n) == nil and not (Spring.GetUnitIsBuilding and Spring.GetUnitIsBuilding(n))
                if (idle or T.airLabNanos[n]) and NANO.Guard(NANO.PRIO.BALANCE, n, T.airLabID) then T.airLabNanos[n] = true end
            elseif T.airLabNanos[n] then
                local a = NANO.Assignment(n)
                if a and a.target == T.airLabID and a.prio == NANO.PRIO.BALANCE then NANO.Release(n) end
                T.airLabNanos[n] = nil
            end
        end
    else
        for n in pairs(T.airLabNanos) do
            local a = NANO.Assignment(n)
            if a and a.target == T.airLabID and a.prio == NANO.PRIO.BALANCE then NANO.Release(n) end
            T.airLabNanos[n] = nil
        end
    end
end

-- ── Grids ────────────────────────────────────────────────────────────────────

local function InsideLine(T, ax, az)
    local b = T.lineBox
    return ax - HALF_GRID < b.x1 and b.x0 < ax + HALF_GRID and az - HALF_GRID < b.z1 and b.z0 < az + HALF_GRID
end

local function AddCompleted(T, ax, az)
    local k = Key(ax, az)
    if not T.completedKeys[k] then
        T.completedKeys[k] = true
        T.completed[#T.completed + 1] = { anchorX = ax, anchorZ = az }
    end
end

-- Free cells next to `sources`, never on the line, queued as candidates.
local function Collect(T, sources)
    if T.consolidateOn then return end      -- at the cap the headroom is for army, not more grid
    for _, r in ipairs(T.BP.FindAllValidPlacements(T.gridBP, sources)) do
        local k = Key(r.anchorX, r.anchorZ)
        if not T.assigned[k] and not InsideLine(T, r.anchorX, r.anchorZ) and not T.OverlapsSpine(T, r.anchorX, r.anchorZ)
           and not T.OnEnemySide(T, r.anchorX, r.anchorZ) then
            T.assigned[k] = true
            T.gridCands[#T.gridCands + 1] = r
        end
    end
end

-- Capstone: the blueprint crowns each grid with a T2 air lab (coraap), which is what makes the T2 air cons that
-- do the retrofits.  A grid's own con that cannot place it has the entry retired so the grid can still finish.
local function ApplyCapstone(T, st, conID)
    for _, item in ipairs(st.queue) do
        if item.cls == "factory" then
            -- SILO_GRIDS (LINE_CLICK_v16): these grids are crowned with a nuke silo instead of the T2 air lab.  The grid's
            -- own T1 air con cannot place it, so the entry is retired here and a free T2 con builds it once the grid is up.
            local gridNo = T.gridsAssigned
            local capName = (T.CFG.SILO_GRIDS and T.CFG.SILO_GRIDS[gridNo] and "corsilo")
                         or (T.CFG.ANTINUKE_GRIDS and T.CFG.ANTINUKE_GRIDS[gridNo] and "corfmd") or nil
            local siloUD = capName and UnitDefNames[capName]
            if siloUD then
                local wx, wz = T.BP.SnapToBuildGrid(siloUD.id, item.wx, item.wz)
                item.built, item.status = true, "skipped"
                T.siloPending[#T.siloPending + 1] = { x = wx, z = wz, f = item.f or 0, key = Key(st.anchorX, st.anchorZ), grid = gridNo,
                                                      name = capName }
                Spring.Echo(string.format("[LT] grid %d capstone: %s at (%d, %d), waits for a T2 con", gridNo, capName, wx, wz))
                return
            end
            if T.CFG.CAPSTONE_MAX and gridNo > T.CFG.CAPSTONE_MAX then
                item.built, item.status = true, "skipped"      -- one lab makes any number of T2 cons: no lab in every grid
                return
            end
            local cdef = Spring.GetUnitDefID(conID)
            if not (cdef and T.BP.CanBuild(cdef, item.defID)) then
                item.built, item.status = true, "skipped"
            end
            return
        end
    end
end

-- A T2 con is one that can build what the upgrade blueprint asks for (same question the placer asks).
local function IsT2Con(T, defID)
    local bp = T.upgradeBP
    if not (bp and bp.layout and bp.layout[1]) then return false end
    local ud = UnitDefNames[bp.layout[1].n]
    return ud and T.BP.CanBuild(defID, ud.id) or false
end

-- Orders n T2 cons spread over the finished advanced air labs: each goes to the lab with the fewest T2 cons already queued there (a lab
-- builds them one after another, so a batch of 6 on each of the first few labs in unit-id order kept the rest of the labs idle for
-- minutes -- the main source of run-to-run spread in the vacuum test: 2.8k vs 6.5k income at 20:00 from the same bot).
-- maxLoad (optional): no lab gets more than that many T2 cons queued.  Returns how many were ordered and the first lab used.  Without EP_CON_FORCE only labs with an empty queue count.
local function OrderT2Spread(T, frame, n, maxLoad)
    if n <= 0 then return 0 end
    T.t2Sent = T.t2Sent or {}
    local labs = {}
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and d.isFactory and uid ~= T.airLabID and not Spring.GetUnitIsBeingBuilt(uid) then
            local t2 = FindAirConDef(Spring.GetUnitDefID(uid))
            if t2 and IsT2Con(T, t2) then
                local q = (Spring.GetFactoryCommands and Spring.GetFactoryCommands(uid, -1)) or {}
                if type(q) ~= "table" then q = {} end
                local queued = 0
                for _, c in ipairs(q) do if c.id == -t2 then queued = queued + 1 end end
                local sent = T.t2Sent[uid] or {}
                while #sent > 0 and (frame or 0) - sent[1] > 450 do table.remove(sent, 1) end   -- long enough to show in the queue
                T.t2Sent[uid] = sent
                if T.CFG.EP_CON_FORCE or #q == 0 then
                    labs[#labs + 1] = { uid = uid, def = t2, load = math.max(queued, #sent), busy = #q > 0 }
                end
            end
        end
    end
    if #labs == 0 then return 0 end
    local first, done = nil, 0
    for _ = 1, n do
        local best = labs[1]
        for _, l in ipairs(labs) do if l.load < best.load then best = l end end
        if maxLoad and best.load >= maxLoad then break end
        OrderT2Con(T, best.uid, best.def, frame, best.busy)
        local sent = T.t2Sent[best.uid]
        sent[#sent + 1] = frame or 0
        best.load = best.load + 1
        first = first or best.uid
        done = done + 1
    end
    return done, first
end

-- Hand the free cons out now (a session ended, a con arrived, a cell opened); the broker also does it every update.
local function AssignCons(T, frame)
    if T.CB then CB.Assign(T.CB, frame or T.frame, T.lastRes) end
end

local function FreeT2(T) return T.CB and CB.NFree(T.CB, 2) or 0 end

-- The grid job's start: the con takes the next pending cell (the broker has STOPped it and adds the session to T.gridStates).
local function StartGrid(T, conID, frame)
        do
            local g = table.remove(T.pendingGrids, 1)
            local k = Key(g.anchorX, g.anchorZ)
            if T.pendingSince[k] and not g.recover then
                Spring.Echo(string.format("[LT] grid %d at (%d, %d) waited %.1fs for a con", T.gridsAssigned + 1,
                    g.anchorX, g.anchorZ, (frame - T.pendingSince[k]) / 30))
            end
            if g.recover then
                Spring.Echo(string.format("[LT] %s RECOVER grid (%d, %d): con %d re-runs it", Clock(frame), g.anchorX, g.anchorZ, conID))
            else
                T.allAnchors[#T.allAnchors + 1] = { anchorX = g.anchorX, anchorZ = g.anchorZ, key = k }
            end
            T.gridRotation[k] = g.rotation
            local intr = T.BP.GRID_INTERRUPTS
            if T.CFG.GRID_PLANNER then
                if not T.planner then
                    local okP, PL = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/eco_planner.lua")
                    if okP and PL then
                        T.plannerMod = PL
                        T.planner = PL.New(T.teamID, T.CFG.PLANNER_CFG)
                        -- Items still to place in the open grids (+ an allowance for the cells that will open): the planner
                        -- cannot build more mexes than there are spots for.
                        T.planner.supplyFn = function()
                            local n = { metal = 0, energy = 0, nano = 0 }
                            for _, gs in ipairs(T.gridStates) do
                                if not gs.done then
                                    for _, it in ipairs(gs.queue) do
                                        if not it.built and n[it.cls] then n[it.cls] = n[it.cls] + 1 end
                                    end
                                end
                            end
                            local open = (T.CFG.PLANNER_NEW_CELLS or 3) + #T.gridCands + #T.pendingGrids
                            n.metal, n.energy, n.nano = n.metal + 6 * open, n.energy + 30 * open, n.nano + 12 * open
                            return n
                        end
                    else
                        Spring.Echo("[LT] GRID_PLANNER: eco_planner failed to load: " .. tostring(PL)); T.CFG.GRID_PLANNER = false
                    end
                end
                intr = {}
                if not T.CFG.PLANNER_ONLY then for _, it in ipairs(T.BP.GRID_INTERRUPTS) do intr[#intr + 1] = it end end
                if T.planner then for _, it in ipairs(T.plannerMod.Interrupts(T.planner)) do intr[#intr + 1] = it end end
            elseif T.CFG.GRID_STALL_RULE then
                intr = T.BP.StallRuleInterrupts()
            elseif T.CFG.GRID_BALANCE then
                -- GRID_BALANCE: below the stall interrupts, build what is under the most pressure (mex / wind), and a
                -- nano only when neither metal nor energy is being used (blueprint_placer.BalanceInterrupts)
                intr = {}
                for _, it in ipairs(T.BP.GRID_INTERRUPTS) do intr[#intr + 1] = it end
                for _, it in ipairs(T.BP.BalanceInterrupts()) do intr[#intr + 1] = it end
            end
            if T.CFG.EARLY_CAPSTONES and T.gridsAssigned < T.CFG.EARLY_CAPSTONES then
                -- the first grids crown themselves (T2 lab -> T2 cons -> retrofits) as soon as their nanos stand, not last
                local own = {}
                for _, it in ipairs(intr) do own[#own + 1] = it end
                own[#own + 1] = { name = "capstone_early", priority = 3, buildType = "factory", noPreempt = true,
                                  check = function(state) return #state.nanoUnitIDs >= (T.CFG.EARLY_CAPSTONE_NANOS or 4) end }
                intr = own
            end
            local st = T.BP.New(T.gridBP, conID, g.anchorX, g.anchorZ, g.rotation, intr)
            -- The grid's own factory is the last thing built, unless metal piles up unspent.
            st.deferFactories, st.handoffProgress = true, T.CFG.GRID_HANDOFF
            if T.CFG.GRID_INTR_MIN_NANOS then st.interruptMinNanos = T.CFG.GRID_INTR_MIN_NANOS end
            if T.gridsAssigned == 0 then T.firstGrid = st end
            if not g.recover then T.gridsAssigned = T.gridsAssigned + 1 end
            ApplyCapstone(T, st, conID)
            if T.consolidateOn and T.windDefID then st.skipDefIDs = { [T.windDefID] = true } end
            st.onNanoThreshold = function(gs)
                AddCompleted(T, gs.anchorX, gs.anchorZ)
                -- RETROFIT_EARLY: the grid's nanos are up -- let a free T2 con retrofit it now instead of waiting for 70% built,
                -- the finish, or the unit cap going tight (which made 15:00 income swing 2.5k-5.4k between identical runs).
                if T.CFG.RETROFIT_EARLY then T.gridFinished[Key(gs.anchorX, gs.anchorZ)] = true; AssignCons(T) end
                Collect(T, T.completed)
                AssignCons(T, T.frame)
            end
            -- 70% built is enough to retrofit: the grid's nanos are up and its con is off on the outlying items.
            st.onMostlyDone = function(gs)
                local key = Key(gs.anchorX, gs.anchorZ)
                if not T.gridFinished[key] then
                    T.gridFinished[key] = true
                    Spring.Echo(string.format("[LT] grid (%d, %d) mostly built -- retrofit eligible", gs.anchorX, gs.anchorZ))
                    AssignCons(T)
                end
            end
            st.onComplete = function(gs)
                AddCompleted(T, gs.anchorX, gs.anchorZ)
                T.gridFinished[Key(gs.anchorX, gs.anchorZ)] = true
                Spring.Echo(string.format("[LT] %s grid (%d, %d) finished -- retrofit eligible", Clock(T.frame), gs.anchorX, gs.anchorZ))
                Collect(T, T.completed)
                AssignCons(T, T.frame)
            end
            return st
        end
end

-- ── Silo capstones: a free T2 con builds the grid's silo once the grid's nanos are up ───────────────────────

local function SiloWant(T)
    if T.ecoPaused then return 0 end
    local n = 0
    for _, job in ipairs(T.siloPending) do if T.gridFinished[job.key] then n = n + 1 end end
    return n
end

-- the silo job's start: the first pending silo of a finished grid this con can place
local function StartSilo(T, conID)
    local cdef = Spring.GetUnitDefID(conID)
    for i, job in ipairs(T.siloPending) do
        if T.gridFinished[job.key] and T.BP.CanBuild(cdef, UnitDefNames[job.name or "corsilo"].id) then
            table.remove(T.siloPending, i)
            local st = T.BP.New({ layout = { { n = job.name or "corsilo", x = 0, z = 0, f = job.f } } }, conID, job.x, job.z, 0, {})
            st.clearBlockers = true
            Spring.Echo(string.format("[LT] %s %s capstone (grid %d) started at (%d, %d) by con %d", Clock(T.frame),
                job.name or "corsilo", job.grid, job.x, job.z, conID))
            return st
        end
    end
    return false
end

-- ── Retrofit: a finished grid is upgraded in place to T2 mexes + fusions by a T2 air con ─────────────────────

-- Finished grids waiting for a T2 con to retrofit them.
local function RetrofitsWaiting(T)
    local n = 0
    for _, a in ipairs(T.completed) do
        local k = Key(a.anchorX, a.anchorZ)
        if T.gridFinished[k] and not T.upgradedKeys[k] then n = n + 1 end
    end
    return n
end

-- The retrofit job's start: the nearest finished grid not yet retrofitted (a grid still building would compete with its own retrofit).
local function StartRetrofit(T, conID)
    local cx, _, cz = Spring.GetUnitPosition(conID)
    local best, bestD2, bestKey = nil, math.huge, nil
    for _, a in ipairs(T.completed) do
        local key = Key(a.anchorX, a.anchorZ)
        if T.gridFinished[key] and not T.upgradedKeys[key] then
            local dx, dz = (cx or 0) - a.anchorX, (cz or 0) - a.anchorZ
            local d2 = dx * dx + dz * dz
            if d2 < bestD2 then best, bestD2, bestKey = a, d2, key end
        end
    end
    if not best then return false end
    T.upgradedKeys[bestKey] = true
    local st = T.BP.New(T.upgradeBP, conID, best.anchorX, best.anchorZ, T.gridRotation[bestKey] or 0, T.BP.GRID_INTERRUPTS)
    st.clearBlockers = true                      -- reclaim the mex/winds the fusions need
    st.clearOnlyDefIDs = {}
    for _, n in ipairs({ "corwin", "cormex" }) do
        local ud = UnitDefNames[n]
        if ud then st.clearOnlyDefIDs[ud.id] = true end
    end
    st.handoffProgress = T.CFG.GRID_HANDOFF
    Spring.Echo(string.format("[LT] %s retrofit started at (%d, %d) by con %d", Clock(T.frame), best.anchorX, best.anchorZ, conID))
    return st
end

-- A retrofit must never compete with a normal grid for metal (T2 mexes earn less per metal): while stalling,
-- retrofit builders are stopped.
-- RETROFIT_FLOAT_CONS (the retrofit job's `produce`): metal floats and finished grids wait for a retrofit with no T2 con free:
-- idle advanced labs make more.
-- T2 cons are built ONLY on demand (user, 2026-10-14): a finished advanced lab orders none by itself.  This is the retrofit job's
-- `produce`: it runs when finished grids wait for a retrofit and no T2 con is free; the orders are capped by the broker's shortfall
-- (jobs' demand + reserve - ready - already ordered).  RETROFIT_FLOAT_CONS adds the metal-float gate (RETROFIT_FLOAT_FRAC).
local function UpdateRetrofitCons(T, frame, res)
    if frame % 150 ~= 0 or not T.upgradeBP or FreeT2(T) > 0 then return end
    if frame - (T.retroConFrame or -1e9) < 450 then return end       -- let the last order's cons arrive before ordering again
    if ConHold(T, frame, "retrofit T2 cons") then return end
    if T.CFG.RETROFIT_FLOAT_CONS and (res.metalStorage <= 0 or res.metal / res.metalStorage < (T.CFG.RETROFIT_FLOAT_FRAC or 0.2)) then return end
    local waiting = RetrofitsWaiting(T)
    if waiting == 0 then return end
    T.floatConsOrdered = T.floatConsOrdered or 0
    -- what the broker says is short, shared out over the labs (at most T2_LAB_DEPTH queued on each)
    local want = math.min(waiting, math.max(0, T2Shortfall(T, frame)))
    local ordered = OrderT2Spread(T, frame, want, T.CFG.T2_LAB_DEPTH)
    if ordered > 0 then
        T.retroConFrame = frame
        T.floatConsOrdered = T.floatConsOrdered + ordered
        Spring.Echo(string.format("[LT] %s RETROFIT CONS: metal %.0f/%.0f floats, %d grid(s) waiting -> %d T2 con(s) ordered (%d so far)",
            Clock(frame), res.metal, res.metalStorage, waiting, ordered, T.floatConsOrdered))
    end
end

-- up-front T2 cons of a lab that finished while the air labs answered a ground raid (CON_HOLD): ordered when the hold ends
local function UpdateT2Deferred(T, frame)
    if not T.t2Deferred or frame % 60 ~= 0 or ConHold(T, frame, "up-front T2 cons") then return end
    for id, t2 in pairs(T.t2Deferred) do
        T.t2Deferred[id] = nil
        if Spring.GetUnitDefID(id) then
            for _ = 1, T.CFG.UPGRADE_CONS_PER_LAB do OrderT2Con(T, id, t2, frame) end
        end
    end
end

-- T2_CONS_PER_GRID: demand-driven T2 cons stop once every finished grid has its retrofit con, but a retrofit with one builder takes minutes
-- and the late game floats metal: keep T2_CONS_PER_GRID cons per finished grid, ordered over the labs while the bank is healthy.
local function UpdateT2TopUp(T, frame, res)
    local K = T.CFG
    if not K.T2_CONS_PER_GRID or not T.upgradeBP or T.ecoPaused or frame % 150 ~= 0 then return end
    if frame - (T.t2TopFrame or -1e9) < 450 then return end
    if res.metalStorage <= 0 or res.metal / res.metalStorage < K.T2_TOPUP_METAL_FRAC then return end
    local grids = 0
    for _, a in ipairs(T.completed) do if T.gridFinished[Key(a.anchorX, a.anchorZ)] then grids = grids + 1 end end
    local have = CB.Count(T.CB, 2) + T2Ordered(T, frame)
    local n = math.min(K.RETROFIT_FLOAT_BATCH or 6, math.floor(K.T2_CONS_PER_GRID * grids) - have)
    if n <= 0 or ConHold(T, frame, "T2 top-up") then return end
    local ordered = OrderT2Spread(T, frame, n, K.T2_LAB_DEPTH)
    if ordered > 0 then
        T.t2TopFrame = frame
        Spring.Echo(string.format("[LT] %s T2 TOP-UP: %d T2 cons for %d finished grids (%d alive/ordered) -> %d ordered", Clock(frame), math.floor(K.T2_CONS_PER_GRID * grids), grids, have, ordered))
    end
end

-- The retrofit sessions themselves are run by the broker; this is the stall rule.
local function UpdateRetrofits(T, frame, res)
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 1
    if not T.retrofitPaused and mFrac < T.CFG.RETROFIT_STALL_FRAC then
        T.retrofitPaused = true
        for _, us in ipairs(T.upgradeStates) do
            if us.builderID and Spring.GetUnitDefID(us.builderID) then
                Spring.GiveOrderToUnit(us.builderID, CMD_STOP, {}, {})
                us.currentTask = nil
            end
        end
    elseif T.retrofitPaused and mFrac > T.CFG.RETROFIT_RESUME_FRAC then
        T.retrofitPaused = false
    end
end

-- Under-spending means too few frames are open at once: hand frames to the nanos sooner so the builder places
-- the next one.  Short on metal, the opposite (finish what is started).  Income above pull = under-spending.
local function UpdateSpendPressure(T, res)
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
    local underSpending = res.metalIncome > res.metalPull * 1.05
    local handoff = T.CFG.GRID_HANDOFF
    if mFrac < T.CFG.BANK_LOW and not underSpending then handoff = T.CFG.SPEND_SLOW
    elseif underSpending or mFrac > T.CFG.BANK_HIGH then handoff = T.CFG.SPEND_FAST end
    for _, st in ipairs(T.gridStates)    do st.handoffProgress = handoff end
    for _, st in ipairs(T.upgradeStates) do st.handoffProgress = handoff end
end

-- ── Unit-cap relief: wind consolidation (TILE_BOT's) ─────────────────────────────────────────────────────────
-- Four winds in a 2x2 block are replaced by ONE fusion or one T2 mex (~34x the energy per unit slot).  Starts
-- when the cap is tight: grids stop building wind, retrofits become eligible at once, winds are reclaimed in a
-- rationed trickle and the T2 cons turn the freed ground into fusions / T2 mexes.

local function CapSlack(T, absolute)
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
    if not maxU or maxU <= 0 then return absolute end
    return math.min(absolute, math.floor(maxU * T.CFG.CAP_SLACK_FRAC))
end

-- Every unclaimed 2x2 block of finished winds, in one pass (winds sit on a global 48-elmo lattice).
local function ScanWindBlocks(T)
    if not T.windDefID then return end
    T.windBlocks = {}
    local at = {}
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        if Spring.GetUnitDefID(uid) == T.windDefID and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then at[math.floor(x + 0.5) .. "," .. math.floor(z + 0.5)] = uid end
        end
    end
    local L, taken = T.CFG.WIND_LATTICE, {}
    for key in pairs(at) do
        if #T.windBlocks >= T.CFG.CONSOLIDATE_MAX then break end
        local sx, sz = key:match("(-?%d+),(-?%d+)")
        local x, z = tonumber(sx), tonumber(sz)
        local k2, k3, k4 = (x + L) .. "," .. z, x .. "," .. (z + L), (x + L) .. "," .. (z + L)
        if at[k2] and at[k3] and at[k4] and not (taken[key] or taken[k2] or taken[k3] or taken[k4]) then
            local cx, cz = x + L / 2, z + L / 2
            local ckey = math.floor(cx) .. "," .. math.floor(cz)
            if not T.consolidatedKeys[ckey] then
                taken[key], taken[k2], taken[k3], taken[k4] = true, true, true, true
                T.windBlocks[#T.windBlocks + 1] = { cx = cx, cz = cz, key = ckey, winds = { at[key], at[k2], at[k3], at[k4] } }
            end
        end
    end
end

-- Condemn a rationed number of winds and put every nano that can reach each one on reclaiming it (rationed: the
-- energy loss must not be a cliff).
local function UpdateWindReclaim(T)
    local NANO = T.BP.NANO
    if not NANO then return end
    T.windDefID = T.windDefID or (UnitDefNames["corwin"] and UnitDefNames["corwin"].id)
    if not T.windDefID then return end
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
    local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(T.teamID)
    if not (maxU and cnt) or (maxU - cnt) > maxU * T.CFG.RECLAIM_TRIGGER_FRAC then return end
    local active = 0
    for wid in pairs(T.reclaimingWinds) do
        if Spring.GetUnitDefID(wid) then active = active + 1 else T.reclaimingWinds[wid] = nil end
    end
    local budget = math.max(1, math.floor(maxU * T.CFG.RECLAIM_BUDGET_FRAC))
    if active >= budget then return end
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        if active >= budget then break end
        if Spring.GetUnitDefID(uid) == T.windDefID and not T.reclaimingWinds[uid] and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local used = 0
                for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
                    if NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, nid, uid) then used = used + 1 end
                end
                if used > 0 then T.reclaimingWinds[uid], active = true, active + 1 end
            end
        end
    end
end

local function StartConsolidation(T, conID, res, forceName)
    local block
    while #T.windBlocks > 0 do
        local b = table.remove(T.windBlocks, 1)
        if not T.consolidatedKeys[b.key] then block = b; break end
    end
    if not block then return false end
    -- Replace the block with whichever resource is scarcer right now (the energy push always wants a fusion).
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 1
    local eFrac = res.energyStorage > 0 and res.energy / res.energyStorage or 1
    local name = forceName or ((eFrac <= mFrac) and "corfus" or "cormoho")
    local ud = UnitDefNames[name]
    if not ud or not T.BP.CanBuild(Spring.GetUnitDefID(conID), ud.id) then
        table.insert(T.windBlocks, 1, block)          -- this con cannot build it: the block waits for another
        return false
    end
    T.consolidatedKeys[block.key] = true
    -- One-item blueprint; clearBlockers reclaims the four winds, and ONLY winds, to make room.
    local st = T.BP.New({ layout = { { n = name, x = 0, z = 0, f = 0 } } }, conID, block.cx, block.cz, 0, {})
    st.clearBlockers = true
    st.clearOnlyDefIDs = { [T.windDefID] = true }
    Spring.Echo(string.format("[LT] %s consolidating 4 winds at (%d, %d) into %s", Clock(T.frame), block.cx, block.cz, name))
    return st
end

local function CheckCapPressure(T, res, frame)
    if T.consolidateOn then
        if T.windDefID then
            for _, gs in ipairs(T.gridStates) do
                gs.skipDefIDs = gs.skipDefIDs or {}
                gs.skipDefIDs[T.windDefID] = true
            end
        end
        return
    end
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
    local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(T.teamID)
    -- TIGHT_ON_FLOAT: metal banked at its storage cap means the builders are soaked in low-metal work (winds); the
    -- unit-cap rule below is what moves them onto retrofits / fusions, but it fired at 13:54 in one identical run and
    -- 16:13 in another.  Fire it when the bank has sat above TIGHT_FLOAT_FRAC of storage for TIGHT_FLOAT_FRAMES.
    local floatTight = false
    if T.CFG.TIGHT_ON_FLOAT and res and frame >= T.CFG.TIGHT_FLOAT_START then
        local frac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
        if frac >= T.CFG.TIGHT_FLOAT_FRAC then
            T.floatSince = T.floatSince or frame
            floatTight = frame - T.floatSince >= T.CFG.TIGHT_FLOAT_FRAMES
        else
            T.floatSince = nil
        end
    end
    if not floatTight and (not (maxU and cnt) or (maxU - cnt) > CapSlack(T, T.CFG.CONSOLIDATE_SLACK)) then return end
    T.consolidateOn = true
    T.windDefID = UnitDefNames["corwin"] and UnitDefNames["corwin"].id
    -- Every grid becomes retrofit-eligible now, finished or not: a T1->T2 mex upgrade costs no unit slot.
    local marked = 0
    for _, g in ipairs(T.allAnchors) do
        if not T.gridFinished[g.key] then
            T.gridFinished[g.key] = true
            AddCompleted(T, g.anchorX, g.anchorZ)
            marked = marked + 1
        end
    end
    Spring.Echo(string.format("[LT] %s %s (%d/%d): grids stop building wind, consolidation on, %d more grids marked for retrofit",
        Clock(T.frame), floatTight and "metal floating at the cap" or "unit cap tight", cnt or 0, maxU or 0, marked))
    AssignCons(T)
end

-- ENERGY PUSH (see LT.CFG): metal floating while energy binds -> wind blocks become fusions.
local function EnergyBound(T, frame, res)
    local C = T.CFG
    if frame < C.EP_START then return false end
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
    local eFrac = res.energyStorage > 0 and res.energy / res.energyStorage or 1
    local ei = res.energyIncomeS or res.energyIncome or 0
    local ep = res.energyPullS or res.energyPull or 0
    -- EP_BANK_SECONDS: a bank under this many seconds of pull is empty at any scale (half of a 58k store is 2 s of a 15k E/s pull)
    local low = eFrac < C.EP_EFRAC or (C.EP_BANK_SECONDS and res.energy < C.EP_BANK_SECONDS * ep)
    -- EP_RATIO (look-ahead): army units cost ~15 E per metal, so energy income under EP_RATIO x metal income will bind as soon
    -- as the metal is spent -- build energy now instead of after the float starts.
    local mi = res.metalIncomeS or res.metalIncome or 0
    if C.EP_RATIO and mi >= (C.EP_RATIO_MIN_INCOME or 300) and ei < C.EP_RATIO * mi then return true end
    return mFrac >= C.EP_MFRAC and res.metal >= C.EP_MIN_METAL and low and ep >= C.EP_EPULL * ei
end

-- No free T2 con for an energy job: an advanced air lab makes one (it then joins the free pool).  Normally only a lab with
-- nothing queued; with EP_CON_FORCE any such lab (a bot whose lab controller keeps those queues full never has an idle one).
local function MakeEnergyT2Con(T, frame, tag)
    local C = T.CFG
    if frame - (T.epConFrame or -1e9) < C.EP_CON_EVERY then return end
    if ConHold(T, frame, tag .. " T2 con") then return end
    local nCon = math.min(C.EP_CON_BATCH or 1, math.max(0, T2Shortfall(T, frame)))     -- never more than the jobs still want
    if nCon == 0 then return end
    local n, lab = OrderT2Spread(T, frame, nCon)       -- spread over the labs; EP_CON_FORCE: ahead of a full queue
    if n > 0 then
        T.epConFrame = frame
        Spring.Echo(string.format("[LT] %s %s: no free T2 con, lab %d makes %d", Clock(frame), tag, lab, n))
    end
end

local function UpdateEnergyPush(T, frame, res)
    local C = T.CFG
    if not C.ENERGY_PUSH or frame - (T.epFrame or -1e9) < C.EP_EVERY then return end
    T.epFrame = frame
    T.epBound = EnergyBound(T, frame, res)
    if T.consolidateOn then
        -- consolidation: energy is priority #1 while it binds or its income is falling off its peak (the winds are going)
        local ei = res.energyIncomeS or res.energyIncome or 0
        T.eiPeak = math.max(T.eiPeak or 0, ei)
        if not T.epBound and C.FUSION_HELPERS and ei < C.CONSOL_FALLING * T.eiPeak then T.epBound = true end
        return                                    -- UpdateConsolidation starts the jobs
    end
    if not T.epBound then return end
    if #T.consolidateJobs >= C.EP_INFLIGHT then return end
    ScanWindBlocks(T)                -- the consolidation job (ConsolWant / StartConsolidation) starts them
end

-- The consolidation job: wind blocks -> fusions (or T2 mexes), one T2 con per block.  While the energy push binds it is
-- limited to EP_INFLIGHT blocks at once; once the cap is tight (consolidateOn) every block gets a con.
local function ConsolForce(T)
    local C = T.CFG
    if not T.consolidateOn then return C.ENERGY_BUILDING or "corfus" end
    return (T.epBound and C.FUSION_HELPERS) and (C.ENERGY_BUILDING or "corfus") or nil     -- energy first: fusions
end

local function ConsolWant(T)
    local C = T.CFG
    if T.ecoPaused or #T.windBlocks == 0 then return 0 end
    if T.consolidateOn then return #T.windBlocks end
    if C.ENERGY_PUSH and T.epBound then return math.max(0, math.min(C.EP_INFLIGHT - #T.consolidateJobs, #T.windBlocks)) end
    return 0
end

local function StartConsolidationJob(T, conID, frame, res)
    res = res or T.lastRes
    if not res then return false end
    local st = StartConsolidation(T, conID, res, ConsolForce(T))
    if st and not T.consolidateOn then
        T.epStarted = (T.epStarted or 0) + 1
        Spring.Echo(string.format("[LT] %s ENERGY PUSH: wind block -> fusion (metal %.0f/%.0f, energy %.0f/%.0f, pull %.0f of %.0f E/s), %d so far",
            Clock(frame), res.metal, res.metalStorage, res.energy, res.energyStorage,
            res.energyPullS or res.energyPull or 0, res.energyIncomeS or res.energyIncome or 0, T.epStarted))
    end
    return st
end

-- no T2 con for the job: an advanced air lab makes one
local function ConsolProduce(T, frame)
    if not T.consolidateOn then MakeEnergyT2Con(T, frame, "ENERGY PUSH")
    elseif ConsolForce(T) then MakeEnergyT2Con(T, frame, "CONSOLIDATION") end
end

-- FUSION_HELPERS (the "fusionhelp" job): idle air cons guard the builder of each running fusion job (a wind block -> fusion, or an
-- energy cell), adding their build power; they go back to the pool when the job ends, and any higher job can take them.
-- (T.fusJobs = the jobs they may guard, refreshed here every 30 frames.)
-- room left under HELPER_CAP for this helper job (the cap counts both helper jobs' cons)
local function HelperRoom(T, name)
    local cap = T.CFG.HELPER_CAP
    if not cap then return math.huge end
    local held = CB.HeldCount(T.CB, "gridhelp") + CB.HeldCount(T.CB, "fusionhelp")
    return math.max(0, cap - held)
end

local function FusionHelperWant(T)
    local K = T.CFG.FUSION_HELPERS
    if not K or T.ecoPaused or #(T.fusJobs or {}) == 0 then return 0 end
    if K == true then return math.min(64, HelperRoom(T)) end
    local have = {}
    for _, cs in pairs(T.fusHelpers) do have[cs] = (have[cs] or 0) + 1 end
    local n = 0
    for _, cs in ipairs(T.fusJobs) do n = n + math.max(0, K - (have[cs] or 0)) end
    return math.min(n, HelperRoom(T))
end

-- every con that is available goes to a fusion job, always the CLOSEST one (a con flying across the map to the "emptiest" job
-- wastes its time); full jobs (K = a number caps each job; true = no cap) are skipped
local function StartFusionHelper(T, id)
    local K = T.CFG.FUSION_HELPERS
    local cap = (K == true) and math.huge or K
    local have = {}
    for _, cs in pairs(T.fusHelpers) do have[cs] = (have[cs] or 0) + 1 end
    local x, _, z = Spring.GetUnitPosition(id)
    local pick, bestD
    for _, cs in ipairs(T.fusJobs or {}) do
        if not cs.done and cs.builderID and Spring.GetUnitDefID(cs.builderID) and (have[cs] or 0) < cap then
            local bx, _, bz = Spring.GetUnitPosition(cs.builderID)
            local d = (bx and x) and ((bx - x) ^ 2 + (bz - z) ^ 2) or 0
            if not bestD or d < bestD then pick, bestD = cs, d end
        end
    end
    if not pick then return false end
    Spring.GiveOrderToUnit(id, CMD_GUARD, { pick.builderID }, {})
    T.fusHelpers[id] = pick
    return true
end

local function UpdateFusionHelpers(T, frame)
    local K = T.CFG.FUSION_HELPERS
    if not K or frame % 30 ~= 0 then return end
    local jobs = {}
    for _, list in ipairs({ T.consolidateJobs, T.ecellStates or {} }) do
        for _, cs in ipairs(list) do
            if not cs.done and cs.builderID and Spring.GetUnitDefID(cs.builderID) then jobs[#jobs + 1] = cs end
        end
    end
    -- ENERGY_PRIORITY: nanos in reach of a fusion job help its builder, ahead of everything else, while energy stalls
    local NANO = T.BP.NANO
    if T.CFG.ENERGY_PRIORITY and NANO and NANO.PRIO.ENERGY then
        T.energyNanos = T.energyNanos or {}
        local want = T.epBound or T.ecellWant
        for n, cs in pairs(T.energyNanos) do
            local live = false
            for _, j in ipairs(jobs) do if j == cs then live = true; break end end
            if not Spring.GetUnitDefID(n) then
                T.energyNanos[n] = nil
            elseif not want or not live then
                local a = NANO.Assignment(n)
                if a and a.prio == NANO.PRIO.ENERGY then NANO.Release(n) end
                T.energyNanos[n] = nil
            end
        end
        if want then
            for _, cs in ipairs(jobs) do
                local x, _, z = Spring.GetUnitPosition(cs.builderID)
                if x then
                    for _, n in ipairs(T.BP.NanosInRange(x, z) or {}) do
                        if not T.energyNanos[n] and NANO.Guard(NANO.PRIO.ENERGY, n, cs.builderID) then T.energyNanos[n] = cs end
                    end
                end
            end
        end
    end
    -- no fusion job running: the idle cons help the retrofits instead (T2 mexes are the biggest eco lever left)
    if #jobs == 0 then
        for _, cs in ipairs(T.upgradeStates or {}) do
            if not cs.done and cs.builderID and Spring.GetUnitDefID(cs.builderID) then jobs[#jobs + 1] = cs end
        end
    end
    T.fusJobs = jobs
    -- helpers whose job ended go back to the pool
    for id, cs in pairs(T.fusHelpers) do
        local live = false
        for _, j in ipairs(jobs) do if j == cs then live = true; break end end
        if not Spring.GetUnitDefID(id) then
            T.fusHelpers[id] = nil
        elseif not live then
            T.fusHelpers[id] = nil
            CB.Release(T.CB, id, true)
        end
    end
    local n = 0
    for _ in pairs(T.fusHelpers) do n = n + 1 end
    if n ~= (T.fusHelpersLogged or 0) then
        T.fusHelpersLogged = n
        Spring.Echo(string.format("[LT] %s fusion helpers: %d air cons on %d jobs", Clock(frame), n, #jobs))
    end
end

local function UpdateConsolidation(T, frame, res)
    UpdateEnergyPush(T, frame, res)
    if T.consolidateOn and (frame % T.CFG.CONSOLIDATE_SCAN == 0 or #T.windBlocks == 0) then ScanWindBlocks(T) end
    UpdateFusionHelpers(T, frame)
end

-- (Energy cells were removed 2026-10-14: never seen built in a real game.  T.ecellStates / T.ecellWant stay as empty hooks.)

local StartSpine      -- defined with the spine glue below

-- The first grid: GAP elmos beyond the line's outer edge, centred on the lab (or the next cell along the line).
local function OpenFirstGrid(T, frame, labX, labZ)
    local LC = T.LC
    local bx0 = T.site.bx
    -- Beyond the edge of the lab's own side first; if that side is unbuildable (map edge, cliff), further along it,
    -- then the far side.
    local north = LINE_BOX.z0 - T.CFG.GAP - HALF_GRID
    local south = LINE_BOX.z1 + T.CFG.GAP + HALF_GRID
    local near, far = north, south
    if T.site.lane == 3 then near, far = south, north end
    -- The spine reserves its cells and exit lanes before any grid cell is seeded (grid cells then keep off them).
    if T.spineMod then StartSpine(T, frame) end
    local tries = {}
    for _, dx in ipairs({ 0, -480, 480, -960 }) do tries[#tries + 1] = { dx, near } end
    for _, dx in ipairs({ 0, -480, 480 }) do tries[#tries + 1] = { dx, far } end
    for _, try in ipairs(tries) do
        local dx, bz = try[1], try[2]
        local wx, wz = LC.World(T.L, bx0 + dx, bz)
        wx, wz = math.floor(wx / 16 + 0.5) * 16, math.floor(wz / 16 + 0.5) * 16
        -- Reuse the placer's own probe + rotation choice: ask for the east neighbour of a pseudo-anchor.
        for _, r in ipairs(T.BP.FindAllValidPlacements(T.gridBP, { { anchorX = wx - T.BP.GRID_SPACING, anchorZ = wz } })) do
            if r.anchorX == wx and r.anchorZ == wz and not T.OverlapsSpine(T, wx, wz) then
                r.rotation = T.BP.BestRotation(T.gridBP, wx, wz, labX, labZ)
                T.assigned[Key(wx, wz)] = true
                T.pendingGrids[#T.pendingGrids + 1] = r
                T.pendingSince[Key(wx, wz)] = frame
                Spring.Echo(string.format("[LT] %s first grid cell (%d, %d) rot %d, %d elmos beyond the line (b %d, %d)",
                    Clock(frame), wx, wz, r.rotation, T.CFG.GAP, bx0 + dx, bz))
                return true
            end
        end
    end
    Spring.Echo("[LT] no valid first grid cell beyond the line; grids off")
    return false
end

-- Opening every free cell at once starves the first grids of build power; pace them (TILE_BOT).
local function ReleaseCandidates(T, frame, res)
    if #T.gridCands == 0 and not T.consolidateOn
       and (T.CFG.COLLECT_ALWAYS or (res.metal >= T.CFG.GRID_BANK and frame - T.lastBankGrid >= T.CFG.GRID_BANK_GAP)) then
        local sources = {}
        for _, a in ipairs(T.completed) do sources[#sources + 1] = a end
        if not T.CFG.COLLECT_DONE_ONLY then
            for _, g in ipairs(T.allAnchors) do sources[#sources + 1] = g end
        end
        Collect(T, sources)
    end
    if #T.gridCands == 0 then return end
    local opening = #T.pendingGrids
    for _, gs in ipairs(T.gridStates) do
        if not gs.done and not gs.nanoThresholdFired then opening = opening + 1 end
    end
    -- The line is the cheapest metal sink and its nanos/cons are the build power: until it is built, grids get only
    -- the paced trickle; after that the bank / fast triggers may run up to GRIDS_OPENING_MAX at once.
    local lineBuilt = T.LC.SlotsRemaining(T.L) == 0
    local why
    -- idle = free cons plus the ones parked as grid / fusion helpers (or an idle crew member): they go straight to a new grid.  Counting
    -- only unowned cons made the gate nearly never open once the helpers soaked up every spare con (STANCE_BOT 8:50: 16 on grids, 46
    -- helping, 700-1200 metal banked, cells waiting; the pre-broker code counted its helpers as idle).
    local idleCon = CB.Available(T.CB, 1, true) > #T.pendingGrids
    local energyOK = res.energyStorage > 0 and res.energy / res.energyStorage >= T.CFG.GRID_FAST_ENERGY
    local income = res.metalIncomeS or res.metalIncome or 0
    if opening < T.CFG.GRIDS_OPENING then why = "pace"
    elseif not lineBuilt and T.CFG.LINE_GATE then return
    elseif income >= T.CFG.GRID_FAST_INCOME and idleCon and energyOK
            and not (T.CFG.FAST_OPEN_CAP and opening >= T.CFG.FAST_OPEN_CAP) then
        -- A big economy: expand whenever an air con stands idle.  No bank test (the army spends it), and no
        -- GRIDS_OPENING_MAX either: the idle-con test is the limit, and cons only come as fast as the air lab makes them.
        why = "fast-income"
    elseif opening >= T.CFG.GRIDS_OPENING_MAX then return
    elseif res.metal >= T.CFG.GRID_BANK and frame - T.lastBankGrid >= T.CFG.GRID_BANK_GAP then
        why, T.lastBankGrid = "bank", frame
    elseif res.metal >= T.CFG.GRID_BANK_FAST and idleCon and energyOK then
        -- Metal piling up, energy healthy and an air con standing idle: the 15 s gap is only there to stop the
        -- early game sinking its metal into slow grids.  Measured 10:00-17:30: 4-10 idle cons, 16-18 cells
        -- waiting, 230-350k banked, one grid per 15 s.
        why = "fast"
    end
    if not why then return end
    -- GRID_CAP_FRAC: grids counted at GRID_UNITS each must fit under the cap share
    do
        local K = T.CFG
        local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
        local why2
        if K.GRID_CAP_FRAC and maxU and maxU > 0 then
            local grids = #T.allAnchors + #T.pendingGrids
            if (grids + 1) * K.GRID_UNITS > maxU * K.GRID_CAP_FRAC then why2 = string.format("%d grids x %d units + 1 > %.0f%% of cap %d", grids, K.GRID_UNITS, 100 * K.GRID_CAP_FRAC, maxU) end
        end
        if why2 then
            T.gridsFull = true                    -- every grid the cap allows is open: new air cons can go to the nano crew
            if frame - (T.capGateLog or -1e9) >= 1800 then
                T.capGateLog = frame
                Spring.Echo(string.format("[LT] %s no new grid: %s", Clock(frame), why2))
            end
            return
        end
    end
    -- GRID_COMPACT: open the candidate nearest the line's centre (fewer open grids in a tighter blob = less to defend),
    -- not the first one found.
    local pick = 1
    if T.CFG.GRID_COMPACT then
        local lb = T.lineBox
        local cx, cz = (lb.x0 + lb.x1) / 2, (lb.z0 + lb.z1) / 2
        local best = math.huge
        for i, c in ipairs(T.gridCands) do
            local d = (c.anchorX - cx) ^ 2 + (c.anchorZ - cz) ^ 2
            if d < best then best, pick = d, i end
        end
    end
    local r = table.remove(T.gridCands, pick)
    T.pendingGrids[#T.pendingGrids + 1] = r
    T.pendingSince[Key(r.anchorX, r.anchorZ)] = frame
    QueueAirCon(T, frame)
    Spring.Echo(string.format("[LT] %s grid cell (%d, %d) opened (%s: %d opening, bank %.0f, %d waiting)",
        Clock(frame), r.anchorX, r.anchorZ, why, opening, res.metal, #T.gridCands))
    AssignCons(T, frame)
end

-- GRID_HELPERS (the "gridhelp" job): a grid with fewer than HELP_NANOS nanos up (HELP_ANY: any unfinished grid) gets idle air cons
-- guarding its builder, HELP_MAX each, so its first nanos stand quickly.  A grid or any higher job takes them back at once.
local function HelpSlots(T)
    local out, total = {}, 0
    if not T.CFG.GRID_HELPERS or T.ecoPaused then return out, 0 end
    local need = T.CFG.HELP_NANOS or 2
    for _, gs in ipairs(T.gridStates) do
        if not gs.done and gs.builderID and Spring.GetUnitDefID(gs.builderID) and (#gs.nanoUnitIDs < need or T.CFG.HELP_ANY) then
            local have = 0
            for _, g in pairs(T.helpers) do if g == gs then have = have + 1 end end
            local open = (T.CFG.HELP_MAX or 2) - have
            if open > 0 then out[#out + 1] = { gs = gs, n = open }; total = total + open end
        end
    end
    return out, total
end

-- the grid nearest the con that still has a helper slot (fewest nanos up first on a tie): a helper flying across the map adds nothing
local function StartGridHelper(T, id)
    local slots = HelpSlots(T)
    if #slots == 0 then return false end
    local x, _, z = Spring.GetUnitPosition(id)
    local gs, bestD
    for _, sl in ipairs(slots) do
        local bx, _, bz = Spring.GetUnitPosition(sl.gs.builderID)
        local d = (bx and x) and ((bx - x) ^ 2 + (bz - z) ^ 2) or 0
        d = d + #sl.gs.nanoUnitIDs * 1e4                -- a tie-break only: a grid with more nanos is a little less needy
        if not bestD or d < bestD then gs, bestD = sl.gs, d end
    end
    Spring.GiveOrderToUnit(id, CMD_GUARD, { gs.builderID }, {})
    T.helpers[id] = gs
    return true
end

-- upkeep: helpers whose grid is done (or has its nanos) go back to the pool
local function UpdateGridHelpers(T, frame)
    if not T.CFG.GRID_HELPERS or frame % 15 ~= 0 then return end
    local need = T.CFG.HELP_NANOS or 2
    for id, gs in pairs(T.helpers) do
        if not Spring.GetUnitDefID(id) then
            T.helpers[id] = nil
        elseif gs.done or (#gs.nanoUnitIDs >= need and not T.CFG.HELP_ANY) then
            T.helpers[id] = nil
            CB.Release(T.CB, id, true)
        end
    end
end

-- NANO_CREW: see the config note.  Members come from the free air con pool AHEAD of pending grids and stay crew.
local function NanoCrewRelease(T, id, toPool)
    T.nanoCrew[id] = nil
    if toPool and Spring.GetUnitDefID(id) then CB.Release(T.CB, id, true) end
end

-- The nanocrew job: members are recruited from the free pool AHEAD of pending grids (user, 2026-10-12) and stay crew.
local function NanoCrewWant(T, frame)
    if T.ecoPaused then return 0 end
    return math.max(0, NanoCrewTarget(T, frame) - CB.HeldCount(T.CB, "nanocrew"))
end

local function StartCrewMember(T, id, frame)
    T.nanoCrew[id] = { since = frame, idleSince = frame }
    local size = CB.HeldCount(T.CB, "nanocrew") + 1
    Spring.Echo(string.format("[LT] %s nano crew: air con %d joins (%d/%d, %d grids short of nanos)", Clock(frame), id, size, T.crewTarget or 0, T.crewDemand or 0))
    return true
end

-- CREW_CHAIN: how many finished nanos reach a nano spot (world position of a grid queue item)
local function NanoCover(T, it)
    return #(T.BP.NanosInRange(it.wx, it.wz) or {})
end

-- does any open nano spot of the grid have a finished nano in reach?
local function CrewCovered(T, gs, NanoItems)
    local _, open = NanoItems(gs)
    for _, it in ipairs(open) do if NanoCover(T, it) > 0 then return true end end
    return false
end

-- open nano spots in build order: the most covered first, then each next one the nearest to the one before (it is in reach of it once
-- that stands), so every nano the crew builds is assisted by the ones already standing and the chain grows grid after grid
local function CrewChainOrder(T, open)
    local rest, out = {}, {}
    for i, it in ipairs(open) do rest[i] = it end
    local cur
    while #rest > 0 do
        local bi, bs
        for i, it in ipairs(rest) do
            local sc
            if cur then sc = (it.wx - cur.wx) ^ 2 + (it.wz - cur.wz) ^ 2 else sc = -NanoCover(T, it) end
            if not bs or sc < bs then bi, bs = i, sc end
        end
        cur = table.remove(rest, bi)
        out[#out + 1] = cur
    end
    return out
end

local function UpdateNanoCrew(T, frame)
    local K = T.CFG
    if not K.NANO_CREW then return end
    T.nanoCrew = T.nanoCrew or {}
    local size = 0
    for _ in pairs(T.nanoCrew) do size = size + 1 end
    if T.consolidateOn then
        if frame % 15 == 0 then for id in pairs(T.nanoCrew) do NanoCrewRelease(T, id, true) end end
        return
    end
    local target = NanoCrewTarget(T, frame)
    -- (recruiting is the nanocrew job's: the crew has PRIORITY over new grids, user 2026-10-12)
    if frame % 15 ~= 0 then return end
    -- shrink: a member with no job for NANO_CREW_IDLE frames goes back to the pool while the crew is over its target
    if size > target then
        for id, m in pairs(T.nanoCrew) do
            if size <= target then break end
            if not m.items and frame - (m.idleSince or frame) >= 300 then
                NanoCrewRelease(T, id, true); size = size - 1
                Spring.Echo(string.format("[LT] %s nano crew: con %d released (%d/%d)", Clock(frame), id, size, target))
            end
        end
    end
    local need = K.NANO_CREW_NANOS
    local function NanoItems(gs)       -- finished nano count, and the nano items still open to the crew
        local built, open = 0, {}
        for _, it in ipairs(gs.queue) do
            if it.cls == "nano" and it.act ~= "reclaim" then
                if it.built or it.status == "built" then built = built + 1
                elseif it.status ~= "skipped" and not it.crewTried then open[#open + 1] = it end
            end
        end
        return built, open
    end
    -- jobs that are over: the nanos stand, the grid is done, or the con sat idle with nanos left (blocked: not again)
    for id, m in pairs(T.nanoCrew) do
        if not Spring.GetUnitDefID(id) then
            T.nanoCrew[id] = nil
        elseif m.items then
            local left = 0
            for _, it in ipairs(m.items) do
                if not (it.built or it.status == "built" or it.status == "skipped") then left = left + 1 end
            end
            local cmds = Spring.GetUnitCommands(id, 1)      -- as the placer does: a queue table (the count form read as idle in single mode)
            local idle = not (cmds and #cmds > 0)
            if left == 0 or m.gs.done or (idle and frame - m.start > 150) or frame - m.start > 2700 then
                if left > 0 and not m.gs.done then
                    for _, it in ipairs(m.items) do
                        if not (it.built or it.status == "built" or it.status == "skipped") then it.crewTried = true end
                    end
                end
                m.items, m.gs, m.idleSince = nil, nil, frame
            end
        end
    end
    -- the crew works in GROUPS of NANO_CREW_GROUP cons; each group works TOGETHER on one grid at a time (T.crewGridOf[group]), every
    -- idle member on its open nanos, until the grid has the goal's nanos (NANO_CREW_NANOS first, then NANO_CREW_FULL); then the group moves
    -- to the nearest grid no other group is on
    local function GridWantsCrew(gs, goal)
        if not gs or gs.done then return false end
        local built, open = NanoItems(gs)
        return built < goal and #open > 0
    end
    local gsize = math.max(1, K.NANO_CREW_GROUP or 4)
    local ids = {}
    for id in pairs(T.nanoCrew) do ids[#ids + 1] = id end
    table.sort(ids)
    local groups = {}
    for i, id in ipairs(ids) do
        local gi = math.floor((i - 1) / gsize) + 1
        local G = groups[gi]
        if not G then G = { idle = {}, cx = 0, cz = 0, cn = 0 }; groups[gi] = G end
        local x, _, z = Spring.GetUnitPosition(id)
        if x then G.cx, G.cz, G.cn = G.cx + x, G.cz + z, G.cn + 1 end
        if not T.nanoCrew[id].items then G.idle[#G.idle + 1] = id end
    end
    T.crewGridOf, T.crewGoalOf = T.crewGridOf or {}, T.crewGoalOf or {}
    local taken = {}
    for gi, cur in pairs(T.crewGridOf) do
        if gi <= #groups and GridWantsCrew(cur, T.crewGoalOf[gi] or need) then taken[cur] = true else T.crewGridOf[gi] = nil end
    end
    for gi, G in ipairs(groups) do
        if #G.idle > 0 then
            if not T.crewGridOf[gi] then
                local best, bestD, bestGoal
                -- tier 1: every grid up to NANO_CREW_NANOS nanos; tier 2 (NANO_CREW_FULL): then up to the full set
                for _, goal in ipairs({ need, K.NANO_CREW_FULL or need }) do
                    for _, gs in ipairs(T.gridStates) do
                        if not taken[gs] and GridWantsCrew(gs, goal) then
                            local d = (gs.anchorX - G.cx / math.max(G.cn, 1)) ^ 2 + (gs.anchorZ - G.cz / math.max(G.cn, 1)) ^ 2
                            -- CREW_CHAIN: a grid whose open nano spots finished nanos can reach comes first (its nanos get help from the
                            -- grid before it); the distance only breaks ties
                            if K.CREW_CHAIN and CrewCovered(T, gs, NanoItems) then d = d - 1e12 end
                            if not bestD or d < bestD then best, bestD = gs, d end
                        end
                    end
                    if best then bestGoal = goal; break end
                end
                if best then
                    T.crewGridOf[gi], T.crewGoalOf[gi], taken[best] = best, bestGoal, true
                    Spring.Echo(string.format("[LT] %s nano crew group %d -> grid (%d, %d): %d nanos up, goal %d, %d of %d cons free", Clock(frame), gi,
                        best.anchorX, best.anchorZ, (NanoItems(best)), bestGoal, #G.idle, #ids))
                end
            end
            local gs = T.crewGridOf[gi]
            if gs then
                local built, open = NanoItems(gs)
                if K.CREW_CHAIN then open = CrewChainOrder(T, open) end
                local want = {}
                for i = 1, math.min((T.crewGoalOf[gi] or need) - built, #open, 4) do want[i] = open[i] end
                for _, id in ipairs(G.idle) do
                    local m = T.nanoCrew[id]
                    m.gs, m.items, m.start = gs, want, frame
                    for jx = 0, #want - 1 do      -- every con of the group on the FIRST nano (it stands sooner, and its 200 BP then speeds up the next)
                        local it = want[jx + 1]
                        local wy = Spring.GetGroundHeight(it.wx, it.wz) or 0
                        Spring.GiveOrderToUnit(id, -it.defID, { it.wx, wy, it.wz, it.f }, jx > 0 and { "shift" } or {})
                    end
                end
            end
        end
    end
end

-- IDLE_CON_SWEEP: a con that is not building and not moving for IDLE_CON_FRAMES gets the nearest unfinished structure it can build to
-- assist (a repair order on a frame is an assist).  Cons with nothing to assist are "surplus": QueueAirCon orders no more while there are
-- more than IDLE_CON_MAX.  Skipped while metal is short (more builders then add nothing).
local CMD_REPAIR = (CMD and CMD.REPAIR) or 40
local function ConDoingNothing(id)
    if Spring.GetUnitIsBuilding and Spring.GetUnitIsBuilding(id) then return false end
    local _, _, _, speed = Spring.GetUnitVelocity(id)
    return not (speed and speed > 0.5)
end

local function UpdateIdleCons(T, frame, res)
    local K = T.CFG
    if not K.IDLE_CON_SWEEP or frame % 60 ~= 0 or not T.CB then return end
    T.idleSince = T.idleSince or {}
    local idle, surplus, given, checked = 0, 0, 0, 0
    local short = res.metalStorage > 0 and res.metal < 150
    for _, c in ipairs(T.CB.list) do
        local id = c.id
        local cdef = Spring.GetUnitDefID(id)
        -- only cons without a job or merely helping: a job's own builder may stand a moment (flying to the site, waiting for a reclaim)
        local sweepable = not c.owner or c.owner == "gridhelp" or c.owner == "fusionhelp"
                          or (c.owner == "nanocrew" and not (T.nanoCrew and T.nanoCrew[id] and T.nanoCrew[id].items))
        if cdef and sweepable and ConDoingNothing(id) then
            T.idleSince[id] = T.idleSince[id] or frame
            if frame - T.idleSince[id] >= K.IDLE_CON_FRAMES then
                idle = idle + 1
                if not short and checked < 12 then
                    checked = checked + 1
                    local x, _, z = Spring.GetUnitPosition(id)
                    local best, bd
                    for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, 1500, T.teamID) or {}) do
                        if uid ~= id and Spring.GetUnitIsBeingBuilt(uid) and T.BP.CanBuild(cdef, Spring.GetUnitDefID(uid)) then
                            local ux, _, uz = Spring.GetUnitPosition(uid)
                            local d = (ux - x) ^ 2 + (uz - z) ^ 2
                            if not bd or d < bd then best, bd = uid, d end
                        end
                    end
                    if best then
                        Spring.GiveOrderToUnit(id, CMD_REPAIR, { best }, {})
                        T.idleSince[id] = nil
                        given = given + 1
                    else
                        surplus = surplus + 1
                    end
                end
            end
        else
            T.idleSince[id] = nil
        end
    end
    T.idleSurplus = surplus
    T.idleStats = { idle = idle, given = given, surplus = surplus }
    if K.AUDIT_EVERY and frame % K.AUDIT_EVERY == 0 and idle > 0 then
        Spring.Echo(string.format("[AUDIT] %s idle cons %d: %d given an assist, %d with nothing to assist (surplus)", Clock(frame), idle, given, surplus))
    end
end

-- AUDIT_EVERY: what stands in every grid (a read-only count; logs only)
local function AuditGrids(T, frame)
    local K = T.CFG
    if not K.AUDIT_EVERY or frame % K.AUDIT_EVERY ~= 0 or #T.allAnchors == 0 then return end
    local half = (T.BP.GRID_SPACING or 480) / 2
    local def = { mex = UnitDefNames.cormex and UnitDefNames.cormex.id, moho = UnitDefNames.cormoho and UnitDefNames.cormoho.id,
                  fus = UnitDefNames.corfus and UnitDefNames.corfus.id, nano = UnitDefNames.cornanotc and UnitDefNames.cornanotc.id,
                  win = UnitDefNames.corwin and UnitDefNames.corwin.id }
    local boxes = {}
    for i, g in ipairs(T.allAnchors) do boxes[i] = { ax = g.anchorX, az = g.anchorZ, mex = 0, moho = 0, fus = 0, nano = 0, win = 0 } end
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        local d = Spring.GetUnitDefID(uid)
        local kind
        for k, id in pairs(def) do if id == d then kind = k; break end end
        if kind and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                for _, b in ipairs(boxes) do
                    if math.abs(x - b.ax) <= half and math.abs(z - b.az) <= half then b[kind] = b[kind] + 1; break end
                end
            end
        end
    end
    local n, noNano, fewNano, fullNano, full, t1, t2, fus, nano, win, someT2 = #boxes, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    local bk = { 0, 0, 0, 0, 0 }        -- grids by finished nanos: 0 | 1 | 2-5 | 6-(full-1) | full  (sums to the grid count)
    for _, b in ipairs(boxes) do
        local i = (b.nano == 0 and 1) or (b.nano == 1 and 2) or (b.nano <= 5 and 3) or (b.nano < K.AUDIT_FULL_NANOS and 4) or 5
        bk[i] = bk[i] + 1
        t1, t2, fus, nano, win = t1 + b.mex, t2 + b.moho, fus + b.fus, nano + b.nano, win + b.win
        if b.nano == 0 then noNano = noNano + 1 end
        if b.nano < 2 then fewNano = fewNano + 1 end
        if b.nano >= K.AUDIT_FULL_NANOS then fullNano = fullNano + 1 end
        if b.moho > 0 then someT2 = someT2 + 1 end
        if b.moho >= K.AUDIT_FULL_MOHO and b.fus >= K.AUDIT_FULL_FUS then full = full + 1 end
    end
    local t2cons = 0
    local t2def = UnitDefNames.coraca and UnitDefNames.coraca.id
    if t2def then
        for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do if Spring.GetUnitDefID(uid) == t2def then t2cons = t2cons + 1 end end
    end
    local nHelp = 0
    for _ in pairs(T.fusHelpers or {}) do nHelp = nHelp + 1 end
    Spring.Echo(string.format("[AUDIT] %s T2 cons alive %d (free %d), retrofits running %d, grids retrofit-eligible %d, retrofitted-started %d, helpers on jobs %d",
        Clock(frame), t2cons, FreeT2(T), #T.upgradeStates, #T.completed, (function() local c = 0 for _ in pairs(T.upgradedKeys) do c = c + 1 end return c end)(), nHelp))
    Spring.Echo(string.format(
        "[AUDIT] %s grids %d | T2 mex %d of %d (%.0f%%) | fusions %d | winds %d | nanos %d (grids by nanos: 0:%d 1:%d 2-5:%d 6-%d:%d all %d:%d) | grids with any T2 %d (%.0f%%), FULLY upgraded %d (%.0f%%)",
        Clock(frame), n, t2, t1 + t2, 100 * t2 / math.max(1, t1 + t2), fus, win, nano, bk[1], bk[2], bk[3], K.AUDIT_FULL_NANOS - 1, bk[4], K.AUDIT_FULL_NANOS, bk[5],
        someT2, 100 * someT2 / n, full, 100 * full / n))
end

-- ── GRID_RECOVER ─────────────────────────────────────────────────────────────

-- Remember a finished grid's mex spots (merged over re-runs: on a re-run the mexes still standing are "skipped").
local function RememberGridMexes(T, gs)
    local key = Key(gs.anchorX, gs.anchorZ)
    T.gridMexes = T.gridMexes or {}
    local list = T.gridMexes[key]
    if not list then list = { anchorX = gs.anchorX, anchorZ = gs.anchorZ, spots = {}, have = {} }; T.gridMexes[key] = list end
    for _, it in ipairs(gs.queue) do
        if it.cls == "metal" and it.act ~= "reclaim" and it.status == "built" then
            local sk = math.floor(it.wx) .. "," .. math.floor(it.wz)
            if not list.have[sk] then list.have[sk] = true; list.spots[#list.spots + 1] = { x = it.wx, z = it.wz } end
        end
    end
end

-- Is any mex of ours (T1 or T2, finished or a frame) standing on this spot?
local function MexAt(T, x, z)
    for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, 40, T.teamID) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and (d.extractsMetal or 0) > 0 then return true end
    end
    return false
end

local function ThreatNear(T, x, z, r)
    local mb = T.WG and T.WG.MetalBot
    for _, t in ipairs((mb and mb.threats) or {}) do
        if t.x and (t.x - x) ^ 2 + (t.z - z) ^ 2 <= r * r then return true end
    end
    return false
end

local function UpdateRecovery(T, frame)
    local C = T.CFG
    if not C.GRID_RECOVER or not T.gridMexes or frame - (T.recoverF or -1e9) < C.RECOVER_EVERY then return end
    T.recoverF = frame
    -- grids being built, re-run or retrofitted right now are not judged (a retrofit reclaims its T1 mexes on purpose)
    local busy = {}
    for _, gs in ipairs(T.gridStates) do busy[Key(gs.anchorX, gs.anchorZ)] = true end
    for _, us in ipairs(T.upgradeStates) do busy[Key(us.anchorX, us.anchorZ)] = true end
    for _, g in ipairs(T.pendingGrids) do busy[Key(g.anchorX, g.anchorZ)] = true end
    T.recoverMiss = T.recoverMiss or {}
    for key, list in pairs(T.gridMexes) do
        if busy[key] then
            T.recoverMiss[key] = nil
        else
            local gone = 0
            for _, s in ipairs(list.spots) do if not MexAt(T, s.x, s.z) then gone = gone + 1 end end
            if gone < C.RECOVER_MIN_MEX then
                T.recoverMiss[key] = nil
            elseif not T.recoverMiss[key] then
                T.recoverMiss[key] = frame                     -- first look: confirm on the next one
            elseif ThreatNear(T, list.anchorX, list.anchorZ, C.RECOVER_SAFE_R) then
                -- the raid is still there: wait
            else
                T.recoverMiss[key] = nil
                T.recovered = (T.recovered or 0) + 1
                if T.upgradedKeys[key] and T.upgradeBP then
                    T.upgradedKeys[key] = nil                  -- retrofit again: the T2 con rebuilds the mohos
                    Spring.Echo(string.format("[LT] %s RECOVER grid (%d, %d): %d of %d mex spots empty -> retrofit re-opened (%d recoveries)",
                        Clock(frame), list.anchorX, list.anchorZ, gone, #list.spots, T.recovered))
                    AssignCons(T)
                else
                    table.insert(T.pendingGrids, 1, { anchorX = list.anchorX, anchorZ = list.anchorZ,
                                                      rotation = T.gridRotation[key] or 0, recover = true })
                    Spring.Echo(string.format("[LT] %s RECOVER grid (%d, %d): %d of %d mex spots empty -> grid re-run queued first (%d recoveries)",
                        Clock(frame), list.anchorX, list.anchorZ, gone, #list.spots, T.recovered))
                end
            end
        end
    end
end

-- ── LINE_RECOVER (the "linenano" job) ───────────────────────────────────────
-- Round 3 (user 2026-10-13): after the line is built its builders are released, so a destroyed line nano was never
-- rebuilt (14 -> 7 nanos by 12:00).  Only the nano spots near a T1 air lab matter (their build power makes the air cons):
-- a spot that stays empty over two looks with no raid near is rebuilt by a free air con.
-- queued slots still empty (a stood-up or reclaimed one drops out)
local function LineNanoWant(T)
    local q, n = T.lineRecQueue, 0
    for i = #q, 1, -1 do
        if q[i].state ~= "free" or q[i].recCon then q[i].recQueued = nil; table.remove(q, i) else n = n + 1 end
    end
    return n
end

-- the con holds out of the pool until the nano stands
local function StartLineNano(T, conID, frame)
    local nanoID = UnitDefNames.cornanotc and UnitDefNames.cornanotc.id
    local s = table.remove(T.lineRecQueue, 1)
    if not (s and nanoID) then return false end
    local y = Spring.GetGroundHeight(s.wx, s.wz) or 0
    Spring.GiveOrderToUnit(conID, -nanoID, { s.wx, y, s.wz, 0 }, {})
    s.recCon, s.recAt = conID, frame
    T.lineRecovered = (T.lineRecovered or 0) + 1
    Spring.Echo(string.format("[LT] %s RECOVER line nano at (%d, %d): con %d rebuilds it (%d so far)",
        Clock(frame), s.wx, s.wz, conID, T.lineRecovered))
    return true
end

local function UpdateLineRecovery(T, frame)
    local C = T.CFG
    if not C.LINE_RECOVER or not T.L or not T.L.nanos or frame - (T.lineRecF or -1e9) < C.RECOVER_EVERY then return end
    T.lineRecF = frame
    local nanoID = UnitDefNames.cornanotc and UnitDefNames.cornanotc.id
    if not nanoID then return end
    local labs = {}
    for _, id in ipairs({ T.airLabID, T.lab2 and T.lab2.labID }) do
        if id and Spring.GetUnitDefID(id) then
            local x, _, z = Spring.GetUnitPosition(id)
            if x then labs[#labs + 1] = { x = x, z = z } end
        end
    end
    if #labs == 0 then return end
    for _, s in ipairs(T.L.nanos) do
        if s.state == "nano" then
            s.wasNano = true
        elseif s.state == "free" and s.wasNano then
            local near = false
            for _, lb in ipairs(labs) do
                if (s.wx - lb.x) ^ 2 + (s.wz - lb.z) ^ 2 <= C.LINE_RECOVER_R ^ 2 then near = true end
            end
            if near and not ThreatNear(T, s.wx, s.wz, C.RECOVER_SAFE_R) then
                if s.recMiss then
                    -- is it already up (a rebuild that finished)?
                    for _, uid in ipairs(Spring.GetUnitsInCylinder(s.wx, s.wz, 40, T.teamID) or {}) do
                        if Spring.GetUnitDefID(uid) == nanoID then
                            s.state, s.unitID, s.recMiss = "nano", uid, nil
                            if s.recCon then CB.Release(T.CB, s.recCon); s.recCon = nil end
                            s.recQueued = nil
                            if T.crew then T.crew.nNano = (T.crew.nNano or 0) + 1 end
                            break
                        end
                    end
                    if s.recCon and frame - s.recAt > 1800 then      -- the rebuild stalled: give the con back, try again
                        CB.Release(T.CB, s.recCon, true)
                        s.recCon, s.recQueued = nil, nil
                    end
                    if s.state == "free" and not s.recCon and not s.recQueued then
                        s.recQueued = true                            -- the linenano job gives it a con
                        T.lineRecQueue[#T.lineRecQueue + 1] = s
                    end
                else
                    s.recMiss = frame                              -- first look: confirm on the next one
                end
            end
        end
    end
end

-- ── SECOND_AIR_LAB ───────────────────────────────────────────────────────────

-- A 3x2 block of wind / mex / free line slots (never a starter, reserved or dead slot): the fewest mexes first (the real
-- line is about half mexes, mixed in with the winds), then nearest the first air lab; and LAB2_NANOS slots of the same
-- kinds beside it, winds first.  Returns { slots, nanos, wx, wz } or nil.
local function PickLab2Site(T)
    local LC = T.LC
    local ok = function(s) return s and (s.state == "wind" or s.state == "free" or s.state == "mex") end
    local lx, lz
    if T.airLabID then local x, _, z = Spring.GetUnitPosition(T.airLabID); lx, lz = x, z end
    local best
    for _, lane in ipairs(T.L.lanes) do
        local at = {}
        for _, s in ipairs(lane.slots) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
        for k0 = LC.K_FIRST, LC.K_LAST - 2 do
            for r0 = 1, 1 do                -- rows 1-2, as the first air lab (other row pairs may not be adjacent)
                local slots, good = {}, true
                for row = r0, r0 + 1 do
                    for k = k0, k0 + 2 do
                        local s = at[row] and at[row][k]
                        if ok(s) then slots[#slots + 1] = s else good = false end
                    end
                end
                if good then
                    local wx, wz, mexes = 0, 0, 0
                    for _, s in ipairs(slots) do
                        wx, wz = wx + s.wx, wz + s.wz
                        if s.state == "mex" then mexes = mexes + 1 end
                    end
                    wx, wz = wx / 6, wz / 6
                    local d = (lx and math.sqrt((wx - lx) ^ 2 + (wz - lz) ^ 2) or 0) + mexes * 100000
                    if not best or d < best.d then
                        best = { d = d, lane = lane, slots = slots, wx = wx, wz = wz, k0 = k0, r0 = r0, mexes = mexes }
                    end
                end
            end
        end
    end
    if not best then return nil end
    local inLab = {}
    for _, s in ipairs(best.slots) do inLab[s] = true end
    local cands = {}
    for _, s in ipairs(best.lane.slots) do
        if ok(s) and not inLab[s] and s.row >= best.r0 and s.row <= best.r0 + 1
           and (s.k == best.k0 - 1 or s.k == best.k0 + 3 or s.k == best.k0 - 2 or s.k == best.k0 + 4) then
            cands[#cands + 1] = { s = s, d = math.abs(s.k - (best.k0 + 1)) + (s.state == "mex" and 10 or 0) }
        end
    end
    table.sort(cands, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.s.row < b.s.row end)
    best.nanos = {}
    for i = 1, math.min(T.CFG.LAB2_NANOS, #cands) do best.nanos[i] = cands[i].s end
    return best
end

-- Planning: is the second lab due, and where would it go?  (T.lab2Site; the "lab2" job gives it a con.)
local function UpdateSecondLab(T, frame, res)
    local C = T.CFG
    if not C.SECOND_AIR_LAB or not T.labDefID or not T.airLabID then T.lab2Site = nil; return end
    local L2 = T.lab2
    if not L2 then
        T.lab2Site = nil
        if frame < C.LAB2_FRAME then return end
        if T.LC.SlotsRemaining(T.L) > 0 and frame < C.LAB2_LATEST then return end
        local site = PickLab2Site(T)
        if not site then
            if frame - (T.lab2LogF or -1e9) >= 900 then
                T.lab2LogF = frame
                Spring.Echo("[LT] " .. Clock(frame) .. " second air lab: no 3x2 block of built line slots")
            end
            return
        end
        T.lab2Site = site
        if not T.lab2Logged then
            T.lab2Logged = true
            Spring.Echo("[LT] " .. Clock(frame) .. " second air lab due: an air con is wanted for it")
        end
        return
    end
    if L2.st and not L2.st.done and L2.st.builderID and Spring.GetUnitDefID(L2.st.builderID) then
        -- LAB2_NANO_HELP (round 3): every nano in reach reclaims the winds / mexes in the way, then builds the lab frame
        local NANO = T.BP.NANO
        if C.LAB2_NANO_HELP and NANO and frame % 60 == 0 then
            local lab
            for _, uid in ipairs(Spring.GetUnitsInCylinder(L2.x, L2.z, 60, T.teamID) or {}) do
                if Spring.GetUnitDefID(uid) == T.labDefID then lab = uid; break end
            end
            if lab then
                L2.labID = lab
                for _, nid in ipairs(T.BP.NanosInRange(L2.x, L2.z) or {}) do NANO.Guard(NANO.PRIO.BALANCE, nid, lab) end
            else
                local windID = T.windDefID or (UnitDefNames.corwin or {}).id
                for _, uid in ipairs(Spring.GetUnitsInCylinder(L2.x, L2.z, 220, T.teamID) or {}) do
                    local did = Spring.GetUnitDefID(uid)
                    if did == windID or did == (UnitDefNames.cormex or {}).id then
                        local x, _, z = Spring.GetUnitPosition(uid)
                        for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, nid, uid) end
                    end
                end
            end
        end
    end
end

-- The lab2 job: one con while the lab is due; later one more if the lab's builder dies mid-job (it then takes the session over).
local function Lab2Want(T)
    local L2 = T.lab2
    if not L2 then return T.lab2Site and 1 or 0 end
    local st = L2.st
    if st and not st.done and st.builderID and not Spring.GetUnitDefID(st.builderID) then return 1 end
    return 0
end

local function StartLab2(T, conID, frame)
    local L2 = T.lab2
    if L2 then                                           -- its con died: this one takes the job over
        L2.st.builderID, L2.st.currentTask = conID, nil
        Spring.Echo(string.format("[LT] %s second air lab: builder died, con %d takes over", Clock(frame), conID))
        return true
    end
    local site = T.lab2Site
    if not site then return false end
    local x, z, f = LT.LabSpot(T, site)
    if not x then
        -- the winds still stand there: TestBuildOrder fails, so place it on the slot centre and let the placer clear it
        x, z = T.BP.SnapToBuildGrid(T.labDefID, site.wx, site.wz, T.BP.RotateFacing(0, T.L.rot))
        f = T.BP.RotateFacing(0, T.L.rot)
    end
    for _, s in ipairs(site.slots) do s.state = "reserved" end
    for _, s in ipairs(site.nanos) do s.state = "reserved" end
    local layout = {}
    for _, s in ipairs(site.nanos) do layout[#layout + 1] = { n = "cornanotc", x = s.wx - x, z = s.wz - z, f = 0 } end
    layout[#layout + 1] = { n = UnitDefs[T.labDefID].name, x = 0, z = 0, f = f }
    local st = T.BP.New({ layout = layout }, conID, x, z, 0, {})
    st.clearBlockers = true
    st.clearOnlyDefIDs = { [(UnitDefNames.corwin or {}).id or -1] = true, [(UnitDefNames.cormex or {}).id or -1] = true }
    T.lab2 = { st = st, x = x, z = z, site = site, since = frame }
    T.lab2Site = nil
    Spring.Echo(string.format("[LT] %s SECOND AIR LAB: %s at (%d, %d), %d line slots reserved (%d of them mexes) + %d nanos, built by con %d",
        Clock(frame), UnitDefs[T.labDefID].name, x, z, #site.slots, site.mexes or 0, #site.nanos, conID))
    return st
end

-- ── The jobs ─────────────────────────────────────────────────────────────────
-- Every job that wants an air con is registered here; con_broker hands the cons out in priority order.  The jobs keep their
-- own logic above (what to build, where); the broker owns WHICH con does it, the reserve, and the cons' return to the pool.
-- To add a job: one CB.AddJob below (see the header of con_broker.lua).

RegisterJobs = function(T)
    local cb = T.CB
    T.IsT2 = function(defID) return IsT2Con(T, defID) end
    cb.hooks.reserve = function(frame, res) KeepAirConReserve(T, frame, res) end
    cb.hooks.before = function() SetReserves(T) end
    local function CanBuildDef(name)
        return function(id)
            local ud = UnitDefNames[name]
            return ud and T.BP.CanBuild(Spring.GetUnitDefID(id), ud.id) or false
        end
    end

    -- T2 cons ───────────────────────────────────────────────────────────────
    CB.AddJob(cb, { name = "silo", prio = 90, tier = "t2", useReserve = true,
        sessions = T.siloJobs, paused = function() return T.ecoPaused end,
        want = function() return SiloWant(T) end,
        start = function(id) return StartSilo(T, id) end })

    CB.AddJob(cb, { name = "consolidate", tier = "t2", useReserve = true, prio = 45,   -- after the retrofits, but it may use the T2 hold
        sessions = T.consolidateJobs, paused = function() return T.ecoPaused end,
        want = function() return ConsolWant(T) end,
        start = function(id, frame, res) return StartConsolidationJob(T, id, frame, res) end,
        canTake = function(id)
            local force = ConsolForce(T)
            local ud = force and UnitDefNames[force]
            return not ud or T.BP.CanBuild(Spring.GetUnitDefID(id), ud.id)
        end,
        produce = function(frame) ConsolProduce(T, frame) end })

    CB.AddJob(cb, { name = "retrofit", prio = 50, tier = "t2",
        -- a floating bank (RETROFIT_HOLD_FRAC of storage) is the best case for retrofits: they may take the cons the hold keeps for the
        -- consolidation / fusion jobs (vacuum test: 60k metal wasted at the cap 15:00-17:00 with 3 retrofits running and 30 T2 cons consolidating)
        useReserve = function()
            local r, f = T.lastRes, T.CFG.RETROFIT_HOLD_FRAC
            return f and r and r.metalStorage > 0 and r.metal / r.metalStorage >= f or false
        end,
        sessions = T.upgradeStates, paused = function() return T.ecoPaused or T.retrofitPaused end,
        preemptMax = 4,                                            -- helpers released for retrofits: a few at a time
        want = function() return (T.upgradeBP and not T.ecoPaused) and RetrofitsWaiting(T) or 0 end,
        start = function(id) return StartRetrofit(T, id) end,
        produce = function(frame, res) UpdateRetrofitCons(T, frame, res) end })

    -- T1 cons ───────────────────────────────────────────────────────────────
    CB.AddJob(cb, { name = "lab2", prio = 78, tier = "t1", useReserve = true,
        sessions = T.lab2Sessions,
        want = function() return Lab2Want(T) end,
        start = function(id, frame) return StartLab2(T, id, frame) end,
        onOrphan = function(st) return T.lab2 ~= nil and T.lab2.st == st end,     -- wait for a new builder (it takes the job over)
        onDone = function(st, frame)
            local L2 = T.lab2
            if L2 and L2.st == st and not L2.logged then
                L2.logged = true
                Spring.Echo(string.format("[LT] %s second air lab site done (lab %s)", Clock(frame), tostring(L2.labID)))
            end
            if st.builderID and Spring.GetUnitDefID(st.builderID) then CB.Release(cb, st.builderID) end
        end })

    CB.AddJob(cb, { name = "linenano", prio = 75, tier = "t1", useReserve = true,
        want = function() return T.CFG.LINE_RECOVER and LineNanoWant(T) or 0 end,
        start = function(id, frame) return StartLineNano(T, id, frame) end,
        onLost = function(id)
            for _, s in ipairs((T.L and T.L.nanos) or {}) do
                if s.recCon == id then s.recCon, s.recQueued = nil, nil end
            end
        end })

    CB.AddJob(cb, { name = "nanocrew", prio = 72, tier = "t1", useReserve = true, urgent = false,
        preemptable = true,                                        -- only an idle member, only for the energy push
        canPreempt = function(id) local m = T.nanoCrew[id]; return T.CFG.ENERGY_PRIORITY and m and not m.items end,
        heldPrio = function(id) local m = T.nanoCrew[id]; return (m and not m.items) and 25 or 72 end,
        want = function(frame) return NanoCrewWant(T, frame) end,
        start = function(id, frame) return StartCrewMember(T, id, frame) end,
        idleCount = function()
            local n = 0
            for id, m in pairs(T.nanoCrew) do if not m.items and Spring.GetUnitDefID(id) then n = n + 1 end end
            return n
        end,
        onPreempt = function(id) T.nanoCrew[id] = nil end,
        onLost = function(id) T.nanoCrew[id] = nil end })

    CB.AddJob(cb, { name = "grid", prio = 70, tier = "t1", useReserve = true,
        sessions = T.gridStates, paused = function() return T.ecoPaused end,
        want = function() return T.ecoPaused and 0 or #T.pendingGrids end,
        start = function(id, frame) return StartGrid(T, id, frame) end,
        onDone = function(st)
            if st.builderID and Spring.GetUnitDefID(st.builderID) then CB.Release(cb, st.builderID) end
            if T.CFG.GRID_RECOVER then RememberGridMexes(T, st) end
        end })

    -- helpers: they take what is idle and give it back to any job above them ──────
    CB.AddJob(cb, { name = "fusionhelp", tier = "any", preemptable = true,
        prio = function() return 30 end,
        want = function() return FusionHelperWant(T) end,
        start = function(id) return StartFusionHelper(T, id) end,
        canTake = function(id, tier)                              -- a T2 con helps only when no wind block or retrofit needs it
            return tier == 1 or (#T.windBlocks == 0 and RetrofitsWaiting(T) == 0)
        end,
        onPreempt = function(id) T.fusHelpers[id] = nil end,
        onLost = function(id) T.fusHelpers[id] = nil end })

    CB.AddJob(cb, { name = "gridhelp", prio = 20, tier = "t1", preemptable = true, urgent = false,
        want = function() local _, n = HelpSlots(T); return math.min(n, HelperRoom(T)) end,
        start = function(id) return StartGridHelper(T, id) end,
        onPreempt = function(id) T.helpers[id] = nil end,
        onLost = function(id) T.helpers[id] = nil end })
end

local function UpdateGrids(T, frame, res)
    AuditGrids(T, frame)
    UpdateRecovery(T, frame)
    UpdateLineRecovery(T, frame)
    UpdateSecondLab(T, frame, res)
    if T.CFG.RETROFIT_MEX_DONE and frame % 60 == 0 then
        for _, gs in ipairs(T.gridStates) do
            local key = Key(gs.anchorX, gs.anchorZ)
            if not gs.done and not T.gridFinished[key] then
                local mexes, left = 0, 0
                for _, it in ipairs(gs.queue) do
                    if it.cls == "metal" and it.act ~= "reclaim" then
                        mexes = mexes + 1
                        if not (it.built or it.status == "built" or it.status == "skipped") then left = left + 1 end
                    end
                end
                if mexes > 0 and left == 0 then
                    T.gridFinished[key] = true
                    AddCompleted(T, gs.anchorX, gs.anchorZ)
                    if T.windDefID or UnitDefNames.corwin then
                        gs.skipDefIDs = gs.skipDefIDs or {}
                        gs.skipDefIDs[T.windDefID or UnitDefNames.corwin.id] = true
                    end
                    Spring.Echo(string.format("[LT] %s grid (%d, %d) mexes up -- retrofit eligible", Clock(frame), gs.anchorX, gs.anchorZ))
                    AssignCons(T)
                end
            end
        end
    end
    UpdateNanoCrew(T, frame)
    if not T.firstGridOK and T.firstGrid then
        local st, n, done = T.firstGrid, 0, 0
        for _, it in ipairs(st.queue) do
            n = n + 1
            if it.status == "built" or it.status == "skipped" or it.built then done = done + 1 end
        end
        if st.done or (n > 0 and done / n >= T.CFG.AIR_CON_CAP_UNTIL) then
            LiftAirConCap(T, string.format("first grid %d%% built", n > 0 and math.floor(100 * done / n) or 100))
        end
    end
    -- every job's build sessions run now (grids, retrofits, fusions, silos, cells, the second lab); a finished one frees its con
    CB.RunSessions(T.CB, frame, res)
    if not T.ecoPaused then UpdateGridHelpers(T, frame) end
    if not T.ecoPaused then ReleaseCandidates(T, frame, res) end
    CheckCapPressure(T, res, frame)
    if not T.ecoPaused then
        UpdateRetrofits(T, frame, res)
        UpdateT2TopUp(T, frame, res)
        UpdateT2Deferred(T, frame)
        UpdateIdleCons(T, frame, res)
        UpdateConsolidation(T, frame, res)
    end
    if frame % T.CFG.RECLAIM_EVERY == 0 then UpdateWindReclaim(T) end
    UpdateSpendPressure(T, res)
    -- hand the cons out, ask the labs for what is short (T1: the reserve; T2: the jobs' `produce`)
    CB.Update(T.CB, frame, res, true)
    -- an order older than AIR_CON_TIMEOUT is forgotten only if the air lab no longer has it queued: a deep queue (30 cons ordered at
    -- once) takes longer than the timeout to work off, and forgetting orders that are still queued made the labs order the same cons again
    if #T.orders > 0 and frame - T.orders[1] > T.CFG.AIR_CON_TIMEOUT then
        local queued = 0
        local lab = T.airLabID
        if lab and T.airConDefID and Spring.GetFactoryCommands then
            for _, c in ipairs(Spring.GetFactoryCommands(lab, -1) or {}) do
                if c.id == -T.airConDefID then queued = queued + 1 end
            end
        end
        while #T.orders > 0 and frame - T.orders[1] > T.CFG.AIR_CON_TIMEOUT and T.airConsOrdered > queued do
            Spring.Echo("[LT] an air con order never came out; forgetting it")
            AirConOrderDone(T)
        end
        -- (still queued: re-date the oldest so the check is not repeated every frame)
        if #T.orders > 0 and frame - T.orders[1] > T.CFG.AIR_CON_TIMEOUT then T.orders[1] = frame - T.CFG.AIR_CON_TIMEOUT + 300 end
    end
    UpdateLabAssist(T, frame)
end

-- ── Spine (TILE_BOT's unit production, hosted here) ──────────────────────────────────────────────────────────
-- What the spine borrows (see SPINE_BRIEF.md): constructors from the air-con pool, a way to reserve grid cells, the
-- unit-cap test, and a lab.  Its stack of 480-cell blueprints lies on the grid lattice (anchored on the first grid
-- cell), is reserved when the air lab finishes (before any grid cell is seeded), and cell 1 opens when the vehicle
-- lab stands.  Everything unit-related lives in bar_framework/spine.lua.

local function SpineTakeCon(T, defID, t1Only)
    return CB.Take(T.CB, "spine", { tier = t1Only and 1 or nil,
        canTake = function(cid) return not defID or T.BP.CanBuild(Spring.GetUnitDefID(cid), defID) end })
end

local function SpineReturnCon(T, uid)
    if not Spring.GetUnitDefID(uid) then return end
    CB.Add(T.CB, uid)                          -- (already known: no-op)
    CB.Release(T.CB, uid, true)
    AssignCons(T, T.frame)
end

-- Metal value of our finished ground army (armed, mobile, non-air, non-builder).  Gates the T2 labs.
local function SpineGroundArmyValue(T)
    if T.frame - (T.groundAVFrame or -1e9) < 15 then return T.groundAV or 0 end
    local total = 0
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and not d.isBuilder and not d.isFactory and not d.canFly
           and (d.speed or 0) > 0 and d.weapons and #d.weapons > 0
           and not Spring.GetUnitIsBeingBuilt(uid) then
            total = total + (d.metalCost or 0)
        end
    end
    T.groundAV, T.groundAVFrame = total, T.frame
    return total
end

-- The first three grids are at least 70% built (retrofit eligible): from here the spine releases nanos for 100% army.
local function SpineMexGridsReady(T)
    local n = 0
    for _ in pairs(T.gridFinished) do n = n + 1 end
    return n >= 3
end

local function FacingFor(dx, dz)          -- Spring facing: 0 south (+z), 1 east, 2 north, 3 west
    if dz > 0 then return 0 elseif dz < 0 then return 2 elseif dx > 0 then return 1 end
    return 3
end

-- The outer lane the vehicle lab goes on: the one the air lab did not take.
-- The vehicle lab's lane: the outer lane that faces the enemy (needs a builder on it before a site can be claimed).
local function VpLane(T)
    return T.enemyLane
end

-- Spine geometry: cell 1 sits directly in front of the vehicle lab (just outside the line, on the lab's side), so the
-- lab's two nanos reach it; the labs face away from the line and the stack of cells runs PARALLEL to the line.
-- Returns { geo, baseX, baseZ } (base = one cell behind cell 1) or nil.
local function SpineGeo(T)
    local SPINE, LC = T.spineMod, T.LC
    local lane = VpLane(T)
    if not lane then return nil end
    local out = (lane == 3) and 1 or -1                           -- b-z outward: lane 3 south of the line, lane 4 north
    local bx = T.vpSite and T.vpSite.bx or (LC.X0 + 64 * 8)       -- the lab's place along the line
    local bz = out > 0 and (LINE_BOX.z1 + T.CFG.SPINE_GAP + HALF_GRID) or (LINE_BOX.z0 - T.CFG.SPINE_GAP - HALF_GRID)
    local cx, cz = LC.World(T.L, bx, bz)
    cx, cz = math.floor(cx / 16 + 0.5) * 16, math.floor(cz / 16 + 0.5) * 16
    local fx, fz = LC.Rotate(0, out, T.L.rot)                     -- front: away from the line
    local sx, sz = LC.Rotate(1, 0, T.L.rot)                       -- stack: along the line
    local geo = SPINE.GeometryFor(fx, fz, sx, sz)
    local C = T.BP.GRID_SPACING
    local baseX, baseZ = cx - fx * C, cz - fz * C
    for n = 1, 3 do
        local ax, az = SPINE.CellAnchor(geo, baseX, baseZ, n)
        if ax < 240 or az < 240 or ax > T.L.mapX - 240 or az > T.L.mapZ - 240 then return nil end
    end
    return { geo = geo, baseX = baseX, baseZ = baseZ }
end

StartSpine = function(T, frame)
    local SPINE = T.spineMod
    if T.spineOn or not (SPINE and T.spineBPs and T.spineBPs.T1) then return end
    local g = SpineGeo(T)
    if not g then
        Spring.Echo("[LT] spine: no room in front of the vehicle lab; spine off")
        T.spineMod = nil
        return
    end
    -- Every cell and exit lane of the stack: grid cells must keep off them (their own lattice differs).
    T.spineBoxes = {}
    for n = 1, 2 * SPINE.CFG.STACK_HALF + 1 do
        local ax, az = SPINE.CellAnchor(g.geo, g.baseX, g.baseZ, n)
        local lx, lz = SPINE.LaneAnchor(g.geo, g.baseX, g.baseZ, n)
        T.spineBoxes[#T.spineBoxes + 1] = { x = ax, z = az }
        T.spineBoxes[#T.spineBoxes + 1] = { x = lx, z = lz }
    end
    SPINE.Init{
        BP_PLACER = T.BP, NANO = T.BP.NANO, blueprints = T.spineBPs,
        baseX = g.baseX, baseZ = g.baseZ, mapX = T.L.mapX, mapZ = T.L.mapZ,
        geo = g.geo, GroundOnly = true,        -- built by the vehicle lab's ground cons only, never by air cons
        EarlyCons = T.CFG.SPINE_EARLY_CONS,    -- one ground con until cell 1 is built
        AnchorKey   = Key,
        Reserve     = function(key) T.assigned[key] = true end,
        CellOK      = function(ax, az) return not InsideLine(T, ax, az) end,
        TakeCon     = function(defID, t1Only) return SpineTakeCon(T, defID, t1Only) end,
        ReturnCon   = function(uid) SpineReturnCon(T, uid) end,
        QueueAirCon = function() QueueAirCon(T, T.frame) end,
        DeferStop   = function(uid) T.pendingStops[#T.pendingStops + 1] = { id = uid, fire = T.frame + 30 } end,
        CapPressure = function()
            local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
            local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(T.teamID)
            return (maxU and cnt and (maxU - cnt) <= CapSlack(T, T.CFG.CONSOLIDATE_SLACK)) and true or false
        end,
        Threat      = function()
            local mb = T.WG and T.WG.MetalBot
            if not mb then return nil, 0 end
            return mb.urgency, mb.threats and #mb.threats or 0
        end,
        MexGridsReady   = function() return SpineMexGridsReady(T) end,
        GroundArmyValue = function() return SpineGroundArmyValue(T) end,
    }
    -- lab_controller reads WG.Spine.  The widget's WG is passed in: a module included with VFS.Include does not
    -- see the widget environment's globals (a bare WG was nil in the real game and killed this function here).
    if T.WG then T.WG.Spine = SPINE end
    SPINE.Start(frame, { deferOpen = true })
    T.spineOn = true
    local c1x, c1z = SPINE.CellAnchor(g.geo, g.baseX, g.baseZ, 1)
    Spring.Echo(string.format("[LT] %s spine: cell 1 at (%d, %d) in front of the vehicle lab, front (%d, %d), stack along (%d, %d)",
        Clock(frame), c1x, c1z, g.geo.dx, g.geo.dz, g.geo.px, g.geo.pz))
    -- The vehicle lab can already stand (air lab finished late): hand it over now.
    if T.vpID and Spring.GetUnitDefID(T.vpID) then
        SPINE.AdoptLab(T.vpID, Spring.GetUnitDefID(T.vpID), T.CFG.VP_CONS)
        SPINE.OpenFirst()
    end
end

-- ── Vehicle lab: 4 slots (2x2) + 2 nanos on the outer lane the air lab did not take ─────────────────────────────

-- Spot: the middle of the 2x2 block, facing outward (toward the lane's corridor, which the lab's units leave by).
local function VpSpot(T, site)
    local out = (site.lane == 3) and 1 or -1            -- b-z outward: lane 3 is south of the line, lane 4 north
    local ox, oz = T.LC.Rotate(0, out, T.L.rot)
    local face = FacingFor(ox, oz)
    if not T.vpSpotLogged then
        T.vpSpotLogged = true
        local ud = UnitDefs[T.vpDefID]
        Spring.Echo(string.format("[LT] vehicle lab %s footprint %dx%d elmos, 2x2 slot block 128x128; facing %d (outward)",
            ud.name, (ud.xsize or 0) * 8, (ud.zsize or ud.ysize or 0) * 8, face))
    end
    for _, f in ipairs({ face, (face + 2) % 4, (face + 1) % 4, (face + 3) % 4 }) do
        local x, z = T.BP.SnapToBuildGrid(T.vpDefID, site.wx, site.wz, f)
        local y = Spring.GetGroundHeight(x, z) or 0
        local ok = Spring.TestBuildOrder(T.vpDefID, x, y, z, f)
        if ok and ok ~= 0 then return x, z, f end
    end
    return nil
end

local function ReleaseVpSite(T)
    if not T.vpSite then return end
    for _, s in ipairs(T.vpSite.slots) do s.state = "free" end
    for _, s in ipairs(T.vpSite.nanos) do s.state = "free" end
    T.vpSite = nil
end

-- Queued backwards from the deadline: it must be FINISHED by VP_DONE_FRAME, so it starts when
-- frame >= deadline - build time (with everything that reaches it) - margin.  Always after the air lab is queued.
local function UpdateVehicleLab(T, frame, res)
    if T.vpPhase ~= "wait" or T.phase == "off" then return end
    local LC = T.LC
    if T.vpSite and not LC.LaneBuilder(T.crew, T.vpSite.lane) then ReleaseVpSite(T) end
    if not T.vpSite then
        local lane = VpLane(T)
        local site = lane and LT.PickSite(T, { lanes = { lane }, cols = T.CFG.VP_COLS })
        if not site then
            if frame % 300 == 0 and lane and LC.LaneBuilder(T.crew, lane) then
                local open = 0
                for _, s in ipairs((lane and T.L.lanes[lane] or { slots = {} }).slots) do if s.state == "free" then open = open + 1 end end
                Spring.Echo(string.format("[LT] %s no open 2x2 block on lane %s (builder %s, %d open slots) for the vehicle lab yet",
                    Clock(frame), tostring(lane), LC.LaneBuilder(T.crew, lane or 0) and "yes" or "no", open))
            end
            return
        end
        for _, s in ipairs(site.slots) do s.state = "reserved" end
        for _, s in ipairs(site.nanos) do s.state = "reserved" end
        T.vpSite = site
    end
    local site = T.vpSite
    local ud = UnitDefNames[T.CFG.VP_NAME]
    local bdef = Spring.GetUnitDefID(site.builder)
    if not ud or not (bdef and T.BP.CanBuild(bdef, ud.id)) then
        Spring.Echo("[LT] the lane's con cannot place " .. T.CFG.VP_NAME .. "; vehicle lab off")
        ReleaseVpSite(T)
        T.vpPhase = "off"
        return
    end
    T.vpDefID = ud.id
    local x, z, f = VpSpot(T, site)
    if not x then
        if frame % 300 == 0 then Spring.Echo("[LT] " .. Clock(frame) .. " no legal spot for the vehicle lab yet") end
        return
    end
    local p = LT.LabPlan(T, res, x, z, site.builder, T.vpDefID)
    local fire = T.CFG.VP_DONE_FRAME - math.floor(p.t * 30) - T.CFG.VP_MARGIN
    if not T.labFrame then return end            -- the site is held; the air lab always goes first
    if frame % T.CFG.LOG_EVERY == 0 then
        Spring.Echo(string.format("[LT] %s vehicle lab plan: BP %.0f (%d nanos) -> %.0fs; start at %s for done by %s; bank %d",
            Clock(frame), p.bp, p.nanos, p.t, Clock(math.max(fire, 0)), Clock(T.CFG.VP_DONE_FRAME), res.metal))
    end
    if frame < fire then return end
    -- urgent: the lane's con drops the slot it is on (it was seen stuck on one) and goes straight to the lab.
    LC.QueueJob(T.crew, site.builder, { name = ud.name, x = x, z = z, f = f, tag = "vp", urgent = true })
    T.vpPhase, T.vpFrame = "lab", frame
    Spring.Echo(string.format("[LT] %s VEHICLE LAB queued (%s) at (%d, %d) facing %d; BP %.0f, %.0fs, bank %d income %.1f%s",
        Clock(frame), ud.name, x, z, f, p.bp, p.t, res.metal, res.metalIncome, p.ok and "" or " (bank short)"))
end

-- ── Job results: lab, then its nanos ────────────────────────────────────────

-- Called by line_crew when a job's frame appears: every nano in reach goes onto the lab (the vehicle lab was built
-- by its con alone while the nanos worked on other jobs).
function LT.OnJobStarted(T, j)
    if j.tag ~= "lab" and j.tag ~= "vp" then return end
    local NANO = T.BP.NANO
    if not (NANO and j.unitID) then return end
    local x, _, z = Spring.GetUnitPosition(j.unitID)
    if not x then return end
    local n = 0
    for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
        if NANO.Assist(NANO.PRIO.HANDOFF, nid, j.unitID) then n = n + 1 end
    end
    Spring.Echo(string.format("[LT] %s %s frame up: %d nano(s) assisting", Clock(T.frame), j.tag == "vp" and "vehicle lab" or "air lab", n))
end

-- Called by line_crew when a job ends.
function LT.OnJobDone(T, j, state)
    if j.tag == "lab" then
        if state ~= "done" then
            T.labTries = T.labTries + 1
            Spring.Echo(string.format("[LT] air lab job %s (try %d)", state, T.labTries))
            T.phase = T.labTries >= 3 and "off" or "wait"
            -- Give the slots back to the line; the next try picks a fresh site.
            for _, s in ipairs(T.site.slots) do s.state = "free" end
            for _, s in ipairs(T.site.nanos) do s.state = "free" end
            T.site = nil
            return
        end
        T.airLabID, T.phase = j.unitID, "grids"
        T.airConDefID = FindAirConDef(T.labDefID)
        Spring.Echo(string.format("[LT] %s AIR LAB finished (%d); %.0fs after it was queued", Clock(T.frame), j.unitID,
            (T.frame - (T.labFrame or T.frame)) / 30))
        -- Two nanos on the open slots beside the lab, on the same con.
        local LC = T.LC
        for _, s in ipairs(T.site.nanos) do
            LC.QueueJob(T.crew, T.site.builder, { name = "cornanotc", x = s.wx, z = s.wz, f = 0, tag = "labnano" })
        end
        if #T.site.nanos < 2 then Spring.Echo("[LT] only " .. #T.site.nanos .. " open slot(s) for lab nanos") end
        T.labNanosPending = #T.site.nanos
        if T.labNanosPending == 0 then LiftAirConCap(T, "no lab nanos to wait for") end
        local lx, _, lz = Spring.GetUnitPosition(T.airLabID)
        if T.airConDefID and lx then
            OpenFirstGrid(T, T.frame, lx, lz)
            for _ = 1, 1 + T.CFG.AIR_CON_RESERVE do QueueAirCon(T, T.frame) end
        else
            Spring.Echo("[LT] the air lab has no air constructor to build")
        end
    elseif j.tag == "labnano" then
        Spring.Echo(string.format("[LT] %s lab nano %s", Clock(T.frame), state))
        if state == "done" and j.unitID then T.labNanoIDs[j.unitID] = true end
        T.labNanosPending = math.max(0, (T.labNanosPending or 1) - 1)
        if T.labNanosPending == 0 then LiftAirConCap(T, "the air lab's nanos are up") end
    elseif j.tag == "vp" then
        if state ~= "done" then
            T.vpTries = T.vpTries + 1
            Spring.Echo(string.format("[LT] vehicle lab job %s (try %d)", state, T.vpTries))
            T.vpPhase = T.vpTries >= 3 and "off" or "wait"
            ReleaseVpSite(T)
            return
        end
        T.vpID, T.vpPhase = j.unitID, "done"
        Spring.Echo(string.format("[LT] %s VEHICLE LAB finished (%d); %.0fs after it was queued", Clock(T.frame), j.unitID,
            (T.frame - (T.vpFrame or T.frame)) / 30))
        for _, s in ipairs(T.vpSite.nanos) do
            T.LC.QueueJob(T.crew, T.vpSite.builder, { name = "cornanotc", x = s.wx, z = s.wz, f = 0, tag = "vpnano" })
        end
        if T.spineOn then
            T.spineMod.AdoptLab(j.unitID, Spring.GetUnitDefID(j.unitID), T.CFG.VP_CONS)
            T.spineMod.OpenFirst()
        end
    elseif j.tag == "vpnano" then
        Spring.Echo(string.format("[LT] %s vehicle lab nano %s", Clock(T.frame), state))
    end
end

-- ── Entry points ─────────────────────────────────────────────────────────────

function LT.Update(T, frame, res)
    T.frame = frame
    T.lastRes = res
    local i = 1
    while i <= #T.pendingStops do
        local ps = T.pendingStops[i]
        if frame >= ps.fire then
            if Spring.GetUnitDefID(ps.id) then Spring.GiveOrderToUnit(ps.id, CMD_STOP, {}, {}) end
            table.remove(T.pendingStops, i)
        else
            i = i + 1
        end
    end
    if T.CFG.SHARE_GOV then
        if not T.sg then
            local ok, SG = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/spend_governor.lua")
            if ok and SG then
                T.sgMod, T.sg = SG, SG.New(T)
                for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
                    if not Spring.GetUnitIsBeingBuilt(uid) then T.sgMod.OnUnitFinished(T.sg, uid, Spring.GetUnitDefID(uid)) end
                end
            else
                Spring.Echo("[LT] SHARE_GOV: spend_governor failed to load: " .. tostring(SG)); T.CFG.SHARE_GOV = false
            end
        end
        if T.sg then T.sgMod.Update(T.sg, frame, res) end
    end
    if T.phase == "wait" then UpdateWait(T, frame, res)
    elseif T.phase == "grids" then UpdateGrids(T, frame, res) end
    UpdateVehicleLab(T, frame, res)
    if T.spineOn then T.spineMod.Update(frame, res) end
end

function LT.OnUnitCreated(T, unitID, defID, builderID)
    if T.spineOn then T.spineMod.OnUnitCreated(unitID, defID, builderID) end
end

function LT.OnUnitFinished(T, unitID, defID, x, z)
    local d = UnitDefs[defID]
    if T.sg then T.sgMod.OnUnitFinished(T.sg, unitID, defID) end
    -- A finished advanced air lab orders no T2 cons itself unless T2_CONS_UP_FRONT: they are built only when a job wants one
    -- (UpdateRetrofitCons / MakeEnergyT2Con).  Up front is what kept the old STANCE_BOT's retrofits and fusions supplied.
    if T.CFG.T2_CONS_UP_FRONT and d and d.isFactory and T.upgradeBP and unitID ~= T.airLabID then
        local t2 = FindAirConDef(defID)
        if t2 and IsT2Con(T, t2) then
            if ConHold(T, T.frame or 0, "up-front T2 cons") then
                T.t2Deferred = T.t2Deferred or {}
                T.t2Deferred[unitID] = t2                       -- ordered once the air labs are free again (UpdateT2Deferred)
            else
                for _ = 1, T.CFG.UPGRADE_CONS_PER_LAB do OrderT2Con(T, unitID, t2, T.frame) end
            end
        end
    end
    -- Air cons come out guarding the lab: stop them now and again once that order has landed.
    if T.airLabID and d and d.isBuilder and d.canFly and not d.isFactory then
        Spring.GiveOrderToUnit(unitID, CMD_STOP, {}, {})
        T.pendingStops[#T.pendingStops + 1] = { id = unitID, fire = T.frame + 30 }
        -- the broker hands the new con to the highest job that wants one (the second lab, the nano crew, a grid, ...); the
        -- spine gets it only when no job did and no grid is waiting
        local t1 = not IsT2Con(T, defID)
        if not t1 and T.t2Orders and #T.t2Orders > 0 then table.remove(T.t2Orders, 1) end
        if t1 then
            AirConOrderDone(T)
            T.airConsAlive[unitID] = true
        end
        CB.Add(T.CB, unitID, defID)
        AssignCons(T, T.frame)
        if t1 and CB.Owner(T.CB, unitID) == nil and #T.pendingGrids == 0 and T.spineOn and T.spineMod.OfferCon(unitID) then
            CB.Claim(T.CB, unitID, "spine")
        end
    end
    if T.spineOn then T.spineMod.OnUnitFinished(unitID, defID, x, z) end
    CB.EachSession(T.CB, function(st) T.BP.OnUnitFinished(st, unitID, defID, x, z) end)
    local L2 = T.lab2
    if L2 and L2.st then
        if defID == T.labDefID and not L2.labID and x and (x - L2.x) ^ 2 + (z - L2.z) ^ 2 < 200 * 200 then
            L2.labID = unitID
            Spring.Echo(string.format("[LT] %s SECOND AIR LAB finished (%d), %.0fs after it was started", Clock(T.frame), unitID,
                (T.frame - L2.since) / 30))
        end
    end
end

-- A ground constructor (or necro) of ours joins the broker too: the cons the line / the spine / the rez crew run are CLAIMED by
-- those systems (owner "line" / "spine" / "rez"), so defense_crew and the jobs leave them alone; one from any other factory is a
-- free ground con that a job with kind = "ground" (or `defs`) may take.  owner = nil: free.
local function IsGroundCon(d)
    return d and d.isBuilder and not d.isFactory and not d.canFly and (d.speed or 0) > 0
       and not (d.customParams and d.customParams.iscommander)
end

function LT.AdoptCon(T, unitID, owner)
    local defID = Spring.GetUnitDefID(unitID)
    if not defID or not IsGroundCon(UnitDefs[defID]) then return false end
    CB.Add(T.CB, unitID, defID)
    if owner then CB.Claim(T.CB, unitID, owner) end
    return true
end

function LT.OnUnitFromFactory(T, unitID, defID, factID)
    if factID and factID == T.airLabID then Spring.GiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
    local gd = UnitDefs[defID]
    if IsGroundCon(gd) then
        local owner
        if gd.canResurrect then owner = "rez"
        elseif factID and factID == T.vpID then owner = "spine" end
        LT.AdoptCon(T, unitID, owner)
    end
    if T.spineOn then T.spineMod.OnUnitFromFactory(unitID, defID, factID) end
end

function LT.OnUnitDestroyed(T, unitID)
    if T.sg then T.sgMod.OnUnitDestroyed(T.sg, unitID) end
    -- A dead builder's id is KEPT in its session: the placer's Update checks Spring.GetUnitDefID(state.builderID) and
    -- ends the session itself; a nil id made that call error and removed the whole macro widget (seen at 6:30 when
    -- an enemy air raid killed an air con).
    T.airConsAlive[unitID] = nil
    CB.Remove(T.CB, unitID)
    if unitID == T.airLabID then T.airLabID = nil end
    if T.spineOn then T.spineMod.OnUnitDestroyed(unitID) end
end

-- What defense_crew needs from the broker (its `pool` option): which cons it may use, taking one, giving it back.
function LT.ConPool(T)
    return { Usable  = function(id) return CB.Usable(T.CB, id) end,
             Seize   = function(id, owner) return CB.Seize(T.CB, id, owner) end,
             Release = function(id) if CB.IsManaged(T.CB, id) then CB.Release(T.CB, id, true) end end }
end

function LT.Status(T)
    return string.format("phase %s grids %d (open %d) aircons free %d ordered %d", T.phase, T.gridsAssigned,
        #T.pendingGrids, CB.NFree(T.CB, 1), T.airConsOrdered)
end

-- For tests only (tests/test_con_hold.lua): the air / T2 con order paths that CON_HOLD gates.
LT._test = { QueueAirCon = QueueAirCon, MakeEnergyT2Con = MakeEnergyT2Con, UpdateRetrofitCons = UpdateRetrofitCons,
             RememberGridMexes = RememberGridMexes, UpdateRecovery = UpdateRecovery, PickLab2Site = PickLab2Site,
             UpdateSecondLab = UpdateSecondLab }

return LT
