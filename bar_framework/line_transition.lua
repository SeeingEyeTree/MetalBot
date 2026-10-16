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
--
-- Layout (2026-10-16): this file is the sequencer -- LT.New / Update / the entry points, the air lab and vehicle lab, and the spine
-- host.  Every job is a module in line_transition/ (see its header for the options it reads): con_orders (ordering cons, CON_HOLD,
-- reserve), grid_core, grid_interrupts, grid_helpers, grid_retrofit, grid_recovery, energy, nano_crew, silo, line_recovery,
-- second_lab, spine_cons.  A module is `Install(X)`: its functions take the state table T and are exported on X for the others;
-- its con_broker job (X.jobs.<name>) carries a `section`.  To add a job: a new module (copy a small one such as silo.lua), add it to the
-- install list and its job name to JOB_ORDER below.  Tests: tests/test_line_transition_modules.lua (a module on its own, via LT._X),
-- tests/check_lua_unbound.py (a name used without being bound), order_check.py (the whole game's order stream is unchanged).

local LT = {}
local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")   -- typed WG access (bar_framework/wg_channels.lua)
local CB = VFS.Include("LuaUI/Widgets/bar_framework/con_broker.lua")   -- every air con's owner: jobs ask it for cons (see the header there)
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")   -- Apply(): merge overrides + one [CFG] log row
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")   -- unit roles per faction (C4)
local BT = VFS.Include("LuaUI/Widgets/bar_framework/build_tree.lua")   -- the build tree (C1): who can build what
local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")   -- spend / energy / unit-cap questions (C3)
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")   -- the per-frame unit snapshot (C5)
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
    -- RETROFIT_MIN_NANOS (user, 2026-10-14): a grid is retrofit-eligible when this many of its nanos stand -- nothing else (not the 70% / mexes-up /
    --   nano-threshold triggers).  RETROFIT_BANK_GATE: new retrofits start while the bot is banking (bank >= this share of storage, or income above
    --   pull); while all income is spent only RETROFIT_MIN_RUNNING keep going -- and a running retrofit is never paused (set RETROFIT_STALL_FRAC 0).
    RETROFIT_MIN_NANOS = false,
    RETROFIT_BANK_GATE = false,
    RETROFIT_MIN_RUNNING = 4,
    T2_TOPUP_AHEAD = false,       -- number (3): grids with this many nanos standing count for the top-up before they are eligible
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
    VP_NAME       = ROLES.Get("lab_t1_veh"),
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
    -- RADAR_POSTS (user, 2026-10-16): a radar tower beside each blob of the maneuver plan (WG.MetalBot.blobs, maneuver_defence.lua),
    --   built by a free air con.  Inert under any other plan (no blobs published).  A blob with no radar within RADAR_COVER gets one,
    --   RADAR_BACK elmos behind its post; at most RADAR_AT_ONCE cons at a time, RADAR_MAX radars in all; a started site is not retried
    --   for RADAR_RETRY frames.
    RADAR_POSTS = true, RADAR_NAMES = { "corrad" }, RADAR_FRAME = 4 * 60 * 30, RADAR_COVER = 900, RADAR_BACK = 200,
    RADAR_AT_ONCE = 1, RADAR_MAX = 10, RADAR_RETRY = 1800,
    LAB2_FRAME        = 7 * 60 * 30,   -- not before this
    LAB2_LATEST       = 10 * 60 * 30,  -- ...and from here even if the line still has open slots
    LAB2_NANOS        = 4,             -- nano slots beside the lab
    LINE_RECOVER      = false,         -- rebuild destroyed line nanos near the T1 air labs (a free air con, two looks, no raid near)
    LINE_RECOVER_R    = 700,           -- ...within this of an air lab
    T2BOT_LAB         = false,         -- CORE (user 2026-10-16): a T2 bot lab on the line's last slots (line_transition/t2bot_lab.lua) makes the T2 bot cons
                                       -- the spine's blocks keep; reserved at the start, built at T2BOT_INCOME, then adopted by the spine
    T2BOT_INCOME      = 600,           -- metal income (m/s) at which it is built: not before, so the early eco is not eaten
    T2BOT_CONS        = 2,             -- T2BOT_CON_UNIT cons the lab makes first
    T2BOT_CON_UNIT    = ROLES.Get("con_t2_bot"),
    T2BOT_LAB_UNIT    = ROLES.Get("lab_t2_bot"),
    T2BOT_NANOS       = 2,             -- nano slots beside it that help build it
    DECOY_LINE        = false,         -- CORE (user 2026-10-16): once the spine is saturated the line is eaten, 3x2 slots at a time, into T2 bot labs that
                                       -- make decoy commanders (line_transition/line_decoy.lua); 8 decoys assist each, then the sink labs
    DECOY_LINE_MAX    = 6,             -- labs at most
    DECOY_LINE_PER_LAB = 8,            -- decoys that assist one line lab (lab_rules fills these first)
    DECOY_LINE_FRAC   = 0.85,          -- first lab when income >= this x the spine's spend capacity ...
    DECOY_LINE_MIN_INCOME = 800,       -- ... and never under this income
    DECOY_LINE_GAP    = 1800,          -- frames between labs
    DECOY_LINE_HELPERS = 3,            -- spine cons that repair the frame
    DECOY_LINE_LAB    = ROLES.Get("lab_t2_bot"),
    T2BOT_LANES       = { 3, 4 },      -- outer lanes tried for the site, in order (3 first: the lab faces out of the line there; 4 faced into it)
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

-- ── The modules ──────────────────────────────────────────────────────────────
-- The transition's jobs live in bar_framework/line_transition/*.lua.  Each module's Install(X) defines its functions (all take the
-- state table T) and exports what the others need on X; the order matters (a module binds the exports of those before it).
local INC = "LuaUI/Widgets/bar_framework/line_transition/"
local X = { LT = LT, CB = CB, BC = BC, CH = CH, Clock = Clock, Key = Key, jobs = {},
            HALF_GRID = HALF_GRID, LINE_BOX = LINE_BOX, CMD_STOP = CMD_STOP, CMD_INSERT = CMD_INSERT, OPT_ALT = OPT_ALT,
            OPT_CTRL = OPT_CTRL, OPT_INTERNAL = OPT_INTERNAL, CMD_GUARD = CMD_GUARD }
-- a module reading an export that no earlier module made is an install-order mistake: fail at load, not 20 minutes into a game
setmetatable(X, { __index = function(_, k) error("line_transition: X." .. tostring(k) .. " read before a module exported it (install order)", 2) end })
for _, name in ipairs({ "con_orders", "grid_recovery", "grid_core", "grid_interrupts", "grid_helpers", "grid_retrofit",
                        "energy", "nano_crew", "silo", "line_recovery", "second_lab", "t2bot_lab", "line_decoy", "radar_posts", "spine_cons" }) do
    VFS.Include(INC .. name .. ".lua").Install(X)
end
local JOB_ORDER = { "silo", "consolidate", "retrofit", "lab2", "linenano", "nanocrew", "grid", "fusionhelp", "gridhelp", "radar", "spine" }   -- registration order

-- what the line / lab / spine code below calls from the modules
local FindAirConDef, LiftAirConCap, ConHold, OrderT2Con = X.FindAirConDef, X.LiftAirConCap, X.ConHold, X.OrderT2Con
local QueueAirCon, AirConOrderDone, SetReserves, KeepAirConReserve = X.QueueAirCon, X.AirConOrderDone, X.SetReserves, X.KeepAirConReserve
local IsT2Con, AssignCons, InsideLine, OpenFirstGrid = X.IsT2Con, X.AssignCons, X.InsideLine, X.OpenFirstGrid
local ReleaseCandidates, UpdateEligibility, UpdateGridHelpers, UpdateRetrofitCons = X.ReleaseCandidates, X.UpdateEligibility, X.UpdateGridHelpers, X.UpdateRetrofitCons
local UpdateT2Deferred, UpdateT2TopUp, UpdateRetrofits, UpdateSpendPressure = X.UpdateT2Deferred, X.UpdateT2TopUp, X.UpdateRetrofits, X.UpdateSpendPressure
local AuditGrids, RememberGridMexes, ThreatNear, UpdateRecovery = X.AuditGrids, X.RememberGridMexes, X.ThreatNear, X.UpdateRecovery
local CapSlack, UpdateWindReclaim, CheckCapPressure, MakeEnergyT2Con = X.CapSlack, X.UpdateWindReclaim, X.CheckCapPressure, X.MakeEnergyT2Con
local UpdateConsolidation, UpdateNanoCrew, UpdateIdleCons, UpdateLineRecovery = X.UpdateConsolidation, X.UpdateNanoCrew, X.UpdateIdleCons, X.UpdateLineRecovery
local SpineTakeCon, SpineReturnCon = X.SpineTakeCon, X.SpineReturnCon
local PickLab2Site, UpdateSecondLab = X.PickLab2Site, X.UpdateSecondLab
local UpdateT2BotLab, T2BotJobStarted, T2BotJobDone = X.UpdateT2BotLab, X.T2BotJobStarted, X.T2BotJobDone
local UpdateLineDecoy, LineDecoyFinished = X.UpdateLineDecoy, X.LineDecoyFinished

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
    if o.WG then CH.Publish(o.WG, "ConBroker", T.CB) end              -- tests / other widgets can read who owns which con
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
    local bd = Spring.GetUnitDefID(builderID)
    local best
    for optID in pairs(BT.Options(bd)) do
        local od = UnitDefs[optID]
        if od and od.isFactory and BT.ConMadeBy(od, { air = true }) then
            if not best or (od.metalCost or math.huge) < (UnitDefs[best].metalCost or math.huge)
               or ((od.metalCost or 0) == (UnitDefs[best].metalCost or 0) and optID < best) then best = optID end
        end
    end
    return best
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

-- The bot's macro orders its starter-lab cons the same way (LT.OrderCon(WG, lab, def, frame)).
LT.OrderCon = CB.OrderCon

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

local StartSpine      -- defined with the spine glue below

-- ── The jobs ─────────────────────────────────────────────────────────────────
-- Every job that wants an air con is registered here; con_broker hands the cons out in priority order.  A job's logic (what to
-- build, where) lives in its module under line_transition/ (X.jobs.<name>); the broker owns WHICH con does it, the reserve, and
-- the cons' return to the pool.  To add a job: write X.jobs.<name> = function(T, cb) CB.AddJob(cb, {...}) end in a module and add
-- its name to JOB_ORDER (see the header of con_broker.lua).

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

    for _, name in ipairs(JOB_ORDER) do X.jobs[name](T, cb) end
end

local function UpdateGrids(T, frame, res)
    AuditGrids(T, frame)
    UpdateRecovery(T, frame)
    UpdateLineRecovery(T, frame)
    UpdateSecondLab(T, frame, res)
    UpdateT2BotLab(T, frame, res)
    UpdateLineDecoy(T, frame, res)
    UpdateEligibility(T, frame)
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

-- Metal value of our finished ground army (armed, mobile, non-air, non-builder).  Gates the T2 labs.
local function SpineGroundArmyValue(T)
    if T.frame - (T.groundAVFrame or -1e9) < 15 then return T.groundAV or 0 end
    local total = 0
    for _, uid in ipairs(UQ.snapshot(T.teamID).ids) do
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
            local left = LEDGER.CapLeft(T.teamID)
            return (left and left <= CapSlack(T, T.CFG.CONSOLIDATE_SLACK)) and true or false
        end,
        Threat      = function()
            local mb = T.WG and T.WG.MetalBot
            if not mb then return nil, 0 end
            return mb.urgency, mb.threats and #mb.threats or 0
        end,
        Safe            = function(x, z, r) return not ThreatNear(T, x, z, r) end,    -- slot_spine REBUILD_NANOS
        MexGridsReady   = function() return SpineMexGridsReady(T) end,
        GroundArmyValue = function() return SpineGroundArmyValue(T) end,
    }
    -- lab_controller reads WG.Spine.  The widget's WG is passed in: a module included with VFS.Include does not
    -- see the widget environment's globals (a bare WG was nil in the real game and killed this function here).
    if T.WG then CH.Publish(T.WG, "Spine", SPINE) end
    SPINE.Start(frame, { deferOpen = true })
    T.spineOn = true
    -- the spine's ground cons are a broker pool (C2): the sink / the line decoy labs borrow them through CB.TakeAny and give them back by owner
    local SM = T.spineMod
    if SM.SpendCapacity then LEDGER.Register(T.WG, "spine", { capacity = function() return (SM.SpendCapacity()) end }) end   -- what its nanos can spend
    if SM.PoolTake then            -- (the older spine.lua of LINE_CLICK_v16 / LINE_BOMB has no pool API)
        CB.AddPool(T.CB, "spine-ground", {
            take  = function(owner, req) return SM.PoolTake(owner, req) end,
            give  = function(uid, owner) SM.PoolGive(uid, owner) end,
            count = function() return SM.PoolCount() end })
    end
    local c1x, c1z = SPINE.CellAnchor(g.geo, g.baseX, g.baseZ, 1)
    Spring.Echo(string.format("[LT] %s spine: cell 1 at (%d, %d) in front of the vehicle lab, front (%d, %d), stack along (%d, %d)",
        Clock(frame), c1x, c1z, g.geo.dx, g.geo.dz, g.geo.px, g.geo.pz))
    -- The vehicle lab can already stand (air lab finished late): hand it over now.
    if T.vpID and Spring.GetUnitDefID(T.vpID) then
        SPINE.AdoptLab(T.vpID, Spring.GetUnitDefID(T.vpID), T.CFG.VP_CONS)
        SPINE.OpenFirst()
    end
end
X.StartSpine = StartSpine   -- grid_core opens the spine once the first grid stands

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
    if j.tag == "t2bot" then T2BotJobStarted(T, j); return end
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
    if j.tag == "t2bot" or j.tag == "t2bnano" then T2BotJobDone(T, j, state); return end
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
                for _, uid in ipairs(UQ.snapshot(T.teamID).ids) do
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
    if T.CFG.T2_CONS_UP_FRONT and d and d.isFactory and T.upgradeBP and unitID ~= T.airLabID and not (T.noConLabs and T.noConLabs[unitID]) then
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
    LineDecoyFinished(T, unitID, defID, x, z)
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
local function IsGroundCon(d) return BT.IsGroundCon(d) end

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
        elseif factID and ((factID == T.vpID) or (T.spineOn and T.spineMod.IsLab and T.spineMod.IsLab(factID))) then owner = "spine" end
        LT.AdoptCon(T, unitID, owner)
    end
    if T.spineOn then T.spineMod.OnUnitFromFactory(unitID, defID, factID) end
end

function LT.OnUnitDestroyed(T, unitID, attackerID)
    if T.sg then T.sgMod.OnUnitDestroyed(T.sg, unitID) end
    -- A dead builder's id is KEPT in its session: the placer's Update checks Spring.GetUnitDefID(state.builderID) and
    -- ends the session itself; a nil id made that call error and removed the whole macro widget (seen at 6:30 when
    -- an enemy air raid killed an air con).
    T.airConsAlive[unitID] = nil
    CB.Remove(T.CB, unitID)
    CB.Forget(T.CB, unitID)
    if unitID == T.airLabID then T.airLabID = nil end
    if T.spineOn then T.spineMod.OnUnitDestroyed(unitID, attackerID) end
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
LT._X = X   -- the modules' shared internals (tests/test_line_transition_modules.lua)
LT._test = { QueueAirCon = QueueAirCon, MakeEnergyT2Con = MakeEnergyT2Con, UpdateRetrofitCons = UpdateRetrofitCons,
             RememberGridMexes = RememberGridMexes, UpdateRecovery = UpdateRecovery, PickLab2Site = PickLab2Site,
             UpdateSecondLab = UpdateSecondLab }

return LT
