-- unit_controller.lua  -  LINE_HUMAN: intentionally empty.
-- A person commands every unit; human_control_logger.lua records how.  Nothing here issues orders.
-- (WG.MetalBot stays nil: lab_controller reads it nil-safely, and the macro does not use it.)

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "LINE_HUMAN: disabled, a human controls units",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end
