-- INACTIVE_BOT: does nothing.  A target for single-bot tests (the commander just sits there).
function widget:GetInfo()
    return {
        name    = "Idle",
        desc    = "No-op opponent for single-bot tests",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end
