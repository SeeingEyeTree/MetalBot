-- lab_controller.lua  ─  DRAGON_ECO: factory queues (user 2026-10-14)
--
-- Three wants on the lab broker (bar_framework/lab_broker.lua), nothing else:
--   spine   every slot-spine lab: the cons the spine asks for (SS.NextOrder), then decoy commanders while the Dragon lab wants
--           more help (coralab only), then the stance's units (pounder_hold: Pounders + Lashers; mammoth_hold from 1.1k m/s:
--           Mammoths + Manticores).  Stance picks are paid from the army budget (a token bucket at income x army share).
--   dragon  every finished Dragon lab (WG.DragonLabs, placed by the macro -- more of them while metal floats): Dragons, forever.
--   raid    (user 2026-10-14: "hold a floor of Shurikens and make Shurikens and Wasps when it is being raided") while the unit
--           controller's raid record (mb.raid, raid_response.lua) is live for a ground raid: T1 air labs put Shurikens ahead of
--           their queue and the grid T2 air labs Wasps, each until NEED_MULT x the raid's value has been ordered since it began --
--           and none at all while the standing Shurikens + Wasps are worth RAID_AIR_ENOUGH (0.5) x the raid.
--   scouts  (as STANCE_ECO2) scouts up to the unit controller's mb.scoutWant from the air labs -- T1 air labs build Finks, grid
--           T2 air labs the AWAC (user 2026-10-15: a fast unarmed unit is a scout only when it has radar, so the Skyhook
--           (corseah, radar 0) is never built and the AWAC doubles as the radar plane) --, a radar plane from one grid T2 air
--           lab (RADAR_TARGET, 2 from RADAR_LATE_FRAME), and a slow trickle of ring radar units (mb.ringRadarWant, one per RING_GAP
--           across all labs) from the labs that can build one (the T2 bot labs) -- the unit controller's scout rings use them.
--   shuri   the standing Shuriken floor (SHURI_* ramp, RAID_BOT's: ~9 by 6:00, +6 every 3 min, 25 at most), ahead in T1 air labs.
--           Scouts and the floor wait while the macro still owes an air lab constructors (WG.TileLabHold); raid answers do not.
-- Otherwise the T1 air labs and the grid capstone T2 air labs get only what the macro orders through the broker (air cons): no
-- fighters, bombers, scouts or rez bots.
-- Decoy commanders guard (= assist) a Dragon lab -- each the one with the fewest decoys; they are listed in that lab's .decoys so
-- nothing else takes them.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID     = Spring.GetUnitDefID
local spGiveOrderToUnit  = Spring.GiveOrderToUnit
local spGetMyTeamID      = Spring.GetMyTeamID
local spGetTeamResources = Spring.GetTeamResources

local CMD_GUARD = (CMD and CMD.GUARD) or 25

local CFG = {
    LAB_ORDER_GRACE   = 120,    -- frames to leave a lab alone after an order (a factory's queue reads back late)
    SPINE_ORDER_GRACE = 90,
    DRAGON_DEPTH      = 3,      -- Dragons kept queued in the Dragon lab
    DECOY_SPEND       = 0.9,    -- decoys wanted = this share of metal income / what one decoy spends on Dragons...
    DECOY_METAL_RATE  = 12.75,  -- ...one decoy's 300 BP on a Dragon (5100 m / 120000 BP) spends 12.75 m/s
    DECOY_MIN         = 8,
    DECOY_PER_LAB     = 32,     -- at most this many per finished sink lab (the lab record's decoyMax overrides: metal_sink SINK_DECOYS)
    DECOY_ORDER_TTL   = 3600,   -- frames before a decoy order that never started is written off
    BUDGET_FREE_FILL  = 0.5,    -- a metal bank at least this full lifts the army budget
    BUDGET_CAP_SECONDS = 20,    -- the bucket never holds more than this many seconds of army income
    LOG_EVERY         = 1800,
    -- raid answer and Shuriken floor (RAID_BOT's numbers)
    RAID_TTL          = 300,    -- frames mb.raid stays live after the last intruder sighting
    RAID_NEW_GAP      = 900,    -- a raid this long after the last one starts the counts over
    NEED_MULT         = 2.0,    -- value to order against a raid, in raider value
    STUN_MAX          = 30,     -- Shurikens standing + ordered above this: no more raid Shurikens
    RAID_AIR_ENOUGH   = 0.5,    -- user 2026-10-14: standing Shuriken + Wasp value at least this x the raid's value -> no more raid air
    SHURI_RAMP_START  = 2 * 60 * 30,
    SHURI_EARLY_FRAME = 6 * 60 * 30,
    SHURI_EARLY       = 9,
    SHURI_STEP        = 6,
    SHURI_STEP_FRAMES = 3 * 60 * 30,
    SHURI_MAX         = 25,
    SHURI_ORDER_TTL   = 1800,   -- frames before a Shuriken order that never started is written off
    -- scouting (STANCE_ECO2's numbers)
    SCOUT_TARGET      = 2,      -- until the unit controller publishes mb.scoutWant
    SCOUT_ORDER_TTL   = 3600,
    RADAR_TARGET      = 1,
    RADAR_TARGET_LATE = 2,
    RADAR_LATE_FRAME  = 20 * 60 * 30,
    RING_MIN_RADIUS   = 1400,   -- a ring radar unit: ground, unarmed, radar radius at least this
    RING_GAP          = 45 * 30,
    RING_MIN_METAL    = 150,
}

function widget:GetInfo()
    return {
        name    = "Lab Controller",
        desc    = "DRAGON_ECO: spine stance units, decoy commanders, Dragons",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")   -- typed WG access (bar_framework/wg_channels.lua)
local myTeamID
local LB, lb = nil, nil
local labs = {}                          -- [labID] = labDefID
local decoys = {}                        -- [unitID] = true: alive decoy commanders (finished or being built)
local decoyOrders = {}                   -- { frame, ... } ordered, not yet started
local budget = { v = 0, frame = nil, free = false }
local C = {}                             -- this tick's facts (GameFrame fills it)

local function Clock(frame) return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")   -- unit roles per faction (C4)
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")   -- the per-frame unit snapshot (C5)
local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")   -- spend / energy / unit-cap questions (C3)
local BT = VFS.Include("LuaUI/Widgets/bar_framework/build_tree.lua")   -- the build tree (C1)
local function CanBuildSet(labDefID) return BT.Options(labDefID) end

local function DefIDOf(name) local d = UnitDefNames and UnitDefNames[name]; return d and d.id end

-- the finished sink labs, in id order (WG.SinkLabs, bar_framework/metal_sink.lua)
local function DragonLabs()
    local out = {}
    for _, L in pairs(CH.SinkLabs(WG)) do
        if L.id and L.ready and spGetUnitDefID(L.id) then out[#out + 1] = L end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
local function IsDragonLab(id)
    return CH.SinkLabs(WG)[id] ~= nil
end


-- ── army budget (as RAID_BOT's: the stance share is a ratio, the labs only see on/off) ──────────────────────────────────
local function BudgetUpdate(frame, share, income, metalFill)
    local last = budget.frame
    budget.frame = frame
    budget.free = metalFill >= CFG.BUDGET_FREE_FILL
    if not last then return end
    local rate = income * share
    budget.v = math.min(budget.v + rate * (frame - last) / 30, math.max(400, rate * CFG.BUDGET_CAP_SECONDS))
end

local function StancePick(labDefID)
    local ST = WG and WG.Strategy
    if not ST then return nil end
    if budget.frame and not budget.free and budget.v <= 0 then return nil end
    local set = CanBuildSet(labDefID)
    local defID = ST:Pick(function(d) return set[d] end)
    if defID then
        ST:Note(defID)
        budget.v = budget.v - ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0)
    end
    return defID
end

-- During the move to T2 (user 2026-10-14: "the T1 vehicle labs can still make Pounders, we are just moving towards Mammoths") a
-- vehicle plant the T2 stance has nothing for keeps making the T1 comp -- Pounders, a Lasher in every TRANSITION_LASHER_EVERY --
-- until the spine reclaims it.  Same army budget as the stance picks.
local TRANSITION_LASHER_EVERY = 7
local transitionN = 0
local function TransitionPick(labDefID)
    if budget.frame and not budget.free and budget.v <= 0 then return nil end
    local set = CanBuildSet(labDefID)
    local pounder, lasher = DefIDOf("corlevlr"), DefIDOf("cormist")
    transitionN = transitionN + 1
    local defID = (lasher and set[lasher] and transitionN % TRANSITION_LASHER_EVERY == 0) and lasher
                  or (pounder and set[pounder] and pounder) or nil
    if defID then budget.v = budget.v - ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0) end
    return defID
end

-- ── Shuriken floor and raid answer ───────────────────────────────────────────
local RAID = { live = false, lastLive = -1e9, need = 0, stunOrdered = 0, waspOrdered = 0 }
local shuriOrders = {}                   -- { frame, ... } Shurikens ordered, not yet started

local function ShuriWant(frame)
    if frame < CFG.SHURI_RAMP_START then return 0 end
    if frame < CFG.SHURI_EARLY_FRAME then
        return math.ceil(CFG.SHURI_EARLY * (frame - CFG.SHURI_RAMP_START) / (CFG.SHURI_EARLY_FRAME - CFG.SHURI_RAMP_START))
    end
    return math.min(CFG.SHURI_MAX, CFG.SHURI_EARLY + CFG.SHURI_STEP * (1 + math.floor((frame - CFG.SHURI_EARLY_FRAME) / CFG.SHURI_STEP_FRAMES)))
end

local function ShuriHave(frame)
    local d = UnitDefNames and UnitDefNames.corbw
    local n = d and #(Spring.GetTeamUnitsByDefs(myTeamID, d.id) or {}) or 0
    local keep = {}
    for _, f in ipairs(shuriOrders) do if frame - f <= CFG.SHURI_ORDER_TTL then keep[#keep + 1] = f end end
    shuriOrders = keep
    return n + #shuriOrders
end

local function UpdateRaid(frame)
    local mb = WG and WG.MetalBot
    local raid = mb and mb.raid
    local live = raid ~= nil and frame - (raid.frame or -1e9) <= CFG.RAID_TTL and (raid.value or 0) > 0 and raid.channel ~= "air"
    if live and frame - RAID.lastLive > CFG.RAID_NEW_GAP then RAID.stunOrdered, RAID.waspOrdered = 0, 0 end
    if live then RAID.lastLive = frame end
    if live ~= RAID.live then
        Spring.Echo(string.format("[LabCtrl] %s raid %s: value %.0f (Shurikens ordered %.0f, Wasps ordered %.0f, air standing %.0f)", Clock(frame),
            live and "ON" or "over", raid and raid.value or 0, RAID.stunOrdered, RAID.waspOrdered, RAID.airValue or 0))
    end
    RAID.live = live
    RAID.need = live and (raid.value or 0) * CFG.NEED_MULT or 0
    -- the air we already have against it: every standing Shuriken and Wasp (they are all home guard / raid response)
    local airV = 0
    for _, n in ipairs({ ROLES.Get("stunner"), ROLES.Get("raider") }) do
        local d = UnitDefNames and UnitDefNames[n]
        if d then airV = airV + #(Spring.GetTeamUnitsByDefs(myTeamID, d.id) or {}) * (d.metalCost or 0) end
    end
    RAID.airValue = airV
    RAID.enough = live and airV >= CFG.RAID_AIR_ENOUGH * (raid.value or 0)
end

-- ── scouting ─────────────────────────────────────────────────────────────────
local RADAR_PLANE = { [ROLES.Get("radar_plane")] = true, armawac = true }    -- the AWAC is the radar plane (and, from a grid T2 air lab, a scout too)
local scoutOrders, radarOrders, ringOrders = {}, {}, {}      -- { frame, ... } ordered, not yet started
local ringLast = -1e9

local function IsScoutDef(d)
    if not d or (d.speed or 0) <= 0 or d.isBuilder or d.isFactory then return false end
    for k in pairs(d.modCategories or {}) do if string.find(k, "scout") then return true end end
    local name = string.lower(d.name or "")
    if string.find(name, "scout") or string.find(name, "fink") or string.find(name, "peep") or string.find(name, "flea")
       or string.find(name, "weasel") or string.find(name, "wheelie") then return true end
    -- a fast unarmed unit is a scout only when it has radar (user 2026-10-15): the Skyhook (corseah, radar 0) is never built
    return (d.speed or 0) > 150 and (not d.weapons or #d.weapons == 0) and (d.radarDistance or d.radarRadius or 0) > 0
end
local function IsRingRadarDef(d)
    return d ~= nil and (d.speed or 0) > 0 and not d.canFly and not d.isBuilder and not d.isFactory
           and (not d.weapons or #d.weapons == 0) and (d.radarRadius or d.radarDistance or 0) >= CFG.RING_MIN_RADIUS
end
-- cheapest unit of a kind this lab can build (cached per lab type)
local pickCache = {}
local function CheapestOf(labDefID, kind, test)
    local key = labDefID .. ":" .. kind
    local c = pickCache[key]
    if c ~= nil then return c or nil end
    local best
    for _, o in ipairs((UnitDefs[labDefID] or {}).buildOptions or {}) do
        local od = UnitDefs[o]
        if od and test(od) and (not best or (od.metalCost or 0) < (UnitDefs[best].metalCost or 0)) then best = o end
    end
    pickCache[key] = best or false
    return best
end
local function Fresh(list, frame, ttl)
    local keep = {}
    for _, f in ipairs(list) do if frame - f <= ttl then keep[#keep + 1] = f end end
    return keep
end
local function CountKind(test)
    local n = 0
    for defID, list in pairs(UQ.snapshot(myTeamID).byDef) do      -- one walk of the team per frame, shared (C5); a def is tested once, not a unit
        local d = UnitDefs[defID]
        if d and test(d) then n = n + #list end
    end
    return n
end
local function UpdateScouting(frame)
    local mb = WG and WG.MetalBot
    scoutOrders = Fresh(scoutOrders, frame, CFG.SCOUT_ORDER_TTL)
    radarOrders = Fresh(radarOrders, frame, CFG.SCOUT_ORDER_TTL)
    ringOrders = Fresh(ringOrders, frame, CFG.SCOUT_ORDER_TTL)
    C.scoutRoom = ((mb and mb.scoutWant) or CFG.SCOUT_TARGET) - CountKind(IsScoutDef) - #scoutOrders
    C.radarRoom = (frame >= CFG.RADAR_LATE_FRAME and CFG.RADAR_TARGET_LATE or CFG.RADAR_TARGET)
                  - CountKind(function(d) return RADAR_PLANE[d.name] == true end) - #radarOrders
    C.ringRoom = ((mb and mb.ringRadarWant) or 0) - CountKind(IsRingRadarDef) - #ringOrders
    -- the radar plane comes from one grid T2 air lab: the lowest id that can build one (never the Dragon lab)
    C.radarLab = nil
    for id, defID in pairs(labs) do
        if not IsDragonLab(id) and CheapestOf(defID, "radar", function(d) return RADAR_PLANE[d.name] == true end)
           and (not C.radarLab or id < C.radarLab) then C.radarLab = id end
    end
end

-- ── decoy commanders ─────────────────────────────────────────────────────────
local function DecoyWant()
    local nLabs = #DragonLabs()
    if nLabs == 0 then return 0 end
    local room = 0
    for _, L in ipairs(DragonLabs()) do room = room + (L.decoyMax or CFG.DECOY_PER_LAB) end
    return LEDGER.DecoyDemand(C.metalIncome, room, { spend = CFG.DECOY_SPEND, rate = CFG.DECOY_METAL_RATE, min = CFG.DECOY_MIN })
end

local function DecoyHave(frame)
    local n = 0
    for uid in pairs(decoys) do if spGetUnitDefID(uid) then n = n + 1 else decoys[uid] = nil end end
    local keep = {}
    for _, f in ipairs(decoyOrders) do if frame - f <= CFG.DECOY_ORDER_TTL then keep[#keep + 1] = f end end
    decoyOrders = keep
    return n + #decoyOrders
end

-- each decoy guards (assists) one Dragon lab: the one with the fewest when it has none (or its lab died); idle ones are re-told
local decoyLab = {}                      -- [decoy uid] = Dragon lab id
local function AssignDecoy(uid, list)
    local best, bestN
    for _, L in ipairs(list) do
        local n = 0
        for d in pairs(L.decoys) do if decoyLab[d] == L.id and spGetUnitDefID(d) then n = n + 1 end end
        if n < (L.decoyMax or CFG.DECOY_PER_LAB) and (not bestN or n < bestN) then best, bestN = L, n end
    end
    if not best then return nil end
    decoyLab[uid] = best.id
    best.decoys[uid] = true
    spGiveOrderToUnit(uid, CMD_GUARD, { best.id }, {})
    return best
end
local function UpdateDecoys(frame)
    local list = DragonLabs()
    if #list == 0 then return end
    local alive = {}
    for _, L in ipairs(list) do alive[L.id] = L end
    for uid in pairs(decoys) do
        if spGetUnitDefID(uid) and not Spring.GetUnitIsBeingBuilt(uid) then
            local L = alive[decoyLab[uid] or -1]
            if not L then
                AssignDecoy(uid, list)
            else
                local q = Spring.GetUnitCommands(uid, 1)
                if not q or #q == 0 then spGiveOrderToUnit(uid, CMD_GUARD, { L.id }, {}) end
            end
        end
    end
end

-- ── wants ────────────────────────────────────────────────────────────────────
local function RegisterWants()
    LB.AddWant(lb, { name = "spine", prio = 100, mode = "topup", grace = CFG.SPINE_ORDER_GRACE, log = false,
        depth = function() local SP = C.SP; return (SP and SP.CFG and SP.CFG.QUEUE_DEPTH) or 3 end,
        applies = function(lab) return lab.isSpine end,
        pick = function(lab, frame)
            local SP = C.SP
            local defID = SP.NextOrder(lab.id, lab.defID)
            if defID then return defID, "spine-con" end
            local decoy = C.decoyDef
            if decoy and CanBuildSet(lab.defID)[decoy] and C.decoyRoom > 0 then
                C.decoyRoom = C.decoyRoom - 1
                decoyOrders[#decoyOrders + 1] = frame
                return decoy, "decoy"
            end
            if SP.Share() > 0 then
                local st = StancePick(lab.defID)
                if st then return st, "stance" end
                return TransitionPick(lab.defID), "transition"
            end
        end })
    -- raid answer: ahead of a busy queue, one at a time (the air cons the macro ordered are delayed by one build at most)
    LB.AddWant(lb, { name = "raid-shuri", prio = 95, mode = "ahead", why = "raid-shuriken",
        applies = function(lab) return RAID.live and not RAID.enough and not lab.isSpine and not lab.isDragon and lab.can.corbw end,
        pick = function(lab, frame)
            local d = UnitDefNames.corbw
            if C.shuriHave < CFG.STUN_MAX and RAID.stunOrdered < math.max(RAID.need, 2 * d.metalCost) then
                RAID.stunOrdered = RAID.stunOrdered + d.metalCost
                C.shuriHave = C.shuriHave + 1
                shuriOrders[#shuriOrders + 1] = frame
                return d.id
            end
        end })
    LB.AddWant(lb, { name = "raid-wasp", prio = 95, mode = "ahead", why = "raid-wasp",
        applies = function(lab) return RAID.live and not RAID.enough and not lab.isSpine and not lab.isDragon and lab.can.corape end,
        pick = function()
            local d = UnitDefNames.corape
            if RAID.waspOrdered < RAID.need then
                RAID.waspOrdered = RAID.waspOrdered + d.metalCost
                return d.id
            end
        end })
    -- scouting: a scout ahead of a busy air lab queue (one at a time), the radar plane, ring radar units
    LB.AddWant(lb, { name = "scout", prio = 85, mode = "ahead", why = "scout",
        applies = function(lab) return C.scoutRoom > 0 and not lab.isSpine and not lab.isDragon and not lab.held end,
        pick = function(lab, frame)
            local d = CheapestOf(lab.defID, "scout", IsScoutDef)
            if d and C.scoutRoom > 0 then
                C.scoutRoom = C.scoutRoom - 1
                scoutOrders[#scoutOrders + 1] = frame
                return d
            end
        end })
    LB.AddWant(lb, { name = "radar-plane", prio = 84, mode = "ahead", why = "radar-plane",
        applies = function(lab) return C.radarRoom > 0 and lab.id == C.radarLab end,
        pick = function(lab, frame)
            local d = CheapestOf(lab.defID, "radar", function(od) return RADAR_PLANE[od.name] == true end)
            if d then C.radarRoom = C.radarRoom - 1; radarOrders[#radarOrders + 1] = frame; return d end
        end })
    LB.AddWant(lb, { name = "ring-radar", prio = 105, mode = "ahead", noPending = true, why = "ring-radar",
        applies = function(lab) return C.ringRoom > 0 and not lab.isDragon and C.frame - ringLast >= CFG.RING_GAP and C.metal >= CFG.RING_MIN_METAL end,
        pick = function(lab, frame)
            local d = CheapestOf(lab.defID, "ring", IsRingRadarDef)
            if d then
                C.ringRoom, ringLast = C.ringRoom - 1, frame
                ringOrders[#ringOrders + 1] = frame
                return d
            end
        end })
    -- the standing Shuriken floor
    LB.AddWant(lb, { name = "shuri", prio = 80, mode = "ahead", why = "shuriken-floor",
        applies = function(lab) return not lab.isSpine and not lab.isDragon and not lab.held and lab.can.corbw end,
        pick = function(lab, frame)
            if C.shuriHave < C.shuriWant then
                C.shuriHave = C.shuriHave + 1
                shuriOrders[#shuriOrders + 1] = frame
                return UnitDefNames.corbw.id
            end
        end })
    LB.AddWant(lb, { name = "dragon", prio = 90, mode = "topup", why = "dragon",
        depth = function() return CFG.DRAGON_DEPTH end,
        applies = function(lab) return IsDragonLab(lab.id) end,
        pick = function() return C.dragonDef end })
end

-- ── callins ──────────────────────────────────────────────────────────────────
function widget:Initialize()
    myTeamID = spGetMyTeamID()
    local okL, rL = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/lab_broker.lua")
    if okL and rL then
        LB = rL
        lb = LB.New{ cfg = { ORDER_GRACE = CFG.LAB_ORDER_GRACE } }
        RegisterWants()
        CH.Publish(WG, "LabBroker", { LB = LB, lb = lb })    -- the macro's con orders (line_transition) go through the same broker
    else
        Spring.Echo("[LabCtrl] ERROR loading lab_broker: " .. tostring(rL))
    end
end

function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if teamID ~= myTeamID then return end
    if lb and builderID then LB.UnitStarted(lb, builderID) end
    local d = UnitDefs[unitDefID]
    if d and d.name == ROLES.Get("stunner") and #shuriOrders > 0 then table.remove(shuriOrders, 1) end
    if d and IsScoutDef(d) and #scoutOrders > 0 then table.remove(scoutOrders, 1) end
    if d and RADAR_PLANE[d.name] and #radarOrders > 0 then table.remove(radarOrders, 1) end
    if d and IsRingRadarDef(d) and #ringOrders > 0 then table.remove(ringOrders, 1) end
    if d and d.name == ROLES.Get("decoy") and builderID and labs[builderID] then
        decoys[unitID] = true
        if #decoyOrders > 0 then table.remove(decoyOrders, 1) end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if d and d.isFactory then labs[unitID] = unitDefID end
    if decoys[unitID] then AssignDecoy(unitID, DragonLabs()) end
end

function widget:UnitDestroyed(unitID)
    labs[unitID] = nil
    decoys[unitID] = nil
    local labID = decoyLab[unitID]
    decoyLab[unitID] = nil
    local all = WG and WG.DragonLabs
    if labID and all and all[labID] then all[labID].decoys[unitID] = nil end
    if WG and WG.DragonLab and WG.DragonLab.decoys then WG.DragonLab.decoys[unitID] = nil end
    if lb then LB.Forget(lb, unitID) end
end

function widget:GameFrame(frame)
    if frame % 60 ~= 0 or not myTeamID or not lb then return end
    local ok, metalCur, metalStorage, _, metalIncome = pcall(spGetTeamResources, myTeamID, "metal")
    metalCur     = (ok and type(metalCur) == "number") and metalCur or 0
    metalStorage = (ok and type(metalStorage) == "number") and metalStorage or 0
    metalIncome  = (ok and type(metalIncome) == "number") and metalIncome or 0
    C.SP, C.frame, C.metalIncome = WG and WG.Spine, frame, metalIncome
    local sinkLab = DragonLabs()[1]
    C.decoyDef, C.dragonDef = DefIDOf(ROLES.Get("decoy")), DefIDOf(sinkLab and sinkLab.unit or ROLES.Get("sink_unit"))
    local mFill = metalStorage > 0 and metalCur / metalStorage or 0
    BudgetUpdate(frame, (C.SP and C.SP.Share and C.SP.Share()) or 0, metalIncome, mFill)
    local want = DecoyWant()
    C.decoyRoom = want - DecoyHave(frame)
    UpdateDecoys(frame)
    UpdateRaid(frame)
    C.metal = metalCur
    UpdateScouting(frame)
    C.shuriHave, C.shuriWant = ShuriHave(frame), ShuriWant(frame)

    local SP = C.SP
    for labID, labDefID in pairs(labs) do
        if spGetUnitDefID(labID) then
            local isSpine = (SP and SP.IsLab(labID)) and true or false
            local leaving = isSpine and SP.IsLeaving and SP.IsLeaving(labID) or false
            local set = CanBuildSet(labDefID)
            local can = { [ROLES.Get("stunner")] = set[DefIDOf(ROLES.Get("stunner")) or -1] == true, [ROLES.Get("raider")] = set[DefIDOf(ROLES.Get("raider")) or -1] == true }
            -- held: the macro still owes this air lab constructors (WG.TileLabHold, as STANCE_ECO2): only raid answers go ahead of
            -- them; scouts and the Shuriken floor wait (in eco_sim they took the air lab's time: 46 air cons by 10:00 instead of 76)
            local held = CH.TileLabHeld(WG, labID) or false
            LB.Service(lb, { id = labID, defID = labDefID, isSpine = isSpine, skip = leaving, can = can, held = held,
                             isDragon = IsDragonLab(labID) }, frame)
        end
    end
    LB.Update(lb, frame)
    if frame % CFG.LOG_EVERY == 0 then
        local n = 0
        for _ in pairs(decoys) do n = n + 1 end
        Spring.Echo(string.format("[LabCtrl] %s decoys %d (want %d), Shurikens %d (floor %d), Dragon lab %s, army budget %.0f, stance %s",
            Clock(frame), n, want, C.shuriHave, C.shuriWant, #DragonLabs() .. " up", budget.v,
            tostring(WG and WG.Strategy and WG.Strategy:Name())))
    end
end
