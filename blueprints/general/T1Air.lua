-- Blueprint: T1Air  (LINE_BOMB)
-- The bomber lab cell: 3 T1 aircraft plants in a column (x = 0, 160 apart: a plant is 144 x 96 whichever way it faces) with
-- 10 construction turrets behind them (west, toward the base).  Built whole and early (spine.OpenAirCell): this is the
-- pre-built build power for the bombing run.
-- 3 labs x 150 BP + 10 nanos x 200 BP = 2450 BP -> a Whirlwind (buildtime 5050) every ~6 s per lab with everything
-- assisting; a lab can use at most buildtime/2.5 = 2020 BP, so the nanos are the limit, not the labs.  Cost ~4.2k metal.
-- M.swap: what the lab recycler puts in the same slots after the raid (spine.OpenSwapCell): two T2 aircraft plants (144 x
-- 144) centred between the old T1 labs and shifted 16 east, clear of the nano columns (x <= -72).
local M = {}
M.layout = {
    {n="corap", x=    0, z= -160, f=1},
    {n="corap", x=    0, z=    0, f=1},
    {n="corap", x=    0, z=  160, f=1},
    {n="cornanotc", x=  -96, z= -168, f=0},
    {n="cornanotc", x=  -96, z= -120, f=0},
    {n="cornanotc", x=  -96, z=  -72, f=0},
    {n="cornanotc", x=  -96, z=  -24, f=0},
    {n="cornanotc", x=  -96, z=   24, f=0},
    {n="cornanotc", x=  -96, z=   72, f=0},
    {n="cornanotc", x=  -96, z=  120, f=0},
    {n="cornanotc", x=  -96, z=  168, f=0},
    {n="cornanotc", x= -144, z=  -24, f=0},
    {n="cornanotc", x= -144, z=   24, f=0},
}
M.swap = {
    {n="coraap", x=   16, z=  -80, f=1},
    {n="coraap", x=   16, z=   80, f=1},
}
return M
