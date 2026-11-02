-- bar_framework/support/stop.lua  (army_groups element: "stopping power" -- 2 Tzars per group, screened like the Quakers)
-- User 2026-11-02: "the quakers did exactly what I wanted them to.  They just might not be the right unit.  'Stopping power' t2 is 2 tzar (corgol).
-- Tzar has less range but it is enough.  It can't be moved by light trans only heavy corseah or corhvytrans.  It is the same kind of idea to always keep
-- the tzar firing ... the same kind of standing ground that the quakers had.  For the targeting of the tzar have it target the highest unit density in
-- its range, that is closest to it ... The unit density range should be 250 (it has 292 aoe).  Just use set target on the unit in the center of a clump.
-- Make a small consideration for friendly fire."
-- The behaviour is support/arty.lua's (a fresh copy of it, so it has its own on-latch): role heavy_t2_veh, TARGET "density".  air_lift picks a transport
-- that can carry it (corseah / corhvytrans) and asks the labs for heavy transports while Tzar lifts wait.
local M = VFS.Include("LuaUI/Widgets/bar_framework/support/arty.lua")
M.name, M.LABEL = "stop", "Tzars"
M.CFG.N, M.CFG.UNIT, M.CFG.TARGET = 2, "heavy_t2_veh", "density"
M.CFG.SPACING = 110
M.RANK = "density"        -- army_groups: pool Tzars go first to the groups with the most enemy ground units near them
return M
