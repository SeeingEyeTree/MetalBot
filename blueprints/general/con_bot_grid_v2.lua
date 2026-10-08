-- Blueprint: con_bot_grid_v2  (TILE_V2)
-- Same 12 buildings at the same positions as con_bot_grid, in a different ORDER:
--   4 mexes first (a mex pays back ~2.4 m/s for 50m, ~20 s), then the 6 winds, nanos last.
-- con_bot_grid builds nano, 3 winds, 4 mexes, 3 winds, nano; in a real game that meant 8 winds
-- (344m) against 3 mexes (150m) at 2:00 and energy at 97-100% of storage from 2:30 to 4:00.
-- Winds still come early when energy is the tighter resource: the tile interrupts
-- (energy_now / energy_soon) and BP_PLACER.BalanceInterrupts pick wind by flow, not by order.
-- Nanos are the fallback, not the opener: the opening is metal-limited, and 2 nanos cost 460m.
local M = {}
M.layout = {
    {n="cormex", x=  -32, z=  -16, f=0},
    {n="cormex", x=   48, z=  -16, f=0},
    {n="cormex", x=   48, z=  -80, f=0},
    {n="cormex", x=  -32, z=  -80, f=0},
    {n="corwin", x=  -88, z=    8, f=0},
    {n="corwin", x=  104, z=    8, f=0},
    {n="corwin", x=  -88, z=  -40, f=0},
    {n="corwin", x=  104, z=  -40, f=0},
    {n="corwin", x=  -88, z=  -88, f=0},
    {n="corwin", x=  104, z=  -88, f=0},
    {n="cornanotc", x=  -88, z=  104, f=0},
    {n="cornanotc", x=  104, z=  104, f=0},
}
return M
