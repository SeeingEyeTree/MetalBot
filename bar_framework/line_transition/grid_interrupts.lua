-- bar_framework/line_transition/grid_interrupts.lua
-- Grid interrupts: events that change a grid's state from outside its own build queue -- a grid whose mexes are all up, or that has enough nanos, becomes retrofit-eligible.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): RETROFIT_MEX_DONE RETROFIT_MIN_NANOS

local M = {}

function M.Install(X)
    local Clock, Key = X.Clock, X.Key
    local AssignCons = X.AssignCons     -- con_orders
    local AddCompleted = X.AddCompleted     -- grid_core

    local function UpdateEligibility(T, frame)
        if T.CFG.RETROFIT_MEX_DONE and not T.CFG.RETROFIT_MIN_NANOS and frame % 60 == 0 then
            for _, gs in ipairs(T.gridStates) do
                local key = Key(gs.anchorX, gs.anchorZ)
                if not gs.done and not T.gridFinished[key] then
                    local mexes, left = 0, 0
                    for _, it in ipairs(gs.queue) do
                        if it.cls == "metal" and it.act ~= "reclaim" then
                            mexes = mexes + 1
                            if not (it.built or it.status == "built" or it.status == "skipped") then left = left + 1 end
                        end
                    end
                    if mexes > 0 and left == 0 then
                        T.gridFinished[key] = true
                        AddCompleted(T, gs.anchorX, gs.anchorZ)
                        if T.windDefID or UnitDefNames.corwin then
                            gs.skipDefIDs = gs.skipDefIDs or {}
                            gs.skipDefIDs[T.windDefID or UnitDefNames.corwin.id] = true
                        end
                        Spring.Echo(string.format("[LT] %s grid (%d, %d) mexes up -- retrofit eligible", Clock(frame), gs.anchorX, gs.anchorZ))
                        AssignCons(T)
                    end
                end
            end
        end
        if T.CFG.RETROFIT_MIN_NANOS and frame % 60 == 0 then
            for _, gs in ipairs(T.gridStates) do
                local key = Key(gs.anchorX, gs.anchorZ)
                if not T.gridFinished[key] then
                    local n = 0
                    for _, it in ipairs(gs.queue) do
                        if it.cls == "nano" and it.act ~= "reclaim" and (it.built or it.status == "built") then n = n + 1 end
                    end
                    if n >= T.CFG.RETROFIT_MIN_NANOS then
                        T.gridFinished[key] = true
                        AddCompleted(T, gs.anchorX, gs.anchorZ)
                        Spring.Echo(string.format("[LT] %s grid (%d, %d) has %d nanos -- retrofit eligible", Clock(frame), gs.anchorX, gs.anchorZ, n))
                        AssignCons(T)
                    end
                end
            end
        end
    end

    X.UpdateEligibility = UpdateEligibility
end

return M
