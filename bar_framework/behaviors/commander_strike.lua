-- bar_framework/behaviors/commander_strike.lua
-- ARMY behaviour.  When pick_target found the enemy commander in the open (few guards around it), EVERY unit still in the
-- stack goes for it (FIGHT) -- killing it wins the game, so nothing else (flank, spread, run-by) may split the army.
-- Put it right after pick_target.   ctx needs: shared (pick_target)
local M = { name = "commander_strike", cfg = {} }

function M.Update(st, group, ctx, frame, host)
    local t = ctx.shared.target
    if not (t and t.commander) then return nil end
    for _, u in ipairs(group.list) do host:Order(frame, u.uid, 16, t.x, t.z) end
    return true
end

function M.Describe() return "the enemy commander in the open pulls the whole army" end
return M
