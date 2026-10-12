-- unit_controller.lua  ─  LINE_NOSPINE: economy-only baseline for A/B against LINE_BOT; no unit orders.
-- (Present so deploy overwrites whatever another bot left in the widget folder.)

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "LINE_NOSPINE: no-op",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end
