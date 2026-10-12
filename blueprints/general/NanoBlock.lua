-- Blueprint: NanoBlock  (bar_framework/slot_spine.lua)
-- 16 construction turrets in a 4x4 block (48 apart), built nearest-the-labs column first, and the SLOTS in front of
-- them where a lab of any kind can stand.  The block never holds a lab itself: slot_spine decides, from the current
-- unit comp, which lab goes into which slot, reclaims one that no unit in the comp needs, and puts another in its
-- place -- the nanos stay, so the new lab has its build power at once.
--
-- +x is the way the labs face (toward the enemy).  Two slots, 144 apart: a T2 plant is 144 x 144 whichever way it
-- faces, a T1 plant 144 x 96.  Every slot is within nano build range of all 16 nanos (cornanotc 380 + the lab's
-- half-extent; the farthest, the outer column to the far slot, is ~290 away).
-- M.slots is read by slot_spine only (the placer ignores it).
local M = {}
M.layout = {
    -- column nearest the labs first (1-4), then outward
    {n="cornanotc", x=  -72, z=  -72, f=0},
    {n="cornanotc", x=  -72, z=  -24, f=0},
    {n="cornanotc", x=  -72, z=   24, f=0},
    {n="cornanotc", x=  -72, z=   72, f=0},
    {n="cornanotc", x= -120, z=  -72, f=0},
    {n="cornanotc", x= -120, z=  -24, f=0},
    {n="cornanotc", x= -120, z=   24, f=0},
    {n="cornanotc", x= -120, z=   72, f=0},
    {n="cornanotc", x= -168, z=  -72, f=0},
    {n="cornanotc", x= -168, z=  -24, f=0},
    {n="cornanotc", x= -168, z=   24, f=0},
    {n="cornanotc", x= -168, z=   72, f=0},
    {n="cornanotc", x= -216, z=  -72, f=0},
    {n="cornanotc", x= -216, z=  -24, f=0},
    {n="cornanotc", x= -216, z=   24, f=0},
    {n="cornanotc", x= -216, z=   72, f=0},
}
M.slots = {
    { x = 24, z = -72 },
    { x = 24, z =  72 },
}
return M
