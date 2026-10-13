
-- VACUUM TEST: armed mobile non-builder units self-destruct 1350 frames after they finish
do
    local vacBorn = {}
    local origFinished, origFrame = widget.UnitFinished, widget.GameFrame
    function widget:UnitFinished(uid, defID, teamID)
        local d = UnitDefs[defID]
        if d and not d.isBuilding and not d.isBuilder and not d.isFactory and (d.canMove or d.canFly) and #(d.weapons or {}) > 0 then vacBorn[uid] = Spring.GetGameFrame() end
        if origFinished then return origFinished(self, uid, defID, teamID) end
    end
    function widget:GameFrame(frame)
        if frame % 30 == 0 then
            for uid, f in pairs(vacBorn) do
                if not Spring.GetUnitDefID(uid) then vacBorn[uid] = nil
                elseif frame - f > 1350 then Spring.GiveOrderToUnit(uid, 65, {}, {}); vacBorn[uid] = nil end
            end
        end
        if origFrame then return origFrame(self, frame) end
    end
end
