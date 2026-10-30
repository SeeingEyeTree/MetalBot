-- bar_framework/line_transition/grid_helpers.lua
-- Grid helpers: idle cons that assist a grid's builder (the `gridhelp` job).
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): GRID_HELPERS HELPER_CAP HELP_ANY HELP_MAX HELP_NANOS

local M = {}

function M.Install(X)
    local CB = X.CB
    local CMD_GUARD = X.CMD_GUARD

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

    -- GRID_HELPERS (the "gridhelp" job): a grid with fewer than HELP_NANOS nanos up (HELP_ANY: any unfinished grid) gets idle air cons
    -- guarding its builder, HELP_MAX each, so its first nanos stand quickly.  A grid or any higher job takes them back at once.
    -- GRID_FOCUS: the grid everything works on (a table), "pending" while the next cell waits for its first con, or nil.  The newest grid whose
    -- builder lives, that has fewer than GRID_FOCUS nanos and has held the focus for less than GRID_FOCUS_MAX frames.
    function X.FocusGrid(T, frame)
        local n = T.CFG.GRID_FOCUS
        if not n then return nil end
        for i = #T.gridStates, 1, -1 do
            local gs = T.gridStates[i]
            if not gs.done and gs.focusSince and gs.builderID and Spring.GetUnitDefID(gs.builderID)
               and #gs.nanoUnitIDs < n and frame - gs.focusSince < (T.CFG.GRID_FOCUS_MAX or 2700) then
                return gs
            end
        end
        if #T.pendingGrids > 0 then return "pending" end
        return nil
    end

    local function HelpSlots(T)
        local out, total = {}, 0
        if not T.CFG.GRID_HELPERS or T.ecoPaused then return out, 0 end
        local F = T.CFG.GRID_FOCUS and X.FocusGrid(T, T.frame or 0)
        if type(F) == "table" then return { { gs = F, n = 99 } }, 99 end          -- every idle con on the grid in focus (HelperRoom caps it)
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
        -- GRID_FOCUS: when the focus moves (to a new grid, or to none) the helpers not on the new focus go back to the pool; the gridhelp job
        -- sends them to the focus grid, or spreads them by HELP_MAX when there is none
        local focus
        if T.CFG.GRID_FOCUS then
            local F = X.FocusGrid(T, frame)
            focus = type(F) == "table" and F or nil
            if focus ~= T.focusGS then
                T.focusGS = focus
                for id, gs in pairs(T.helpers) do
                    if gs ~= focus and Spring.GetUnitDefID(id) then T.helpers[id] = nil; CB.Release(T.CB, id, true) end
                end
            end
        end
        for id, gs in pairs(T.helpers) do
            if not Spring.GetUnitDefID(id) then
                T.helpers[id] = nil
            elseif gs.done or (#gs.nanoUnitIDs >= need and not T.CFG.HELP_ANY) then
                T.helpers[id] = nil
                CB.Release(T.CB, id, true)
            end
        end
    end

    X.HelperRoom = HelperRoom
    X.UpdateGridHelpers = UpdateGridHelpers

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.gridhelp = function(T, cb)
        CB.AddJob(cb, { name = "gridhelp", section = "grid", prio = 20, tier = "t1", preemptable = true, urgent = false,
            want = function() local _, n = HelpSlots(T); return math.min(n, HelperRoom(T)) end,
            start = function(id) return StartGridHelper(T, id) end,
            onPreempt = function(id) T.helpers[id] = nil end,
            onLost = function(id) T.helpers[id] = nil end })
    end
end

return M
