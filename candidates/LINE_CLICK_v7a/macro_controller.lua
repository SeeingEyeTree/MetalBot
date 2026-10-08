-- macro_controller.lua  ─  LINE_BOT: build the line as fast as it can scale (COR)
--
-- One job: the commander places blueprints/general/line_com.lua (2 mex, winds, bot lab, first nano) without
-- walking, up to 3 con bots are added one at a time, and each builder works its own lane of the line
-- (bar_framework/line_crew.lua) until its 32 slots are done.  Nanos go in the nano column only when build
-- power is short.  No army, no grids, no transition: the [LN] log says when to add cons, how much the line
-- spends, and when metal / energy start to float (when a transition would pay).
--
-- Log lines (all "[LN]"): layout, con #N queued (reason, income, bank) / out, builder takes lane,
-- lane N DONE, FLOAT metal|energy onset, and a status row every 15 game-seconds.

local widget = widget
local Spring = Spring

local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID     = Spring.GetMyTeamID

local CMD_GUARD = (CMD and CMD.GUARD) or 25
local CMD_STOP  = 0

local CFG = {
    MAX_CONS            = 3,         -- one per lane besides the commander's
    -- Con #n (n = 2, 3) is queued once CON_GAP[n] frames have passed since the previous con came out AND any of:
    CON_GAP             = { [2] = 20 * 30, [3] = 20 * 30 },
    CON_INCOME          = { [2] = 20, [3] = 30 },   -- metal income (m/s) that queues con #n
    CON_BANK_TRIGGER    = 130,       -- metal in the bank
    CON_FALLBACK_FRAMES = 45 * 30,   -- frames after the previous con came out (no other condition needed)
    CON1_RELEASE_WAIT   = 20 * 30,   -- frames con #1 may finish a starter item first
    NANOS_HELPED        = 2,         -- the commander helps con #1 while it places nanos, until this many stand
    NANO_U              = 0.8,       -- both resources under this utilisation -> con #1 builds a nano
    WIND_U              = 1.0,       -- wind instead of mex only when energy utilisation is above this
    FLOAT_FRAC          = 0.25,      -- bank / storage that counts as floating...
    FLOAT_FRAMES        = 10 * 30,   -- ...when held this long
    LOG_EVERY           = 450,
    SPINE               = true,      -- vehicle lab + the spine (army); false = the economy-only bot
    RECLAIM_STARTER_LAB = true,      -- reclaim the starter bot lab once the air lab is queued and the cons are out
    -- Overrides of line_transition's LT.CFG.  The vehicle lab (the only ground-unit factory) was finished by 4:30
    -- (first ground unit 4:34) and the bank sat at 800-1200 metal for the minute before; a human rush of gators
    -- arrived at 5:28, killed the commander by 6:50 and the bot had 13 army units, 3 of them AA, and no defences.
    -- Finish it by 3:30 (the human reference: 3:57), so the labs have ~1 more minute of ground output.
    LT                  = { VP_DONE_FRAME = 3 * 60 * 30 + 30 * 30,
                            -- LINE_CLICK_v7a: 5 air cons (not 3) before the air lab's two nanos stand.  The lab was done
                            -- at 4:05, its nanos at 5:13, metal banked 400-750 meanwhile: grids waited for cons.
                            AIR_CON_CAP_EARLY = 5 },
}
local START_FRAME = 15
local NET_SMOOTH  = 0.1

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "LINE_BOT: build the line (commander starter + one builder per lane)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local BP_PLACER, LC, LT, BUILD_ORDER, GRID_BP, UPGRADE_BP
local SPINE, SPINE_BPS = nil, {}     -- bar_framework/spine.lua and its cell blueprints (nil if they failed to load)
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

local function FindConBotDefID(labDefID)
    local d = UnitDefs[labDefID]
    if not d or not d.buildOptions then return nil end
    local best, bestCost = nil, math.huge
    for _, optID in ipairs(d.buildOptions) do
        local od = UnitDefs[optID]
        if IsGroundCon(od) and (od.metalCost or 999999) < bestCost then
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
    layout = LC.Layout(cx, cz, (Game and Game.mapSizeX) or 8192, (Game and Game.mapSizeZ) or 8192, BUILD_ORDER)
    startPending = true
end

local function BeginBuildOrder()
    distState = BP_PLACER.NewDistributed(BUILD_ORDER, layout.anchorX, layout.anchorZ, layout.rot)
    BP_PLACER.EnableEscapeGuard(distState)
    BP_PLACER.AddBuilder(distState, commanderID)
    crew = LC.NewCrew{ BP = BP_PLACER, layout = layout,
                       onJobDone = function(j, state) if trans then LT.OnJobDone(trans, j, state) end end,
                       onJobStarted = function(j) if trans then LT.OnJobStarted(trans, j) end end }
    trans = LT.New{ BP = BP_PLACER, LC = LC, crew = crew, layout = layout, gridBP = GRID_BP, upgradeBP = UPGRADE_BP,
                    teamID = myTeamID, spine = SPINE, spineBPs = SPINE_BPS, cfg = CFG.LT, WG = WG }
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
    spGiveOrderToUnit(TS.botLabID, -TS.conDefID, { 0 }, {})
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
    -- The spine (TILE_BOT's unit production).  If any of it fails to load the bot still plays, economy only.
    if CFG.SPINE then
        local okS, rS = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/spine.lua")
        if okS and rS then
            local all = true
            for kind, file in pairs(rS.BLUEPRINT) do
                local okB, rB = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/" .. file .. ".lua")
                if okB and rB then SPINE_BPS[kind] = rB
                else all = false; Spring.Echo("[LN] ERROR loading spine blueprint " .. file .. ": " .. tostring(rB)) end
            end
            if all then SPINE = rS else Spring.Echo("[LN] spine disabled: blueprint missing") end
        else
            Spring.Echo("[LN] ERROR loading spine: " .. tostring(rS))
        end
    end
    -- Labs the lab controller must leave alone: the air lab while it owes air cons, and the starter bot lab
    -- (it only makes the 3 cons, then is reclaimed).
    if WG then
        WG.TileLabHold = function(labID)
            if labID == nil then return false end
            if trans and labID == trans.airLabID and trans.airConsOrdered > 0 then return true end
            return labID == TS.botLabID
        end
    end
    for _, u in ipairs(BUILD_ORDER.layout) do
        local ud = UnitDefNames[u.n]
        if ud and ud.isFactory and not TS.botLabName then TS.botLabName = u.n end
    end
    myTeamID = spGetMyTeamID()
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
    if teamID ~= myTeamID then return end
    if IsCommander(unitDefID) and not commanderID then
        commanderID = unitID
        StartBuildOrder()
    end
    if unitID == TS.botLabID then
        TS.conDefID = FindConBotDefID(unitDefID)
        if TS.conDefID then
            spGiveOrderToUnit(TS.botLabID, -TS.conDefID, { 0 }, {})
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

function widget:UnitDestroyed(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    if distState then BP_PLACER.OnUnitDestroyed(distState, unitID) end
    if crew then LC.OnUnitDestroyed(crew, unitID) end
    if trans then LT.OnUnitDestroyed(trans, unitID) end
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
    ReleaseCon1(frame)
    UpdateCommander(frame, res)
    LC.Update(crew, frame, res)
    CheckFloat(frame, res)
    if BP_PLACER.NANO and BP_PLACER.NANO.Sweep then BP_PLACER.NANO.Sweep() end
    LT.Update(trans, frame, res)
    if frame % CFG.LOG_EVERY == 0 then
        LogStatus(frame, res)
        Spring.Echo("[LT] " .. Clock(frame) .. " " .. LT.Status(trans))
    end
    if not distState.done then BP_PLACER.Update(distState, frame, res) end
end
