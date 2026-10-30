-- ecosim/physics.lua -- every constant of the simulated engine, with where it came from.
-- Calibration (eco_sim.py calibrate) changes THESE, never the bot.  A run can override any of them:
--   python eco_sim.py run --phys ORDER_LAG=30 --phys MEX_MODE=constant
local P = {
    STEP          = 10,      -- frames per physics step (LT runs every 10 frames, so its timing is unchanged)
    ORDER_LAG     = 20,      -- frames from GiveOrderToUnit to the order taking effect (single mode: p90 19-31, CLAUDE.md)
    ORDER_JITTER  = 6,       -- +- uniform jitter on ORDER_LAG (seeded)
    MAP_X         = 12288,   -- Full Metal Plate 1.7 (overridden by the [UMAP] dump)
    MAP_Z         = 12288,
    GROUND_Y      = 450,     -- flat map; [UMAP] groundHeight 449.98
    START         = { { 2816, 1904 }, { 9472, 10384 } },   -- bot_testing.py DEFAULT_STARTPOS (team 0, team 1); 2026-10-30: ~400 elmos further in than 2400 / 9888 so the nano-column block fits
    MAX_UNITS     = 3000,    -- harness modoption maxunits
    START_METAL   = 1000,    -- BAR start resources
    START_ENERGY  = 1000,
    BASE_M_STORAGE = 500,    -- team storage = this + sum of finished units' metalStorage ([SNAP] 1:00 and 10:00: ms - units = 500)
    BASE_E_STORAGE = 500,
    WIND          = 25,      -- FMP: constant wind 25 (game_mechanics.md); [UMAP] windMin/windMax: mean is used
    -- Metal extraction.  "squares": the engine rule -- each extractor owns the 16-elmo metal-map squares within its
    -- extractRange (a square goes to the deepest extractor, ties to the oldest) and yields extractsMetal x metal x
    -- squares.  "constant": a fixed m/s per type (MEX_CONST).
    MEX_MODE      = "squares",
    METAL_PER_SQUARE = 592.5, -- [UMAP] metalAtStart (GetMetalAmount).  cormex: 0.001 x 592.5 x 4 squares (extractRange 24) = 2.37
    MEX_CONST     = { cormex = 2.37, cormoho = 9.48 },   -- knowledge/economy_numbers.md (user, FMP)
    -- Reach: a builder works on a target when 2D distance <= buildDistance + target radius (+ RANGE_PAD).
    -- knowledge/lessons_learned.md "build range is buildDistance + the target's footprint half-extent".
    RANGE_PAD     = 0,
    RADIUS_RULE   = "footprint",   -- "footprint" (half the larger footprint side) or "radius" (UnitDef.radius)
    MOVE_STOP     = 0.9,     -- mobile builders stop at this share of their reach
    -- calibration sweep phys1 (2026-10-14, 8 variants x 4 seeds vs 3 real games): 15/15 + "idle" scored best (0.168)
    START_MOVE_FRAMES = 15,  -- a standing mobile unit loses this many frames before it moves (take-off, turn, accelerate)
    ARRIVE_FRAMES = 15,      -- ... and this many after it arrives before it builds (decelerate, hover)
    FACTORY_EXIT  = 80,      -- elmos a finished unit is put in front of its factory
    SELFD_FRAMES  = 150,     -- self-destruct countdown when the def has none (5 s)
    -- BAR Builder Priority gadget (luarules/gadgets/unit_builder_priority.lua): every non-commander builder is LOW
    -- priority (stock widget unit_builder_priority.lua); low-priority builders are switched fully on or off in a stable
    -- order so the team never stalls past these margins.
    PRIORITY      = true,
    CMD_PRIORITY  = 34571,   -- GameCMD.PRIORITY (BAR modules/customcommands.lua): params {1} high, {0} low; a high builder is served before every low one
    STALL_MARGIN_INC_M = 0.2,
    STALL_MARGIN_INC_E = 0.4,
    STALL_MARGIN_STO   = 0.01,
    -- Stock widget unit_immobile_builder.lua: nano turrets get FIGHT (assist anything in reach) when created / idle.
    NANO_FIGHT    = true,
    -- Engine idle behaviour: static builders with nothing to build from their orders assist the nearest frame in reach
    -- (nano_broker.lua's measurement: parked nanos with only WAIT queued kept building).  ONOFF=off stops them.
    -- "idle": only when the queue is empty or WAIT; "all": also under a GUARD with nothing in reach; false: never.
    -- phys1: idle 0.168 / all 0.165 calibration error, idle matches 16-20 min, all matches 10-14 min (see knowledge/eco_sim.md)
    STATIC_AUTO_ASSIST = "idle",
    -- Energy converters (game_energy_conversion gadget): convert while energy is above this share of storage.
    MM_LEVEL      = 0.75,
    -- stockpiled missiles: metal, energy, seconds per missile (weapondefs metalpershot / energypershot / stockpiletime, BAR archive)
    STOCKPILE     = { corsilo = { 1500, 187500, 180 }, corfmd = { 150, 7500, 90 }, cormabm = { 150, 7500, 90 } },
    -- army spending sink (world.lua "army spending sink"): blocks of 1 coraap + 40 cordecom building corcrwh (Dragons) on repeat,
    -- added while metal stays banked above max(bank_min, bank_frac x storage) for `hold` s, one per `gap` s.  Off unless on = true
    -- (eco_sim.py --sink turns it on).
    SINK = { on = false, unit = "corcrwh", lab = "coraap", builder = "cordecom", builders = 40, slots = 46,
             bank_min = 3000, bank_frac = 0.10, hold = 20, gap = 20, max_blocks = 40, cap_margin = 50, start = 0 },
    SAMPLE_EVERY  = 300,     -- frames between timeline rows (10 game-s)
    HASH          = 256,     -- spatial hash bucket size (elmos)
}
return P
