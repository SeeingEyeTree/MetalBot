-- bar_framework/line_transition/grid_core.lua
-- Mex grids: which cells are inside the line, picking and opening grids, the capstone, handing grids to cons, releasing candidates.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): ANTINUKE_GRIDS CAPSTONE_MAX COLLECT_ALWAYS COLLECT_DONE_ONLY EARLY_CAPSTONES EARLY_CAPSTONE_NANOS
--   FAST_OPEN_CAP GAP GRIDS_OPENING GRIDS_OPENING_MAX GRID_BALANCE GRID_BANK GRID_BANK_FAST GRID_BANK_GAP GRID_CAP_FRAC
--   GRID_COMPACT GRID_FAST_ENERGY GRID_FAST_INCOME GRID_HANDOFF GRID_INTR_MIN_NANOS GRID_PLANNER GRID_RECOVER
--   GRID_STALL_RULE GRID_UNITS IDLE_CON_SWEEP LINE_GATE PLANNER_CFG PLANNER_NEW_CELLS PLANNER_ONLY RETROFIT_EARLY
--   RETROFIT_MIN_NANOS SILO_GRIDS

local M = {}

function M.Install(X)
    local CB, LT, Clock, Key = X.CB, X.LT, X.Clock, X.Key
    local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")     -- spend / energy / unit-cap questions (C3)
    local HALF_GRID, LINE_BOX = X.HALF_GRID, X.LINE_BOX
    local QueueAirCon, AssignCons = X.QueueAirCon, X.AssignCons     -- con_orders
    local RememberGridMexes = X.RememberGridMexes     -- grid_recovery

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
                    if T.CFG.RETROFIT_EARLY and not T.CFG.RETROFIT_MIN_NANOS then T.gridFinished[Key(gs.anchorX, gs.anchorZ)] = true; AssignCons(T) end
                    Collect(T, T.completed)
                    AssignCons(T, T.frame)
                end
                -- 70% built is enough to retrofit: the grid's nanos are up and its con is off on the outlying items.
                st.onMostlyDone = function(gs)
                    local key = Key(gs.anchorX, gs.anchorZ)
                    if not T.gridFinished[key] and not T.CFG.RETROFIT_MIN_NANOS then
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
        if T.spineMod then X.StartSpine(T, frame) end   -- (defined by line_transition: the spine host)
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
            local _, maxU = LEDGER.CapLeft(T.teamID)
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
        -- IDLE_CON_SWEEP: cons already standing around (free or only helping) take the new grid; the lab makes one only for the rest
        if not T.CFG.IDLE_CON_SWEEP or CB.Available(T.CB, 1, true) + T.airConsOrdered < #T.pendingGrids then QueueAirCon(T, frame, "grid") end
        Spring.Echo(string.format("[LT] %s grid cell (%d, %d) opened (%s: %d opening, bank %.0f, %d waiting)",
            Clock(frame), r.anchorX, r.anchorZ, why, opening, res.metal, #T.gridCands))
        AssignCons(T, frame)
    end

    -- AIR_CON_LABS (user 2026-10-25: CORE lost many T1 air cons to fighters and did not replace them -- one air lab, its queue
    -- shared with the floor).  While the jobs + reserve want at least AIR_CON_DEFICIT more T1 air cons than stand ready, for
    -- AIR_CON_DEFICIT_S seconds, an open grid's SKIPPED capstone (past CAPSTONE_MAX) comes back as a T1 air lab, built next; at most
    -- AIR_CON_LABS_MAX of them.  con_orders.QueueAirCon then spreads the cons over every
    -- T1 air lab (and keeps making them if the line's air lab is gone).  Not at the unit cap (consolidation).
    local function UpdateAirConRecovery(T, frame, res)
        local C = T.CFG
        if not C.AIR_CON_LABS or T.consolidateOn or not T.labDefID or not T.CB or frame - (T.acCheckF or -1e9) < 90 then return end
        -- not in the opening: the jobs always want more cons than stand there (the first game spent both labs at 4:30 / 5:30)
        if frame < (C.AIR_CON_START_FRAME or 0) or not T.firstGridOK then return end
        T.acCheckF = frame
        local gap = CB.Unmet(T.CB, 1, frame, res) + (T.CB.reserve and T.CB.reserve[1] or 0) - CB.Available(T.CB, 1, true)
        if gap >= C.AIR_CON_DEFICIT then T.acDefSince = T.acDefSince or frame else T.acDefSince = nil end
        if not (T.acDefSince and frame - T.acDefSince >= C.AIR_CON_DEFICIT_S * 30) then return end
        T.capAirLabs = T.capAirLabs or {}
        local live = 0
        for _, c in ipairs(T.capAirLabs) do
            if not c.dead then
                local alive = c.id and Spring.GetUnitDefID(c.id)
                local st = c.st
                if alive or (st and not st.done) then live = live + 1 else c.dead = c.id ~= nil end
            end
        end
        if live >= C.AIR_CON_LABS_MAX then return end
        for _, st in ipairs(T.gridStates) do
            if not st.done and not st.capAirLab and st.builderID and Spring.GetUnitDefID(st.builderID) then
                local cdef = Spring.GetUnitDefID(st.builderID)
                for _, item in ipairs(st.queue) do
                    -- only a capstone the grid would skip anyway (past CAPSTONE_MAX): a T2 air lab capstone makes the T2 cons the
                    -- retrofits and the fusion push need, so it is never taken (AIR_CON_LAB_TAKE_T2 allows it)
                    local spare = item.status == "skipped" or C.AIR_CON_LAB_TAKE_T2
                    if item.cls == "factory" and spare and (not item.built or item.status == "skipped") and item.status ~= "started"
                       and item.status ~= "claimed" and cdef and T.BP.CanBuild(cdef, T.labDefID) then
                        local wx, wz = T.BP.SnapToBuildGrid(T.labDefID, item.wx, item.wz)
                        item.defID, item.wx, item.wz = T.labDefID, wx, wz
                        item.built, item.status = false, nil
                        st.deferFactories, st.capAirLab = false, true
                        T.capAirLabs[#T.capAirLabs + 1] = { x = wx, z = wz, st = st }
                        T.acDefSince = frame        -- the next one only after another full deficit window
                        Spring.Echo(string.format("[LT] %s T1 air con deficit (%d short for %ds): grid (%d, %d) capstone -> T1 air lab at (%d, %d), built next (%d of max %d)",
                            Clock(frame), gap, C.AIR_CON_DEFICIT_S, st.anchorX, st.anchorZ, wx, wz, live + 1, C.AIR_CON_LABS_MAX))
                        return
                    end
                end
            end
        end
        if frame - (T.acLogF or -1e9) >= 1800 then
            T.acLogF = frame
            Spring.Echo(string.format("[LT] %s T1 air con deficit (%d short) but no open grid has a capstone left for a T1 air lab", Clock(frame), gap))
        end
    end

    X.InsideLine = InsideLine
    X.AddCompleted = AddCompleted
    X.UpdateAirConRecovery = UpdateAirConRecovery
    X.OpenFirstGrid = OpenFirstGrid
    X.ReleaseCandidates = ReleaseCandidates

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.grid = function(T, cb)
        CB.AddJob(cb, { name = "grid", section = "grid", prio = 70, tier = "t1", useReserve = true,
            sessions = T.gridStates, paused = function() return T.ecoPaused end,
            want = function() return T.ecoPaused and 0 or #T.pendingGrids end,
            start = function(id, frame) return StartGrid(T, id, frame) end,
            onDone = function(st)
                if st.builderID and Spring.GetUnitDefID(st.builderID) then CB.Release(cb, st.builderID) end
                if T.CFG.GRID_RECOVER then RememberGridMexes(T, st) end
            end })
    end
end

return M
