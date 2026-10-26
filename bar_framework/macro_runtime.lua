-- bar_framework/macro_runtime.lua
-- The macro controller (RAID_BOT's, moved here on 2026-10-16): build the line (commander starter + one builder per lane), queue the
-- line's cons, hand over to line_transition (air lab, mex grids, energy, spine), run the strategy (stances + hooks) and the
-- commander's safety.  Callbacks are added to the widget passed in; WG is passed in too (see lab_rules.lua for why).
--
-- A bot's macro_controller.lua is the widget's GetInfo plus
--     local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")
--     MACRO.Install(widget, WG, { <overrides of M.DEFAULTS> })
--
-- Configuration (K overrides M.DEFAULTS key by key; `false` switches a stance off, nil means "absent"):
--   NAME          bot name for log rows / the line_transition label
--   LT_PRESETS    line_transition preset groups (bar_framework/presets/line_transition.lua), LT_CFG: options on top of them
--   STANCE, HOLD_STANCE, LATE_STANCE, INCOME_SWITCH, BURST_SWITCH, PLAN, MIX, SHARE, MATCH   the strategy (stances + game_plan / cap_switch / income_switch / income_mix hooks)
--   CON_HOLD_VALUE   a live ground raid worth this holds new air/T2 con orders; absent/false = no hold
--   SPINE, SPINE_CFG   the slot spine on/off and its overrides
--   the line/con/commander timings listed in M.DEFAULTS below
-- Not configurable yet: the strategy wiring assumes RAID_BOT's shape (cap_switch -> game_plan chain, income_mix weights); a
-- bot with another hook set (DRAGON_ECO's income_switch, the metal sink, the line-con hand-over) needs hooks added here.

local M = {}

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")   -- unit roles per faction (C4)
M.DEFAULTS = {
    MAX_CONS            = 3,         -- one per lane besides the commander's
    -- Con #n (n = 2, 3) is queued once CON_GAP[n] frames have passed since the previous con came out AND any of:
    CON_GAP             = { [2] = 20 * 30, [3] = 20 * 30 },
    CON_INCOME          = { [2] = 20, [3] = 30 },   -- metal income (m/s) that queues con #n
    CON_BANK_TRIGGER    = 130,       -- metal in the bank
    CON_FALLBACK_FRAMES = 45 * 30,   -- frames after the previous con came out (no other condition needed)
    CON1_RELEASE_WAIT   = 20 * 30,   -- frames con #1 may finish a starter item first
    EARLY_GRUNTS        = 2,         -- user 2026-10-26: an enemy unit / radar blip seen before EARLY_GRUNTS_BY: the starter bot lab makes this many Grunts first (0 = off)
    EARLY_GRUNTS_BY     = 4 * 60 * 30,
    EARLY_GRUNTS_MAX    = 8,         -- user 2026-10-26
    EARLY_GRUNT_RATIO   = 0.5,       -- Grunts worth this share of the enemy value seen (same as lab_rules' DEFENDER_ENEMY_RATIO)
    EARLY_BLIP_VALUE    = 50,        -- a radar blip with no unit type counts this much
    EARLY_GRUNT         = ROLES.Get("grunt"),
    CMDR_RADAR          = ROLES.Get("radar"), -- user 2026-10-26: the commander builds a radar beside the base once CMDR_RADAR_NANOS nanos stand (early warning); false = none
    CMDR_RADAR_NANOS    = 2,
    NANOS_HELPED        = 2,         -- the commander helps con #1 while it places nanos, until this many stand
    NANO_U              = 0.8,       -- both resources under this utilisation -> con #1 builds a nano
    WIND_U              = 1.0,       -- wind instead of mex only when energy utilisation is above this
    FLOAT_FRAC          = 0.25,      -- bank / storage that counts as floating...
    FLOAT_FRAMES        = 10 * 30,   -- ...when held this long
    LOG_EVERY           = 450,
    SPINE               = true,      -- vehicle lab + the spine (army); false = the economy-only bot
    STANCE              = "raid_open",     -- RAID_BOT: stances/<name>.lua, the opening game plan (raid)
    HOLD_STANCE         = "hold",          -- RAID_BOT: the game plan after bad trades (strategy_hooks.game_plan); nil = never
    LATE_STANCE         = "raid_late",     -- stance taken once the unit cap is filling (strategy_hooks.cap_switch): most value per unit slot; nil = never
    INCOME_SWITCH2      = nil,             -- a second, higher income switch { to, income, hold_s }: it wins over INCOME_SWITCH once it holds (T1 -> T2 -> a third stance)
    BURST_SWITCH        = nil,             -- { to, back, income = 250, hold_s = 20, spend, burst_s = 240, minute }: once income holds, stance `to` until `spend` metal went into the army (at most burst_s), then `back` for good (strategy_hooks.burst_switch; after the income switches in the chain)
    INCOME_SWITCH       = nil,             -- { to = "<stance>", income = 1100, hold_s = 20 }: take that stance once smoothed metal income holds (strategy_hooks.income_switch); e.g. a T1 stance -> a T2 stance
    PLAN                = {},              -- strategy_hooks.game_plan options (hold_ratio, trade_ratio, min_lost, ...)
    MIX                 = {},              -- strategy_hooks.income_mix options (lo, hi, mass_lo, ...)
    CON_HOLD_VALUE      = 800,             -- a live ground raid worth at least this holds new air/T2 con orders
    LATE_CAP_FRAC       = 0.75,        -- ... cap share at which it is taken (not before LATE_MINUTE)
    LATE_MINUTE         = 12,
    SHARE               = {},        -- strategy_hooks.v16_share / match_enemy options (start, floor, hold, ratio, ...)
    CAP_T1_FRAC         = 0.6,       -- user 2026-10-25: from this unit-cap fill the stances' T1 combat units are dropped (strategy.lua CapFiltered:
                                     -- room for Tigers / Demons / eco instead of hundreds of Grunts); false = never
    AIR_RUSH_SHARE      = 1.0,       -- user 2026-10-25: the army share while a large air raid is on (mb.airRaid.rush, unit_runtime): all of income
                                     -- into the AA the labs are rushing; false = no lift
    LINE_NANO_CAP       = nil,       -- { max = n, untilF = frame }: at most n nanos on the line before that frame (CORE_6K); nil = no cap
    LANE_MAX_K          = nil,       -- { [lane] = last column built } shrinks the line (CORE_6K); nil = the full line
    ESTOR_SLOTS         = 0,         -- user 2026-10-26: the last N slots of the commander lane's near row hold energy storage (line_crew LC.ESTOR_SLOTS); 0 = mex / wind as before
    HOME_DEFENCE        = true,      -- user 2026-10-26: nanos / cons reclaim enemy units in reach and nanos repair cons under attack (home_defence.lua); table = its options; false = off
    MATCH               = true,      -- army share follows the scouted enemy army (humans); false = plain v16_share for bot-vs-bot
    SPINE_CFG           = { FLOAT_MULT = 2.5 },   -- slot_spine overrides: while both banks float, plan nanos/labs for 2.5x income
    RECLAIM_STARTER_LAB = true,      -- reclaim the starter bot lab once the air lab is queued and the cons are out
    -- LINE_CLICK_v13: spine overrides (user: army floor 10%, and more responsive production)
    -- LINE_CLICK_v2 (2026-10-08): commander safety, bar_framework/commander_guard.lua.  In the first v2-vs-LINE_CLICK
    -- match an attack group dove into the base at 9:30, found the commander building its lane with 9 enemies near
    -- and few guards, and killed it at 9:39 (instant loss).  Once it is in its lane, the commander walks away from
    -- armed enemies (the crew gets it back when the area is quiet) and cloaks whenever energy allows.
    CMDR_EVADE          = true,
    CMDR_CLOAK          = false,     -- v3b: off (cloak rarely affordable, and it toggled in the opening)
    -- ...and once its lane is done, or from this frame on, it retires: leaves the line (game_mechanics 1.5: after the
    -- opening its 300 BP hardly matters) for a safe spot behind the base, where it builds a jammer and 2 AA turrets.
    CMDR_RETIRE_FRAME   = nil,       -- v3b: never retires (it defends the base; v3 lost 4.6k eco by 10:00)
    CMDR_DANGER_VALUE   = 1500,      -- v3b: evade only when armed enemy value near it is at least this (~12 gators)
    NAME                = "CORE",    -- the bot name in the [CFG] / [CFG-slot_spine] log rows and the line_transition label
    -- STANCE_ECO2's economy (user 2026-10-16: "eco2 has a good eco config, make that the default for CORE"; 7.6k m/s mean at 20:00 in 4 real vacuum
    -- games vs 4.2-5.6k for the RAID_BOT-style list this had): T2_TOPUP not T2_UP_FRONT, no second air lab; RECOVER kept (grid / line recovery
    -- is a background system every bot keeps).
    LT_PRESETS          = { "CONS_AT_BACK", "T2_TOPUP", "NO_IDLE", "RETROFIT", "AUDIT", "GRID_HELP", "ENERGY_PUSH", "ENERGY_CELLS", "RECOVER" },
                                 -- bar_framework/presets/line_transition.lua groups, in order
    -- ...and its options (eco_sim tune4 winner): NO nuke silos (SILO_GRIDS = {}: the eco scales much better without them), T2 lab capstones on the first
    -- 10 grids only, 14 fusion jobs at once.  A bot's own LT_CFG is added on top of these.
    LT_CFG              = { HELPER_CAP = 24, LAB2_FRAME = 12 * 60 * 30, LAB2_LATEST = 12 * 60 * 30,
                            SILO_GRIDS = {}, CAPSTONE_MAX = 10, EP_INFLIGHT = 14 },
    -- The metal sink (bar_framework/metal_sink.lua), the last stage of line -> grids -> spine -> sink.  Off by default.  On: when income reaches
    -- SINK_SPEND_FRAC of what the spine can spend, sink labs go up in front of the spine and make SINK_UNIT forever, helped by decoy commanders
    -- (the lab controller needs SINK = true too).  Any SINK_* key of metal_sink.lua's M.CFG may be set here (SINK_UNIT, SINK_MAX, SINK_FRONT ...).
    SINK                = false,
    -- Units the stances do not build but still want controlled (stance `extras`, added to every stance when SINK is on): the sink unit waits
    -- at the sink lab and raids in waves (behaviors/dragon_raid.lua, dragon_defend.lua).
    SINK_EXTRAS         = { { n = ROLES.Get("sink_unit"), behaviors = { "dragon_raid", "dragon_defend" }, cfg = { dragon_raid = { wave = 50 } } } },
}

-- Options whose default is nil on purpose (a key set to nil is "absent", so these are the only ones not in M.DEFAULTS).
M.NIL_OPTIONS = { MACHINE = true, MANUAL_STANCES = true, CMDR_RETIRE_FRAME = true, INCOME_SWITCH = true, INCOME_SWITCH2 = true, BURST_SWITCH = true }

function M.Install(widget, WG, K)
local CFG = {}
for k, v in pairs(M.DEFAULTS) do CFG[k] = v end
for k, v in pairs(K or {}) do
    CFG[k] = v
    if M.DEFAULTS[k] == nil and not M.NIL_OPTIONS[k] and not tostring(k):find("^SINK_") then      -- same warning bot_config.lua gives the framework modules
        Spring.Echo("[CFG] macro_runtime (" .. tostring(CFG.NAME) .. "): option '" .. tostring(k) .. "' is not in the defaults (typo, or default nil?)")
    end
end
-- macro_controller.lua  ─  LINE_BOT: build the line as fast as it can scale (COR)
--
-- RAID_BOT (2026-10-13): STANCE_BOT's macro with game plans.  Stances raid_open (initial), hold, raid_late; the switch hook
-- chains cap_switch (raid_late once the cap is 75% full) before strategy_hooks.game_plan (raid -> hold when behind and the
-- raids trade badly, back when ahead); income_mix tilts the hold comp from mass to quality with income.  line_transition's
-- CON_HOLD stops new air/T2 con orders while a ground raid is on the base (the air labs make Shurikens / Wasps).
--
-- One job: the commander places blueprints/general/line_com.lua (2 mex, winds, bot lab, first nano) without
-- walking, up to 3 con bots are added one at a time, and each builder works its own lane of the line
-- (bar_framework/line_crew.lua) until its 32 slots are done.  Nanos go in the nano column only when build
-- power is short.  No army, no grids, no transition: the [LN] log says when to add cons, how much the line
-- spends, and when metal / energy start to float (when a transition would pay).
--
-- Log lines (all "[LN]"): layout, con #N queued (reason, income, bank) / out, builder takes lane,
-- lane N DONE, FLOAT metal|energy onset, and a status row every 15 game-seconds.

local Spring = Spring

local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID     = Spring.GetMyTeamID

local CMD_GUARD = (CMD and CMD.GUARD) or 25
local CMD_STOP  = 0

local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")   -- typed WG access (bar_framework/wg_channels.lua)
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")   -- BC.Preset: named option groups for framework modules (bar_framework/presets/)

local START_FRAME = 15
local NET_SMOOTH  = 0.1


local BP_PLACER, LC, LT, BUILD_ORDER, GRID_BP, UPGRADE_BP, ECELL_BP
local CB, MS = nil, nil   -- bar_framework/con_broker.lua and metal_sink.lua (CFG.SINK only)
local HD = nil     -- bar_framework/home_defence.lua
local DC = nil     -- bar_framework/defense_crew.lua (LINE_CLICK_v16), nil if it failed to load
local CG = nil    -- bar_framework/commander_guard.lua (LINE_CLICK_v2), nil if it failed to load
local SPINE, SPINE_BPS = nil, {}     -- bar_framework/slot_spine.lua (STANCE_BOT: nano blocks + lab slots) and its blueprint
local STRAT, GS = nil, nil           -- bar_framework/strategy.lua (stance + hooks) and game_state.lua; published as WG.Strategy
local myTeamID, commanderID
local layout, distState, crew, trans
local startPending = false
local currentFrame = 0
local TS = {                 -- state, one table (Lua's local limit)
    pendingCons = {}, conBots = {}, conCount = 0, queuedCount = 0,
    conOrderOpen = false, lastConFrame = nil,
    cmdPhase = "starter", guardTarget = nil, guardFrame = 0,
    starterNanos = 0,
    smooth = {}, spent = 0,
    float = { metal = { since = nil, on = false, n = 0 }, energy = { since = nil, on = false, n = 0 } },
}

local function IsCommander(defID)
    local d = defID and UnitDefs[defID]
    if not d then return false end
    return d.customParams ~= nil
        and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
end

local function IsGroundCon(d)
    return d ~= nil and d.isBuilder and not d.canFly and not d.isFactory and d.speed and d.speed > 0
end

-- A con must be able to place a factory or a mex.  Without this the cheapest "builder" of the vehicle plant was the Trapper (cormlv,
-- 65 m, builds only mines) and the rez bot / spy in other labs: the line got a minelayer where its con bot should be.
local function BuildsEconomy(d)
    for _, o in ipairs(d.buildOptions or {}) do
        local od = UnitDefs[o]
        if od and (od.isFactory or (od.extractsMetal or 0) > 0) then return true end
    end
    return false
end

local function FindConBotDefID(labDefID)
    local d = UnitDefs[labDefID]
    if not d or not d.buildOptions then return nil end
    local best, bestCost = nil, math.huge
    for _, optID in ipairs(d.buildOptions) do
        local od = UnitDefs[optID]
        if IsGroundCon(od) and BuildsEconomy(od) and (od.metalCost or 999999) < bestCost then
            bestCost, best = od.metalCost or 999999, optID
        end
    end
    return best
end

local function Clock(frame)
    return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60)
end

local function StopGuard()
    if TS.guardTarget and commanderID and spGetUnitDefID(commanderID) then
        spGiveOrderToUnit(commanderID, CMD_STOP, {}, {})
    end
    TS.guardTarget = nil
end

local function Guard(targetID)
    if TS.guardTarget == targetID then return end
    spGiveOrderToUnit(commanderID, CMD_GUARD, { targetID }, {})
    TS.guardTarget = targetID
end

-- ── Start ────────────────────────────────────────────────────────────────────

local function StartBuildOrder()
    local cx, _, cz = spGetUnitPosition(commanderID)
    if not cx then return end
    LC.ESTOR_SLOTS = CFG.ESTOR_SLOTS or 0
    LC.LANE_MAX_K = CFG.LANE_MAX_K
    LC.NANO_CAP = CFG.LINE_NANO_CAP
    layout = LC.Layout(cx, cz, (Game and Game.mapSizeX) or 8192, (Game and Game.mapSizeZ) or 8192, BUILD_ORDER)
    startPending = true
end

-- RAID_BOT: no new air/T2 constructors while a ground raid worth CON_HOLD_VALUE is live on the base (raid record from the
-- unit controller, the same 10 s freshness the lab controller uses); the air labs build Shurikens / Wasps instead.
local function ConHold()
    local mb = WG and WG.MetalBot
    local raid = mb and mb.raid
    if not raid then return false end
    local f = Spring.GetGameFrame()
    return f - (raid.frame or -1e9) <= 300 and raid.channel == "ground" and (raid.ground or 0) >= CFG.CON_HOLD_VALUE
end

local function BeginBuildOrder()
    distState = BP_PLACER.NewDistributed(BUILD_ORDER, layout.anchorX, layout.anchorZ, layout.rot)
    BP_PLACER.EnableEscapeGuard(distState)
    BP_PLACER.AddBuilder(distState, commanderID)
    crew = LC.NewCrew{ BP = BP_PLACER, layout = layout,
                       onJobDone = function(j, state) if trans then LT.OnJobDone(trans, j, state) end end,
                       onJobStarted = function(j) if trans then LT.OnJobStarted(trans, j) end end }
    local ltOwn = {}
    for k, v in pairs(M.DEFAULTS.LT_CFG or {}) do ltOwn[k] = v end       -- the defaults first, the bot's own LT_CFG on top
    for k, v in pairs(CFG.LT_CFG or {}) do ltOwn[k] = v end
    if CFG.CON_HOLD_VALUE then ltOwn.CON_HOLD = ConHold end      -- nil value = no con hold (bots that never switch to a ground-raid answer)
    local ltArgs = { "line_transition" }
    for _, g in ipairs(CFG.LT_PRESETS) do ltArgs[#ltArgs + 1] = g end
    ltArgs[#ltArgs + 1] = ltOwn
    trans = LT.New{ BP = BP_PLACER, LC = LC, crew = crew, layout = layout, gridBP = GRID_BP, upgradeBP = UPGRADE_BP, ecellBP = ECELL_BP,
                    teamID = myTeamID, spine = SPINE, spineBPs = SPINE_BPS, WG = WG,
                    cfg = BC.Preset(unpack(ltArgs)), label = CFG.NAME }
    BP_PLACER.BALANCE_BP_U = CFG.NANO_U
    LC.WIND_U = CFG.WIND_U
    crew.reserved = { [2] = true }       -- the nano lane is con #1's, whenever it is released from the starter
    startPending = false
end

-- ── Resources ────────────────────────────────────────────────────────────────

local function Ema(key, v)
    local s = TS.smooth
    s[key] = s[key] and (s[key] + NET_SMOOTH * (v - s[key])) or v
    return s[key]
end

local function ReadResources()
    local _, m,  ms,  mp, mi, mx = pcall(Spring.GetTeamResources, myTeamID, "metal")
    local _, em, ems, ep, ei, ex = pcall(Spring.GetTeamResources, myTeamID, "energy")
    m, ms, mp, mi, mx = m or 0, ms or 1000, mp or 0, mi or 0, mx or 0
    em, ems, ep, ei, ex = em or 0, ems or 1000, ep or 0, ei or 0, ex or 0
    TS.spent = TS.spent + mx / 3            -- expense is per second; this runs every 10 frames
    return {
        metal = m, metalStorage = ms, energy = em, energyStorage = ems,
        metalIncome = mi, metalPull = mp, energyIncome = ei, energyPull = ep,
        metalIncomeS = Ema("mi", mi), metalPullS = Ema("mp", mp),
        energyIncomeS = Ema("ei", ei), energyPullS = Ema("ep", ep),
        metalExpense = mx, energyExpense = ex,
    }
end

-- "Floating": the bank sits above FLOAT_FRAC of storage for FLOAT_FRAMES.  Each onset is a hint that
-- the line can no longer use what it earns (a transition would pay).
local function CheckFloat(frame, res)
    for _, kind in ipairs({ "metal", "energy" }) do
        local f = TS.float[kind]
        local bank, store = res[kind], res[kind .. "Storage"]
        local over = store > 0 and bank / store >= CFG.FLOAT_FRAC
        if over then
            f.since = f.since or frame
            if not f.on and frame - f.since >= CFG.FLOAT_FRAMES then
                f.on, f.n = true, f.n + 1
                Spring.Echo(string.format(
                    "[LN] %s FLOAT %s onset #%d: bank %d / %d, income %.1f pull %.1f, cons %d, slots %d mex %d wind %d nano",
                    Clock(frame), kind, f.n, bank, store, res[kind .. "Income"], res[kind .. "Pull"],
                    #TS.conBots, crew.nMex, crew.nWind, crew.nNano))
            end
        else
            if f.on then Spring.Echo(string.format("[LN] %s FLOAT %s cleared", Clock(frame), kind)) end
            f.since, f.on = nil, false
        end
    end
end

local function LogStatus(frame, res)
    local t = LC.SampleBuilders(crew)
    local alive = 0
    for _, id in ipairs(TS.conBots) do if spGetUnitDefID(id) then alive = alive + 1 end end
    local starterBuilt = BP_PLACER.CountBuilt(distState, "mex") + BP_PLACER.CountBuilt(distState, "wind")
    Spring.Echo(string.format(
        "[LN] %s status: cons %d | metal inc %.1f pull %.1f bank %d (%.0f%%) | energy inc %.0f pull %.0f bank %d (%.0f%%) | spent~%d | nanos %d | %s | builders build/walk/idle %d/%d/%d (%s)",
        Clock(frame), alive, res.metalIncome, res.metalPull, res.metal, 100 * res.metal / math.max(res.metalStorage, 1),
        res.energyIncome, res.energyPull, res.energy, 100 * res.energy / math.max(res.energyStorage, 1),
        TS.spent, crew.nNano + TS.starterNanos, LC.LaneSummary(crew), t.build, t.walk, t.idle, LC.BuilderSummary(crew)))
    crew.samples = nil
end

-- ── Cons ─────────────────────────────────────────────────────────────────────

local function AliveCons()
    local n = 0
    for _, id in ipairs(TS.conBots) do if spGetUnitDefID(id) then n = n + 1 end end
    return n
end

local function FactoryBusy(fid)
    if not (fid and spGetUnitDefID(fid)) then return false end
    local cmds = Spring.GetFactoryCommands and Spring.GetFactoryCommands(fid, -1)
    return cmds ~= nil and #cmds > 0
end

-- Early defence (user 2026-10-26, from the _Opal_ game): the starter bot lab has Grunts ahead of its queue as soon as an enemy unit or a radar
-- blip is about, while the lab still stands.  Once per game.
local function EarlyGrunts(frame)
    if (CFG.EARLY_GRUNTS or 0) <= 0 or frame > CFG.EARLY_GRUNTS_BY or frame % 30 ~= 0 then return end
    local mb = WG and WG.MetalBot
    local intel = mb and mb.intel or {}
    local seenV = (intel.groundValue or 0) + (intel.airValue or 0)
    local seen = seenV > 0 or (mb and mb.threats and #mb.threats > 0)
    local hx, hz = mb and mb.homeX, mb and mb.homeZ
    if not hx and commanderID then hx, _, hz = spGetUnitPosition(commanderID) end
    if hx then
        -- enemy units / radar blips near the base, valued by their cost (a blip with no def counts EARLY_BLIP_VALUE)
        local ally, scanV = Spring.GetMyAllyTeamID(), 0
        for _, eid in ipairs(Spring.GetUnitsInCylinder(hx, hz, 2500) or {}) do
            if Spring.GetUnitAllyTeam(eid) ~= ally then
                local ed = spGetUnitDefID(eid)
                scanV = scanV + ((ed and UnitDefs[ed] and UnitDefs[ed].metalCost) or CFG.EARLY_BLIP_VALUE)
            end
        end
        if scanV > 0 then seen = true; seenV = math.max(seenV, scanV) end
    end
    if not seen then return end
    if trans then LT.NoteThreat(trans, frame) end      -- the vehicle lab makes Incisors first once it stands (line_transition VP_RUSH)
    local lab = TS.botLabID
    if not (lab and spGetUnitDefID(lab)) or Spring.GetUnitIsBeingBuilt(lab) then return end
    local gd = UnitDefNames and UnitDefNames[CFG.EARLY_GRUNT]
    if not gd then return end
    -- the vehicle plant stands: it makes Incisors from here (lab_rules' defender floor), no more Grunts
    local vp = trans and trans.vpID
    if vp and spGetUnitDefID(vp) and not Spring.GetUnitIsBeingBuilt(vp) then return end
    -- how many Grunts that is worth: EARLY_GRUNT_RATIO x the seen value, at least EARLY_GRUNTS, at most EARLY_GRUNTS_MAX; order the shortfall
    local cost = math.max(1, gd.metalCost or 55)
    local want = math.min(CFG.EARLY_GRUNTS_MAX, math.max(CFG.EARLY_GRUNTS, math.ceil(CFG.EARLY_GRUNT_RATIO * seenV / cost)))
    local alive = #(Spring.GetTeamUnitsByDefs and Spring.GetTeamUnitsByDefs(myTeamID, { gd.id }) or {})
    local have = alive + math.max(0, (TS.gruntsOrdered or 0) - (TS.gruntsFinished or 0))
    local need = want - have
    if need <= 0 then return end
    for _ = 1, need do LT.OrderCon(WG, lab, gd.id, frame, true) end
    TS.gruntsOrdered = (TS.gruntsOrdered or 0) + need
    Spring.Echo(string.format("[LN] %s enemy about (seen value %.0f): %d %s ordered ahead in the starter lab (want %d, have %d)",
        Clock(frame), seenV, need, CFG.EARLY_GRUNT, want, have))
end

-- One con at a time.  Reason is logged: the thresholds are what the test is for.
local function MaybeQueueNextCon(frame, res)
    if TS.conOrderOpen or not TS.lastConFrame or not TS.conDefID then return end
    if not (TS.botLabID and spGetUnitDefID(TS.botLabID)) then return end
    if TS.queuedCount >= CFG.MAX_CONS then return end
    local n = TS.queuedCount + 1                    -- the con about to be queued
    local since = frame - TS.lastConFrame
    if since < (CFG.CON_GAP[n] or 0) then return end
    local reason
    local need = CFG.CON_INCOME[n]
    if need and res.metalIncome >= need then reason = "income"
    elseif res.metal >= CFG.CON_BANK_TRIGGER then reason = "bank"
    elseif since >= CFG.CON_FALLBACK_FRAMES then reason = "timer" end
    if not reason then return end
    LT.OrderCon(WG, TS.botLabID, TS.conDefID, frame)
    TS.conOrderOpen = true
    TS.queuedCount = n
    Spring.Echo(string.format("[LN] %s con #%d queued (reason %s): income %.1f pull %.1f bank %d",
        Clock(frame), n, reason, res.metalIncome, res.metalPull, res.metal))
end

-- The starter bot lab has made its 3 cons: reclaim it (its metal pays for the vehicle lab).  Waits until the air lab
-- is queued (so the metal is wanted) and the lab's queue is empty; nanos in reach do the work (NANO.PRIO.CLEAR).
local function ReclaimStarterLab(frame)
    if not CFG.RECLAIM_STARTER_LAB or TS.labReclaimDone then return end
    local lab = TS.botLabID
    if not (lab and spGetUnitDefID(lab)) then TS.labReclaimDone = TS.labReclaimStart ~= nil; return end
    if not TS.labReclaimStart then
        if TS.conOrderOpen or TS.queuedCount < CFG.MAX_CONS or FactoryBusy(lab) then return end
        if not (trans and trans.labFrame) then return end           -- the air lab has not been queued yet
    end
    local NANO = BP_PLACER.NANO
    if not NANO then return end
    if TS.labReclaimStart and frame % 30 ~= 0 then return end
    local x, _, z = spGetUnitPosition(lab)
    if not x then return end
    local used = 0
    for _, n in ipairs(BP_PLACER.NanosInRange(x, z) or {}) do
        if NANO.Reclaim(NANO.PRIO.CLEAR, n, lab) then used = used + 1 end
    end
    if used > 0 and not TS.labReclaimStart then
        TS.labReclaimStart = frame
        Spring.Echo(string.format("[LN] %s starter lab reclaim: %d nano(s) on it", Clock(frame), used))
    end
end

-- Con #1 starts in the starter's queue (the commander cannot build its nano).  Once that nano stands it
-- takes the nano lane.
local function ReleaseCon1(frame)
    if TS.con1Released or not TS.con1ID then return end
    if not spGetUnitDefID(TS.con1ID) then
        TS.con1Released = true
        crew.reserved[2] = nil           -- con #1 died unreleased: the next con takes the nano lane
        return
    end
    if BP_PLACER.CountBuilt(distState, "nano") < 1 then return end
    if BP_PLACER.GetClaim(distState, TS.con1ID) ~= nil
       and frame - (TS.con1JoinFrame or frame) < CFG.CON1_RELEASE_WAIT then
        return
    end
    BP_PLACER.RemoveBuilder(distState, TS.con1ID)
    crew.reserved[2] = nil
    LC.AddCon(crew, TS.con1ID, 2, LC.LaneRoute(layout, 2))     -- round the west end of the starter, not past the commander
    TS.con1Released, TS.con1ReleaseFrame = true, frame
    TS.starterNanos = BP_PLACER.CountBuilt(distState, "nano")
end

-- ── Commander ────────────────────────────────────────────────────────────────

local function JoinLane(why)
    StopGuard()
    BP_PLACER.RemoveBuilder(distState, commanderID)
    LC.AddCommander(crew, commanderID)
    TS.cmdPhase = "lane"
    Spring.Echo(string.format("[LN] %s commander joins its lane (%s)", Clock(currentFrame), why))
end

-- Is con #1 placing a nano right now (the starter's, through the placer, or one from its lane)?
local function Con1BuildsNano()
    local id = TS.con1ID
    if not (id and spGetUnitDefID(id)) then return false end
    if not TS.con1Released then
        local claim = BP_PLACER.GetClaim(distState, id)
        return claim ~= nil and claim.cls == "nano"
    end
    local c = crew.cons[id]
    local s = c and c.target
    return s ~= nil and s.cls == "nano" and (s.state == "ordered" or s.state == "building")
end

-- Is any starter item left that the commander is going to place?  A claim, the order the placer has already
-- queued behind it (shiftNext: that item is "reserved" and so invisible to HasClaimable, which used to send the
-- commander to its lane right after the lab and skip the winds), or any unfinished item it can build.
-- Latest-frame cap so one stuck item cannot hold it forever.
local STARTER_MAX_FRAMES = 4 * 60 * 30
local function CommanderHasStarterWork(frame, res)
    if frame > STARTER_MAX_FRAMES then return false end
    if BP_PLACER.GetClaim(distState, commanderID) ~= nil then return true end
    if distState.shiftNext and distState.shiftNext[commanderID] then return true end
    if BP_PLACER.HasClaimable(distState, commanderID, frame, res) then return true end
    local def = spGetUnitDefID(commanderID)
    for _, it in ipairs(distState.queue) do
        if it.act ~= "reclaim" and it.status ~= "built" and it.status ~= "skipped"
           and (it.reservedBy == commanderID or (not it.claimedBy and BP_PLACER.CanBuild(def, it.defID))) then
            return true
        end
    end
    return false
end

-- The commander builds its own lane.  It only helps con #1 (guard) while con #1 is placing one of the first
-- NANOS_HELPED nanos, and goes back to its slots between items once they stand.
local function UpdateCommander(frame, res)
    if not commanderID or not spGetUnitDefID(commanderID) then commanderID = nil; return end
    if TS.cmdPhase == "starter" then
        if CommanderHasStarterWork(frame, res) then return end
        -- Starter placed.  If the bot lab is still on con #1, help it (guard the lab) before the lane.
        if not TS.con1ID and TS.botLabID and spGetUnitDefID(TS.botLabID) then
            StopGuard()
            Guard(TS.botLabID)
            TS.cmdPhase = "lab"
            Spring.Echo(string.format("[LN] %s starter placed, commander helps the lab with con #1", Clock(frame)))
            return
        end
        JoinLane("starter placed")
        return
    end
    if TS.cmdPhase == "lab" then
        if TS.con1ID or not (TS.botLabID and spGetUnitDefID(TS.botLabID)) then JoinLane("con #1 out") end
        return
    end
    local c = crew.cons[commanderID]
    if not c then return end
    local nanos = BP_PLACER.CountBuilt(distState, "nano") + crew.nNano
    if CFG.CMDR_RADAR and not TS.cmdRadarQueued and nanos >= CFG.CMDR_RADAR_NANOS and c.phase ~= "help" then
        local rd = UnitDefNames and UnitDefNames[CFG.CMDR_RADAR]
        local cx, _, cz = spGetUnitPosition(commanderID)
        if rd and cx then
            -- the nearest free spot (rings of 8 around the commander, 120 .. 480 elmos out)
            local site
            for r = 120, 480, 90 do
                for k = 0, 7 do
                    local a = k * math.pi / 4
                    local x, z = BP_PLACER.SnapToBuildGrid(rd.id, cx + r * math.cos(a), cz + r * math.sin(a), 0)
                    if Spring.TestBuildOrder(rd.id, x, Spring.GetGroundHeight(x, z) or 0, z, 0) ~= 0 then site = { x = x, z = z }; break end
                end
                if site then break end
            end
            if site then
                LC.QueueJob(crew, commanderID, { name = rd.name, x = site.x, z = site.z, f = 0, tag = "cmdradar" })
                TS.cmdRadarQueued = true
                Spring.Echo(string.format("[LN] %s commander builds a %s (nanos %d)", Clock(frame), rd.name, nanos))
            end
        end
    end
    if c.phase == "help" then
        if nanos >= CFG.NANOS_HELPED or not Con1BuildsNano() then
            StopGuard()
            c.phase, c.target = "idle", nil
            Spring.Echo(string.format("[LN] %s commander back to its lane (nanos %d)", Clock(frame), nanos))
        end
    elseif nanos < CFG.NANOS_HELPED and Con1BuildsNano() then
        -- The commander is nearly always mid-item (its crew starts the next one at once), so hold it: it
        -- finishes the item it is on, goes idle, and only then guards con #1.
        if c.phase == "idle" then
            c.hold = nil
            Guard(TS.con1ID)
            c.phase = "help"
            Spring.Echo(string.format("[LN] %s commander helps con #1 with a nano (nanos %d)", Clock(frame), nanos))
        else
            c.hold = true
        end
    else
        c.hold = nil
    end
end

-- LINE_CLICK_v2: once the commander is in its lane, commander_guard walks it away from armed enemies near it (the
-- crew is suspended meanwhile and takes it back when the area is quiet) and cloaks it whenever energy allows.
local function UpdateCommanderSafety(frame, res)
    if not (CG and crew and commanderID and TS.cmdPhase == "lane") then return end
    if not (CFG.CMDR_EVADE or CFG.CMDR_CLOAK) then return end
    local mb = WG and WG.MetalBot or {}
    local retire = CFG.CMDR_RETIRE_FRAME and mb.homeX ~= nil
                   and (frame >= CFG.CMDR_RETIRE_FRAME or (crew.lanesDone and crew.lanesDone[1] ~= nil))
    local state = CG.Update(frame, commanderID, res, {
        retire = retire, homeX = mb.homeX, homeZ = mb.homeZ, foeX = mb.foeX, foeZ = mb.foeZ,
        threats = CFG.CMDR_EVADE and mb.threats or nil, cloakAlways = CFG.CMDR_CLOAK })
    if state == "retired" and not TS.cmdRetired then
        TS.cmdRetired = frame
        LC.Release(crew, commanderID)          -- the line goes on without it
        TS.cmdEvading = nil
        Spring.Echo(string.format("[LN] %s commander leaves the line for its safe spot", Clock(frame)))
    end
    if not CFG.CMDR_EVADE or TS.cmdRetired then return end
    if state == "evading" and not TS.cmdEvading then
        TS.cmdEvading = frame
        LC.Suspend(crew, commanderID)
    elseif state ~= "evading" and TS.cmdEvading then
        Spring.Echo(string.format("[LN] %s commander back to its lane after evading for %ds", Clock(frame),
            math.floor((frame - TS.cmdEvading) / 30)))
        TS.cmdEvading = nil
        LC.Resume(crew, commanderID)
    end
end

-- ── Callbacks ────────────────────────────────────────────────────────────────

function widget:Initialize()
    local ok1, r1 = pcall(VFS.Include, "LuaUI/Widgets/blueprint_placer.lua")
    local ok2, r2 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/line_com.lua")
    local ok3, r3 = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/line_crew.lua")
    local ok4, r4 = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/line_transition.lua")
    local ok5, r5 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/mex_grid_alab.lua")
    if not ok1 then Spring.Echo("[LN] ERROR loading blueprint_placer: " .. tostring(r1)); return end
    if not ok2 then Spring.Echo("[LN] ERROR loading line_com: " .. tostring(r2)); return end
    if not ok3 then Spring.Echo("[LN] ERROR loading line_crew: " .. tostring(r3)); return end
    if not ok4 then Spring.Echo("[LN] ERROR loading line_transition: " .. tostring(r4)); return end
    if not ok5 then Spring.Echo("[LN] ERROR loading mex_grid_alab: " .. tostring(r5)); return end
    BP_PLACER, BUILD_ORDER, LC, LT, GRID_BP = r1, r2, r3, r4, r5
    local ok6, r6 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/upgrade.lua")
    if ok6 then UPGRADE_BP = r6 else Spring.Echo("[LN] no upgrade blueprint; retrofits disabled") end
    local ok6b, r6b = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/energy_cell.lua")
    if ok6b then ECELL_BP = r6b else Spring.Echo("[LN] no energy_cell blueprint; energy cells disabled") end
    -- The spine (TILE_BOT's unit production).  If any of it fails to load the bot still plays, economy only.
    if CFG.SPINE then
        local okS, rS = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/slot_spine.lua")
        if okS and rS then
            local all = true
            for kind, file in pairs(rS.BLUEPRINT) do
                local okB, rB = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/" .. file .. ".lua")
                if okB and rB then SPINE_BPS[kind] = rB
                else all = false; Spring.Echo("[LN] ERROR loading spine blueprint " .. file .. ": " .. tostring(rB)) end
            end
            if all then SPINE = rS else Spring.Echo("[LN] spine disabled: blueprint missing") end
            if SPINE and CFG.SPINE_CFG then
                BC.Apply("slot_spine", SPINE.CFG, CFG.SPINE_CFG, CFG.NAME)
            end
        else
            Spring.Echo("[LN] ERROR loading spine: " .. tostring(rS))
        end
    end
    -- STANCE_BOT: the strategy.  The stance says what the spine's labs build and how the units are controlled; the
    -- hooks decide at run time how much of income goes to army (here the same rule v16's spine policies used).
    if SPINE then
        local okT, ST = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/strategy.lua")
        local okG, G  = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/game_state.lua")
        local okH, H  = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/strategy_hooks.lua")
        if okT and okG and okH and ST and G and H then
            GS = G
            -- MACHINE (state machines, machines/<name>.lua, edited in machine_editor.html): its stance machine replaces the switch chain
            -- below and its share machine replaces the share rule (a machine without one leaves that part as it is).  Falls back to
            -- the options below when the file does not load or fails its checks.
            local BUNDLE
            if CFG.MACHINE then
                local okF, FSMod = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/fsm.lua")
                local spec, err
                if okF and FSMod then spec, err = FSMod.Load(CFG.MACHINE) else err = FSMod end
                if spec then
                    local hookFac = { match_enemy = H.match_enemy, v16_share = H.v16_share }
                    local probs = FSMod.Validate(spec, { hookFactories = hookFac, stanceExists = function(n)
                        local okL, L = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/stance_loader.lua")
                        return okL and L and L.Load(n) ~= nil
                    end })
                    if #probs == 0 then
                        BUNDLE = FSMod.Bundle(spec, { hookFactories = hookFac, log = Spring.Echo })
                        Spring.Echo("[FSM] machine '" .. tostring(CFG.MACHINE) .. "' loaded (" .. (spec.stance_machine and "stance" or "-") .. (spec.share_machine and " + share" or "") .. ")")
                    else
                        for _, pr in ipairs(probs) do Spring.Echo("[FSM] ERROR " .. pr) end
                        Spring.Echo("[FSM] machine '" .. tostring(CFG.MACHINE) .. "' rejected; using the CFG switch options")
                    end
                else
                    Spring.Echo("[FSM] machine '" .. tostring(CFG.MACHINE) .. "' did not load: " .. tostring(err) .. "; using the CFG switch options")
                end
            end
            -- RAID_BOT: cap_switch first (once on it holds for the game), then the game plan
            local function StanceList()           -- the stances to load (a stance switched off with false is not loaded)
                local out = {}
                for _, n in ipairs({ CFG.STANCE, CFG.HOLD_STANCE, CFG.LATE_STANCE, CFG.INCOME_SWITCH and CFG.INCOME_SWITCH.to or false, CFG.INCOME_SWITCH2 and CFG.INCOME_SWITCH2.to or false,
                                     CFG.BURST_SWITCH and CFG.BURST_SWITCH.to or false, CFG.BURST_SWITCH and CFG.BURST_SWITCH.back or false }) do
                    if n then out[#out + 1] = n end
                end
                if BUNDLE and BUNDLE.stanceMachine then
                    out = {}
                    for _, n in ipairs(BUNDLE.StanceNames()) do out[#out + 1] = n end
                end
                for _, n in ipairs(CFG.MANUAL_STANCES or {}) do          -- MANUAL_STANCES: the buttons' choices (stance_panel.lua)
                    local dup = false
                    for _, m in ipairs(out) do if m == n then dup = true end end
                    if not dup then out[#out + 1] = n end
                end
                return out
            end
            local switches = {}
            if CFG.LATE_STANCE then
                switches[#switches + 1] = H.cap_switch{ late = CFG.LATE_STANCE, cap_frac = CFG.LATE_CAP_FRAC, minute = CFG.LATE_MINUTE }
            end
            if CFG.INCOME_SWITCH2 then                 -- before INCOME_SWITCH: once it holds it wins
                switches[#switches + 1] = H.income_switch(CFG.INCOME_SWITCH2)
            end
            if CFG.INCOME_SWITCH then
                switches[#switches + 1] = H.income_switch(CFG.INCOME_SWITCH)
            end
            if CFG.BURST_SWITCH then                   -- after the income switches (they win once they hold), before the game plan (it always names one)
                switches[#switches + 1] = H.burst_switch(CFG.BURST_SWITCH)
            end
            if CFG.HOLD_STANCE then
                local po = { raid = CFG.STANCE, hold = CFG.HOLD_STANCE }
                for k, v in pairs(CFG.PLAN or {}) do po[k] = v end
                switches[#switches + 1] = H.game_plan(po)
            end
            if BUNDLE and BUNDLE.stanceMachine then switches = { BUNDLE.switch } end
            if CFG.MANUAL_STANCES then
                -- a person picks the stance (stance_panel.lua writes WG.StanceRequest); no automatic switch runs
                switches = { function() local r = WG and WG.StanceRequest; if r and r ~= (STRAT and STRAT:Name()) then return r end end }
            end
            STRAT = ST.New{
                stances = StanceList(), initial = (BUNDLE and BUNDLE.stanceMachine and BUNDLE.InitialStance()) or CFG.STANCE, capFilter = CFG.CAP_T1_FRAC or nil,
                -- MATCH: keep our army value up with the scouted enemy's (for games against people; two bots would chase
                -- each other's share, so bot-vs-bot tests set CFG.MATCH = false)
                hooks = { army_share = (function(base0)
                              -- a large air raid: the share goes to AIR_RUSH_SHARE while it lasts (the labs clear their queues for AA)
                              local base = base0
                              if CFG.AIR_RUSH_SHARE then
                                  base = function(state, strat)
                                      local ar = WG and WG.MetalBot and WG.MetalBot.airRaid
                                      if ar and ar.rush then return CFG.AIR_RUSH_SHARE end
                                      return base0(state, strat)
                                  end
                              end
                              if not CFG.MANUAL_STANCES then return base end
                              -- a person sets the share (stance_panel.lua writes WG.ArmyShareRequest, 0..1; nil = automatic)
                              return function(state, strat)
                                  local r = WG and tonumber(WG.ArmyShareRequest)
                                  if r then return r end
                                  return base(state, strat)
                              end
                          end)((BUNDLE and BUNDLE.shareMachine) and BUNDLE.army_share or (CFG.MATCH and H.match_enemy or H.v16_share)(CFG.SHARE)),
                          switch = (#switches > 0) and H.chain_switch(switches) or nil,
                          weights = H.income_mix(CFG.MIX) },
            }
            if STRAT:Stance() and CFG.SINK then
                for _, st in pairs(STRAT.stances) do
                    for _, e in ipairs(CFG.SINK_EXTRAS or {}) do
                        local ud = UnitDefNames[e.n]
                        if ud and not st.extraByDef[ud.id] then
                            local rec = { n = e.n, defID = ud.id, behaviors = e.behaviors, cfg = e.cfg }
                            st.extras[#st.extras + 1], st.extraByDef[ud.id] = rec, rec
                        end
                    end
                end
            end
            if STRAT:Stance() then
                STRAT:InstallSlotSpine(SPINE)
                CH.Publish(WG, "Strategy", STRAT)
                if CFG.MANUAL_STANCES and WG then WG.StanceChoices = CFG.MANUAL_STANCES end
            else
                STRAT = nil
                Spring.Echo("[STANCE] stance " .. tostring(CFG.STANCE) .. " did not load; the spine has no army")
            end
        else
            Spring.Echo("[STANCE] strategy modules failed to load: " .. tostring(ST) .. " " .. tostring(G) .. " " .. tostring(H))
        end
    end
    -- Labs the lab controller must leave alone: the air lab while it owes air cons, and the starter bot lab
    -- (it only makes the 3 cons, then is reclaimed).
    if WG then
        CH.Publish(WG, "TileLabHold", function(labID)
            if labID == nil then return false end
            if trans and labID == trans.airLabID and trans.airConsOrdered > 0 then return true end
            return labID == TS.botLabID
        end)
    end
    for _, u in ipairs(BUILD_ORDER.layout) do
        local ud = UnitDefNames[u.n]
        if ud and ud.isFactory and not TS.botLabName then TS.botLabName = u.n end
    end
    myTeamID = spGetMyTeamID()
    if CFG.CMDR_EVADE or CFG.CMDR_CLOAK then
        local okG, rG = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/commander_guard.lua")
        local okQ, rQ = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/unit_query.lua")
        if okG and rG and okQ and rQ then
            CG = rG
            CG.Init{ UQ = rQ, teamID = myTeamID, allyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID() }
            if CFG.CMDR_DANGER_VALUE then CG.DANGER_VALUE = CFG.CMDR_DANGER_VALUE end
            local cd = UnitDefNames and UnitDefNames["corcom"]
            if cd then
                Spring.Echo(string.format("[LN] corcom: speed %s hp %s canCloak %s cloakCost %s moving %s decloakDistance %s",
                    tostring(cd.speed), tostring(cd.health), tostring(cd.canCloak), tostring(cd.cloakCost),
                    tostring(cd.cloakCostMoving), tostring(cd.decloakDistance)))
            end
        else
            Spring.Echo("[LN] ERROR loading commander_guard / unit_query: " .. tostring(rG) .. " " .. tostring(rQ))
        end
    end
    if CFG.SINK then
        local okC, rC = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/con_broker.lua")
        if okC and rC then CB = rC else Spring.Echo("[SINK] ERROR loading con_broker: " .. tostring(rC)) end
        local okL, rL = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/metal_sink.lua")
        if okL and rL and CB then
            MS = rL
            MS.Init{ cfg = CFG, CB = CB, SPINE = function() return SPINE end, trans = function() return trans end,
                     teamID = myTeamID, Clock = Clock,
                     Capacity = function() return SPINE and SPINE.SpendCapacity and (SPINE.SpendCapacity()) or nil end,
                     BorrowCon = function(defID) return trans and trans.CB and (CB.TakeAny(trans.CB, "sinklab", { defID = defID, kind = "ground" })) or nil end,
                     GiveBackCon = function(uid) if trans and trans.CB then CB.GiveBack(trans.CB, uid, "sinklab") end end }
        else
            Spring.Echo("[SINK] ERROR loading metal_sink: " .. tostring(rL))
        end
    end
    if CFG.HOME_DEFENCE then
        local okH, rH = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/home_defence.lua")
        local okQ2, rQ2 = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/unit_query.lua")
        if okH and rH and okQ2 and rQ2 and BP_PLACER and BP_PLACER.NANO then
            HD = rH
            HD.Init{ teamID = myTeamID, allyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID(), NANO = BP_PLACER.NANO, UQ = rQ2,
                     cfg = type(CFG.HOME_DEFENCE) == "table" and CFG.HOME_DEFENCE or nil }
        else
            Spring.Echo("[HD] ERROR loading home_defence: " .. tostring(rH) .. " " .. tostring(rQ2))
        end
    end
    -- LINE_CLICK_v16: flak when bombers come, anti-nuke, silos (bar_framework/defense_crew.lua).
    local okD, rD = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/defense_crew.lua")
    if okD and rD then
        DC = rD
        -- cover / assist cons come from the con broker (trans exists only once the build order starts, so it is looked up per call)
        local function Pool() return trans and LT.ConPool(trans) end
        DC.Init{ teamID = myTeamID, WG = WG, pool = {
            Usable  = function(id) local p = Pool(); return not p or p.Usable(id) end,
            Seize   = function(id, owner) local p = Pool(); return not p or p.Seize(id, owner) end,
            Release = function(id) local p = Pool(); if p then p.Release(id) end end } }
        DC.BUILD_AA, DC.BUILD_ANTINUKE = false, false   -- loose flak / anti-nukes removed for now; anti-nukes are grid capstones
        DC.SILO_INCOME, DC.SILO_SECOND = 1e12, 1e12     -- silos are grid capstones (line_transition SILO_GRIDS), not loose sites
    else
        Spring.Echo("[LN] ERROR loading defense_crew: " .. tostring(rD))
    end
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        if IsCommander(spGetUnitDefID(uid)) then commanderID = uid; break end
    end
    if commanderID then StartBuildOrder() end
end

function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if not myTeamID then myTeamID = spGetMyTeamID() end
    if teamID ~= myTeamID then return end
    if distState then BP_PLACER.OnUnitCreated(distState, unitID, unitDefID, builderID) end
    if crew then LC.OnUnitCreated(crew, unitID, unitDefID, builderID) end
    if MS then MS.OnCreated(unitID, unitDefID, builderID, currentFrame) end
    if trans then LT.OnUnitCreated(trans, unitID, unitDefID, builderID) end
    local d = UnitDefs[unitDefID]
    if not d then return end
    if d.isFactory then
        if trans and trans.labDefID == unitDefID and trans.phase == "lab" then return end   -- the transition's air lab
        -- Only the FIRST corlab is the starter lab.  After it is reclaimed the spine cell's corlab is a second one: it
        -- was taken for the starter lab, and its cons were counted as line cons.
        if not TS.botLabID and not TS.botLabSeen and d.name == TS.botLabName then
            TS.botLabID, TS.botLabSeen = unitID, true
        end
        return
    end
    if builderID and builderID == TS.botLabID and unitDefID == TS.conDefID then
        TS.pendingCons[unitID] = true
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID == myTeamID and UnitDefNames and UnitDefNames[CFG.EARLY_GRUNT] and unitDefID == UnitDefNames[CFG.EARLY_GRUNT].id then
        TS.gruntsFinished = (TS.gruntsFinished or 0) + 1
    end
    if teamID ~= myTeamID then return end
    if MS then MS.OnFinished(unitID, currentFrame) end
    if IsCommander(unitDefID) and not commanderID then
        commanderID = unitID
        StartBuildOrder()
    end
    if unitID == TS.botLabID then
        TS.conDefID = FindConBotDefID(unitDefID)
        if TS.conDefID then
            LT.OrderCon(WG, TS.botLabID, TS.conDefID, currentFrame)       -- through the lab broker when the bot has one
            TS.conOrderOpen, TS.queuedCount = true, 1
            local cd = UnitDefs[TS.conDefID]
            Spring.Echo(string.format("[LN] %s lab finished, con #1 queued (%s, buildDistance %s, cost %s)",
                Clock(currentFrame), cd.name, tostring(cd.buildDistance), tostring(cd.metalCost)))
        end
    end
    if TS.pendingCons[unitID] then
        TS.pendingCons[unitID] = nil
        TS.conCount = TS.conCount + 1
        TS.conBots[#TS.conBots + 1] = unitID
        TS.conOrderOpen, TS.lastConFrame = false, currentFrame
        if trans then LT.AdoptCon(trans, unitID, "line") end      -- the line's cons are the line's: not for defense_crew or the jobs
        if not TS.con1ID then
            TS.con1ID, TS.con1JoinFrame = unitID, currentFrame
            BP_PLACER.AddBuilder(distState, unitID)           -- builds the starter's nano
        elseif crew then
            LC.AddCon(crew, unitID)
        end
        Spring.Echo(string.format("[LN] %s con #%d out (%d)", Clock(currentFrame), TS.conCount, unitID))
    end
    local x, _, z = spGetUnitPosition(unitID)
    if distState then BP_PLACER.OnUnitFinished(distState, unitID, unitDefID, x, z) end
    if crew then LC.OnUnitFinished(crew, unitID, unitDefID) end
    if trans then LT.OnUnitFinished(trans, unitID, unitDefID, x, z) end
end

function widget:UnitFromFactory(unitID, unitDefID, teamID, factID)
    if teamID == myTeamID and trans then LT.OnUnitFromFactory(trans, unitID, unitDefID, factID) end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID, attackerDefID)
    if teamID ~= myTeamID then return end
    if MS then MS.OnDestroyed(unitID, attackerID, attackerDefID, currentFrame) end
    if distState then BP_PLACER.OnUnitDestroyed(distState, unitID) end
    if crew then LC.OnUnitDestroyed(crew, unitID) end
    if trans then LT.OnUnitDestroyed(trans, unitID, CFG.SINK and attackerID or nil) end   -- the killer reaches the spine only with the sink on (as DRAGON_ECO)
    TS.pendingCons[unitID] = nil
    if unitID == commanderID then commanderID = nil end
    if unitID == TS.botLabID then TS.botLabID = nil end
    if unitID == TS.guardTarget then TS.guardTarget = nil end
end

function widget:GameFrame(frame)
    currentFrame = frame
    if not myTeamID or not BP_PLACER then return end
    if startPending and frame >= START_FRAME then BeginBuildOrder() end
    if not distState or frame % 10 ~= 0 then return end

    local res = ReadResources()
    MaybeQueueNextCon(frame, res)
    ReclaimStarterLab(frame)
    EarlyGrunts(frame)
    ReleaseCon1(frame)
    if TS.cmdEvading == nil then UpdateCommander(frame, res) end
    if frame % 30 == 0 then UpdateCommanderSafety(frame, res) end
    LC.Update(crew, frame, res)
    CheckFloat(frame, res)
    if BP_PLACER.NANO and BP_PLACER.NANO.Sweep then BP_PLACER.NANO.Sweep() end
    if HD then
        local okHD, errHD = pcall(HD.Update, frame)
        if not okHD then Spring.Echo("[HD] error: " .. tostring(errHD)) end
    end
    if STRAT and frame % 30 == 0 then
        STRAT:Tick(frame, GS.Collect(frame, { team = myTeamID, Spine = SPINE, MB = WG and WG.MetalBot }))
        -- the labs are rushing units out (an urgent raid on us, or a large air raid): the spine's nanos go to the labs at high priority
        if SPINE and SPINE.SetRush then
            local mb = WG and WG.MetalBot
            SPINE.SetRush(mb ~= nil and (mb.urgency == "rush" or (mb.airRaid ~= nil and mb.airRaid.rush == true)))
        end
    end
    LT.Update(trans, frame, res)
    if MS then
        local okL, errL = pcall(MS.Update, frame, res)
        if not okL then Spring.Echo("[SINK] error: " .. tostring(errL)) end
    end
    if DC then
        local okU, errU = pcall(DC.Update, frame, WG and WG.MetalBot)
        if not okU then Spring.Echo("[DC] error: " .. tostring(errU)) end
    end
    if frame % CFG.LOG_EVERY == 0 then
        LogStatus(frame, res)
        Spring.Echo("[LT] " .. Clock(frame) .. " " .. LT.Status(trans))
    end
    if not distState.done then BP_PLACER.Update(distState, frame, res) end
end
end

return M
