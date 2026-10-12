-- Blueprint: energy_cell
-- A dedicated ENERGY cell on the grid lattice (30x30 cells = 480 elmos, centre 0,0), derived from
-- fussion_grid_60x60: fusions in blocks, build power in the corridors between them.
--   * 12 nanos run along a cross of corridors 160 wide (|x| < 80 or |z| < 80), built first, inner to outer;
--   * 16 fusions (corfus, 5x5 = 80 elmos) fill the four corner blocks (2x2 each at +-120 / +-200), inner block first.
-- Every nano reaches every fusion; the cross stays open so cons can walk through.
-- Opened by bar_framework/line_transition.lua (ECELL) when energy binds while metal floats.
local M = {}
M.layout = {
    -- horizontal corridor (z = 8), inner to outer
    {n="cornanotc", x=  104, z=    8, f=0},
    {n="cornanotc", x= -104, z=    8, f=0},
    {n="cornanotc", x=  152, z=    8, f=0},
    {n="cornanotc", x= -152, z=    8, f=0},
    -- vertical corridor (x = 8)
    {n="cornanotc", x=    8, z=  104, f=0},
    {n="cornanotc", x=    8, z= -104, f=0},
    {n="cornanotc", x=    8, z=  152, f=0},
    {n="cornanotc", x=    8, z= -152, f=0},
    {n="cornanotc", x=  200, z=    8, f=0},
    {n="cornanotc", x= -200, z=    8, f=0},
    {n="cornanotc", x=    8, z=  200, f=0},
    {n="cornanotc", x=    8, z= -200, f=0},
    -- inner fusion of each corner block, then the rest of the block
    {n="corfus", x=  120, z=  120, f=0},
    {n="corfus", x= -120, z= -120, f=0},
    {n="corfus", x=  120, z= -120, f=0},
    {n="corfus", x= -120, z=  120, f=0},
    {n="corfus", x=  200, z=  120, f=0},
    {n="corfus", x= -200, z= -120, f=0},
    {n="corfus", x=  120, z= -200, f=0},
    {n="corfus", x= -120, z=  200, f=0},
    {n="corfus", x=  200, z= -120, f=0},
    {n="corfus", x= -200, z=  120, f=0},
    {n="corfus", x=  120, z=  200, f=0},
    {n="corfus", x= -120, z= -200, f=0},
    {n="corfus", x=  200, z=  200, f=0},
    {n="corfus", x= -200, z= -200, f=0},
    {n="corfus", x=  200, z= -200, f=0},
    {n="corfus", x= -200, z=  200, f=0},
}
return M
