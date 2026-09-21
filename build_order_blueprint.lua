-- Auto-generated build-order blueprint
-- max_rate — 260.33 m/s
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
    {n="corwin", x=      8, z=      8, f=0},  -- wind #1
    {n="corwin", x=    -40, z=      8, f=0},  -- wind #2
    {n="corlab", x=      0, z=    -64, f=0},  -- bot_lab #1
    {n="cormex", x=      0, z=     64, f=0},  -- mex #1
    {n="corwin", x=     56, z=      8, f=0},  -- wind #3
    {n="corwin", x=     56, z=     56, f=0},  -- wind #4
    {n="cornanotc", x=    -56, z=     56, f=0},  -- nano #1
    {n="cornanotc", x=     72, z=    -40, f=0},  -- nano #2
    {n="corlab", a="reclaim", x=      0, z=    -64, f=0},  -- reclaim bot_lab
    {n="cornanotc", x=      8, z=    -40, f=0},  -- nano #3
    {n="corwin", x=    -40, z=    -40, f=0},  -- wind #5
    {n="corwin", x=    -88, z=      8, f=0},  -- wind #6
    {n="cornanotc", x=      8, z=    -88, f=0},  -- nano #4
    {n="cormex", x=    112, z=     16, f=0},  -- mex #2
    {n="cormex", x=    -96, z=    -48, f=0},  -- mex #3
    {n="cormex", x=     64, z=    -96, f=0},  -- mex #4
    {n="cormex", x=     64, z=    112, f=0},  -- mex #5
    {n="cornanotc", x=    -40, z=    -88, f=0},  -- nano #5
    {n="corwin", x=      8, z=    120, f=0},  -- wind #7
    {n="cormex", x=    -64, z=    112, f=0},  -- mex #6
    {n="cormex", x=    128, z=    -48, f=0},  -- mex #7
    {n="corwin", x=   -104, z=     56, f=0},  -- wind #8
    {n="cornanotc", x=    120, z=     72, f=0},  -- nano #6
    {n="corwin", x=   -136, z=      8, f=0},  -- wind #9
    {n="cormex", x=      0, z=   -144, f=0},  -- mex #8
    {n="cormex", x=    -96, z=   -112, f=0},  -- mex #9
    {n="corwin", x=    120, z=   -104, f=0},  -- wind #10
    {n="cornanotc", x=    120, z=    120, f=0},  -- nano #7
    {n="corwin", x=   -120, z=    104, f=0},  -- wind #11
    {n="cormex", x=      0, z=    176, f=0},  -- mex #10
    {n="cormex", x=    176, z=     16, f=0},  -- mex #11
    {n="cornanotc", x=   -152, z=    -40, f=0},  -- nano #8
    {n="corwin", x=   -152, z=     56, f=0},  -- wind #12
    {n="corwin", x=     56, z=   -152, f=0},  -- wind #13
    {n="cormex", x=     64, z=    176, f=0},  -- mex #12
    {n="corwin", x=    -56, z=    168, f=0},  -- wind #14
    {n="cormex", x=    176, z=     80, f=0},  -- mex #13
    {n="cornanotc", x=    184, z=    -40, f=0},  -- nano #9
    {n="corwin", x=   -152, z=    -88, f=0},  -- wind #15
    {n="corwin", x=    104, z=   -152, f=0},  -- wind #16
    {n="cormex", x=    -64, z=   -176, f=0},  -- mex #14
    {n="corwin", x=   -184, z=      8, f=0},  -- wind #17
    {n="cormex", x=   -128, z=    160, f=0},  -- mex #15
    {n="cormex", x=    128, z=    176, f=0},  -- mex #16
    {n="corwin", x=    168, z=   -104, f=0},  -- wind #18
    {n="cormex", x=      0, z=   -208, f=0},  -- mex #17
    {n="cormex", x=   -208, z=    -48, f=0},  -- mex #18
    {n="cornanotc", x=   -168, z=    104, f=0},  -- nano #10
    {n="corwin", x=   -200, z=     56, f=0},  -- wind #19
    {n="corwin", x=     56, z=   -200, f=0},  -- wind #20
    {n="cormex", x=   -160, z=   -144, f=0},  -- mex #19
    {n="cormex", x=    160, z=   -160, f=0},  -- mex #20
    {n="corwin", x=    -56, z=    216, f=0},  -- wind #21
    {n="cormex", x=    192, z=    144, f=0},  -- mex #21
    {n="cormex", x=      0, z=    240, f=0},  -- mex #22
    {n="cormex", x=    240, z=      0, f=0},  -- mex #23
    {n="corwin", x=     56, z=    232, f=0},  -- wind #22
    {n="cormex", x=    240, z=     64, f=0},  -- mex #24
    {n="cormex", x=    224, z=    -96, f=0},  -- mex #25
    {n="cormex", x=   -112, z=    224, f=0},  -- mex #26
    {n="corwin", x=    104, z=   -200, f=0},  -- wind #23
    {n="cormex", x=   -192, z=    160, f=0},  -- mex #27
    {n="cormex", x=    112, z=    240, f=0},  -- mex #28
    {n="corwin", x=   -232, z=      8, f=0},  -- wind #24
    {n="cormex", x=   -128, z=   -208, f=0},  -- mex #29
    {n="cormex", x=    -64, z=   -240, f=0},  -- mex #30
    {n="corwin", x=   -216, z=    104, f=0},  -- wind #25
    {n="cormex", x=   -224, z=   -112, f=0},  -- mex #31
    {n="cormex", x=     64, z=   -256, f=0},  -- mex #32
    {n="corwin", x=   -248, z=     56, f=0},  -- wind #26
    {n="cormex", x=    192, z=    208, f=0},  -- mex #33
    {n="cormex", x=    224, z=   -160, f=0},  -- mex #34
    {n="cormex", x=    256, z=    128, f=0},  -- mex #35
    {n="corwin", x=    -56, z=    264, f=0},  -- wind #27
    {n="cormex", x=    160, z=   -224, f=0},  -- mex #36
    {n="cormex", x=      0, z=   -272, f=0},  -- mex #37
    {n="cormex", x=   -176, z=    224, f=0},  -- mex #38
    {n="cormex", x=   -272, z=    -48, f=0},  -- mex #39
    {n="corwin", x=     56, z=    280, f=0},  -- wind #28
    {n="cormex", x=    288, z=    -64, f=0},  -- mex #40
    {n="cormex", x=   -192, z=   -208, f=0},  -- mex #41
    {n="cormex", x=      0, z=    304, f=0},  -- mex #42
    {n="cormex", x=    304, z=      0, f=0},  -- mex #43
    {n="cormex", x=   -272, z=    112, f=0},  -- mex #44
    {n="cormex", x=    304, z=     64, f=0},  -- mex #45
    {n="corwin", x=   -280, z=      8, f=0},  -- wind #29
    {n="cormex", x=   -112, z=    288, f=0},  -- mex #46
    {n="cormex", x=    256, z=    192, f=0},  -- mex #47
    {n="cormex", x=   -128, z=   -272, f=0},  -- mex #48
    {n="cormex", x=    288, z=   -128, f=0},  -- mex #49
    {n="cormex", x=   -256, z=    176, f=0},  -- mex #50
    {n="cormex", x=    176, z=    272, f=0},  -- mex #51
    {n="corwin", x=    104, z=    296, f=0},  -- wind #30
    {n="cormex", x=    224, z=   -224, f=0},  -- mex #52
    {n="cormex", x=   -288, z=   -112, f=0},  -- mex #53
    {n="cormex", x=    128, z=   -288, f=0},  -- mex #54
    {n="cormex", x=    -64, z=   -304, f=0},  -- mex #55
    {n="cormex", x=   -256, z=   -176, f=0},  -- mex #56
    {n="cormex", x=     64, z=   -320, f=0},  -- mex #57
    {n="cormex", x=    320, z=    128, f=0},  -- mex #58
    {n="corwin", x=   -296, z=     56, f=0},  -- wind #31
    {n="cormex", x=   -176, z=    288, f=0},  -- mex #59
    {n="cormex", x=   -240, z=    240, f=0},  -- mex #60
    {n="cormex", x=   -336, z=      0, f=0},  -- mex #61
    {n="cormex", x=   -192, z=   -272, f=0},  -- mex #62
    {n="cormex", x=      0, z=   -336, f=0},  -- mex #63
    {n="cormex", x=    288, z=   -192, f=0},  -- mex #64
    {n="cormex", x=     64, z=    352, f=0},  -- mex #65
    {n="cormex", x=    192, z=   -288, f=0},  -- mex #66
    {n="corwin", x=    -56, z=    312, f=0},  -- wind #32
    {n="cormex", x=    256, z=    256, f=0},  -- mex #67
    {n="cormex", x=    352, z=    -64, f=0},  -- mex #68
    {n="cormex", x=   -336, z=    112, f=0},  -- mex #69
    {n="cormex", x=      0, z=    368, f=0},  -- mex #70
    {n="cormex", x=    368, z=      0, f=0},  -- mex #71
    {n="cormex", x=    160, z=    336, f=0},  -- mex #72
    {n="cormex", x=   -256, z=   -240, f=0},  -- mex #73
    {n="cormex", x=    320, z=    192, f=0},  -- mex #74
    {n="corwin", x=   -328, z=    -56, f=0},  -- wind #33
    {n="cormex", x=   -112, z=    352, f=0},  -- mex #75
    {n="cormex", x=    368, z=     64, f=0},  -- mex #76
    {n="cormex", x=   -320, z=    176, f=0},  -- mex #77
    {n="cormex", x=   -128, z=   -336, f=0},  -- mex #78
    {n="cormex", x=    352, z=   -128, f=0},  -- mex #79
    {n="cormex", x=   -320, z=   -176, f=0},  -- mex #80
    {n="cormex", x=   -352, z=   -112, f=0},  -- mex #81
    {n="cormex", x=    128, z=   -352, f=0},  -- mex #82
    {n="cormex", x=    -64, z=   -368, f=0},  -- mex #83
    {n="corwin", x=   -344, z=     56, f=0},  -- wind #34
    {n="cormex", x=    288, z=   -256, f=0},  -- mex #84
    {n="cormex", x=   -240, z=    304, f=0},  -- mex #85
    {n="cormex", x=   -304, z=    240, f=0},  -- mex #86
    {n="cormex", x=    240, z=    320, f=0},  -- mex #87
    {n="cormex", x=   -176, z=    352, f=0},  -- mex #88
    {n="cormex", x=    384, z=    128, f=0},  -- mex #89
    {n="cormex", x=     64, z=   -384, f=0},  -- mex #90
    {n="cormex", x=   -192, z=   -336, f=0},  -- mex #91
    {n="cormex", x=    352, z=   -192, f=0},  -- mex #92
    {n="cormex", x=    320, z=    256, f=0},  -- mex #93
    {n="cormex", x=    192, z=   -352, f=0},  -- mex #94
    {n="cormex", x=   -400, z=      0, f=0},  -- mex #95
    {n="cormex", x=      0, z=   -400, f=0},  -- mex #96
    {n="cormex", x=   -256, z=   -304, f=0},  -- mex #97
    {n="cormex", x=    128, z=    400, f=0},  -- mex #98
    {n="cormex", x=   -320, z=   -240, f=0},  -- mex #99
    {n="cormex", x=    256, z=   -320, f=0},  -- mex #100
    {n="cormex", x=   -400, z=     64, f=0},  -- mex #101
    {n="cormex", x=     64, z=    416, f=0},  -- mex #102
    {n="cormex", x=    -64, z=    416, f=0},  -- mex #103
    {n="cormex", x=    416, z=    -64, f=0},  -- mex #104
    {n="cormex", x=    384, z=    192, f=0},  -- mex #105
    {n="cormex", x=      0, z=    432, f=0},  -- mex #106
    {n="cormex", x=    432, z=      0, f=0},  -- mex #107
    {n="cormex", x=   -400, z=    128, f=0},  -- mex #108
    {n="cormex", x=    432, z=     64, f=0},  -- mex #109
}
return M
