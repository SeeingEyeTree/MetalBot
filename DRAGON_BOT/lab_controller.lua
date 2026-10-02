-- lab_controller.lua  ─  Factory queue manager
-- Priority per idle lab: an outmatched threat first, then scouts, then the defence
-- floor (fighters, vehicle defenders), then army -- the last only out of surplus
-- metal.  BLACKLIST units are never built by any lab.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID       = Spring.GetUnitDefID
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spGetMyTeamID        = Spring.GetMyTeamID
local spGetFactoryCommands = Spring.GetFactoryCommands
local spGetUnitCommands    = Spring.GetUnitCommands
local spGetTeamResources   = Spring.GetTeamResources

local DEBUG = false  -- set true to enable verbose logging

local SCOUT_TARGET = 2

-- Army composition, kept deliberately simple.  Internal names, checked against the
-- BAR unit defs: human names are ambiguous ("Dragon" also matches Dragonslayer,
-- Dragon's Claw and Archaic Dragon).  Each lab resolves only what IT can build:
--   corap  (T1 air, the hand-off lab) -> Shuriken
--   coraap (T2 air, one per mex grid) -> Wasp, and Dragon while metal is floating
-- What resolved is echoed once per lab, so a miss is visible rather than silent.
local ARMY_PICKS = {
    cheap    = {"corbw"},     -- Shuriken
    main     = {"corape"},    -- Wasp
    floating = {"corcrwh"},   -- Dragon
    -- Dedicated air-to-air.  corveng reads aaOnly=true (hits air, cannot hit ground),
    -- which is the only kind of answer a bomber raid actually respects.
    fighter  = {"corveng"},
    -- corvp.  corgator (speed 85) and corraid (72) are fast enough to RESPOND to a
    -- raid; corwolv/cormist are longer-ranged but too slow to chase anything.
    vcheap   = {"corgator"},
    vmain    = {"corraid"},
}
-- Army beyond the defence floor is paid for out of surplus only: the macro is
-- exponential and the army's job is to buy it time, not to compete with it.
local FLOAT_FRAC     = 0.40   -- metal at this share of storage counts as floating
local FLOAT_HEAVY    = 0.60   -- and at this share, build the expensive unit
local FLOAT_SURPLUS  = 15     -- or income exceeding pull by this much (m/s): storage
                              -- can be large enough that the fraction never trips
-- The defence floor: built whether or not metal is floating, because it has to
-- exist BEFORE the raid, not in response to it.
local FIGHTER_TARGET  = 3
local DEFENDER_TARGET = 4

function widget:GetInfo()
    return {
        name    = "Lab Controller",
        desc    = "Queue-based lab manager with blacklist and per-lab build orders",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── Configuration ─────────────────────────────────────────────────────────────

-- Units that should never be built by any lab.
local BLACKLIST = {
    cortitan = true,
    corsala  = true,
    corarrow = true,
    corvroc  = true,
    cortrem  = true,
    corstorm = true,
    corsok   = true,
    corkarg  = true,
}

-- ── State ─────────────────────────────────────────────────────────────────────

local myTeamID     = nil
local labs         = {}   -- [labID] = labDefID
local scoutCount   = 0
local myScouts     = {}   -- [unitID] = true
local myFighters   = {}   -- [unitID] = true
-- What this widget has asked for, tracked here rather than read back from factory
-- queues.  Counting only finished (or even started) units left a blind window
-- between ORDERING a unit and its production starting -- minutes long during the
-- economy's deliberate stall -- in which every tick saw the shortfall again and
-- ordered another.  Scouts ordered at 5:40 finished at 7:52; five were queued.
local building = {}       -- [unitID] = kind: started in a lab, not finished
local ordered  = {}       -- { {defID, kind, frame}, ... } ordered, not yet started
local ORDER_TTL = 3600    -- frames before an order that never started is written off
local labPending   = {}   -- [labID] = frame a defence unit was put ahead of its queue
-- Frames to leave a lab alone after ordering it.  Reading a factory's queue back
-- (GetFactoryCommands) lags on the CLIENT process -- the documented host/client
-- asymmetry (game_mechanics 2.7) that forced the macro's ORDER_GRACE_FRAMES to 90.
-- Without this, team 1 saw its just-ordered queue as still empty and re-ordered every
-- tick: five scouts in eight seconds, both labs idle at 5:00, and no fighter up
-- before the bombers.  Slightly above the macro's 90 because this gap looked longer.
local LAB_ORDER_GRACE = 120
local labOrderFrame  = {}   -- [labID] = frame this widget last ordered it
local myDefenders  = {}   -- [unitID] = true

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsScoutDef(d)
    if not d then return false end
    local mc = d.modCategories
    if mc then
        for k in pairs(mc) do
            if string.find(k, "scout") then return true end
        end
    end
    local cat = d.category
    if type(cat) == "string" and string.find(string.lower(cat), "scout") then return true end
    local name  = string.lower(d.name or "")
    local hName = string.lower((d.translatedHumanName or d.humanName) or "")
    if string.find(name,  "scout")   or string.find(hName, "scout")
    or string.find(name,  "peep")    or string.find(name,  "flea")
    or string.find(name,  "fink")    or string.find(name,  "phantom")
    or string.find(name,  "weasel")  or string.find(name,  "wheelie") then
        return true
    end
    return d.speed and d.speed > 150 and (not d.weapons or #d.weapons == 0)
end

-- Shared classifier, so "is this a fighter" means the same thing here as it does in
-- the unit controller and the stats tracker.  Loaded in Initialize.
local UQ = nil

-- Real air cover: flies, hits air, cannot hit ground.  Anything merely air-capable
-- does not count -- almost every weapon reads as air-capable unless it says otherwise.
local function IsFighterDef(defID)
    return UQ ~= nil and UQ.is_air(defID) and UQ.is_dedicated_aa(defID)
end

-- A ground unit that can fight: what the vehicle plant is for.
local function IsDefenderDef(d)
    return UQ ~= nil and d ~= nil and (d.speed or 0) > 0 and not d.canFly
       and not d.isBuilder and not d.isFactory and UQ.has_weapons(d.id)
       and not UQ.is_commander(d.id)
end

local function KindOf(defID)
    local d = defID and UnitDefs[defID]
    if not d or d.isFactory then return nil end
    if IsScoutDef(d) then return "scout" end
    if IsFighterDef(defID) then return "fighter" end
    if IsDefenderDef(d) then return "defender" end
    return nil
end

local function NoteOrder(defID, frame)
    local kind = KindOf(defID)
    if kind then ordered[#ordered + 1] = { defID = defID, kind = kind, frame = frame } end
end

local armyCache = {}    -- [labDefID] = {cheap=defID, main=defID, floating=defID} or false
local armyFlip  = {}    -- [labID] = alternates cheap/main

local function MatchesName(od, wanted)
    local internal = string.lower(od.name or "")
    local human    = string.lower(od.translatedHumanName or od.humanName or "")
    for _, w in ipairs(wanted) do
        w = string.lower(w)
        if internal == w then return true end
        -- Fall back to the display name only if the internal name is not an exact
        -- match, so a rename does not silently disarm this.
        if human ~= "" and human == w then return true end
    end
    return false
end

-- Resolve ARMY_PICKS against what this lab can actually build.
local function GetArmyPicks(labDefID)
    if armyCache[labDefID] ~= nil then return armyCache[labDefID] end
    local d = UnitDefs[labDefID]
    local picks, found = {}, false
    if d and d.buildOptions then
        for _, optID in ipairs(d.buildOptions) do
            local od = UnitDefs[optID]
            if od and od.speed and od.speed > 0 and not od.isBuilder and not od.isFactory then
                for role, names in pairs(ARMY_PICKS) do
                    if not picks[role] and MatchesName(od, names) then
                        picks[role] = optID
                        found = true
                    end
                end
            end
        end
    end
    if found then
        local parts = {}
        for role, defID in pairs(picks) do
            parts[#parts + 1] = role .. "=" .. (UnitDefs[defID] and UnitDefs[defID].name or "?")
        end
        Spring.Echo("[LabCtrl] " .. (d and d.name or "?") .. " army picks: "
                    .. table.concat(parts, " "))
    end
    armyCache[labDefID] = found and picks or false
    return armyCache[labDefID]
end

local buildCache = {}   -- [labDefID] = { scouts={defID,...}, mobile={defID,...} }

local function GetBuildCache(labDefID)
    if buildCache[labDefID] then return buildCache[labDefID] end
    local d     = UnitDefs[labDefID]
    local cache = { scouts = {}, mobile = {} }
    if d and d.buildOptions then
        for _, optID in ipairs(d.buildOptions) do
            local od = UnitDefs[optID]
            if od and od.speed and od.speed > 0
               and not od.isBuilder and not od.isFactory
               and not BLACKLIST[od.name] then
                if IsScoutDef(od) then
                    cache.scouts[#cache.scouts + 1] = optID
                elseif od.weapons and #od.weapons > 0 then
                    cache.mobile[#cache.mobile + 1] = optID
                end
            end
        end
    end
    buildCache[labDefID] = cache
    return cache
end

local function QueueEmpty(labID)
    if spGetFactoryCommands then
        local cmds = spGetFactoryCommands(labID, -1)
        return not cmds or #cmds == 0
    end
    local cmds = spGetUnitCommands(labID, -1)
    return not cmds or #cmds == 0
end

-- Put a unit NEXT in a lab's queue, ahead of whatever is waiting.  The macro keeps
-- the air lab's queue full of air constructors for the grid system, and this widget
-- used to act only when a queue was empty -- so from the weaker slot the air lab
-- never had a gap, no fighter was ever built, and bombers killed the commander at
-- 6:15.  Pattern copied from BAR's own unit_factory_quota.lua.  Position 1 (after
-- the unit currently being built) rather than 0: 0 cancels the build in progress,
-- and throwing away a half-built constructor is a pure loss.
local CMD_INSERT       = CMD and CMD.INSERT
local CMD_OPT_ALT      = (CMD and CMD.OPT_ALT) or 128
local CMD_OPT_CTRL     = (CMD and CMD.OPT_CTRL) or 64
local CMD_OPT_INTERNAL = (CMD and CMD.OPT_INTERNAL) or 8
local PENDING_TIMEOUT  = 600   -- frames before an insert that never started is retried

local function InsertNext(labID, defID)
    if not CMD_INSERT then
        spGiveOrderToUnit(labID, -defID, {}, {})
        return
    end
    local _, busyTarget = Spring.GetUnitWorkerTask(labID)
    local pos = busyTarget and 1 or 0
    spGiveOrderToUnit(labID, CMD_INSERT,
        { pos, -defID, CMD_OPT_ALT + CMD_OPT_INTERNAL }, CMD_OPT_ALT + CMD_OPT_CTRL)
end

local function CheapestScout(scouts)
    local best, bestCost = nil, math.huge
    for _, optID in ipairs(scouts) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        if cost < bestCost then bestCost = cost; best = optID end
    end
    return best
end

local function PickUnit(options, metalCur)
    local CAP = 500
    local totalWeight, affordable = 0, {}
    for _, optID in ipairs(options) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        if cost <= metalCur then
            affordable[#affordable + 1] = optID
            totalWeight = totalWeight + math.sqrt(math.min(cost, CAP) + 1)
        end
    end
    if #affordable == 0 then
        local cheapest, cheapestCost = nil, math.huge
        for _, optID in ipairs(options) do
            local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
            if cost < cheapestCost then cheapestCost = cost; cheapest = optID end
        end
        return cheapest
    end
    local roll = math.random() * totalWeight
    for _, optID in ipairs(affordable) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        roll = roll - math.sqrt(math.min(cost, CAP) + 1)
        if roll <= 0 then return optID end
    end
    return affordable[#affordable]
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    local okU, rU = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/unit_query.lua")
    if okU then UQ = rU
    else Spring.Echo("[LabCtrl] ERROR loading unit_query: " .. tostring(rU)) end
    if DEBUG then Spring.Echo("[LabCtrl] Initialized team=" .. tostring(myTeamID)) end
end

-- A unit starting in a lab means that lab's pending insert has been honoured.  Scouts
-- are counted from here, not only once finished: counting finished scouts alone let
-- every idle lab queue one each tick while the earlier ones were still being built,
-- and one lab turned out six scouts in six seconds during an air alarm.
function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if teamID ~= myTeamID then return end
    if builderID and labPending[builderID] then labPending[builderID] = nil end
    local kind = KindOf(unitDefID)
    if kind then
        building[unitID] = kind
        for i = 1, #ordered do
            if ordered[i].defID == unitDefID then table.remove(ordered, i); break end
        end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if not d then return end

    if d.isFactory then
        labs[unitID] = unitDefID
        local labName = d.name or "?"
        if DEBUG then Spring.Echo("[LabCtrl] Lab registered id=" .. unitID .. " def=" .. labName) end

        return
    end

    building[unitID] = nil
    if IsScoutDef(d) and not myScouts[unitID] then
        myScouts[unitID] = true
        scoutCount = scoutCount + 1
    elseif IsFighterDef(unitDefID) then
        myFighters[unitID] = true
    elseif IsDefenderDef(d) then
        myDefenders[unitID] = true
    end
end

function widget:UnitDestroyed(unitID)
    labs[unitID]        = nil
    myFighters[unitID]   = nil
    myDefenders[unitID]  = nil
    building[unitID]     = nil
    labPending[unitID]   = nil
    labOrderFrame[unitID] = nil
    armyFlip[unitID]     = nil
    if myScouts[unitID] then
        myScouts[unitID] = nil
        scoutCount = math.max(0, scoutCount - 1)
    end
end

local function CountAlive(set)
    local n = 0
    for uid in pairs(set) do
        if spGetUnitDefID(uid) then n = n + 1 else set[uid] = nil end
    end
    return n
end

-- Everything of a kind we already have or have asked for: alive, being built, and
-- ordered but not started.  Stale orders expire so a dropped one cannot block forever.
local function Have(kind, frame)
    for i = #ordered, 1, -1 do
        if frame - ordered[i].frame > ORDER_TTL then table.remove(ordered, i) end
    end
    local n = 0
    for _, o in ipairs(ordered) do
        if o.kind == kind then n = n + 1 end
    end
    for uid, k in pairs(building) do
        if not spGetUnitDefID(uid) then building[uid] = nil
        elseif k == kind then n = n + 1 end
    end
    local alive = (kind == "scout" and myScouts) or (kind == "fighter" and myFighters)
                  or myDefenders
    return n + CountAlive(alive)
end

local function Announce(frame, why, choice, labDefID, inserted)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[LabCtrl] %d:%02d %-14s %s in %s%s",
        math.floor(sec / 60), sec % 60, why,
        UnitDefs[choice] and UnitDefs[choice].name or "?",
        UnitDefs[labDefID] and UnitDefs[labDefID].name or "?",
        inserted and " (ahead of queue)" or ""))
end

function widget:GameFrame(frame)
    if frame % 60 ~= 0 then return end
    if not myTeamID then return end

    local ok,  metalCur, metalStorage, metalPull, metalIncome = pcall(spGetTeamResources, myTeamID, "metal")
    local okE, _,        _, energyPull, energyIncome = pcall(spGetTeamResources, myTeamID, "energy")

    metalCur     = (ok  and type(metalCur)     == "number") and metalCur     or 0
    metalStorage = (ok  and type(metalStorage) == "number") and metalStorage or 0
    metalPull    = (ok  and type(metalPull)    == "number") and metalPull    or 0
    metalIncome  = (ok  and type(metalIncome)  == "number") and metalIncome  or 0
    energyPull   = (okE and type(energyPull)   == "number") and energyPull   or 0
    energyIncome = (okE and type(energyIncome) == "number") and energyIncome or 0

    -- Production urgency is judged by the unit controller, which can see both the
    -- threat and what is in range to answer it (threat_map.ProductionUrgency).
    local mb       = WG and WG.MetalBot
    local urgency  = (mb and mb.urgency) or "none"
    local urgentCh = mb and mb.urgencyChannel
    local rush     = urgency == "rush"

    -- The stall guard now only blocks DISCRETIONARY spending.  It used to return
    -- before anything was decided, and the economy runs a deliberate stall through
    -- the whole growth phase -- so the defence floor, which exists precisely because
    -- it must be up before the raid, was silently never built.
    local metalStalling  = metalPull  > metalIncome  * 1.05
    local energyStalling = energyPull > energyIncome * 1.05
    local stalled        = (metalStalling or energyStalling) and metalCur < 50

    local frac     = metalStorage > 0 and (metalCur / metalStorage) or 0
    local floating = frac >= FLOAT_FRAC or (metalIncome - metalPull) >= FLOAT_SURPLUS
    local heavy    = frac >= FLOAT_HEAVY

    -- Counts include what is already ordered, and are bumped as orders go out below,
    -- so two labs in the same tick cannot both answer the same shortfall.
    local fightersHave  = Have("fighter", frame)
    local defendersHave = Have("defender", frame)
    local scoutsHave    = Have("scout", frame)
    local scoutRoom     = SCOUT_TARGET - scoutsHave

    for labID, labDefID in pairs(labs) do
        local recent = labOrderFrame[labID] and frame - labOrderFrame[labID] < LAB_ORDER_GRACE
        local picks  = not recent and spGetUnitDefID(labID) and GetArmyPicks(labDefID)
        if picks then
            local cache    = GetBuildCache(labDefID)
            local armyA    = picks.cheap or picks.vcheap
            local armyB    = picks.main  or picks.vmain
            local defender = picks.vcheap or picks.vmain

            -- DEFENCE: goes ahead of the queue if the lab is busy.
            local def, defWhy = nil, nil
            if rush then
                if urgentCh ~= "ground" and picks.fighter then
                    def, defWhy = picks.fighter, "rush-air"
                elseif urgentCh ~= "air" then
                    def, defWhy = defender or armyA or armyB, "rush-ground"
                end
            end
            local needFighter  = fightersHave  < FIGHTER_TARGET
            local needDefender = defendersHave < DEFENDER_TARGET
            local floor, floorWhy = nil, nil
            if needFighter and picks.fighter then
                floor, floorWhy = picks.fighter, "floor-fighter"
            elseif needDefender and defender then
                floor, floorWhy = defender, "floor-defender"
            end
            local canScout = not rush and scoutRoom > 0 and #cache.scouts > 0

            if QueueEmpty(labID) then
                -- rush -> ONE early scout -> floor -> more scouts -> surplus army.  The
                -- single early scout outranks the floor so the spawn search starts at
                -- once; every scout after it waits behind defence.  (Only here, where
                -- the lab can actually build it: letting it block the busy-lab branch
                -- below deadlocked a busy air lab -- no scout, and no fighter either.)
                local choice, why = def, defWhy
                if not choice and canScout and scoutsHave == 0 then
                    choice, why = CheapestScout(cache.scouts), "scout"
                end
                if not choice then choice, why = floor, floorWhy end
                if not choice and canScout then
                    choice, why = CheapestScout(cache.scouts), "scout"
                end
                if not choice and floating and not stalled then
                    if heavy and picks.floating then
                        choice, why = picks.floating, "float-heavy"
                    else
                        local flip = armyFlip[labID]
                        armyFlip[labID] = not flip
                        choice, why = (flip and armyA or armyB) or armyA or armyB, "float"
                    end
                end
                -- A lab with no army picks builds NOTHING (the bot lab only makes the
                -- two con bots the build order asks for, then is reclaimed).
                if choice then
                    spGiveOrderToUnit(labID, -choice, {}, {})
                    labOrderFrame[labID] = frame
                    NoteOrder(choice, frame)
                    local k = KindOf(choice)
                    if k == "scout" then
                        scoutRoom, scoutsHave = scoutRoom - 1, scoutsHave + 1
                    elseif k == "fighter" then fightersHave = fightersHave + 1
                    elseif k == "defender" then defendersHave = defendersHave + 1 end
                    if why ~= "float" and why ~= "float-heavy" then
                        Announce(frame, why, choice, labDefID, false)
                    end
                end
            else
                -- Busy (usually the macro's constructors): defence goes in next, once,
                -- and waits for that unit to actually start before inserting again, so
                -- the economy's own units are delayed by one build at most.
                local ins, insWhy = def or floor, def and defWhy or floorWhy
                local pend = labPending[labID]
                if ins and (not pend or frame - pend > PENDING_TIMEOUT) then
                    InsertNext(labID, ins)
                    labPending[labID] = frame
                    labOrderFrame[labID] = frame
                    NoteOrder(ins, frame)
                    local k = KindOf(ins)
                    if k == "fighter" then fightersHave = fightersHave + 1
                    elseif k == "defender" then defendersHave = defendersHave + 1 end
                    Announce(frame, insWhy, ins, labDefID, true)
                end
            end
        end
    end
end
