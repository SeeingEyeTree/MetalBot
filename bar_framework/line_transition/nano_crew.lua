-- bar_framework/line_transition/nano_crew.lua
-- The nano crew (nanos guarding the grids' builders) and the idle-con sweep: an air con must never stand doing nothing.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): AUDIT_EVERY CREW_CHAIN ENERGY_PRIORITY IDLE_CON_FRAMES IDLE_CON_SWEEP NANO_CREW NANO_CREW_AFTER
--   NANO_CREW_FULL NANO_CREW_GRIDS NANO_CREW_GROUP NANO_CREW_MIN NANO_CREW_NANOS NANO_CREW_SIZE NANO_CREW_SIZE_FULL

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock

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

    X.UpdateNanoCrew = UpdateNanoCrew
    X.UpdateIdleCons = UpdateIdleCons

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.nanocrew = function(T, cb)
        CB.AddJob(cb, { name = "nanocrew", section = "crew", prio = 72, tier = "t1", useReserve = true, urgent = false,
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
    end
end

return M
