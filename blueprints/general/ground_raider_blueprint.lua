-- Auto-generated build-order blueprint
-- raid — 132.35 m/s, units {'incisor': 8, 'fighter': 2}
--
-- Positions in elmos relative to blueprint anchor.
-- Load with:
--   local bp    = VFS.Include('LuaUI/Widgets/blueprints/general/build_order_blueprint.lua')
--   local state = BP_PLACER.NewDistributed(bp, anchorX, anchorZ, 0)
--
-- x/z are BUILDING CENTRES in elmos, relative to the blueprint anchor.
-- Entries with a="reclaim" are not builds: reclaim the building already
-- standing at that spot (its metal refund is part of the build order).
-- NOTE: mex positions are ORDER placeholders; real positions depend on map mex spots.

local M = {}
M.layout = {
    {n="cormex", x=      0, z=      0, f=0},  -- mex #1
    {n="corwin", x=      8, z=     56, f=0},  -- wind #1
    {n="corwin", x=     56, z=      8, f=0},  -- wind #2
    {n="corlab", x=    -80, z=      0, f=0},  -- bot_lab #1
    {n="corwin", x=      8, z=    -56, f=0},  -- wind #3
    {n="corwin", x=     56, z=    -40, f=0},  -- wind #4
    {n="cormex", x=     64, z=     64, f=0},  -- mex #2
    {n="cornanotc", x=    -40, z=     72, f=0},  -- nano #1
    {n="cormex", x=    -48, z=    -80, f=0},  -- mex #3
    {n="cornanotc", x=      8, z=    104, f=0},  -- nano #2
    {n="corwin", x=    104, z=      8, f=0},  -- wind #5
    {n="cormex", x=     64, z=    -96, f=0},  -- mex #4
    {n="corwin", x=    104, z=    -40, f=0},  -- wind #6
    {n="corlab", a="reclaim", x=    -80, z=      0, f=0},  -- reclaim bot_lab
    {n="cornanotc", x=    -56, z=      8, f=0},  -- nano #3
    {n="corwin", x=    -88, z=     56, f=0},  -- wind #7
    {n="corwin", x=   -104, z=      8, f=0},  -- wind #8
    {n="corwin", x=      8, z=   -104, f=0},  -- wind #9
    {n="cormex", x=   -112, z=    -48, f=0},  -- mex #5
    {n="corwin", x=    -40, z=    120, f=0},  -- wind #10
    {n="cormex", x=     64, z=    128, f=0},  -- mex #6
    {n="cormex", x=    128, z=     64, f=0},  -- mex #7
    {n="corwin", x=    -88, z=    104, f=0},  -- wind #11
    {n="cornanotc", x=      8, z=    152, f=0},  -- nano #4
    {n="cormex", x=    160, z=      0, f=0},  -- mex #8
    {n="cormex", x=    128, z=    -96, f=0},  -- mex #9
    {n="cormex", x=   -144, z=     64, f=0},  -- mex #10
    {n="cormex", x=    -48, z=   -144, f=0},  -- mex #11
    {n="cormex", x=     16, z=   -160, f=0},  -- mex #12
    {n="corwin", x=   -104, z=   -104, f=0},  -- wind #12
    {n="corvp", x=    144, z=    144, f=0},  -- veh_lab #1
    {n="cornanotc", x=   -152, z=      8, f=0},  -- nano #5
    {n="corwin", x=    -40, z=    168, f=0},  -- wind #13
    {n="corwin", x=     72, z=   -152, f=0},  -- wind #14
    {n="cormex", x=    -96, z=    160, f=0},  -- mex #13
    {n="cornanotc", x=   -168, z=    -40, f=0},  -- nano #6
    {n="corwin", x=     56, z=    184, f=0},  -- wind #15
    {n="cormex", x=    192, z=     64, f=0},  -- mex #14
    {n="cormex", x=    192, z=    -64, f=0},  -- mex #15
    {n="cormex", x=   -160, z=   -112, f=0},  -- mex #16
    {n="corwin", x=      8, z=    200, f=0},  -- wind #16
    {n="cormex", x=   -160, z=    128, f=0},  -- mex #17
    {n="cormex", x=    128, z=   -160, f=0},  -- mex #18
    {n="cormex", x=   -208, z=     16, f=0},  -- mex #19
    {n="corwin", x=   -104, z=   -152, f=0},  -- wind #17
    {n="cormex", x=    224, z=      0, f=0},  -- mex #20
    {n="cormex", x=    -48, z=   -208, f=0},  -- mex #21
    {n="cormex", x=    -48, z=    224, f=0},  -- mex #22
    {n="corwin", x=   -200, z=     72, f=0},  -- wind #18
    {n="cormex", x=    192, z=   -128, f=0},  -- mex #23
    {n="cormex", x=     16, z=   -224, f=0},  -- mex #24
    {n="cormex", x=   -224, z=    -48, f=0},  -- mex #25
    {n="cormex", x=     64, z=    240, f=0},  -- mex #26
    {n="cormex", x=     80, z=   -224, f=0},  -- mex #27
    {n="corwin", x=   -104, z=   -200, f=0},  -- wind #19
    {n="cormex", x=   -112, z=    224, f=0},  -- mex #28
    {n="cormex", x=    224, z=    128, f=0},  -- mex #29
    {n="cormex", x=   -160, z=   -176, f=0},  -- mex #30
    {n="cormex", x=    256, z=     64, f=0},  -- mex #31
    {n="cormex", x=    256, z=    -64, f=0},  -- mex #32
    {n="cormex", x=   -176, z=    192, f=0},  -- mex #33
    {n="corwin", x=      8, z=    248, f=0},  -- wind #20
    {n="cormex", x=   -224, z=   -112, f=0},  -- mex #34
    {n="cormex", x=   -224, z=    128, f=0},  -- mex #35
    {n="cormex", x=    144, z=   -224, f=0},  -- mex #36
    {n="cormex", x=   -272, z=     16, f=0},  -- mex #37
    {n="cormex", x=    288, z=      0, f=0},  -- mex #38
    {n="cormex", x=    208, z=   -192, f=0},  -- mex #39
    {n="cormex", x=    256, z=   -128, f=0},  -- mex #40
    {n="corwin", x=   -248, z=     72, f=0},  -- wind #21
    {n="cormex", x=    224, z=    192, f=0},  -- mex #41
    {n="cormex", x=    -48, z=   -272, f=0},  -- mex #42
    {n="cormex", x=    -48, z=    288, f=0},  -- mex #43
    {n="cormex", x=   -112, z=   -256, f=0},  -- mex #44
    {n="cormex", x=   -224, z=   -176, f=0},  -- mex #45
    {n="cormex", x=     16, z=   -288, f=0},  -- mex #46
    {n="cormex", x=     16, z=    304, f=0},  -- mex #47
    {n="cormex", x=   -288, z=    -48, f=0},  -- mex #48
    {n="cormex", x=   -112, z=    288, f=0},  -- mex #49
    {n="cormex", x=     80, z=   -288, f=0},  -- mex #50
    {n="cormex", x=    288, z=    128, f=0},  -- mex #51
    {n="corwin", x=     72, z=    296, f=0},  -- wind #22
    {n="cormex", x=   -240, z=    192, f=0},  -- mex #52
    {n="corwin", x=   -168, z=   -232, f=0},  -- wind #23
    {n="corwin", x=   -168, z=    248, f=0},  -- wind #24
    {n="corwin", x=    312, z=     56, f=0},  -- wind #25
    {n="corwin", x=   -280, z=   -104, f=0},  -- wind #26
    {n="corwin", x=   -280, z=    120, f=0},  -- wind #27
    {n="corap", x=    184, z=   -304, f=0},  -- air_lab #1
    {n="corwin", x=   -296, z=     72, f=0},  -- wind #28
    {n="cormex", x=    320, z=    -64, f=0},  -- mex #53
    {n="corwin", x=    216, z=    248, f=0},  -- wind #29
    {n="cormex", x=    272, z=   -192, f=0},  -- mex #54
    {n="cormex", x=    288, z=    192, f=0},  -- mex #55
}
-- Reserved exit corridors for ground factories: {x1, z1, x2, z2} relative to the anchor.
-- Keep mex grids and other builds off these so units can leave the base.
M.keepout = {
    {96, 192, 192, 544},
}
-- Air-lab units in the sim's build order; lab_controller queues these first.
M.units = { "corgator", "corgator", "corgator", "corgator", "corveng", "corveng", "corgator", "corgator", "corgator", "corgator" }
return M
