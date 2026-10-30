-- bar_framework/spine_set.lua -- one view of several slot_spine instances (SECOND_SPINE, line_transition/spine2.lua).
-- WG.Spine is replaced by this table once the second spine starts.  Everything the lab rules ask about a lab goes to the spine that owns it;
-- SetUnits / SetShare (strategy.lua pushes them every tick) go to every spine; SpendCapacity is the sum.  Anything else (Front, State, CFG,
-- Status, ...) falls through to the first spine, so a reader that knows only one spine keeps working.
--
--   local set = SpineSet.New(spine1, spine2)

local M = {}

function M.New(first, second)
    local mods = { first, second }
    local F = setmetatable({ mods = mods }, { __index = first })

    local function Owner(labID)
        for _, m in ipairs(mods) do if m.IsLab(labID) then return m end end
        return nil
    end

    function F.IsLab(labID) return Owner(labID) ~= nil end
    function F.IsT1Lab(labID) local m = Owner(labID); return m ~= nil and m.IsT1Lab(labID) end
    function F.IsLeaving(labID) local m = Owner(labID); return m ~= nil and m.IsLeaving(labID) end
    function F.IsReplacing(labID) local m = Owner(labID); return m ~= nil and m.IsReplacing ~= nil and m.IsReplacing(labID) end
    function F.FirstConWanted(labID) local m = Owner(labID); return m ~= nil and m.FirstConWanted(labID) end
    function F.NextOrder(labID, labDefID) local m = Owner(labID); return m and m.NextOrder(labID, labDefID) or nil end

    function F.SetUnits(units) for _, m in ipairs(mods) do m.SetUnits(units) end end
    function F.SetShare(s) for _, m in ipairs(mods) do m.SetShare(s) end end
    function F.SetNanoFloor(f) for _, m in ipairs(mods) do m.SetNanoFloor(f) end end
    function F.SetSpendFloor(v) for _, m in ipairs(mods) do if m.SetSpendFloor then m.SetSpendFloor(v) end end end
    function F.Share() return first.Share() end

    -- the same four numbers as slot_spine.SpendCapacity, summed over the spines that have a comp
    function F.SpendCapacity()
        local a, b, c, d
        for _, m in ipairs(mods) do
            local x1, x2, x3, x4 = m.SpendCapacity()
            if x1 then a, b, c, d = (a or 0) + x1, (b or 0) + x2, (c or 0) + x3, (d or 0) + x4 end
        end
        return a, b, c, d
    end
    return F
end

return M
