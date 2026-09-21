-- Blueprint: prod_grid_vp
-- Hand-derived from VechT1_and_BotT2.lua (same nano/corvp/corrl layout) with the
-- coralab entry removed, so this grid can be placed repeatedly by the dynamic
-- production-scaling system in macro_controller.lua without spawning a new T2
-- bot lab every time. Meant to tile into the same mex-grid expansion slots
-- (30x30 cells, 1 cell = 16 world units, GRID_SPACING=480) as mex_grid_aa_corner.
local M = {}
M.layout = {
    {n="cornanotc", x= -216, z= -120, f=0},
    {n="cornanotc", x= -216, z=  -72, f=0},
    {n="cornanotc", x= -216, z=  -24, f=0},
    {n="cornanotc", x= -168, z= -168, f=0},
    {n="cornanotc", x= -168, z= -120, f=0},
    {n="cornanotc", x= -168, z=  -72, f=0},
    {n="cornanotc", x= -168, z=  -24, f=0},
    {n="corvp", x=  -96, z= -144, f=1},
    {n="corvp", x=  -96, z=  -48, f=1},
    {n="cornanotc", x= -216, z=   24, f=0},
    {n="cornanotc", x= -168, z=   24, f=0},
    {n="cornanotc", x= -216, z=   72, f=0},
    {n="cornanotc", x= -168, z=   72, f=0},
    {n="cornanotc", x= -216, z=  120, f=0},
    {n="cornanotc", x= -168, z=  120, f=0},
    {n="cornanotc", x= -216, z=  168, f=0},
    {n="cornanotc", x= -168, z=  168, f=0},
    {n="corvp", x=  -96, z=   48, f=1},
    {n="corvp", x=  -96, z=  144, f=1},
    {n="cornanotc", x=  120, z=  136, f=0},
    {n="cornanotc", x=  168, z=  136, f=0},
    {n="cornanotc", x=  216, z=  136, f=0},
    {n="cornanotc", x=  120, z=   88, f=0},
    {n="cornanotc", x=  168, z=   88, f=0},
    {n="cornanotc", x=  216, z=   88, f=0},
    {n="cornanotc", x=  120, z= -104, f=0},
    {n="cornanotc", x=  120, z= -152, f=0},
    {n="cornanotc", x=  168, z= -104, f=0},
    {n="cornanotc", x=  168, z= -152, f=0},
    {n="cornanotc", x=  216, z= -104, f=0},
    {n="cornanotc", x=  216, z= -152, f=0},
    {n="cornanotc", x=  168, z=   -8, f=0},
    {n="cornanotc", x=  216, z=   -8, f=0},
    {n="corrl", x= -216, z= -168, f=0},
}
return M
