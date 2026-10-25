-- unit_controller.lua  -  CORE_HUMAN: intentionally empty.
-- A person commands every unit (write behaviours from what human_control_logger.lua records); nothing here issues orders.
-- WG.MetalBot stays nil: the macro, lab rules and strategy read it nil-safely (army share falls back to the plain schedule).

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "CORE_HUMAN: disabled, a human controls units",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end
