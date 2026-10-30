-- bar_framework/click_army.lua
-- LINE_CLICK's army: a human-style "BP hunter".  The goal of these units is to kill the enemy's
-- build power (nanos, constructors, labs) and eco, while the home guard keeps the same from
-- happening to us.  An attack is judged on what it destroyed, NOT on the trade ratio: a 600-800 m
-- group that kills a 220 m nano still pays, because the enemy loses the rebuild cost plus
-- everything the nano would have built until it is back.
--
-- Derived from two human games on Full Metal Plate (human_control_logger.lua / human_control_report.py)
-- and the user's notes: several attacks AT ONCE on different parts of the enemy base, so that an
-- enemy who answers one has to pull units away from defending another.
--
-- GROUPS  up to MAX_GROUPS attack groups run at the same time.  Each has its own target.
--   stage      ground units that belong to no group gather on a tight ring at STAGE (MOVE).
--   launch     a new group leaves when the army value at the stage (stage av) is at least
--              LAUNCH_MIN_AV AND at least LAUNCH_RATIO x the value still walking to the stage
--              (reinforce av): with a lot on its way, wait and send one bigger group; with 2.5x
--              as much standing there as arriving, go.  (LAUNCH_FORCE_AV launches regardless, so a
--              steady trickle of reinforcements cannot hold the army back for ever.)
--   attack     the group goes for TARGETS, best damage value first (build power and constructors,
--              then eco; labs far down, they are tough and not what starves the enemy).  The enemy
--              COMMANDER outranks all of them when it is out in the open (few guards around it): every
--              group goes for it, since killing it wins.  A target close to another group's target is heavily
--              discounted, so the groups hit different points of the base.  Short MOVE legs steer
--              round enemy armed value; within ATTACK_SWITCH the order becomes ATTACK on the
--              building.  Not recalled for a bad value ratio -- only when the group is spent
--              (FALL_FRAC of its peak) or nothing is left in reach.
--   reinforce  once all MAX_GROUPS exist, a new unit goes straight to the weakest attacking group.
--   fall       survivors of a spent group MOVE back to the stage and become stage units again.
-- Hurt squads (<= SQUAD_MAX units, in no group, enemies near and outvaluing them) retreat.
-- Fighters escort the biggest group; bombers (>= BOMBER_MIN) strike the best target together.
--
-- The caller owns the unit tables; this module only reads them and claims units through
-- army_broker with role "BLOB" at the lowest priority, so retreat/respond/home guard still win.
--
-- Log rows, all "[CK]": launches, target picks, KILLs of build power / eco, group ends, the
-- stage/reinforce values while waiting, bomber runs, and a once-a-minute total.

local M = {}
local unseenFn, holdHomeFn          -- Init hooks (UNSEEN_FIRST, holdHome)
local onlySet                       -- SetOnly: when set, only these units are commanded (the small raid squad that raids while the army holds)
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")   -- Apply(): merge overrides + one [CFG] log row

local CFG = {
    STAGE_FRAC      = 0.45,   -- stage this far along home->foe (human: ~(6000-6400, 2400-3100) of ~8000)
    STAGE_SPACING   = 55,     -- elmos between units on the staging ring (tight blob)
    STAGE_JOIN_R    = 1200,   -- a unit is "at the stage" this close to it; farther = still reinforcing
    BLIND_DIVE_FRAME = 12 * 60 * 30,  -- attack on the mirror guess only after this long without a sighting
    MAX_GROUPS      = 3,      -- user: "you want 3 different attacks in general"
    LAUNCH_MIN_AV   = 1800,   -- smallest group worth sending (~15 gators; human's first push had 25)
    LAUNCH_RATIO    = 2.5,    -- stage av must be this x the av still walking to the stage (user: 2.5)
    -- Production-based mass (AIR_TIMING, user 2026-10-25: "an attack should at least be as large as what can be made in 20 seconds ...
    -- most alive units were reinforcing"): with M.SetProduction(army metal/s), the smallest fast group is LAUNCH_PROD_S x that (the
    -- slow group SLOW_PROD_FRAC of it), and BATCH_REINFORCE makes new units gather at the stage and join the weakest group together,
    -- in batches worth the same, instead of walking out one by one.  nil / false = off.
    LAUNCH_PROD_S   = nil,
    SLOW_PROD_FRAC  = 0.5,
    BATCH_REINFORCE = false,
    LAUNCH_FORCE_AV = 5400,   -- ...or this much, whatever is walking in
    FALL_FRAC       = 0.30,   -- a group is spent when this share of its peak size is left
    FALL_MAX_FRAMES = 1200,   -- ...and survivors give up waiting for the return after this long
    FALL_ARRIVE     = 700,    -- back at stage when the centroid is this close
    LEG             = 1000,   -- steering leg length (human legs: median 900-1900)
    -- LEG_LEAD (nil = off; user 2026-10-29, the BM_akumar6 game: the 11:00 push crawled -- units turn and accelerate, so a move that ends just
    -- ahead of a unit makes it slow down at the point and speed up again for the next one): the leg point is at least LEG_LEAD past the
    -- FRONT-most unit of the core along the way (not LEG from the centroid), so no unit nears its goal before the next order (every 3-5 s)
    LEG_LEAD        = nil,
    ATTACK_SWITCH   = 800,    -- closer than this to the target: ATTACK it
    NO_TARGET_R     = 1500,   -- at the enemy start with nothing to hit this close: give up
    LOOK_FRAMES     = 180,    -- ...after looking this long (intel scans every 90 frames)
    TARGET_REPICK   = 450,    -- frames before a target is re-evaluated even if alive
    MOBILE_FACTOR   = 0.5,    -- a mobile target (a con) is worth half: its remembered spot goes stale
    KILL_R          = 1800,   -- an enemy death counts toward an attack only this close to a group
    BP_WEIGHT       = 4,      -- damage value of 1 build power (a 200 BP nano -> +800)
    ECO_BONUS       = 150,    -- damage value of an income building
    LAB_FACTOR      = 0.15,   -- a factory is worth this share of cost + build power: tough, and not what
                              -- starves the enemy (nanos, cons and eco are).  A T2 vehicle plant at
                              -- ~5,200 dropped to ~780, under one nano (~1,075), so labs go last.
    -- The enemy commander: killing it wins, so when it is out in the open every group goes for it.
    CMDR_OPEN_FRAC  = 0.3,    -- "open" = armed enemy value around it (not counting itself) <= this x the group
    CMDR_MIN_AV     = 1200,   -- ...and the group is at least this big (~10 gators), no suicide runs
    CMDR_FRESH      = 900,    -- ...and it was seen this recently (it walks)
    DIST_SCALE      = 4000,   -- a target this far away is worth half
    DIFF_R          = 1200,   -- targets this close to another group's target are "the same point"...
    DIFF_PENALTY    = 0.2,    -- ...and score this share (groups hit different points of the base)
    LANE_SPACING    = 900,    -- with no target known, groups approach the enemy start this far apart
    TARGET_DEF_MAX  = 1.5,    -- armed value at a target above this x the group: deprioritised
    DEF_PENALTY     = 0.25,   -- ...to this share of its score
    FLANK_PENALTY   = 0.15,   -- cost of a turned leg, in shares of the group's value
    STRAGGLER_R     = 2500,   -- a unit this far from its group's core walks to the core instead
    SQUAD_MAX       = 6,      -- human pulled back squads of 3-5 at 40-60% hp
    SQUAD_HP        = 0.60,
    SQUAD_RELEASE   = 0.85,
    SQUAD_R         = 600,    -- units this close are one squad
    ENEMY_NEAR_R    = 900,
    BOMBER_MIN      = 8,
    BOMB_COOLDOWN   = 2700,   -- frames between bomber runs
    BOMB_AIR_MAX    = 0.5,    -- skip targets with more than this x the group's value in AA
    WAIT_LOG_EVERY  = 450,
    MARGIN          = 200,
    -- The slow group: Mammoths (speed 23) next to gators (85) made every group crawl, so the slow
    -- units get a group of their own and the fast groups keep probing.  Tigers (69) stay fast.
    SLOW_SPEED      = 0,      -- a unit slower than this belongs to the slow group; 0 = none (slow_front.lua runs Lashers/Pounders)
    SLOW_MIN_AV     = 2000,   -- the slow group leaves once this much slow value is at the stage
    SLOW_ESCORT_SHARE = 0.35, -- fast units in the slow group: this share of the slow value, no more
    SLOW_ESCORT_WAIT  = 0.5,  -- launch once this share of the wanted escorts is there...
    SLOW_FORCE_MULT   = 2.0,  -- ...or the slow value is this x SLOW_MIN_AV
    SLOW_DIST_SCALE   = 2500, -- the slow group prefers nearer targets (it cannot cross the map twice)
    SLOW_DEF_MAX      = 3.0,  -- ...and takes on defended targets (TARGET_DEF_MAX x this)
    -- The slow group TRADES: it fights the enemy army cost-effectively instead of hunting build power.
    --   T1: Lashers (cormist, long-range support) behind Pounders (corlevlr, the screen);
    --   T2: Sheldons (cormort, long-range support) behind Mammoths (corsumo, the screen).
    -- Fast units that escort it count as screen (mass).  Everything is a plain FIGHT order; the
    -- support kites by staying behind the screen and letting its range do the work.
    SLOW_SUPPORT      = { cormist = true, cormort = true },
    SLOW_SUPPORT_RANGE = 650,   -- a slow unit not listed above with at least this range is support too
    SLOW_SCREEN_AHEAD = 250,    -- the screen stands this far in front of the support's spot
    SLOW_SUPPORT_BACK = 250,    -- ...and the support holds this far behind the screen's centre
    SLOW_THREAT_R     = 450,    -- an enemy armed unit this close to a support is on top of it: the screen steps out
                                -- (no further: stray units further off are not chased)
    SLOW_LEG          = 600,    -- advance this far at a time (the screen must keep up)
    SLOW_ENGAGE_R     = 1600,   -- enemy armed value within this of the screen counts toward "a fight"
    -- The slow group ATTACKS THE OTHER SIDE: it always marches on the enemy's eco / main base and only
    -- stops for a real fight (enemy value near >= SLOW_FIGHT_FRAC x its own).  A few stray units are not a
    -- fight: it does not chase them (its FIGHT orders still shoot whatever is in range on the way).
    SLOW_FIGHT_FRAC   = 0.5,
    SLOW_BASE_R       = 1500,   -- structures this close together are one base; the densest cluster is the target
    SLOW_OBJ_EVERY    = 300,    -- frames between re-picking the base (keeps it from flip-flopping)
    SLOW_ARRIVE       = 250,    -- marches to within this of the base's centre
    SLOW_PULL_RATIO   = 1.5,    -- enemy value near / ours above this: pull back (trade well, don't die)
    SLOW_RESUME_RATIO = 1.0,    -- ...and go back in once it is under this
    -- The slow group moves as LINES, not one ball.  The support stands SLOW_SPOT_DEPTH deep in each spot and
    -- the line widens one spot at a time only once a spot is full (4 Lashers deep, then a second spot, ...);
    -- the screen is a thinner line in front spanning the same width.
    SLOW_SPOT_DEPTH   = 4,      -- support units per spot, deep
    SLOW_SCREEN_DEPTH = 2,      -- screen units per spot (the screen is a thin front line)
    SLOW_SPOT_SPACING = 110,    -- elmos between spots across the line
    SLOW_DEPTH_SPACING = 55,    -- elmos between units standing deep in a spot
    -- The support's default is a FIGHT order toward the base: it fires as much as it can.  It gives ground
    -- only when it is at risk of dying:
    SLOW_DANGER_FRAC  = 0.6,    -- ...outvalued AND the nearest enemy is inside this share of its range
    SLOW_RISK_HP      = 0.4,    -- ...or a single unit is under this health with the enemy within 1.3 x range
    -- Range kiting.  The support is only worth anything while it fires, so it keeps the enemy IN range:
    SLOW_IN_RANGE     = 0.95,   -- the enemy is "in range" inside this share of the support's range
    SLOW_ADVANCE_TO   = 0.8,    -- out of range: close in to this share of range, then stand and shoot
    SLOW_RANGE_KEEP   = 0.9,    -- outvalued: back off only while the enemy is nearer than this share
    SLOW_PULL_STEP    = 300,    -- ...and by at most this much per pass (it fires while it moves)
    SLOW_STAND_OFF    = 2.0,    -- hold at the edge of STATIC defences worth more than this x the group (it was 1.0
                                -- and counted mobile units too, which stopped it short of the base)
    -- Scout calls: each attacking group asks for scouts to look ahead of where it wants to go.
    SCOUT_AHEAD     = 2200,   -- elmos ahead of the group, along its path to the target
    SCOUT_SIDE      = 900,    -- the second scout looks this far to the side
    CALL_SCOUTS_PER_GROUP = 2,
    CALL_SCOUT_MAX  = 6,
    -- FORWARD_CORE (2026-10-08): a group's core is its FORWARD cluster --
    -- the unit nearest its target (or furthest along home->foe) that has company, and everyone within
    -- CORE_R of it -- not the units around the centroid of everyone.  With 3 groups out every new unit joins
    -- the weakest group from the factory, so the centroid slid back toward home (a group "attacking" a nano
    -- at the enemy base had its centre 11,000 elmos away) and the units at the front were sent back to it:
    -- vs BARb at 20:00, 112k of army stood at mid-map with the enemy commander in sight and 633 value guarding it.
    -- The core's value (not the whole group's, half of which is still walking) decides fights and targets.
    FORWARD_CORE    = true,
    CORE_R          = 1500,
    CORE_CLUSTER_R  = 500,    -- the forward unit needs CORE_COMPANY others this close
    CORE_COMPANY    = 2,
    -- Once a group is on the commander it keeps going while the guard is under this share of the core
    -- (CMDR_OPEN_FRAC only decides when it starts).  The guard estimate swings, and every drop-out sent three
    -- groups back across the map (flip-flopped 14:59-15:28 in that game).
    CMDR_KEEP_FRAC  = 0.8,    -- nil = CMDR_OPEN_FRAC
    -- FORWARD_CORE: a core holding less than this share of the group's value waits (FIGHT where it stands) for
    -- the rest to catch up, unless it is already at its target.  nil = never waits.
    CORE_WAIT_FRAC  = 0.35,
    CORE_WAIT_R     = 4000,   -- ...counting only the units this close to the core
    -- FLANK (2026-10-08): go round the enemy's main army instead of through it.  In the mirror
    -- both stages sit ~45% of the way across, ~1300 elmos apart, and every group walked into the other side's staged
    -- army: 70-80% of a group lost in ~2 min for 450-2100 value killed by 16:30.  User: "gators are fast: group
    -- quickly, flank the enemy army, reach eco".  When the path to the target passes within FLANK_CLEAR of the
    -- biggest recently seen enemy army cluster (worth >= FLANK_MIN_FRAC of the core), the group heads for a waypoint
    -- FLANK_OFFSET to one side of it (the side is kept per group) until it is past the cluster.
    FLANK           = true,
    -- SIDE_R (AIR_TIMING's push, user 2026-10-25: "a main push ... the slow cost effective units pull attention to let the raids get
    -- in"): a fast group's targets within SIDE_R of the slow group's target score x SIDE_PENALTY, so the raids hit the sides while
    -- the main push draws the enemy army.  nil = off.
    SIDE_R          = nil,
    SIDE_PENALTY    = 0.25,
    FLANK_CLEAR     = 1800,
    FLANK_OFFSET    = 2800,
    FLANK_MIN_FRAC  = 0.5,
    FLANK_CLUSTER_R = 1200,
    FLANK_MAX_AGE   = 600,    -- frames: a cluster seen longer ago than this is not steered round
    -- DIRECT (PAINTKID_BOT, user 2026-10-12): no stage, no groups, no squads, no steering.  The ground army is run by a STACK
    -- of plug-in behaviours (bar_framework/behaviors/, run by behavior_host.lua), first claim wins:
    --   pick_target -> commander_strike -> flank -> spread -> run_by -> attack_target
    -- The bot chooses the stack and its tunables (unit_controller passes cfg = { DIRECT = true, ARMY_BEHAVIORS = ..., ARMY_BEHAVIOR_CFG = ... });
    -- remove a name to switch that behaviour off.  What uses what: `python behavior_usage.py`.
    LAB_BP_R        = 650,    -- build power (nanos, cons) within this of an enemy factory is the TOP target, above everything else
    -- SET_TARGET (STANCE_BOT, user 2026-10-12): an attack group does NOT stop to ATTACK its target.  It keeps MOVEing through
    -- and past the enemy base while every unit is given SET_TARGET (BAR's target-on-the-move command) on the most damaging
    -- enemy building inside its own weapon range, so it does eco damage while running.  A defender that stops to catch it
    -- is outrun; one that keeps following is pulled off the base.  Needs BAR's unit_target_on_the_move gadget.
    SET_TARGET        = false,
    SET_TARGET_BEYOND = 900,   -- elmos the MOVE runs past the target
    SET_TARGET_EVERY  = 30,    -- frames between target refreshes per group
    SET_TARGET_SCAN   = 1600,  -- candidate buildings this close to the group
    SET_TARGET_RANGE  = 1.0,   -- x weapon range: a building farther than this is not set as the target
    SET_TARGET_NO_ECO = false, -- true: only buildings that carry build power / income / value (skip walls etc.)
    DIRECT          = false,
    ARMY_BEHAVIORS  = { "pick_target", "commander_strike", "flank", "spread", "run_by", "attack_target" },
    ARMY_BEHAVIOR_CFG = {},   -- { flank = { every = 4 }, ... } tunables per behaviour (see each file's cfg)
    -- Bombers as behaviours too: { "bomber_run" } replaces the built-in UpdateBombers (empty = the built-in one).
    BOMBER_BEHAVIORS  = {},
    BOMBER_BEHAVIOR_CFG = {},
    -- RAID_BOT (game review 2026-10-13: the army idled at the stage until 8:00, then 7 groups lost 33k for 0 kills).
    -- Every key below defaults to the old behaviour.
    -- Early launch: the smallest group ramps linearly from av0 at frame f0 to av1 at f1 (LAUNCH_MIN_AV before/after
    -- is replaced by av0/av1); nil = flat LAUNCH_MIN_AV.  LAUNCH_RATIO_EARLY replaces LAUNCH_RATIO before f1.
    EARLY_LAUNCH       = nil,     -- e.g. { f0 = 5400, av0 = 350, f1 = 18000, av1 = 1800 }
    LAUNCH_RATIO_EARLY = nil,
    BLIND_LAUNCH       = false,   -- launch while the foe is still the mirror guess (the no-target branch scouts it)
    MIN_GROUP_UNITS    = 1,       -- a group needs this many units (3: no lone-Demon groups)
    -- Fresh enemy units leaving a factory do not steer the legs: armed mobile enemies within LAB_EXIT_R of a known
    -- enemy factory count LAB_EXIT_W of their value in LegPoint (they still count for ENGAGE).
    LAB_EXIT_R         = 0,
    LAB_EXIT_W         = 1,
    -- ENGAGE: per group, advance / commit / escape.  Dancing while surrounded is the worst option: either commit to the
    -- enemy build power next to the group, or run all the way back to our line front.
    ENGAGE             = false,
    ENGAGE_R           = 900,     -- local threat = armed enemy value this close to the core (mobile seen <= 300 frames)
    SECTOR_MIN_FRAC    = 0.10,    -- a sector (of 6) is "occupied" when its threat is >= this x the core value
    SURROUND_SECTORS   = 3,       -- occupied sectors that make the group surrounded
    SURROUND_MIN_FRAC  = 0.6,     -- ...and surrounded only matters when the total threat is >= this x the core
    COMMIT_RATIO       = 1.2,     -- threat >= this x the core is danger
    ESCAPE_RATIO       = 2.0,     -- danger with no build power near: escape when threat >= this x (or surrounded/losing)
    ESCAPE_LOSS_FRAC   = 0.25,    -- lost this share of the group's value within ENGAGE_LOSS_WINDOW = danger
    ENGAGE_LOSS_WINDOW = 300,
    COMMIT_R           = 700,     -- enemy build power (lab, nano, con, commander) this close = something to commit to
    COMMIT_KEEP_R      = 1000,    -- a commit continues while build power is this close
    ESCAPE_FRAC        = 0.25,    -- escape to this share of home->foe (our line front), not the stage
    ESCAPE_ARRIVE      = 900,
    ESCAPE_MAX_FRAMES  = 2700,
    -- HOLE_FIND: from HOLE_MIN_D..HOLE_MAX_D off the target, go to the least defended of HOLE_N points on a ring of HOLE_R
    -- around it and strike in from there, instead of walking the straight line (replaces FLANK while it applies).
    -- Ring points nobody has seen are sent to the scouts.
    HOLE_FIND          = false,
    HOLE_R             = 1400,
    HOLE_N             = 12,
    HOLE_MIN_D         = 1200,
    HOLE_MAX_D         = 4500,
    HOLE_ARRIVE        = 450,
    HOLE_REPICK_FRAC   = 0.5,     -- re-pick when the chosen point's threat rises above this x the core
    HOLE_SCOUTS        = 2,       -- unseen ring points added to the group's scout requests
    -- Game plan (M.SetMode): "hold" launches nothing, recalls the groups and moves the stage back to HOLD_STAGE_FRAC.
    HOLD_STAGE_FRAC    = 0.25,
    TRADE_WINDOW       = 5400,    -- frames M.TradeSummary looks back
    -- FIGHTER_POST (user 2026-10-13: "stage the fighters closer to the front, still far enough back that enemy ground AA
    -- cannot hit them"): the dedicated fighters click_army holds wait FIGHT-ing at M.FighterPost() -- FIGHTER_POST_BACK
    -- elmos behind the biggest attacking group (else the stage) toward home, pulled further back in FIGHTER_POST_STEP steps
    -- while the known enemy AA there is above FIGHTER_POST_AA -- instead of flying over the group (into its AA).
    FIGHTER_POST       = false,
    FIGHTER_POST_BACK  = 900,
    FIGHTER_POST_STEP  = 300,
    FIGHTER_POST_STEPS = 15,
    FIGHTER_POST_AA    = 150,     -- air threat value (enemy_intel.ThreatAt "air") allowed at the post
    -- SCOUT_ROUTE (user 2026-10-13: raid groups call scouts "to go down the path they want to attack"): a group's scout
    -- requests are a point SCOUT_AHEAD along the way it is actually going (toward its hole / flank waypoint, not straight
    -- at the target), the target itself, and the unseen ring points round it (HOLE_FIND).
    SCOUT_ROUTE        = false,
    -- SURVIVE (user 2026-10-27, "raids should still move in and attack but steer away more aggressively and not dive unless there is a big hole"): switched on per stance
    -- (plan.survive, M.SetSurvive).  While on, SURVIVE_SET overrides the values it names (earlier escape, wider steering, harsher defended-target penalty, a group is spent at half
    -- its peak), and inside ATTACK_SWITCH of the target the group dives only if the armed value round the target is <= SURVIVE_HOLE_FRAC x the core (and no big enemy army
    -- cluster stands by it); otherwise it skirmishes: it stands off SURVIVE_STANDOFF from the target (SET_TARGET fires in range) and steps back SURVIVE_STEP away from the
    -- nearest armed enemy when the threat round the core passes SURVIVE_THREAT_FRAC x the core (resuming under half of that), holding SURVIVE_HOLD frames per step.
    -- Units under SURVIVE_UNIT_HP with an armed enemy near leave the group for the hurt-squad retreat.
    SURVIVE            = false,
    SURVIVE_SET        = { ESCAPE_RATIO = 1.0, COMMIT_RATIO = 0.8, ESCAPE_LOSS_FRAC = 0.15, SURROUND_SECTORS = 2, ENGAGE_R = 1100, FALL_FRAC = 0,
                           DEF_PENALTY = 0.05, TARGET_DEF_MAX = 0.6, FLANK_PENALTY = 0.05, HOLE_N = 16, HOLE_R = 1800, HOLE_REPICK_FRAC = 0.25,
                           FLANK_MIN_FRAC = 0.25, FLANK_CLEAR = 2400, CMDR_OPEN_FRAC = 0.15, ENEMY_NEAR_R = 1500, EVADE_FOE_PULL = 0.3, LOSS_MIN_THREAT = 0.25 },
    LOSS_MIN_THREAT    = 0,        -- EngageSurvive: a recent loss (ESCAPE_LOSS_FRAC) is danger only when the armed enemy value near the group is at least this x the core's; 0 = any loss
    EVADE_FOE_PULL     = 0,        -- EngageSurvive: how much cheaper a heading toward the enemy base is (x the core's value per evade distance); 0 = pure threat avoidance
    SURVIVE_R          = 1200,
    SURVIVE_STEP       = 500,
    SURVIVE_HOLE_FRAC  = 0.10,     -- dive only when the armed value round the target is under this x the core (0.35 dived into 2-3 defenders)
    SURVIVE_EVADE_D    = 900,      -- an evade picks the least-threat heading of 12 at this distance
    SURVIVE_ORBIT_STEP = 0.6,      -- radians the standoff point moves round the target per tick (a raider never stands still)
    SURVIVE_AVOID_S    = 60,       -- seconds a target the group evaded from is shunned
    SURVIVE_THREAT_FRAC = 0.5,
    SURVIVE_STANDOFF   = 250,
    SURVIVE_HOLD       = 120,
    SURVIVE_UNIT_HP    = 0.45,
    UNSEEN_FIRST       = false,   -- blind groups (the enemy not located: the mirror guess) head for the nearest never-seen enemy-half sector (Init o.unseen) instead of the mirror lane point
}
M.CFG = CFG
-- The slow group's speed line at run time (unit_runtime: the plan army "defend" turns the slow group on while it pushes, so
-- Mammoths / Pounders screen and Sheldons support instead of trailing the fast raid groups).  0 = no slow group.
local prodRate = 0
function M.SetProduction(rate) prodRate = math.max(0, rate or 0) end
local function ProdMin(frac) return CFG.LAUNCH_PROD_S and prodRate * CFG.LAUNCH_PROD_S * (frac or 1) or 0 end
local slowCache
function M.SetSlowSpeed(v)
    v = v or 0
    if CFG.SLOW_SPEED ~= v then CFG.SLOW_SPEED = v; slowCache = {} end
end

local CMD_MOVE, CMD_FIGHT, CMD_ATTACK = 10, 16, 20
-- BAR gadget unit_target_on_the_move: 34923 set target (unit id, or x y z), 34924 cancel.  Resolved from the engine's
-- custom command table when it has them (the ids moved between BAR releases), else the numbers above.
local CMD_SET_TARGET, CMD_CANCEL_TARGET = 34923, 34924
do
    local gc = Game and Game.CustomCommands and Game.CustomCommands.GameCMD
    if gc then
        CMD_SET_TARGET    = gc.UNIT_SET_TARGET or CMD_SET_TARGET
        CMD_CANCEL_TARGET = gc.UNIT_CANCEL_TARGET or CMD_CANCEL_TARGET
    end
end

local MM, UQ, EI, ARMY
local combat, guards, muster, scouts, responding, bombers
local isHunting = function() return false end
local NotHeld = function() return false end
local isHeld = NotHeld      -- o.isHeld(uid, frame): a behaviour (range_kite, kite) is moving the unit on purpose

local groups      = {}      -- array of attack groups
local byId        = {}      -- [id] = group
local unitGroup   = {}      -- [uid] = group id
local nextId      = 1
local squad       = {}      -- [uid] = frame it began a squad retreat
local stageX, stageZ
local foeSeenX, foeSeenZ, foeSeenSrc = 0, 0, nil
local lastBombF   = -99999
local lastWaitLog = -99999
local stageAV, reinforceAV = 0, 0
local totals      = { launches = 0, kills = 0, killBP = 0, killValue = 0, lostUnits = 0, lostValue = 0 }
local mode        = "raid"  -- M.SetMode: "raid" | "hold"
local stageFrac   = nil     -- the STAGE_FRAC the stage point was computed with
local tradeLog    = {}      -- { f, killed, lost }: every enemy death near a group / every group loss (TradeSummary)
local groupEnds   = {}      -- { f, killed, lost, reason } per ended group, oldest first
local lastPruneF  = -99999

local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end

local function Value(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end

slowCache = {}          -- (declared above M.SetSlowSpeed)
local function IsSlow(defID)
    local v = slowCache[defID]
    if v == nil then
        v = (UQ.max_speed(defID) or 0) < CFG.SLOW_SPEED
        slowCache[defID] = v
    end
    return v
end

local function Log(frame, fmtStr, ...)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[CK] %d:%02d " .. fmtStr, math.floor(sec / 60), sec % 60, ...))
end

M.NIL_OPTIONS = { "EARLY_LAUNCH", "LAUNCH_RATIO_EARLY", "LAUNCH_PROD_S", "SIDE_R", "LEG_LEAD" }   -- options whose default is nil on purpose (bot_config.lua does not warn about them)
function M.Init(o)
    MM, UQ, EI, ARMY = o.MM, o.UQ, o.EI, o.ARMY
    BC.Apply("click_army", CFG, o.cfg, o.label, M.NIL_OPTIONS)    -- caller overrides (LINE_CLICK: no automatic slow group)
    combat, guards, muster = o.combat, o.guards, o.muster
    scouts, responding, bombers = o.scouts, o.responding, o.bombers
    if o.isHunting then isHunting = o.isHunting end
    unseenFn, holdHomeFn = o.unseen, o.holdHome      -- scout_lanes' NextUnseen(x, z, frame); unit_runtime's 'a ground raid is on the base' test
    isHeld = o.isHeld or NotHeld
    groups, byId, unitGroup, squad, slowCache = {}, {}, {}, {}, {}
    nextId, lastBombF, lastWaitLog = 1, -99999, -99999
    stageX, stageZ, foeSeenSrc = nil, nil, nil
    stageAV, reinforceAV = 0, 0
    totals = { launches = 0, kills = 0, killBP = 0, killValue = 0, lostUnits = 0, lostValue = 0 }
    mode, stageFrac, tradeLog, groupEnds, lastPruneF = "raid", nil, {}, {}, -99999
end

-- Game plan: "raid" (default) or "hold".  Hold launches nothing, sends every attacking group back (they fall to the
-- stage, which moves to HOLD_STAGE_FRAC of home->foe) and leaves the stage units for the base defence to pick up.
function M.SetMode(m, frame)
    if m ~= "raid" and m ~= "hold" then return false end
    if m == mode then return false end
    mode = m
    local f = frame or 0
    local sec = math.floor(f / 30)
    Spring.Echo(string.format("[CK] %d:%02d mode -> %s", math.floor(sec / 60), sec % 60, m))
    return true
end
function M.Mode() return mode end

-- A table { [uid] = true }: click_army commands only these units (RAID_SQUAD: five gators keep raiding while the army defends).  nil = every free unit.
function M.SetOnly(t) onlySet = t end

-- SURVIVE on / off (plan.survive of the current stance): swaps the values of CFG.SURVIVE_SET in and out, once per change.
local surviveBase
function M.SetSurvive(on)
    on = on and true or false
    if on == (surviveBase ~= nil) then return false end
    if on then
        surviveBase = {}
        for k, v in pairs(CFG.SURVIVE_SET) do surviveBase[k] = CFG[k]; CFG[k] = v end
    else
        for k, v in pairs(surviveBase) do CFG[k] = v end
        surviveBase = nil
    end
    CFG.SURVIVE = on
    Spring.Echo("[CK] survive mode " .. (on and "ON" or "off"))
    return true
end

-- What the attack groups traded over the last `window` frames (default TRADE_WINDOW): value killed near a group (any
-- enemy unit, army included), value lost from groups, and how many of the most recent ended groups in a row were
-- spent while killing under a quarter of what they lost (badEnds).
function M.TradeSummary(frame, window)
    window = window or CFG.TRADE_WINDOW
    local killed, lost = 0, 0
    for _, e in ipairs(tradeLog) do
        if frame - e.f <= window then killed, lost = killed + e.killed, lost + e.lost end
    end
    local bad = 0
    for i = #groupEnds, 1, -1 do
        local e = groupEnds[i]
        if frame - e.f > window then break end
        if e.reason == "group spent" and e.killed < 0.25 * e.lost then bad = bad + 1 else break end
    end
    return { killed = killed, lost = lost, ratio = lost > 0 and killed / lost or (killed > 0 and 99 or 1),
             badEnds = bad, ends = #groupEnds }
end

-- ── Queries other widgets use ─────────────────────────────────────────────────

-- On an attack: no per-unit retreat (the attack is a commitment, like a raider).
function M.IsRaiding(uid)
    local g = byId[unitGroup[uid]]
    return g ~= nil and g.state == "attack"
end
function M.IsSquadRetreating(uid) return squad[uid] ~= nil end
function M.StagePoint() return stageX, stageZ end
function M.Totals() return totals end
function M.Groups() return groups end
function M.StageValues() return stageAV, reinforceAV end
function M.GroupOf(uid) return byId[unitGroup[uid]] end
-- Is this unit committed to an attack group?  Units that are not (new units, reinforcements waiting at the
-- stage, fighters) may be pulled off to defend the base; units that are never are.
function M.InGroup(uid) return byId[unitGroup[uid]] ~= nil end

-- Points where the attacking groups want a scout, as {x, z, gid}: ahead of each group along its
-- path (and a second one to the side), refreshed every tick the group is attacking.  The unit
-- controller sends scout aircraft there so the group moves on fresh information.
function M.ScoutRequests()
    local out = {}
    for _, g in ipairs(groups) do
        if g.state == "attack" and g.scoutPts then
            for _, p in ipairs(g.scoutPts) do
                if #out < CFG.CALL_SCOUT_MAX then out[#out + 1] = { p[1], p[2], g.id } end
            end
        end
    end
    return out
end

-- FIGHTER_POST: where fighters wait -- behind the front (the biggest attacking group while raiding, else the stage),
-- toward home, out of the known enemy AA.  Returns x, z (nil before the stage exists).
local postF, postX, postZ = -1, nil, nil
function M.FighterPost(frame)
    if postF == frame then return postX, postZ end
    postF = frame
    if not stageX then postX, postZ = nil, nil; return nil end
    local fx, fz = stageX, stageZ
    if mode ~= "hold" then
        local best
        for _, g in ipairs(groups) do
            if g.state == "attack" and g.cx and (not best or g.value > best.value) then best = g end
        end
        if best then fx, fz = best.cx, best.cz end
    end
    local hx, hz = MM.Home()
    local dx, dz = hx - fx, hz - fz
    local d = math.sqrt(dx * dx + dz * dz)
    if d < 1 then postX, postZ = MM.Clamp(fx, fz, CFG.MARGIN); return postX, postZ end
    dx, dz = dx / d, dz / d
    local px, pz
    for i = 0, CFG.FIGHTER_POST_STEPS do
        local back = math.min(d, CFG.FIGHTER_POST_BACK + i * CFG.FIGHTER_POST_STEP)
        px, pz = MM.Clamp(fx + dx * back, fz + dz * back, CFG.MARGIN)
        if EI.ThreatAt(frame, px, pz, "air") <= CFG.FIGHTER_POST_AA or back >= d then break end
    end
    postX, postZ = px, pz
    return px, pz
end

-- How many scouts the labs should keep for the groups out now.
function M.ScoutDemand()
    local n = 0
    for _, g in ipairs(groups) do if g.state == "attack" then n = n + CFG.CALL_SCOUTS_PER_GROUP end end
    return math.min(n, CFG.CALL_SCOUT_MAX)
end

-- "attack" while any group attacks, "fall" while only retreating groups remain, else "stage".
function M.State()
    local fall = false
    for _, g in ipairs(groups) do
        if g.state == "attack" then return "attack" end
        fall = true
    end
    return fall and "fall" or "stage"
end

-- Centre of the biggest attacking group (the army's "front").
function M.Centroid()
    local best
    for _, g in ipairs(groups) do
        if g.state == "attack" and g.cx and (not best or g.value > best.value) then best = g end
    end
    if best then return best.cx, best.cz end
    return nil, nil
end

-- ── Enemy knowledge ───────────────────────────────────────────────────────────

-- Armed enemy value near a point: static defences within their reach, mobile units only if seen
-- recently.
local function ArmedValueNear(frame, x, z, r, mobileMaxAge, skipUid)
    local v = 0
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and not c.scout and rec.uid ~= skipUid then
            local reach = r + (c.mobile and 0 or (c.range or 0))
            if (not c.mobile or frame - rec.frame <= (mobileMaxAge or 300))
               and Dist(rec.x, rec.z, x, z) <= reach then
                v = v + c.value
            end
        end
    end
    return v
end

-- Known enemy factory positions, once per frame (LAB_EXIT).
local labsF, labsList = -1, {}
local function EnemyLabs(frame)
    if labsF == frame then return labsList end
    labsF, labsList = frame, {}
    for _, rec in pairs(EI.Records()) do
        if rec.c.factory then labsList[#labsList + 1] = rec end
    end
    return labsList
end

-- ArmedValueNear for steering: fresh units at an enemy factory's exit count LAB_EXIT_W of their value (there will
-- always be units coming off the labs; turning away from each one made the groups dance).  Same as ArmedValueNear
-- while LAB_EXIT_R is 0.
local function SteerValueNear(frame, x, z, r, skipUid)
    if (CFG.LAB_EXIT_R or 0) <= 0 then return ArmedValueNear(frame, x, z, r, nil, skipUid) end
    local labs = EnemyLabs(frame)
    local v = 0
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and not c.scout and rec.uid ~= skipUid then
            local reach = r + (c.mobile and 0 or (c.range or 0))
            if (not c.mobile or frame - rec.frame <= 300) and Dist(rec.x, rec.z, x, z) <= reach then
                local w = 1
                if c.mobile then
                    for _, l in ipairs(labs) do
                        if Dist(rec.x, rec.z, l.x, l.z) <= CFG.LAB_EXIT_R then w = CFG.LAB_EXIT_W; break end
                    end
                end
                v = v + c.value * w
            end
        end
    end
    return v
end

-- ENGAGE: armed enemy ground value within r of (x, z) and how many of 6 sectors around it hold at least minV of it.
local function LocalThreat(frame, x, z, r, minV)
    local sect = { 0, 0, 0, 0, 0, 0 }
    local total = 0
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and not c.scout and not c.air and c.hitsGnd ~= false then
            local reach = r + (c.mobile and 0 or (c.range or 0))
            local d = Dist(rec.x, rec.z, x, z)
            if (not c.mobile or frame - rec.frame <= 300) and d <= reach then
                total = total + c.value
                local a = math.atan2(rec.z - z, rec.x - x)          -- -pi..pi
                local i = math.floor((a + math.pi) / (2 * math.pi) * 6) + 1
                if i > 6 then i = 6 elseif i < 1 then i = 1 end
                sect[i] = sect[i] + c.value
            end
        end
    end
    local n = 0
    for i = 1, 6 do if sect[i] > 0 and sect[i] >= minV then n = n + 1 end end
    return total, n
end

-- Damage value of killing a target: what it cost, the build power it carries, the income it makes.
local function DamageValue(t)
    local v = (t.value or 0) + CFG.BP_WEIGHT * (t.bp or 0) + (t.eco and CFG.ECO_BONUS or 0)
    if t.factory then v = v * CFG.LAB_FACTOR end
    return v
end

-- The enemy commander as a target, but only when it is open: seen recently, and little armed enemy
-- value around it besides itself (EI.ThreatAt counts the commander too, so its own value is taken
-- off).  Returns a target record like EI.RaidTargets' entries, or nil.
local function CommanderTarget(frame, groupValue, keeping)
    if groupValue < CFG.CMDR_MIN_AV then return nil end
    local x, z, seen, uid = EI.Commander()
    if not x or frame - seen > CFG.CMDR_FRESH then return nil end
    local rec = EI.Records()[uid]
    local c = rec and rec.c
    local own = (c and c.armed and c.hitsGnd) and c.value or 0
    local guard = math.max(0, EI.ThreatAt(frame, x, z, "ground") - own)
    local frac = (keeping and CFG.CMDR_KEEP_FRAC) or CFG.CMDR_OPEN_FRAC
    if guard > frac * groupValue then return nil end
    return { uid = uid, x = x, z = z, defID = rec and rec.defID, value = c and c.value or 0,
             bp = c and c.bp or 0, commander = true, guard = guard }
end

-- Best target for group g.  A target near another group's target is discounted so the groups
-- spread over the base instead of piling onto the same nano.
local function PickTarget(frame, g, groupValue)
    local best, bestScore
    local scale = g.slow and CFG.SLOW_DIST_SCALE or CFG.DIST_SCALE
    local defMax = CFG.TARGET_DEF_MAX * (g.slow and CFG.SLOW_DEF_MAX or 1)
    for _, t in ipairs(EI.RaidTargets(frame)) do
        local score = DamageValue(t) / (1 + Dist(g.cx, g.cz, t.x, t.z) / scale)
        if t.mobile then score = score * CFG.MOBILE_FACTOR end
        if g.avoid and g.avoid[t.uid] and frame < g.avoid[t.uid] then score = score * 0.02 end      -- SURVIVE: a target the group just evaded from
        if EI.ThreatAt(frame, t.x, t.z, "ground") > defMax * groupValue then
            score = score * CFG.DEF_PENALTY
        end
        for _, o in ipairs(groups) do
            if o ~= g and o.state == "attack" and o.target
               and Dist(t.x, t.z, o.target.x, o.target.z) < CFG.DIFF_R then
                score = score * CFG.DIFF_PENALTY
                break
            end
        end
        if CFG.SIDE_R and not g.slow then                  -- the raids go for the sides, away from the main push
            for _, o in ipairs(groups) do
                if o.slow and o.target and Dist(t.x, t.z, o.target.x, o.target.z) < CFG.SIDE_R then
                    score = score * CFG.SIDE_PENALTY
                    break
                end
            end
        end
        if not bestScore or score > bestScore then best, bestScore = t, score end
    end
    return best, bestScore
end

-- ── Orders ────────────────────────────────────────────────────────────────────

-- A unit a behaviour holds (o.isHeld: kite's step back) is left alone, except by `force` (commit / escape orders).
local function Claim(frame, uid, cmd, x, z, targetID, force)
    if not force and isHeld(uid, frame) then return end
    ARMY.Claim(ARMY.PRIO.LINE, uid, {
        role = "BLOB", cmd = cmd, x = x, z = z, targetID = targetID,
    }, frame)
end

local GOLDEN = 2.399963
local function RingPos(i, cx, cz)
    local a, r = i * GOLDEN, CFG.STAGE_SPACING * math.sqrt(i)
    local x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
    return MM.Clamp(x, z, CFG.MARGIN)
end

local function SendToStage(frame, list, base)
    table.sort(list, function(a, b) return a.uid < b.uid end)
    for i, u in ipairs(list) do
        local x, z = RingPos((base or 0) + i - 1, stageX, stageZ)
        Claim(frame, u.uid, CMD_MOVE, x, z)
    end
end

-- ── Members ───────────────────────────────────────────────────────────────────

-- Units this module commands: armed combat units nobody else has claimed.
local function Members()
    local ground, air = {}, {}
    for uid, defID in pairs(combat) do
        if Alive(uid) and not guards[uid] and not muster[uid] and not scouts[uid] and (not onlySet or onlySet[uid])
           and not responding[uid] and (CFG.DIRECT or not squad[uid]) then
            local role = ARMY.RoleOf(uid)
            -- DIRECT: a hurt squad (role RETREAT, squad[uid]) stays in the list so the squad_retreat behaviour can release it
            if role == nil or role == "BLOB" or role == "LINE" or (CFG.DIRECT and role == "RETREAT" and squad[uid]) then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then
                    local hp, mhp = Spring.GetUnitHealth(uid)
                    local u = { uid = uid, defID = defID, x = x, z = z,
                                hp = (hp and mhp and mhp > 0) and hp / mhp or 1, v = Value(defID) }
                    if UQ.is_air(defID) then air[#air + 1] = u
                    else
                        u.slow = IsSlow(defID)
                        ground[#ground + 1] = u
                    end
                end
            end
        end
    end
    return ground, air
end

local function Centroid(list)
    local sx, sz, sv = 0, 0, 0
    for _, u in ipairs(list) do sx, sz, sv = sx + u.x * u.v, sz + u.z * u.v, sv + u.v end
    if sv <= 0 then return nil end
    return sx / sv, sz / sv, sv
end

local function SumValue(list)
    local v = 0
    for _, u in ipairs(list) do v = v + u.v end
    return v
end

local function NearValue(list, x, z, r)
    local v = 0
    for _, u in ipairs(list) do
        if Dist(u.x, u.z, x, z) <= r then v = v + u.v end
    end
    return v
end

-- ── Hurt squads ───────────────────────────────────────────────────────────────

local function UpdateSquads(frame, ground)
    -- release finished retreats
    for uid, since in pairs(squad) do
        if not Alive(uid) then squad[uid] = nil
        else
            local hp, mhp = Spring.GetUnitHealth(uid)
            local ux, _, uz = Spring.GetUnitPosition(uid)
            local calm = ux and ArmedValueNear(frame, ux, uz, CFG.ENEMY_NEAR_R) <= 0
            if (hp and mhp and mhp > 0 and hp / mhp >= CFG.SQUAD_RELEASE)
               or (calm and frame - since > 450) then
                if ARMY.RoleOf(uid) == "RETREAT" then ARMY.Release(uid) end
                squad[uid] = nil
            else
                local hx, hz = MM.PointAt(0.10 * MM.Dist(), 0)
                ARMY.Claim(ARMY.PRIO.RETREAT, uid, { role = "RETREAT", cmd = CMD_MOVE, x = hx, z = hz }, frame)
            end
        end
    end
    -- find new ones among units that are in no group
    local free, taken = {}, {}
    for _, u in ipairs(ground) do if not unitGroup[u.uid] then free[#free + 1] = u end end
    for _, a in ipairs(free) do
        if not taken[a.uid] then
            local group, sumHp, val = {}, 0, 0
            for _, b in ipairs(free) do
                if not taken[b.uid] and Dist(a.x, a.z, b.x, b.z) <= CFG.SQUAD_R then
                    group[#group + 1] = b; sumHp = sumHp + b.hp; val = val + b.v
                end
            end
            for _, b in ipairs(group) do taken[b.uid] = true end
            if #group <= CFG.SQUAD_MAX and sumHp / #group < CFG.SQUAD_HP
               and ArmedValueNear(frame, a.x, a.z, CFG.ENEMY_NEAR_R) > val then
                for _, b in ipairs(group) do squad[b.uid] = frame end
                Log(frame, "squad retreat n=%d hp=%.2f", #group, sumHp / #group)
            end
        end
    end
end

-- ── Attack groups ─────────────────────────────────────────────────────────────

-- Fast groups are the MAX_GROUPS; the slow group is the one more, so at most MAX_GROUPS + 1 are out.
local function FastCount()
    local n = 0
    for _, g in ipairs(groups) do if not g.slow then n = n + 1 end end
    return n
end

local function SlowGroup()
    for _, g in ipairs(groups) do if g.slow and g.state == "attack" then return g end end
    return nil
end

local function HasSlowGroup()
    for _, g in ipairs(groups) do if g.slow then return true end end
    return false
end

local function FreeLane()
    local used = {}
    for _, g in ipairs(groups) do if not g.slow then used[g.lane] = true end end
    for l = 1, CFG.MAX_GROUPS do if not used[l] then return l end end
    return 1
end

local function Launch(frame, staged, slow)
    local g = { id = nextId, lane = slow and 2 or FreeLane(), state = "attack", peakN = #staged,
                startN = #staged, startF = frame, target = nil, arrivedF = nil, value = SumValue(staged),
                slow = slow or nil }
    nextId = nextId + 1
    for _, u in ipairs(staged) do unitGroup[u.uid] = g.id end
    groups[#groups + 1] = g
    byId[g.id] = g
    totals.launches = totals.launches + 1
    if slow then
        local heavy, escort, nh = 0, 0, 0
        for _, u in ipairs(staged) do
            if u.slow then heavy = heavy + u.v; nh = nh + 1 else escort = escort + u.v end
        end
        Log(frame, "SLOW group #%d launch: %d slow units av=%d + %d fast escorts av=%d (%.0f%% of the slow value) | %d groups out",
            g.id, nh, heavy, #staged - nh, escort, heavy > 0 and 100 * escort / heavy or 0, #groups)
    else
        Log(frame, "group #%d launch: %d units av=%d | stage av=%d vs reinforcing av=%d (%s) | %d groups out",
            g.id, #staged, g.value, stageAV, reinforceAV,
            reinforceAV > 0 and string.format("%.1fx", stageAV / reinforceAV) or "none walking", #groups)
    end
    return g
end

local function RemoveGroup(g)
    for uid, id in pairs(unitGroup) do if id == g.id then unitGroup[uid] = nil end end
    byId[g.id] = nil
    for i, o in ipairs(groups) do if o == g then table.remove(groups, i); break end end
end

local function EndGroup(frame, g, reason, n)
    Log(frame, "group #%d end (%s): %d of peak %d left after %ds | totals kills=%d bp=%d value=%d lost=%d units/%d",
        g.id, reason, n, g.peakN, math.floor((frame - g.startF) / 30),
        totals.kills, totals.killBP, totals.killValue, totals.lostUnits, totals.lostValue)
    g.state, g.fallFrame, g.target = "fall", frame, nil
    groupEnds[#groupEnds + 1] = { f = frame, killed = g.killV or 0, lost = g.lostV or 0, reason = reason }
    if #groupEnds > 50 then table.remove(groupEnds, 1) end
end

-- FLANK: the biggest cluster of enemy ground army seen in the last FLANK_MAX_AGE frames (value within
-- FLANK_CLUSTER_R of its densest unit), as x, z, value.  Computed once per frame for all groups.
local clusterF, clusterX, clusterZ, clusterV = -1, nil, nil, 0
local function EnemyArmyCluster(frame)
    if clusterF == frame then return clusterX, clusterZ, clusterV end
    clusterF, clusterX, clusterZ, clusterV = frame, nil, nil, 0
    local pts = {}
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and c.mobile and not c.scout and not c.commander and not c.air
           and frame - rec.frame <= CFG.FLANK_MAX_AGE then
            pts[#pts + 1] = rec
        end
    end
    local R2 = CFG.FLANK_CLUSTER_R * CFG.FLANK_CLUSTER_R
    local best, bestV
    for _, a in ipairs(pts) do
        local v = 0
        for _, b in ipairs(pts) do
            local dx, dz = a.x - b.x, a.z - b.z
            if dx * dx + dz * dz <= R2 then v = v + b.c.value end
        end
        if not bestV or v > bestV then best, bestV = a, v end
    end
    if not best then return nil, nil, 0 end
    local sx, sz, sv = 0, 0, 0
    for _, b in ipairs(pts) do
        local dx, dz = best.x - b.x, best.z - b.z
        if dx * dx + dz * dz <= R2 then sx, sz, sv = sx + b.x * b.c.value, sz + b.z * b.c.value, sv + b.c.value end
    end
    clusterX, clusterZ, clusterV = sx / sv, sz / sv, sv
    return clusterX, clusterZ, clusterV
end

-- FLANK: a waypoint beside the enemy army when the straight path to (tx,tz) runs into it, else nil.  The side is
-- the far side from where the cluster sits relative to the path, and is kept for the group (g.flankSide).
local function FlankPoint(frame, g, cx, cz, tx, tz, groupValue)
    local ax, az, av = EnemyArmyCluster(frame)
    if not ax or av < CFG.FLANK_MIN_FRAC * groupValue then g.flankSide = nil; return nil end
    if Dist(ax, az, tx, tz) < CFG.FLANK_CLEAR then return nil end     -- it guards the target itself: no way round
    local dx, dz = tx - cx, tz - cz
    local L = math.sqrt(dx * dx + dz * dz)
    if L < 1 then return nil end
    local ux, uz = dx / L, dz / L
    local px, pz = ax - cx, az - cz
    local along = px * ux + pz * uz
    if along <= 0 or along >= L then g.flankSide = nil; return nil end  -- behind us, or beyond the target
    local lat = -px * uz + pz * ux                                     -- its offset across our path
    if math.abs(lat) >= CFG.FLANK_CLEAR then return nil end            -- the path already clears it
    local side = g.flankSide or ((lat >= 0) and -1 or 1)
    local wx, wz = ax - uz * side * CFG.FLANK_OFFSET, az + ux * side * CFG.FLANK_OFFSET
    local cwx, cwz = MM.Clamp(wx, wz, CFG.MARGIN)
    if not g.flankSide and Dist(cwx, cwz, wx, wz) > CFG.FLANK_OFFSET * 0.5 then
        side = -side                                                   -- that side is off the map: the other one
        wx, wz = ax - uz * side * CFG.FLANK_OFFSET, az + ux * side * CFG.FLANK_OFFSET
        cwx, cwz = MM.Clamp(wx, wz, CFG.MARGIN)
    end
    g.flankSide = side
    return cwx, cwz, av
end

-- Next leg: toward (tx,tz), turned up to ~70 degrees if that avoids enemy armed value.
-- The unit being attacked (skipUid) is not something to steer round: an armed target such as the
-- enemy commander would otherwise push every leg sideways and the group would circle it.
local function LegPoint(frame, cx, cz, tx, tz, groupValue, skipUid, units)
    local dx, dz = tx - cx, tz - cz
    local d = math.sqrt(dx * dx + dz * dz)
    if d < 1 then return tx, tz end
    local step = math.min(CFG.LEG, d)
    dx, dz = dx / d, dz / d
    if CFG.LEG_LEAD and units then                 -- LEG_LEAD: past the front-most unit, not just LEG from the centroid
        local front = 0
        for _, u in ipairs(units) do
            local a = (u.x - cx) * dx + (u.z - cz) * dz
            if a > front then front = a end
        end
        step = math.min(d, math.max(step, front + CFG.LEG_LEAD))
    end
    local bx, bz, bestCost
    for _, ang in ipairs({ 0, 0.6, -0.6, 1.2, -1.2 }) do
        local c, s = math.cos(ang), math.sin(ang)
        local rx, rz = dx * c - dz * s, dx * s + dz * c
        local px, pz = MM.Clamp(cx + rx * step, cz + rz * step, CFG.MARGIN)
        local cost = SteerValueNear(frame, px, pz, CFG.ENEMY_NEAR_R, skipUid)
                     + math.abs(ang) * CFG.FLANK_PENALTY * groupValue
        if not bestCost or cost < bestCost then bx, bz, bestCost = px, pz, cost end
    end
    return bx, bz
end

-- HOLE_FIND: a point on a ring of HOLE_R round the target to strike in from -- the one with the least known armed value
-- (and away from the enemy army cluster), paying for the detour.  Kept in g.approach until reached (then the group strikes
-- in) or until it gets defended.  Returns x, z or nil (go straight).  Unseen ring points go to g.holeScout.
local function ApproachPoint(frame, g, cx, cz, tx, tz, groupValue)
    local d = Dist(cx, cz, tx, tz)
    local key = g.target and g.target.uid or nil
    local a = g.approach
    if a and (a.key ~= key or Dist(a.tx, a.tz, tx, tz) > CFG.HOLE_R * 0.5) then a = nil; g.approach = nil end
    if d < CFG.HOLE_MIN_D or (not a and d > CFG.HOLE_MAX_D) then g.holeScout = nil; return nil end
    if a then
        if a.done then g.holeScout = nil; return nil end
        if Dist(cx, cz, a.x, a.z) <= CFG.HOLE_ARRIVE then a.done = true; g.holeScout = nil; return nil end
        if ArmedValueNear(frame, a.x, a.z, CFG.ENEMY_NEAR_R) <= CFG.HOLE_REPICK_FRAC * groupValue then
            return a.x, a.z
        end
    end
    local ax, az, av = EnemyArmyCluster(frame)
    local los = Spring.IsPosInLos
    local ally = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    local best, bestCost
    local unseen = {}
    for i = 0, CFG.HOLE_N - 1 do
        local ang = 2 * math.pi * i / CFG.HOLE_N
        local rx, rz = tx + math.cos(ang) * CFG.HOLE_R, tz + math.sin(ang) * CFG.HOLE_R
        local px, pz = MM.Clamp(rx, rz, CFG.MARGIN)
        if Dist(px, pz, rx, rz) <= CFG.HOLE_R * 0.5 then           -- mostly on the map
            local cost = ArmedValueNear(frame, px, pz, CFG.ENEMY_NEAR_R)
            if ax and av > 0 then
                local dc = Dist(px, pz, ax, az)
                if dc < CFG.FLANK_CLEAR then cost = cost + av * (1 - dc / CFG.FLANK_CLEAR) end
            end
            local detour = Dist(cx, cz, px, pz) + Dist(px, pz, tx, tz) - d
            cost = cost + math.max(0, detour) / 1000 * CFG.FLANK_PENALTY * groupValue
            if not bestCost or cost < bestCost then best, bestCost = { x = px, z = pz }, cost end
            if los and ally and not los(px, 0, pz, ally) then unseen[#unseen + 1] = { px, pz, cost } end
        end
    end
    table.sort(unseen, function(p, q) return p[3] < q[3] end)
    g.holeScout = {}
    for i = 1, math.min(CFG.HOLE_SCOUTS, #unseen) do g.holeScout[i] = { unseen[i][1], unseen[i][2] } end
    if not best then return nil end
    g.approach = { x = best.x, z = best.z, key = key, tx = tx, tz = tz }
    if frame - (g.holeLogF or -99999) >= 450 then
        g.holeLogF = frame
        Log(frame, "group #%d approach via (%d,%d): threat there %d (core %d), %d unseen ring points",
            g.id, best.x, best.z, bestCost, groupValue, #unseen)
    end
    return best.x, best.z
end

local supportCache = {}
local function IsSupport(defID)
    local v = supportCache[defID]
    if v == nil then
        local d = UnitDefs[defID]
        v = (d ~= nil and CFG.SLOW_SUPPORT[d.name] == true)
            or (IsSlow(defID) and (UQ.max_weapon_range(defID) or 0) >= CFG.SLOW_SUPPORT_RANGE)
        supportCache[defID] = v
    end
    return v
end

-- Enemy armed MOBILE units seen recently within r of the support units: the nearest one's position.
local function NearestThreat(frame, support, r)
    local best, bestD
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and c.mobile and not c.scout and frame - rec.frame <= 300 then
            for _, s in ipairs(support) do
                local d = Dist(rec.x, rec.z, s.x, s.z)
                if d <= r and (not bestD or d < bestD) then best, bestD = rec, d end
            end
        end
    end
    return best
end

-- The shortest weapon range among the support units: every one of them must be able to fire.
local rangeCache = {}
local function SupportRange(support)
    local r
    for _, u in ipairs(support) do
        local x = rangeCache[u.defID]
        if x == nil then x = UQ.max_weapon_range(u.defID) or 0; rangeCache[u.defID] = x end
        if x > 0 and (not r or x < r) then r = x end
    end
    return r or CFG.SLOW_SUPPORT_RANGE
end

-- The nearest enemy armed unit (a mobile one seen lately, or a standing defence) within r of a point.
local function NearestEnemy(frame, x, z, r)
    local best, bestD
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and not c.scout and (not c.mobile or frame - rec.frame <= 300) then
            local d = Dist(rec.x, rec.z, x, z)
            if d <= r and (not bestD or d < bestD) then best, bestD = rec, d end
        end
    end
    return best, bestD
end

-- The enemy's eco / main base: the densest cluster of standing enemy structures we know of (weighted by
-- how much it hurts to lose them), as its centre.  Before any structure is known, the enemy's start.
local function MainBase(frame)
    local pts = {}
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile then pts[#pts + 1] = { t.x, t.z, math.max(1, DamageValue(t)) } end
    end
    local bestI, bestDens = nil, 0
    for i, p in ipairs(pts) do
        local dens = 0
        for _, q in ipairs(pts) do
            if Dist(p[1], p[2], q[1], q[2]) <= CFG.SLOW_BASE_R then dens = dens + q[3] end
        end
        if dens > bestDens then bestI, bestDens = i, dens end
    end
    if not bestI then
        local fx, fz = MM.Foe()
        return fx, fz, "foe"
    end
    local sx, sz, sv = 0, 0, 0
    for _, q in ipairs(pts) do
        if Dist(pts[bestI][1], pts[bestI][2], q[1], q[2]) <= CFG.SLOW_BASE_R then
            sx, sz, sv = sx + q[1] * q[3], sz + q[2] * q[3], sv + q[3]
        end
    end
    return sx / sv, sz / sv, "base"
end

-- Positions for a LINE of units.  `perSpot` units stand deep in each spot, and the line gets one more spot
-- across for every `perSpot` units, so it only widens once every spot is full (4 Lashers deep, then a
-- second spot, ...).  The line faces (ux,uz) and is centred on (cx,cz); the front rank of each spot is on
-- the line, the rest stand behind it.  Units are sorted by where they already stand across the line, so
-- neighbours stay neighbours and the group does not reshuffle every pass.  `width` (optional) makes the
-- line at least that wide (the screen spans the support's width).  Returns {[uid] = {x, z}}.
local function FormationSlots(units, perSpot, ux, uz, cx, cz, width)
    local out = {}
    local n = #units
    if n == 0 then return out end
    local px, pz = -uz, ux
    local spots = math.ceil(n / perSpot)
    width = math.max(width or 0, (spots - 1) * CFG.SLOW_SPOT_SPACING)
    -- (c is the CENTRE of the formation, not its front rank: shift the front forward by half the depth so the
    -- units' average stays on c.  Otherwise a group told to hold slides back half a depth every pass.)
    local frontShift = (math.min(perSpot, n) - 1) * 0.5 * CFG.SLOW_DEPTH_SPACING
    cx, cz = cx + ux * frontShift, cz + uz * frontShift
    for _, u in ipairs(units) do
        u.lat = (u.x - cx) * px + (u.z - cz) * pz
        u.fwd = (u.x - cx) * ux + (u.z - cz) * uz
    end
    table.sort(units, function(a, b)
        if a.lat ~= b.lat then return a.lat < b.lat end
        return a.uid < b.uid
    end)
    for s = 0, spots - 1 do
        local chunk = {}
        for i = s * perSpot + 1, math.min(n, (s + 1) * perSpot) do chunk[#chunk + 1] = units[i] end
        table.sort(chunk, function(a, b)
            if a.fwd ~= b.fwd then return a.fwd > b.fwd end
            return a.uid < b.uid
        end)
        local lat = (spots == 1) and 0 or ((s / (spots - 1)) - 0.5) * width
        for k, u in ipairs(chunk) do
            local back = (k - 1) * CFG.SLOW_DEPTH_SPACING
            local x, z = MM.Clamp(cx + px * lat - ux * back, cz + pz * lat - uz * back, CFG.MARGIN)
            out[u.uid] = { x, z }
        end
    end
    return out
end

local function Away(fromX, fromZ, x, z, fallbackX, fallbackZ)
    local ax, az = x - fromX, z - fromZ
    local al = math.sqrt(ax * ax + az * az)
    if al > 1 then return ax / al, az / al end
    return fallbackX, fallbackZ
end

-- The slow group: a line of Pounders (screen) in front of a line of Lashers/Sheldons (support), marching on
-- the enemy's main base.  The support is only worth anything while it FIRES, so its default is a FIGHT
-- order toward the base, and it gives ground only when it is at risk of dying (outvalued with the enemy
-- on top of it, or low on health with the enemy near) -- in short steps that keep the enemy in range.
local function UpdateSlow(frame, g, list)
    local screen, support = {}, {}
    for _, u in ipairs(list) do
        if IsSupport(u.defID) then support[#support + 1] = u else screen[#screen + 1] = u end
    end
    local lead = (#screen > 0) and screen or support
    local cx, cz = Centroid(lead)
    g.cx, g.cz, g.value, g.n = cx, cz, SumValue(list), #list
    g.heavy, g.escort = 0, 0
    for _, u in ipairs(list) do
        if u.slow then g.heavy = g.heavy + u.v else g.escort = g.escort + u.v end
    end

    local near = ArmedValueNear(frame, cx, cz, CFG.SLOW_ENGAGE_R)
    local ratio = near / math.max(1, g.value)

    -- where to: always the enemy's eco / main base, never a unit
    if not g.objX or frame - (g.objF or -99999) >= CFG.SLOW_OBJ_EVERY then
        g.objX, g.objZ, g.objKind = MainBase(frame)
        g.objF = frame
    end
    local ox, oz, objective = g.objX, g.objZ, g.objKind
    local dx, dz = ox - cx, oz - cz
    local d = math.sqrt(dx * dx + dz * dz)
    local ux, uz = 1, 0
    if d > 1 then ux, uz = dx / d, dz / d end

    -- scouts look ahead of the group, along its way and to one side
    do
        local k = math.min(CFG.SCOUT_AHEAD, d + 400)
        local ax, az = cx + ux * k, cz + uz * k
        local side = (g.id % 2 == 0) and 1 or -1
        local p1x, p1z = MM.Clamp(ax, az, CFG.MARGIN)
        local p2x, p2z = MM.Clamp(ax - uz * CFG.SCOUT_SIDE * side, az + ux * CFG.SCOUT_SIDE * side, CFG.MARGIN)
        g.scoutPts = { { p1x, p1z }, { p2x, p2z } }
    end

    -- Where the support is, how far it shoots, and the nearest enemy (the direction of a real fight).
    local spx, spz = cx, cz
    if #support > 0 then spx, spz = Centroid(support) end
    local R = SupportRange(support)
    local foe, dn = NearestEnemy(frame, spx, spz, CFG.SLOW_ENGAGE_R)
    local eux, euz = ux, uz
    if foe then
        local ex, ez = foe.x - cx, foe.z - cz
        local el = math.sqrt(ex * ex + ez * ez)
        if el > 1 then eux, euz = ex / el, ez / el end
    end
    local fight = foe ~= nil and near >= CFG.SLOW_FIGHT_FRAC * g.value     -- strays are not a fight
    local threat = NearestThreat(frame, support, CFG.SLOW_THREAT_R)

    -- AT RISK OF DYING is the only reason to give ground: outvalued AND the enemy right on top of the
    -- support (inside SLOW_DANGER_FRAC of its range).  Short of that the support keeps firing.
    local close = foe ~= nil and dn < R * CFG.SLOW_DANGER_FRAC
    if not g.pulled and ratio > CFG.SLOW_PULL_RATIO and close then
        g.pulled = true
        Log(frame, "SLOW group #%d pulls back (at risk): enemy av=%d vs ours %d (%.1fx), nearest %dm", g.id, near, g.value, ratio, dn)
    elseif g.pulled and (ratio < CFG.SLOW_RESUME_RATIO or not foe or dn > R * CFG.SLOW_RANGE_KEEP) then
        g.pulled = false
        Log(frame, "SLOW group #%d goes back in: enemy av=%d vs ours %d (%.1fx)", g.id, near, g.value, ratio)
    end

    -- Individual supports low on health with the enemy near back off on their own, a short step.
    local depthExtent = (math.min(CFG.SLOW_SPOT_DEPTH, #support) - 1) * CFG.SLOW_DEPTH_SPACING
    local keep = math.max(R * 0.4, R * CFG.SLOW_RANGE_KEEP - depthExtent)   -- the whole depth stays in range
    local fragile, sturdy = {}, {}
    for _, u in ipairs(support) do
        if foe and u.hp < CFG.SLOW_RISK_HP and Dist(u.x, u.z, foe.x, foe.z) < R * 1.3 then
            fragile[#fragile + 1] = u
        else
            sturdy[#sturdy + 1] = u
        end
    end

    if g.pulled and foe then
        -- the screen holds the line in front while the whole support line gives ground, still in range
        local sc = FormationSlots(screen, CFG.SLOW_SCREEN_DEPTH, eux, euz, cx, cz)     -- hold exactly where it stands
        for _, u in ipairs(screen) do
            local p = sc[u.uid]
            if threat then Claim(frame, u.uid, CMD_FIGHT, threat.x, threat.z)
            else Claim(frame, u.uid, CMD_FIGHT, p[1], p[2]) end
        end
        local back = (dn >= keep) and 0 or math.min(CFG.SLOW_PULL_STEP, keep - dn)     -- short, still in range
        local ax, az = Away(foe.x, foe.z, spx, spz, -eux, -euz)
        local sp = FormationSlots(support, CFG.SLOW_SPOT_DEPTH, eux, euz, spx + ax * back, spz + az * back)
        for _, u in ipairs(support) do
            local p = sp[u.uid]
            Claim(frame, u.uid, back > 0 and CMD_MOVE or CMD_FIGHT, p[1], p[2])      -- it fires while it moves
        end
        return
    end

    -- How far to advance this pass.  In a REAL fight (enemy value near >= half ours): close in until the
    -- enemy is in the support's range, then stand and shoot.  Otherwise -- nothing in sight, or just a few
    -- strays -- march on the main base; the FIGHT orders shoot whatever is in range on the way, and the
    -- strays are not chased.  Never into STATIC defences worth far more than the group.
    local step = 0
    if fight then
        ux, uz = eux, euz
        if dn > R * CFG.SLOW_IN_RANGE then
            step = math.min(CFG.SLOW_LEG, dn - R * CFG.SLOW_ADVANCE_TO)
        end
    elseif d > CFG.SLOW_ARRIVE then
        step = math.min(CFG.SLOW_LEG, d - CFG.SLOW_ARRIVE)
    end
    if step > 0 then
        local px, pz = cx + ux * (step + CFG.SLOW_SCREEN_AHEAD), cz + uz * (step + CFG.SLOW_SCREEN_AHEAD)
        if ArmedValueNear(frame, px, pz, CFG.SLOW_ENGAGE_R / 2, -1) > CFG.SLOW_STAND_OFF * g.value then
            step = 0                                   -- defences ahead worth far more than us: hold at their edge
        end
    end

    -- The lines.  Supports: spots of SLOW_SPOT_DEPTH units deep, widening only when a spot is full.  The
    -- screen spans the same width, a thin line in front.
    -- Where each line is centred.  Moving every unit relative to where the line already stands (never
    -- "centre + a fixed lead" while holding) is what stops a holding line creeping forward or sliding back:
    --   marching          : the screen leads by SCREEN_AHEAD, the support follows SUPPORT_BACK behind it;
    --   closing in (fight): both lines move up by `step`, the support staying at least SUPPORT_BACK behind the screen;
    --   in range (fight)  : both hold exactly where they are, the support FIRING from the spot it is in.
    local fCx, fCz, sCx, sCz
    if not fight then
        local leadDist = (step > 0) and (step + CFG.SLOW_SCREEN_AHEAD) or 0
        fCx, fCz = cx + ux * leadDist, cz + uz * leadDist
        sCx, sCz = cx + ux * (step - CFG.SLOW_SUPPORT_BACK), cz + uz * (step - CFG.SLOW_SUPPORT_BACK)
    elseif step > 0 then
        fCx, fCz = cx + ux * step, cz + uz * step
        sCx, sCz = spx + ux * step, spz + uz * step
        local over = (sCx - fCx) * ux + (sCz - fCz) * uz + CFG.SLOW_SUPPORT_BACK     -- > 0: nearer than BACK behind
        if over > 0 then sCx, sCz = sCx - ux * over, sCz - uz * over end
    else
        fCx, fCz = cx, cz
        sCx, sCz = spx, spz
    end
    local supportWidth = (math.ceil(#sturdy / CFG.SLOW_SPOT_DEPTH) - 1) * CFG.SLOW_SPOT_SPACING
    local sp = FormationSlots(sturdy, CFG.SLOW_SPOT_DEPTH, ux, uz, sCx, sCz)
    local sc = FormationSlots(screen, CFG.SLOW_SCREEN_DEPTH, ux, uz, fCx, fCz, supportWidth)

    -- the screen steps out only for something right on top of the support, otherwise it leads the march
    for _, u in ipairs(screen) do
        if threat then Claim(frame, u.uid, CMD_FIGHT, threat.x, threat.z)
        else Claim(frame, u.uid, CMD_FIGHT, sc[u.uid][1], sc[u.uid][2]) end
    end
    for _, u in ipairs(sturdy) do Claim(frame, u.uid, CMD_FIGHT, sp[u.uid][1], sp[u.uid][2]) end
    for _, u in ipairs(fragile) do
        local dd = Dist(u.x, u.z, foe.x, foe.z)
        if dd < keep then
            local ax, az = Away(foe.x, foe.z, u.x, u.z, -eux, -euz)
            local back = math.min(CFG.SLOW_PULL_STEP, keep - dd)
            local bx, bz = MM.Clamp(u.x + ax * back, u.z + az * back, CFG.MARGIN)
            Claim(frame, u.uid, CMD_MOVE, bx, bz)               -- still in range, still firing
        else
            Claim(frame, u.uid, CMD_FIGHT, u.x, u.z)
        end
    end

    if frame - (g.logF or -9999) >= 900 then
        g.logF = frame
        Log(frame, "SLOW group #%d (%s): %d screen + %d support (range %d, %d spots wide), enemy av near=%d (%.1fx ours), nearest %s%s",
            g.id, objective, #screen, #support, R, math.ceil(#sturdy / CFG.SLOW_SPOT_DEPTH), near, ratio,
            dn and string.format("%dm", dn) or "none",
            threat and ", screen answers a threat to the support" or "")
    end
end

-- FORWARD_CORE: the forward cluster of a group.  "Forward" is nearness to the group's target when it has one,
-- else distance along home->foe.  The forward unit must have CORE_COMPANY others within CORE_CLUSTER_R, so one
-- unit that ran ahead is not the core.  Returns core, far, cx, cz.
local function ForwardCore(list, g)
    local tx, tz = nil, nil
    if g.target then tx, tz = g.target.x, g.target.z end
    local need = math.min(CFG.CORE_COMPANY, #list - 1)
    local best, bestF
    for _, a in ipairs(list) do
        local n = 0
        for _, b in ipairs(list) do
            if a ~= b and Dist(a.x, a.z, b.x, b.z) <= CFG.CORE_CLUSTER_R then
                n = n + 1
                if n >= need then break end
            end
        end
        if n >= need then
            local f = tx and -Dist(a.x, a.z, tx, tz) or MM.Forward(a.x, a.z)
            if not bestF or f > bestF then best, bestF = a, f end
        end
    end
    local core, far = {}, {}
    if best then
        for _, u in ipairs(list) do
            if Dist(u.x, u.z, best.x, best.z) <= CFG.CORE_R then core[#core + 1] = u else far[#far + 1] = u end
        end
    end
    if #core == 0 then core, far = list, {} end
    local cx, cz = Centroid(core)
    return core, far, cx, cz
end

-- SET_TARGET: give each unit of the core the most damaging enemy building inside its weapon range, without stopping it.
-- g.st[uid] = {id|pos key, frame}; a unit with nothing in range has its target cancelled.  Returns the count set.
local function SetTargets(frame, g, core, cx, cz)
    if frame - (g.stF or -1e9) < CFG.SET_TARGET_EVERY then return 0 end
    g.stF = frame
    g.st = g.st or {}
    local cands = {}
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile and Dist(cx, cz, t.x, t.z) <= CFG.SET_TARGET_SCAN then
            local dv = DamageValue(t)
            if dv > 0 or not CFG.SET_TARGET_NO_ECO then cands[#cands + 1] = { t = t, dv = dv } end
        end
    end
    local set = 0
    for _, u in ipairs(core) do
        local range = (UQ.max_weapon_range(u.defID) or 0) * CFG.SET_TARGET_RANGE
        local best, bd
        for _, c in ipairs(cands) do
            local d = Dist(u.x, u.z, c.t.x, c.t.z)
            if d <= range and (not best or c.dv > best.dv or (c.dv == best.dv and d < bd)) then best, bd = c, d end
        end
        local key = best and (best.t.uid or (math.floor(best.t.x) .. "," .. math.floor(best.t.z))) or nil
        local cur = g.st[u.uid]
        if best then
            if not cur or cur.key ~= key or frame - cur.f > 300 then
                local t = best.t
                if t.uid and Alive(t.uid) then
                    Spring.GiveOrderToUnit(u.uid, CMD_SET_TARGET, { t.uid }, {})
                else
                    Spring.GiveOrderToUnit(u.uid, CMD_SET_TARGET, { t.x, Spring.GetGroundHeight(t.x, t.z) or 0, t.z }, {})
                end
                g.st[u.uid] = { key = key, f = frame }
                set = set + 1
            end
        elseif cur then
            Spring.GiveOrderToUnit(u.uid, CMD_CANCEL_TARGET, {}, {})
            g.st[u.uid] = nil
        end
    end
    return set
end

-- ── ENGAGE: advance / commit / escape ─────────────────────────────────────────

-- Enemy build power within r of (x, z), best first: the commander (when fresh), then builders/nanos next to a factory,
-- then any builder, nano or factory -- by damage value over distance.  Returns a target record or nil.
local function BPNear(frame, x, z, r)
    local best, bestS
    local cxx, czz, seen, cuid = EI.Commander()
    if cxx and frame - seen <= CFG.CMDR_FRESH and Dist(x, z, cxx, czz) <= r then
        return { uid = cuid, x = cxx, z = czz, commander = true }
    end
    local labs = EnemyLabs(frame)
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if (t.bp or 0) > 0 or t.factory or t.builder then
            local d = Dist(x, z, t.x, t.z)
            if d <= r then
                local s = DamageValue(t)
                if not t.factory then
                    for _, l in ipairs(labs) do
                        if Dist(t.x, t.z, l.x, l.z) <= CFG.LAB_BP_R then s = s * 3; break end
                    end
                end
                s = s / (1 + d / 400)
                if not bestS or s > bestS then best, bestS = t, s end
            end
        end
    end
    return best
end

local function CancelSetTargets(g)
    if not g.st then return end
    for uid in pairs(g.st) do Spring.GiveOrderToUnit(uid, CMD_CANCEL_TARGET, {}, {}) end
    g.st = {}
end

local function RecentLoss(g, frame)
    local v = 0
    local keep = {}
    for _, e in ipairs(g.losses or {}) do
        if frame - e.f <= CFG.ENGAGE_LOSS_WINDOW then v = v + e.v; keep[#keep + 1] = e end
    end
    g.losses = keep
    return v
end

-- Commit: every unit of the group attacks the best build power in reach (the unit's own weapon range + 200), else the
-- group's commit target.  No steering, no dodging.
local function CommitOrders(frame, g, list, t)
    for _, u in ipairs(list) do
        local reach = (UQ.max_weapon_range(u.defID) or 0) + 200
        local own = BPNear(frame, u.x, u.z, reach) or t
        if own.uid and Alive(own.uid) then Claim(frame, u.uid, CMD_ATTACK, own.x, own.z, own.uid, true)
        else Claim(frame, u.uid, CMD_FIGHT, own.x, own.z, nil, true) end
    end
end

-- SURVIVE (user 2026-10-27: "the escape logic does not take into account where enemy units are, they just got a move order away"; "raiding units should never fight / command, they always
-- stay moving"): danger no longer commits (no attack order) and no longer ends the group or sends it to a fixed point.  It EVADES: the least-threat heading of 12 round the core
-- (armed enemy value near each point), a mild pull toward the target so the raid goes on, shuns the target for SURVIVE_AVOID_S, and holds that heading SURVIVE_HOLD frames.
local function EngageSurvive(frame, g, list, cx, cz, fightV)
    g.engage = nil
    if g.evadeUntil and frame < g.evadeUntil then return true end
    local T, sectors = LocalThreat(frame, cx, cz, CFG.ENGAGE_R, CFG.SECTOR_MIN_FRAC * fightV)
    local loss = RecentLoss(g, frame)
    local lossFrac = loss / math.max(1, fightV + loss)
    -- LOSS_MIN_THREAT (user 2026-10-28, "they pulled back when there was nothing there"): losing a unit only counts as danger while armed enemy value
    -- is actually known near the group.  Without it one dead Incisor of a small group (16% of its value) with 0 threat in view sent the whole
    -- group 900 elmos away, shunned its target for 60 s and cancelled its set-targets -- over and over (7:40, 7:44, 7:48 in the test game).
    local lossDanger = lossFrac >= CFG.ESCAPE_LOSS_FRAC and T >= (CFG.LOSS_MIN_THREAT or 0) * fightV
    local danger = (sectors >= CFG.SURROUND_SECTORS and T >= CFG.SURROUND_MIN_FRAC * fightV) or lossDanger or T >= CFG.COMMIT_RATIO * fightV
    if not danger then return nil end
    local tx, tz = g.target and g.target.x, g.target and g.target.z
    local bx, bz, bc
    local fx, fz = MM.Foe()
    for i = 0, 11 do
        local a = i * math.pi / 6
        local px, pz = MM.Clamp(cx + math.cos(a) * CFG.SURVIVE_EVADE_D, cz + math.sin(a) * CFG.SURVIVE_EVADE_D, CFG.MARGIN)
        local c = SteerValueNear(frame, px, pz, CFG.ENEMY_NEAR_R)
        if tx then c = c + 0.1 * fightV * Dist(px, pz, tx, tz) / 3000 end
        -- EVADE_FOE_PULL (user 2026-10-28: "when they retreat they are just trying to leave instead of getting closer to the enemy base"):
        -- a heading toward the enemy base is cheaper by up to 2 x pull x the core's value than one away from it, so the group steers AROUND
        -- the threat on the side that keeps it going toward the enemy, and only turns back when every way forward is that much worse
        if fx and (CFG.EVADE_FOE_PULL or 0) > 0 then c = c + CFG.EVADE_FOE_PULL * fightV * Dist(px, pz, fx, fz) / math.max(1, CFG.SURVIVE_EVADE_D) end
        if not bc or c < bc then bx, bz, bc = px, pz, c end
    end
    g.evadeUntil = frame + CFG.SURVIVE_HOLD
    if g.target then
        g.avoid = g.avoid or {}
        g.avoid[g.target.uid] = frame + 30 * CFG.SURVIVE_AVOID_S
        g.target = nil
    end
    CancelSetTargets(g)
    Log(frame, "group #%d EVADES to (%d,%d): threat %d vs core %d, %d sectors, lost %d%% (heading threat %d)", g.id, bx, bz, T, fightV, sectors, math.floor(lossFrac * 100), bc)
    for i, u in ipairs(list) do
        local x, z = RingPos(40 * g.id + i - 1, bx, bz)
        Claim(frame, u.uid, CMD_MOVE, x, z, nil, true)
    end
    return true
end

-- Returns "done" (escape finished: end the group), true (orders given this tick), or nil (advance as usual).
local function Engage(frame, g, list, cx, cz, fightV)
    if CFG.SURVIVE then return EngageSurvive(frame, g, list, cx, cz, fightV) end
    if g.engage == "escape" then
        local ex, ez = MM.PointAt(CFG.ESCAPE_FRAC * MM.Dist(), 0)
        ex, ez = MM.Clamp(ex, ez, CFG.MARGIN)
        local ax, az = Centroid(list)
        if not ax or Dist(ax, az, ex, ez) <= CFG.ESCAPE_ARRIVE or frame - g.engageF > CFG.ESCAPE_MAX_FRAMES then
            return "done"
        end
        for i, u in ipairs(list) do
            local x, z = RingPos(40 * g.id + i - 1, ex, ez)
            Claim(frame, u.uid, CMD_MOVE, x, z, nil, true)
        end
        return true
    end
    if g.engage == "commit" then
        local t = BPNear(frame, cx, cz, CFG.COMMIT_KEEP_R)
        if t then CommitOrders(frame, g, list, t); return true end
        g.engage = nil
        Log(frame, "group #%d commit over: no build power within %d", g.id, CFG.COMMIT_KEEP_R)
        return nil
    end
    local T, sectors = LocalThreat(frame, cx, cz, CFG.ENGAGE_R, CFG.SECTOR_MIN_FRAC * fightV)
    local loss = RecentLoss(g, frame)
    local lossFrac = loss / math.max(1, fightV + loss)
    local surrounded = sectors >= CFG.SURROUND_SECTORS and T >= CFG.SURROUND_MIN_FRAC * fightV
    local losing = lossFrac >= CFG.ESCAPE_LOSS_FRAC
    if not (surrounded or losing or T >= CFG.COMMIT_RATIO * fightV) then return nil end
    local t = BPNear(frame, cx, cz, CFG.COMMIT_R)
    if t then
        g.engage, g.engageF = "commit", frame
        local d = t.defID and UnitDefs[t.defID]
        Log(frame, "group #%d COMMIT on %s at (%d,%d): threat %d vs core %d, %d sectors, lost %d%% in %ds",
            g.id, t.commander and "commander" or (d and d.name or "?"), t.x, t.z, T, fightV, sectors,
            math.floor(lossFrac * 100), math.floor(CFG.ENGAGE_LOSS_WINDOW / 30))
        CommitOrders(frame, g, list, t)
        return true
    end
    if surrounded or losing or T >= CFG.ESCAPE_RATIO * fightV then
        g.engage, g.engageF, g.target = "escape", frame, nil
        CancelSetTargets(g)
        Log(frame, "group #%d ESCAPE to the line front: threat %d vs core %d, %d sectors, lost %d%% in %ds, no build power within %d",
            g.id, T, fightV, sectors, math.floor(lossFrac * 100), math.floor(CFG.ENGAGE_LOSS_WINDOW / 30), CFG.COMMIT_R)
        return Engage(frame, g, list, cx, cz, fightV)
    end
    return nil
end

local function UpdateAttack(frame, g, list)
    -- SURVIVE: a badly hurt unit with an armed enemy near leaves for the hurt-squad retreat (UpdateSquads moves it home and releases it at SQUAD_RELEASE hp / calm)
    if CFG.SURVIVE and not g.slow then
        local keep, hurt = {}, 0
        for _, u in ipairs(list) do
            if u.hp < CFG.SURVIVE_UNIT_HP and ArmedValueNear(frame, u.x, u.z, CFG.ENEMY_NEAR_R) > 0 then
                squad[u.uid] = frame; unitGroup[u.uid] = nil; hurt = hurt + 1
            else
                keep[#keep + 1] = u
            end
        end
        if hurt > 0 then
            list = keep
            Log(frame, "group #%d: %d hurt unit(s) retreat (hp < %.2f)", g.id, hurt, CFG.SURVIVE_UNIT_HP)
        end
    end
    local n = #list
    if n > g.peakN then g.peakN = n end
    if n == 0 or n < math.max(1, math.floor(g.peakN * CFG.FALL_FRAC)) then
        return EndGroup(frame, g, "group spent", n)
    end
    if g.slow then return UpdateSlow(frame, g, list) end

    -- the core: units near the group's centre.  Units far behind (reinforcements, stragglers) walk
    -- to the core instead of running ahead on their own.
    local cx, cz, core, far
    if CFG.FORWARD_CORE then
        core, far, cx, cz = ForwardCore(list, g)
    else
        cx, cz = Centroid(list)
        core, far = {}, {}
        for _, u in ipairs(list) do
            if Dist(u.x, u.z, cx, cz) <= CFG.STRAGGLER_R then core[#core + 1] = u else far[#far + 1] = u end
        end
        if #core > 0 and #far > 0 then cx, cz = Centroid(core) end
        if #core == 0 then core, far = list, {} end
    end
    g.cx, g.cz, g.value, g.n = cx, cz, SumValue(list), n
    -- what the group can fight with right now (FORWARD_CORE: the core, not units still walking in)
    local fightV = CFG.FORWARD_CORE and SumValue(core) or g.value
    g.coreValue = fightV
    if g.slow then
        g.heavy, g.escort = 0, 0
        for _, u in ipairs(list) do
            if u.slow then g.heavy = g.heavy + u.v else g.escort = g.escort + u.v end
        end
    end
    for _, u in ipairs(far) do Claim(frame, u.uid, CMD_MOVE, cx, cz) end

    -- the enemy commander, when it is out in the open, beats everything and pulls every group
    local cmdr = CommanderTarget(frame, fightV, g.target and g.target.commander)
    if cmdr then
        if g.target and g.target.commander then
            g.target.x, g.target.z, g.target.picked = cmdr.x, cmdr.z, frame     -- it walks: follow it
        else
            g.target = cmdr; cmdr.picked = frame
            Log(frame, "group #%d: enemy COMMANDER is open (guard av=%d vs group av=%d) at (%d,%d), %dm away",
                g.id, cmdr.guard, g.value, cmdr.x, cmdr.z, Dist(cx, cz, cmdr.x, cmdr.z))
        end
    elseif g.target and g.target.commander then
        g.target = nil
        Log(frame, "group #%d: the commander is no longer open, picking another target", g.id)
    end

    -- keep or pick a target
    local recs = EI.Records()
    if g.target and (not recs[g.target.uid] or frame - g.target.picked > CFG.TARGET_REPICK) then
        g.target = nil
    end
    if not g.target then
        local t, score = PickTarget(frame, g, fightV)
        if t then
            g.target = t; t.picked = frame
            local d = t.defID and UnitDefs[t.defID]
            Log(frame, "group #%d target %s bp=%d value=%d at (%d,%d) %dm away, score=%d", g.id,
                d and d.name or "?", t.bp or 0, t.value or 0, t.x, t.z, Dist(cx, cz, t.x, t.z), score or 0)
        end
    end

    local tx, tz
    if g.target then
        tx, tz = g.target.x, g.target.z
        g.arrivedF = nil
    else
        -- nothing known: head for where the enemy started (each group along its own lane) and
        -- look.  Give the intel scan (every 90 frames) time to show what is there.
        local fx, fz = MM.Foe()
        local px, pz = MM.Perp()
        local off = (g.lane - 2) * CFG.LANE_SPACING
        tx, tz = MM.Clamp(fx + px * off, fz + pz * off, CFG.MARGIN)
        -- UNSEEN_FIRST: the enemy is not located yet (the foe is the mirror guess): go where nobody has looked, the likeliest place for it
        local usx, usz
        if CFG.UNSEEN_FIRST and unseenFn and MM.FoeSource and MM.FoeSource() == "mirror" then
            usx, usz = unseenFn(cx, cz, frame)
            if usx then tx, tz = MM.Clamp(usx, usz, CFG.MARGIN) end
        end
        if not usx and Dist(cx, cz, tx, tz) < CFG.NO_TARGET_R then
            g.arrivedF = g.arrivedF or frame
            if frame - g.arrivedF >= CFG.LOOK_FRAMES then return EndGroup(frame, g, "nothing to hit", n) end
        end
    end

    -- where scouts should look: ahead along the path (not past the target), and to one side
    do
        local dx, dz = tx - cx, tz - cz
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 1 then
            local k = math.min(CFG.SCOUT_AHEAD, d + 400)
            local ax, az = cx + dx / d * k, cz + dz / d * k
            local side = (g.id % 2 == 0) and 1 or -1
            local bx, bz = ax - dz / d * CFG.SCOUT_SIDE * side, az + dx / d * CFG.SCOUT_SIDE * side
            local p1x, p1z = MM.Clamp(ax, az, CFG.MARGIN)
            local p2x, p2z = MM.Clamp(bx, bz, CFG.MARGIN)
            g.scoutPts = { { p1x, p1z }, { p2x, p2z } }
        end
    end

    if CFG.ENGAGE then
        local e = Engage(frame, g, list, cx, cz, fightV)
        if e == "done" then return EndGroup(frame, g, "escaped", n) end
        if e then return end
    end

    if CFG.SET_TARGET then
        -- keep moving: the shooting is done by SET_TARGET on whatever is in range (see SetTargets)
        local nset = SetTargets(frame, g, core, cx, cz)
        if nset > 0 and frame - (g.stLogF or -99999) >= 450 then
            g.stLogF = frame
            Log(frame, "group #%d set-target on %d unit(s) while moving (%d in the core)", g.id, nset, #core)
        end
    end
    -- SURVIVE: inside ATTACK_SWITCH dive only into a big hole, otherwise skirmish (see CFG.SURVIVE)
    if CFG.SURVIVE and g.target and Dist(cx, cz, tx, tz) <= CFG.ATTACK_SWITCH then
        local defNear = ArmedValueNear(frame, tx, tz, CFG.ENGAGE_R, nil, g.target.uid)
        local ecx, ecz, ecv = EnemyArmyCluster(frame)
        local hole = defNear <= CFG.SURVIVE_HOLE_FRAC * fightV
                     and not (ecx and ecv >= 0.5 * fightV and Dist(ecx, ecz, tx, tz) <= CFG.FLANK_CLEAR)
        if not hole then
            if g.holdUntil and frame < g.holdUntil then return end         -- a step back is under way
            local threat = SteerValueNear(frame, cx, cz, CFG.SURVIVE_R, g.target.uid)
            local lim = CFG.SURVIVE_THREAT_FRAC * fightV
            if threat > (g.skirmishBack and 0.5 * lim or lim) then
                local foe = NearestEnemy(frame, cx, cz, CFG.SURVIVE_R)
                local ax, az = cx - (foe and foe.x or tx), cz - (foe and foe.z or tz)
                local d = math.sqrt(ax * ax + az * az)
                if d < 1 then ax, az, d = cx - tx, cz - tz, math.max(1, Dist(cx, cz, tx, tz)) end
                local bx, bz = MM.Clamp(cx + ax / d * CFG.SURVIVE_STEP, cz + az / d * CFG.SURVIVE_STEP, CFG.MARGIN)
                for _, u in ipairs(core) do Claim(frame, u.uid, CMD_MOVE, bx, bz, nil, true) end
                g.holdUntil, g.skirmishBack = frame + CFG.SURVIVE_HOLD, true
                if frame - (g.svLogF or -99999) >= 450 then
                    g.svLogF = frame
                    Log(frame, "group #%d steps back %dm: threat %d vs core %d at the target (defence there %d)", g.id, CFG.SURVIVE_STEP, threat, fightV, defNear)
                end
                return
            end
            g.skirmishBack = nil
            -- orbit the target at SURVIVE_STANDOFF, ALWAYS MOVING (never a FIGHT / ATTACK order: SetTargets above shoots what is in weapon range while the units keep going)
            local dT = math.max(1, Dist(cx, cz, tx, tz))
            local ang = math.atan2(cz - tz, cx - tx)
            if dT > CFG.SURVIVE_STANDOFF + 150 then
                local sx, sz = MM.Clamp(tx + math.cos(ang) * CFG.SURVIVE_STANDOFF, tz + math.sin(ang) * CFG.SURVIVE_STANDOFF, CFG.MARGIN)
                for i, u in ipairs(core) do local x, z = RingPos(i - 1, sx, sz); Claim(frame, u.uid, CMD_MOVE, x, z) end
            else
                g.orbitDir = g.orbitDir or 1
                local function Pt(dir)
                    local a = ang + dir * CFG.SURVIVE_ORBIT_STEP
                    return MM.Clamp(tx + math.cos(a) * CFG.SURVIVE_STANDOFF, tz + math.sin(a) * CFG.SURVIVE_STANDOFF, CFG.MARGIN)
                end
                local p1x, p1z = Pt(g.orbitDir)
                local p2x, p2z = Pt(-g.orbitDir)
                if SteerValueNear(frame, p1x, p1z, CFG.SURVIVE_R, g.target.uid) > 1.5 * SteerValueNear(frame, p2x, p2z, CFG.SURVIVE_R, g.target.uid) + 1 then
                    g.orbitDir, p1x, p1z = -g.orbitDir, p2x, p2z
                end
                for i, u in ipairs(core) do local x, z = RingPos(i - 1, p1x, p1z); Claim(frame, u.uid, CMD_MOVE, x, z) end
            end
            return
        end
        if frame - (g.svLogF or -99999) >= 450 then
            g.svLogF = frame
            Log(frame, "group #%d dives: a hole at the target (defence %d vs core %d)", g.id, defNear, fightV)
        end
    end
    if g.target and Dist(cx, cz, tx, tz) <= CFG.ATTACK_SWITCH and CFG.SET_TARGET then
        -- run through and past the target instead of stopping to ATTACK it
        local dx, dz = tx - cx, tz - cz
        local d = math.sqrt(dx * dx + dz * dz)
        local ux, uz = 0, 0
        if d > 1 then ux, uz = dx / d, dz / d end
        local bx, bz = MM.Clamp(tx + ux * CFG.SET_TARGET_BEYOND, tz + uz * CFG.SET_TARGET_BEYOND, CFG.MARGIN)
        for _, u in ipairs(core) do Claim(frame, u.uid, CMD_MOVE, bx, bz) end
    elseif g.target and Dist(cx, cz, tx, tz) <= CFG.ATTACK_SWITCH then
        local visible = Alive(g.target.uid)
        for _, u in ipairs(core) do
            if visible then Claim(frame, u.uid, CMD_ATTACK, tx, tz, g.target.uid)
            else Claim(frame, u.uid, CMD_FIGHT, tx, tz) end
        end
    elseif CFG.FORWARD_CORE and CFG.CORE_WAIT_FRAC and #far > 0 and not CFG.SURVIVE
           and fightV < CFG.CORE_WAIT_FRAC * (fightV + NearValue(far, cx, cz, CFG.CORE_WAIT_R)) then
        -- the front is a small part of what is about to arrive: hold and let it catch up.  Units further
        -- than CORE_WAIT_R (fresh from the factory) do not hold the front back.
        for _, u in ipairs(core) do Claim(frame, u.uid, CMD_FIGHT, cx, cz) end
        if frame - (g.waitLogF or -99999) >= 450 then
            g.waitLogF = frame
            Log(frame, "group #%d core waits for the rest: core av=%d of %d (%d far)", g.id, fightV, g.value, #far)
        end
    else
        local ltx, ltz = tx, tz
        local hx, hz
        if CFG.HOLE_FIND and g.target then
            hx, hz = ApproachPoint(frame, g, cx, cz, tx, tz, fightV)
            if g.scoutPts and g.holeScout then
                for _, p in ipairs(g.holeScout) do g.scoutPts[#g.scoutPts + 1] = p end
            end
        end
        if hx then
            ltx, ltz = hx, hz
        elseif CFG.FLANK then
            local wx, wz, av = FlankPoint(frame, g, cx, cz, tx, tz, fightV)
            if wx then
                ltx, ltz = wx, wz
                if frame - (g.flankLogF or -99999) >= 450 then
                    g.flankLogF = frame
                    Log(frame, "group #%d flanks the enemy army (av=%d vs core %d): via (%d,%d), side %d", g.id, av,
                        fightV, wx, wz, g.flankSide or 0)
                end
            end
        end
        if CFG.SCOUT_ROUTE then
            local pts = {}
            local rdx, rdz = ltx - cx, ltz - cz
            local rd = math.sqrt(rdx * rdx + rdz * rdz)
            if rd > 1 then
                local k = math.min(CFG.SCOUT_AHEAD, rd)
                local px, pz = MM.Clamp(cx + rdx / rd * k, cz + rdz / rd * k, CFG.MARGIN)
                pts[#pts + 1] = { px, pz }
            end
            if g.target then
                local px, pz = MM.Clamp(tx, tz, CFG.MARGIN)
                pts[#pts + 1] = { px, pz }
            end
            for _, p in ipairs(g.holeScout or {}) do pts[#pts + 1] = p end
            g.scoutPts = pts
        end
        local lx, lz = LegPoint(frame, cx, cz, ltx, ltz, fightV, g.target and g.target.uid, core)
        for _, u in ipairs(core) do Claim(frame, u.uid, CMD_MOVE, lx, lz) end
    end
end

local function UpdateFall(frame, g, list)
    for i, u in ipairs(list) do
        local x, z = RingPos(40 * g.id + i - 1, stageX, stageZ)
        Claim(frame, u.uid, CMD_MOVE, x, z)
    end
    local cx, cz = Centroid(list)
    if not cx or Dist(cx, cz, stageX, stageZ) <= CFG.FALL_ARRIVE or frame - g.fallFrame > CFG.FALL_MAX_FRAMES then
        RemoveGroup(g)    -- the survivors are stage units again
    end
end

-- The attacking FAST group with the least value: where a new fast unit is most useful.
local function WeakestAttacker()
    local best
    for _, g in ipairs(groups) do
        if not g.slow and g.state == "attack" and g.cx and (not best or g.value < best.value) then best = g end
    end
    return best
end

-- Put a free unit straight into a group (it walks to the group's centre).
local function JoinGroup(frame, g, u)
    unitGroup[u.uid] = g.id
    g.value = g.value + u.v
    if g.slow then
        if u.slow then g.heavy = (g.heavy or 0) + u.v else g.escort = (g.escort or 0) + u.v end
    end
    if g.cx then Claim(frame, u.uid, CMD_MOVE, g.cx, g.cz) end
end

-- ── Bombers ───────────────────────────────────────────────────────────────────

local function UpdateBombers(frame)
    if not bombers or isHunting() then return end
    local list, value = {}, 0
    for uid, _ in pairs(bombers) do
        if Alive(uid) then
            list[#list + 1] = uid; value = value + Value(Spring.GetUnitDefID(uid))
        end
    end
    -- let go of a finished run so the bombers return to their pads
    if frame - lastBombF == 150 then
        for _, uid in ipairs(list) do if ARMY.RoleOf(uid) == "BLOB" then ARMY.Release(uid) end end
    end
    if #list < CFG.BOMBER_MIN or frame - lastBombF < CFG.BOMB_COOLDOWN then return end
    local hx, hz = MM.Home()
    local best, bestScore
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile and EI.ThreatAt(frame, t.x, t.z, "air") <= CFG.BOMB_AIR_MAX * value then
            local score = DamageValue(t) / (1 + Dist(hx, hz, t.x, t.z) / CFG.DIST_SCALE)
            if not bestScore or score > bestScore then best, bestScore = t, score end
        end
    end
    if not best then return end
    for _, uid in ipairs(list) do
        Claim(frame, uid, CMD_ATTACK, best.x, best.z, Alive(best.uid) and best.uid or nil)
    end
    lastBombF = frame
    local d = best.defID and UnitDefs[best.defID]
    Log(frame, "bomber run: %d bombers -> %s at (%d,%d)", #list, d and d.name or "?", best.x, best.z)
end

-- ── Entry points ──────────────────────────────────────────────────────────────

-- Call every 30 frames, after the planners that outrank this one.
-- DIRECT mode: the ground army is a stack of behaviours (CFG.ARMY_BEHAVIORS) on one behavior_host.  Orders go out through
-- army_broker (Claim), so retreat / respond still outrank them; the host's own de-duplication is off for that reason.
local armyHost, armyCtx, armyShared
local hostLogF = -99999

-- The best `k` different targets (at least DIFF_R apart), best first.  Build power NEAR AN ENEMY LAB (a nano, con or other
-- builder within LAB_BP_R of a factory) always outranks everything else: killing it starves the lab, so it is returned first
-- (t.labBP = true) whatever its distance or defence.  `avoid`: a target whose neighbourhood is skipped.  `groupValue`
-- (optional) discounts targets whose armed defence is above TARGET_DEF_MAX x the army (not for lab build power).
local function RankTargets(frame, cx, cz, k, groupValue, avoid)
    local raw = EI.RaidTargets(frame)
    local labs = {}
    for _, t in ipairs(raw) do if t.factory and not t.mobile then labs[#labs + 1] = t end end
    local list = {}
    for _, t in ipairs(raw) do
        local score = DamageValue(t) / (1 + Dist(cx, cz, t.x, t.z) / CFG.DIST_SCALE)
        if t.mobile then score = score * CFG.MOBILE_FACTOR end
        t.labBP = false
        if (t.bp or 0) > 0 and not t.factory then
            for _, l in ipairs(labs) do
                if Dist(t.x, t.z, l.x, l.z) <= CFG.LAB_BP_R then t.labBP = true; break end
            end
        end
        if t.labBP then
            score = score + 1e9
        elseif groupValue and EI.ThreatAt(frame, t.x, t.z, "ground") > CFG.TARGET_DEF_MAX * groupValue then
            score = score * CFG.DEF_PENALTY
        end
        if not (avoid and Dist(t.x, t.z, avoid.x, avoid.z) < CFG.DIFF_R) then list[#list + 1] = { t = t, s = score } end
    end
    table.sort(list, function(a, b) if a.s ~= b.s then return a.s > b.s end return (a.t.uid or 0) < (b.t.uid or 0) end)
    local out = {}
    for _, e in ipairs(list) do
        if #out >= k then break end
        local near = false
        for _, o in ipairs(out) do if Dist(e.t.x, e.t.z, o.x, o.z) < CFG.DIFF_R then near = true; break end end
        if not near then out[#out + 1] = e.t end
    end
    return out
end

local function TopTargets(frame, cx, cz, k, avoid) return RankTargets(frame, cx, cz, k, nil, avoid) end

local function NewArmyHost()
    local okH, BH = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/behavior_host.lua")
    if not (okH and BH) then Spring.Echo("[CK] behavior_host failed to load: " .. tostring(BH)); return end
    local curFrame = 0
    armyShared = {}
    armyHost = BH.New{
        cfg = { HEARTBEAT = 1, REISSUE_EPS = 0, REISSUE_GAP = 0 },     -- Claim() de-duplicates; a unit released by retreat must be re-ordered
        give = function(uid, cmd, params)
            if #params == 1 then Claim(curFrame, uid, cmd, nil, nil, params[1])
            else Claim(curFrame, uid, cmd, params[1], params[3]) end
        end,
    }
    armyCtx = {
        shared = armyShared,
        Foe = function() return MM.Foe() end,
        Clamp = function(x, z) return MM.Clamp(x, z, CFG.MARGIN) end,
        Alive = Alive,
        Log = function(frame, f, ...) Log(frame, "direct: " .. f, ...) end,
        ArmedValueNear = function(frame, x, z, r, skipUid) return ArmedValueNear(frame, x, z, r, nil, skipUid) end,
        Cluster = EnemyArmyCluster,         -- biggest recently seen enemy army cluster: x, z, value
        squad = squad,                      -- [uid] = frame it began retreating (the unit controller reads it too)
        Retreat = function(frame, uid)
            local hx, hz = MM.PointAt(0.10 * MM.Dist(), 0)
            ARMY.Claim(ARMY.PRIO.RETREAT, uid, { role = "RETREAT", cmd = CMD_MOVE, x = hx, z = hz }, frame)
        end,
        EndRetreat = function(uid) if ARMY.RoleOf(uid) == "RETREAT" then ARMY.Release(uid) end end,
        Release = function(uid) if ARMY.RoleOf(uid) == "BLOB" then ARMY.Release(uid) end end,
        Home = function() return MM.Home() end,
        AirThreatAt = function(frame, x, z) return EI.ThreatAt(frame, x, z, "air") end,
        Hunting = function() return isHunting() end,
        Rank = RankTargets,                 -- Rank(frame, cx, cz, k, groupValue, avoid) -> k different targets, lab build power first
        TopTargets = TopTargets,
        Commander = function(frame, value, keeping) return CommanderTarget(frame, value, keeping) end,
        ThreatAt = function(frame, x, z) return EI.ThreatAt(frame, x, z, "ground") end,
    }
    for _, name in ipairs(CFG.ARMY_BEHAVIORS) do armyHost:Use(name) end
    for _, name in ipairs(CFG.BOMBER_BEHAVIORS) do armyHost:Use(name) end
    local parts = {}
    for _, name in ipairs(CFG.ARMY_BEHAVIORS) do
        local b = armyHost.reg[name]
        local cfg = {}
        for k, v in pairs(b and b.cfg or {}) do cfg[k] = v end
        for k, v in pairs(CFG.ARMY_BEHAVIOR_CFG[name] or {}) do cfg[k] = v end
        parts[#parts + 1] = name .. (b and b.Describe and (" (" .. b.Describe(cfg) .. ")") or "")
    end
    Spring.Echo("[CK] army behaviour stack: " .. table.concat(parts, " > "))
    armyHost.setFrame = function(f) curFrame = f end
end

-- Run the army stack over `ground`; units that left the list are dropped from the host.
local function RunArmyBehaviors(frame, ground)
    if not armyHost then NewArmyHost() end
    if not armyHost then return end
    armyHost.setFrame(frame)
    local present = {}
    if CFG.DIRECT then
        for _, u in ipairs(ground) do
            present[u.uid] = true
            if not armyHost:Has(u.uid) then armyHost:Assign(u.uid, CFG.ARMY_BEHAVIORS, CFG.ARMY_BEHAVIOR_CFG) end
        end
    end
    if #CFG.BOMBER_BEHAVIORS > 0 and bombers then
        for uid in pairs(bombers) do
            if Alive(uid) then
                present[uid] = true
                if not armyHost:Has(uid) then armyHost:Assign(uid, CFG.BOMBER_BEHAVIORS, CFG.BOMBER_BEHAVIOR_CFG) end
            end
        end
    end
    for uid in pairs(armyHost.units) do if not present[uid] then armyHost:Remove(uid) end end
    local acted = armyHost:Update(frame, armyCtx)
    if frame - hostLogF >= 900 then
        hostLogF = frame
        local by, n = {}, 0
        for _, name in pairs(acted) do by[name] = (by[name] or 0) + 1; n = n + 1 end
        local parts = {}
        local order = {}
        for _, name in ipairs(CFG.ARMY_BEHAVIORS) do order[#order + 1] = name end
        for _, name in ipairs(CFG.BOMBER_BEHAVIORS) do order[#order + 1] = name end
        for _, name in ipairs(order) do if by[name] then parts[#parts + 1] = name .. " " .. by[name] end end
        local sh = armyShared
        Log(frame, "direct jobs: %d units | %s | army av=%d, enemy av at target=%d", n, table.concat(parts, ", "),
            sh.total or 0, sh.enemyV or 0)
    end
end

function M.Update(frame)
    if not (MM and ARMY and EI and MM.Ready()) then return end

    -- The enemy's start is usually unreadable, so the foe is a mirror guess until a scout sights it
    -- (map_model.lua), and on this map the guess is thousands of elmos off.  The stage follows the
    -- foe, and no group leaves on a guess.
    local fx, fz = MM.Foe()
    local src = MM.FoeSource()
    local wantFrac = (mode == "hold") and CFG.HOLD_STAGE_FRAC or CFG.STAGE_FRAC
    if not stageX or Dist(fx, fz, foeSeenX, foeSeenZ) > 300 or src ~= foeSeenSrc or wantFrac ~= stageFrac then
        foeSeenX, foeSeenZ, foeSeenSrc, stageFrac = fx, fz, src, wantFrac
        stageX, stageZ = MM.PointAt(wantFrac * MM.Dist(), 0)
        stageX, stageZ = MM.Clamp(stageX, stageZ, CFG.MARGIN)
        Log(frame, "stage point (%d,%d), foe (%d,%d) via %s", stageX, stageZ, fx, fz, tostring(src))
    end
    local foeKnown = src ~= "mirror" or frame >= CFG.BLIND_DIVE_FRAME or CFG.BLIND_LAUNCH
    if frame - lastPruneF >= 900 then
        lastPruneF = frame
        local keep = {}
        for _, e in ipairs(tradeLog) do if frame - e.f <= 2 * CFG.TRADE_WINDOW then keep[#keep + 1] = e end end
        tradeLog = keep
    end

    local ground, air = Members()
    if CFG.DIRECT or #CFG.BOMBER_BEHAVIORS > 0 then RunArmyBehaviors(frame, ground) end
    if CFG.DIRECT then ground = {} end       -- nothing is left for the group logic
    UpdateSquads(frame, ground)

    -- who belongs where
    local byGroup, free = {}, {}
    for _, u in ipairs(ground) do
        if not squad[u.uid] then
            local gid = unitGroup[u.uid]
            if gid and byId[gid] then
                local l = byGroup[gid]
                if not l then l = {}; byGroup[gid] = l end
                l[#l + 1] = u
            else
                unitGroup[u.uid] = nil
                free[#free + 1] = u
            end
        end
    end

    local snapshot = {}      -- groups can be removed while updating
    for i, g in ipairs(groups) do snapshot[i] = g end
    for _, g in ipairs(snapshot) do
        local list = byGroup[g.id] or {}
        if g.state == "attack" and mode == "hold" then EndGroup(frame, g, "hold", #list) end
        if g.state == "attack" then UpdateAttack(frame, g, list) else UpdateFall(frame, g, list) end
    end

    -- Units in no group.
    --  1. The slow group (if out) takes every free slow unit, and tops itself up with fast units
    --     only until they are SLOW_ESCORT_SHARE of its slow value -- enough mass, no more.
    local rest = {}
    local slowG = SlowGroup()
    if slowG then
        local fast = {}
        for _, u in ipairs(free) do
            if u.slow then JoinGroup(frame, slowG, u) else fast[#fast + 1] = u end
        end
        local want = CFG.SLOW_ESCORT_SHARE * (slowG.heavy or 0)
        table.sort(fast, function(a, b)
            return Dist(a.x, a.z, slowG.cx or stageX, slowG.cz or stageZ)
                 < Dist(b.x, b.z, slowG.cx or stageX, slowG.cz or stageZ)
        end)
        for _, u in ipairs(fast) do
            if (slowG.escort or 0) + u.v <= want + 0.5 * u.v then JoinGroup(frame, slowG, u)
            else rest[#rest + 1] = u end
        end
    else
        rest = free
    end

    --  holdHome (unit_runtime HOLD_HOME): a ground raid is on the base -- new production is not added to the groups or sent to the stage; it stays where it is (role nil), which
    --  raid_response answers with (units inside a group never respond)
    if holdHomeFn and holdHomeFn() then rest = {} end

    --  2. With all MAX_GROUPS fast groups out, a fast unit goes straight to the weakest of them.
    local toStage = rest
    if FastCount() >= CFG.MAX_GROUPS and WeakestAttacker() and CFG.BATCH_REINFORCE then
        -- BATCH_REINFORCE: they gather at the stage; once the fast ones there are worth a group, they go together
        local staged, sv = {}, 0
        for _, u in ipairs(rest) do
            if not u.slow and Dist(u.x, u.z, stageX, stageZ) <= CFG.STAGE_JOIN_R then staged[#staged + 1] = u; sv = sv + u.v end
        end
        if #staged > 0 and sv >= math.max(CFG.LAUNCH_MIN_AV, ProdMin(1)) then
            local g = WeakestAttacker()
            local joined = {}
            for _, u in ipairs(staged) do JoinGroup(frame, g, u); joined[u.uid] = true end
            toStage = {}
            for _, u in ipairs(rest) do if not joined[u.uid] then toStage[#toStage + 1] = u end end
            Log(frame, "batch of %d reinforcements (%d value) -> group #%d", #staged, sv, g.id or 0)
        end
    elseif FastCount() >= CFG.MAX_GROUPS and WeakestAttacker() then
        toStage = {}
        for _, u in ipairs(rest) do
            local g = (not u.slow) and WeakestAttacker() or nil
            if not g then toStage[#toStage + 1] = u else JoinGroup(frame, g, u) end
        end
    end
    SendToStage(frame, toStage)

    --  3. The rest wait at the stage.  Slow units there start the slow group; fast ones start fast
    --     groups by the stage-av / reinforce-av rule.  Slow units still walking in do not hold the
    --     fast groups back (they crawl; the fast groups would never leave).
    local stagedFast, stagedSlow, slowAV = {}, {}, 0
    stageAV, reinforceAV = 0, 0
    for _, u in ipairs(toStage) do
        local atStage = Dist(u.x, u.z, stageX, stageZ) <= CFG.STAGE_JOIN_R
        if u.slow then
            if atStage then stagedSlow[#stagedSlow + 1] = u; slowAV = slowAV + u.v end
        elseif atStage then
            stagedFast[#stagedFast + 1] = u; stageAV = stageAV + u.v
        else
            reinforceAV = reinforceAV + u.v
        end
    end
    if mode ~= "hold" and not HasSlowGroup() and foeKnown and slowAV >= math.max(CFG.SLOW_MIN_AV, ProdMin(CFG.SLOW_PROD_FRAC)) then
        -- the escorts: the fast units nearest the stage, up to the share of the slow value
        local want = CFG.SLOW_ESCORT_SHARE * slowAV
        local picked, have = {}, 0
        table.sort(stagedFast, function(a, b)
            return Dist(a.x, a.z, stageX, stageZ) < Dist(b.x, b.z, stageX, stageZ)
        end)
        for _, u in ipairs(stagedFast) do
            if have + u.v > want + 0.5 * u.v then break end
            picked[#picked + 1] = u; have = have + u.v
        end
        if have >= CFG.SLOW_ESCORT_WAIT * want or slowAV >= CFG.SLOW_FORCE_MULT * CFG.SLOW_MIN_AV then
            local members = {}
            for _, u in ipairs(stagedSlow) do members[#members + 1] = u end
            local taken = {}
            for _, u in ipairs(picked) do members[#members + 1] = u; taken[u.uid] = true end
            local remain = {}
            for _, u in ipairs(stagedFast) do
                if not taken[u.uid] then remain[#remain + 1] = u else stageAV = stageAV - u.v end
            end
            stagedFast = remain
            Launch(frame, members, true)
        elseif frame - lastWaitLog >= CFG.WAIT_LOG_EVERY then
            lastWaitLog = frame
            Log(frame, "slow group waiting for escorts: slow av=%d, fast escorts av=%d of %d wanted", slowAV, have, want)
        end
    end
    local minAV, ratio = CFG.LAUNCH_MIN_AV, CFG.LAUNCH_RATIO
    local e = CFG.EARLY_LAUNCH
    if e then
        if frame <= e.f0 then minAV = e.av0
        elseif frame >= e.f1 then minAV = e.av1
        else minAV = e.av0 + (e.av1 - e.av0) * (frame - e.f0) / (e.f1 - e.f0) end
        if CFG.LAUNCH_RATIO_EARLY and frame < e.f1 then ratio = CFG.LAUNCH_RATIO_EARLY end
    end
    minAV = math.max(minAV, ProdMin(1))        -- LAUNCH_PROD_S: at least that many seconds of army production
    if mode ~= "hold" and FastCount() < CFG.MAX_GROUPS and foeKnown and stageAV >= minAV
       and #stagedFast >= CFG.MIN_GROUP_UNITS then
        if stageAV >= ratio * reinforceAV or stageAV >= CFG.LAUNCH_FORCE_AV then
            Launch(frame, stagedFast, false)
        elseif frame - lastWaitLog >= CFG.WAIT_LOG_EVERY then
            lastWaitLog = frame
            Log(frame, "waiting for reinforcements: stage av=%d, reinforcing av=%d (needs %.1fx)",
                stageAV, reinforceAV, ratio)
        end
    end

    -- fighters escort the biggest attacking group, else wait at the stage
    local escort
    for _, g in ipairs(groups) do
        if g.state == "attack" and g.cx and (not escort or g.value > escort.value) then escort = g end
    end
    local postX, postZ
    if CFG.FIGHTER_POST then postX, postZ = M.FighterPost(frame) end
    for _, u in ipairs(air) do
        if UQ.is_dedicated_aa(u.defID) then
            if postX then Claim(frame, u.uid, CMD_FIGHT, postX, postZ)
            elseif escort then Claim(frame, u.uid, CMD_MOVE, escort.cx, escort.cz)
            else Claim(frame, u.uid, CMD_MOVE, stageX, stageZ) end
        end
    end

    if #CFG.BOMBER_BEHAVIORS == 0 then UpdateBombers(frame) end

    if frame % 1800 == 900 and (totals.launches > 0 or stageAV > 0) then
        Log(frame, "totals: launches=%d kills=%d bp=%d value=%d | lost %d units/%d value | groups=%d stage av=%d reinforcing av=%d",
            totals.launches, totals.kills, totals.killBP, totals.killValue, totals.lostUnits,
            totals.lostValue, #groups, stageAV, reinforceAV)
    end
end

-- A unit died.  Ours in a group are the cost; an enemy build-power / eco / factory kill near an
-- attacking group is the result.
function M.OnDestroyed(uid, defID, isMine, frame, x, z)
    if isMine then
        local g = byId[unitGroup[uid]]
        if g and g.state == "attack" then
            local v = Value(defID)
            totals.lostUnits = totals.lostUnits + 1
            totals.lostValue = totals.lostValue + math.floor(v)
            g.lostV = (g.lostV or 0) + v
            g.losses = g.losses or {}
            g.losses[#g.losses + 1] = { f = frame or 0, v = v }
            tradeLog[#tradeLog + 1] = { f = frame or 0, killed = 0, lost = v }
        end
        unitGroup[uid], squad[uid] = nil, nil
        return
    end
    -- the trade (any enemy unit, army included) goes to the nearest attacking group within KILL_R
    if x then
        local nearG, nd
        for _, g in ipairs(groups) do
            if g.state == "attack" and g.cx then
                local d = Dist(x, z, g.cx, g.cz)
                if d <= CFG.KILL_R and (not nd or d < nd) then nearG, nd = g, d end
            end
        end
        if nearG then
            local v = Value(defID)
            nearG.killV = (nearG.killV or 0) + v
            tradeLog[#tradeLog + 1] = { f = frame or 0, killed = v, lost = 0 }
        end
    end
    -- Only what a group (or a bomber run) was actually near counts: the end-of-match commander
    -- self-destruct chain-kills a whole base and is not a result of the attack.
    local bombing = (frame - lastBombF) <= 600
    if not bombing then
        local near = false
        for _, g in ipairs(groups) do
            if g.state == "attack" and g.cx and (not x or Dist(x, z, g.cx, g.cz) <= CFG.KILL_R) then
                near = true; break
            end
        end
        if not near then return end
    end
    local c = EI and EI.Class and defID and EI.Class(defID)
    if c and (c.bp > 0 or c.factory or c.builder or c.eco) then
        totals.kills = totals.kills + 1
        totals.killBP = totals.killBP + math.floor(c.bp)
        totals.killValue = totals.killValue + math.floor(c.value)
        Log(frame, "KILL %s bp=%d value=%d (running: %d kills, %d bp)", UnitDefs[defID].name,
            c.bp, c.value, totals.kills, totals.killBP)
    end
end

return M
