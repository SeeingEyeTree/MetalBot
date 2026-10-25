-- stance_panel.lua -- buttons on the right edge to pick the stance of a CORE_HUMAN-style bot (macro_runtime MANUAL_STANCES).
-- Also army share buttons (auto, 0..100 in 10s; /share <0-100|auto>) that write WG.ArmyShareRequest.
-- Click a button, or type  /stance <name>  (/stance next, /stance prev).  Does nothing unless WG.StanceChoices exists
-- (published only by a bot with MANUAL_STANCES), so it is harmless when another bot is deployed.
-- Writes WG.StanceRequest; the macro controller's switch hook applies it within a second.

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name    = "Stance Panel",
        desc    = "Side buttons to choose the bot's stance (unit comp)",
        author  = "MetalBot",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 100001,
        enabled = true
    }
end

local BTN_W, BTN_H, GAP = 190, 26, 4
local MARGIN_R, TOP_FRAC = 8, 0.62       -- distance from the right edge; panel top as a fraction of screen height
local vsx, vsy = Spring.GetViewGeometry()
local rects = {}                         -- { name, x0, y0, x1, y1 }
local shareTop

local function Current()
    local S = WG and WG.Strategy
    return S and S.Name and S:Name() or nil
end

local function Request(name)
    if not name or not WG.StanceChoices then return end
    WG.StanceRequest = name
    Spring.Echo("[STANCEPANEL] requested " .. name .. " at " .. tostring(Spring.GetGameFrame()))
end

local SHARES = { "auto", 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 }   -- army share buttons (percent of income); "auto" = the bot's own rule
local COLS = 4
local SW = (BTN_W - (COLS - 1) * GAP) / COLS

local function RequestShare(v)
    if v == "auto" then WG.ArmyShareRequest = nil else WG.ArmyShareRequest = v / 100 end
    Spring.Echo("[STANCEPANEL] army share " .. tostring(v) .. " at " .. tostring(Spring.GetGameFrame()))
end

local function Layout()
    rects = {}
    local list = WG and WG.StanceChoices
    if not list then return end
    local x1 = vsx - MARGIN_R
    local x0 = x1 - BTN_W
    local y = vsy * TOP_FRAC
    for _, n in ipairs(list) do
        rects[#rects + 1] = { name = n, x0 = x0, x1 = x1, y1 = y, y0 = y - BTN_H }
        y = y - BTN_H - GAP
    end
    y = y - 22                                   -- room for the "ARMY SHARE" heading
    shareTop = y + 22
    for i, v in ipairs(SHARES) do
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        local bx = x0 + col * (SW + GAP)
        local by = y - row * (BTN_H + GAP)
        rects[#rects + 1] = { share = v, x0 = bx, x1 = bx + SW, y1 = by, y0 = by - BTN_H }
    end
end

function widget:ViewResize(x, y) vsx, vsy = x, y end

local function Hit(x, y)
    for _, r in ipairs(rects) do
        if x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1 then return r end
    end
end

function widget:IsAbove(x, y) return Hit(x, y) ~= nil end

function widget:MousePress(x, y, button)
    local r = button == 1 and Hit(x, y)
    if r then
        if r.share ~= nil then RequestShare(r.share) else Request(r.name) end
        return true
    end
    return false
end

function widget:TextCommand(cmd)
    local sh = cmd:match("^armyshare%s+(%S+)$") or cmd:match("^share%s+(%S+)$")
    if sh then
        if sh == "auto" then RequestShare("auto")
        elseif tonumber(sh) then RequestShare(math.max(0, math.min(100, tonumber(sh))))
        else Spring.Echo("[STANCEPANEL] usage: /share <0-100|auto>") end
        return true
    end
    local arg = cmd:match("^stance%s*(.*)$")
    if not arg then return false end
    local list = WG.StanceChoices
    if not list then Spring.Echo("[STANCEPANEL] no manual stances in this bot"); return true end
    arg = arg:gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "" then Spring.Echo("[STANCEPANEL] current " .. tostring(Current()) .. "; choices: " .. table.concat(list, ", ")); return true end
    if arg == "next" or arg == "prev" then
        local cur, idx = Current(), 1
        for i, n in ipairs(list) do if n == cur then idx = i end end
        idx = idx + (arg == "next" and 1 or -1)
        if idx > #list then idx = 1 elseif idx < 1 then idx = #list end
        Request(list[idx]); return true
    end
    for _, n in ipairs(list) do if n == arg then Request(n); return true end end
    Spring.Echo("[STANCEPANEL] unknown stance '" .. arg .. "'; choices: " .. table.concat(list, ", "))
    return true
end

function widget:DrawScreen()
    if not (WG and WG.StanceChoices) then return end
    Layout()
    local mx, my = Spring.GetMouseState()
    local cur, want = Current(), WG.StanceRequest
    local S = WG.Strategy
    local actual = S and S.Share and S:Share()
    local req = WG.ArmyShareRequest
    if #rects > 0 then
        local top, bot = rects[1], rects[#rects]
        gl.Color(0, 0, 0, 0.55)
        gl.Rect(top.x0 - 6, bot.y0 - 6, top.x1 + 6, top.y1 + 22)
        gl.Text("STANCE", top.x0, top.y1 + 6, 14, "o")
        local line = actual and string.format("ARMY SHARE  now %d%%%s", math.floor(actual * 100 + 0.5), req and "" or " (auto)") or "ARMY SHARE"
        gl.Text(line, top.x0, shareTop - 14, 14, "o")
    end
    for _, r in ipairs(rects) do
        local on, pending, label
        if r.share ~= nil then
            label = (r.share == "auto") and "auto" or (r.share .. "%")
            if r.share == "auto" then on = (req == nil)
            else on = (req ~= nil and math.floor(req * 100 + 0.5) == r.share) end
        else
            label = r.name
            on, pending = (r.name == cur), (r.name == want and want ~= cur)
        end
        if on then gl.Color(0.15, 0.55, 0.2, 0.9)
        elseif pending then gl.Color(0.7, 0.55, 0.1, 0.9)
        elseif mx >= r.x0 and mx <= r.x1 and my >= r.y0 and my <= r.y1 then gl.Color(0.35, 0.35, 0.45, 0.9)
        else gl.Color(0.18, 0.18, 0.22, 0.85) end
        gl.Rect(r.x0, r.y0, r.x1, r.y1)
        gl.Color(1, 1, 1, 1)
        gl.Text(label, r.x0 + 8, r.y0 + 7, 14, "o")
    end
end
