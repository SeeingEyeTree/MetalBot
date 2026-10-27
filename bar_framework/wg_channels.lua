-- bar_framework/wg_channels.lua
-- One place that knows every WG channel (how widgets and modules talk to each other): its shape, a nil-safe getter and a
-- checked publisher.  bar_framework/WG_CHANNELS.md is the prose version; SCHEMA below is the one the tests enforce.
--
--   local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")
--   local mb   = CH.MetalBot(WG)             -- always a table (empty when nothing is published yet)
--   local held = CH.TileLabHeld(WG, labID)   -- boolean
--   CH.Publish(WG, "Strategy", STRAT)        -- checks the shape when CH.STRICT (tests turn it on)
--
-- Every function takes WG as its first argument and never reads the global: in --server single a VFS.Include'd module
-- does not see the widget's own (per-team shim) WG, so the caller passes it in, as game_state.Collect does with MB.
-- Getters tolerate WG == nil.  Tests: tests/test_wg_schema.lua.

local M = {}

-- tests/spring_stub.lua sets the global WG_CHANNELS_STRICT.  (No rawget(_G, ...): the engine's widget environment has no _G, and
-- this file then failed to load in a real game -- every controller that includes it died on the first line.)
local okStrict, strictFlag = pcall(function() return WG_CHANNELS_STRICT end)
M.STRICT = okStrict and strictFlag == true

-- Field kinds: "number" | "string" | "boolean" | "table" | "function" | "any".  A kind may be a list of alternatives.
-- A schema entry is { kind = <kind of the channel itself>, fields = { name = kind, ... }, open = true|nil }.  `open` means
-- other fields are allowed (the channel is a module API / free-form table); a closed channel rejects unknown fields under STRICT.
M.SCHEMA = {
    MetalBot = { kind = "table", fields = {
        frame = "number", urgency = "string", urgencyDeficit = "number", urgencyChannel = "string",
        homeX = "number", homeZ = "number", foeX = "number", foeZ = "number", axisX = "number", axisZ = "number",
        foeDist = "number", threats = "table", raid = "table", airLosses = "number", intel = "table",
        scoutWant = "number", ringRadarWant = "number", callScouts = "number",
        armyCount = "number", armyValue = "number", armyGround = "number", armyAir = "number", squadHave = "number", squadWant = "number", squadMade = "number", garrisonHave = "number", garrisonWant = "number", garrisonMade = "number", avOwnRate = "number", avEnemyRate = "number", avProjRatio = "number",
        trade = "table", airKills = "number", airLost = "number", hunt = "boolean", airAlarm = "table", airRaid = "table", pushMode = "string", blobs = "table",
    } },
    Strategy    = { kind = "table", open = true },                  -- strategy.lua object: Name / Plan / Assign / Pick / Note
    Spine       = { kind = "table", open = true },                  -- spine / slot_spine API
    TileLabHold = { kind = "function" },                            -- function(labID) -> boolean
    BombPlan    = { kind = "table", open = true },                  -- phase_plan.View
    AntiNuke    = { kind = "table", fields = { saviorWant = "number", points = "number" } },
    UQSnap      = { kind = "table", open = true },                  -- { [teamID] = per-frame unit snapshot } (unit_query.lua, C5)
    EcoLedger   = { kind = "table", open = true },                  -- { consumers = { [name] = {capacity, energyPerMetal} } } (eco_ledger.lua)
    SinkLabs    = { kind = "table" },                               -- { [labID] = {id, x, z, ready, decoys, decoyMax, unit, spot} } (metal_sink.lua)
    DecoyLabs   = { kind = "table" },                               -- { [labID] = {id, x, z, ready, decoys, decoyMax, line = true} } the line's decoy T2 bot labs (line_decoy.lua)
    DragonLab   = { kind = "table", fields = { id = "number", x = "number", z = "number", ready = "boolean", decoys = "table", decoyMax = "number", unit = "string", spot = "number" } },
    DragonLabs  = { kind = "table" },                               -- { [labID] = DragonLab-shaped }
    LabBroker   = { kind = "table", fields = { LB = "any", lb = "any" } },
    ConBroker   = { kind = "table", open = true },                  -- con_broker instance (who owns which constructor)
    StatsTracker = { kind = "table", open = true },
    StanceChoices = { kind = "table" },                             -- { "raid_open", ... } the stances a person may pick (macro_runtime MANUAL_STANCES; stance_panel.lua shows them)
    StanceRequest = { kind = "string" },                            -- the stance a person picked (stance_panel.lua); the manual switch hook applies it
    ArmyShareRequest = { kind = "number" },                         -- army share 0..1 a person set (stance_panel.lua); nil = the bot's own rule
    RezLab      = { kind = "table", fields = { id = "number" } },   -- the line's finished rez lab (rez_lab.lua); lab_rules' "rez-lab" want owns its queue
    ScoutNet    = { kind = "table", open = true },                  -- scout_net.lua API: RequestScout / SacrificeScout / Picture ... (CORE)
}

-- WG entries that belong to BAR's own widgets, not to a bot (ignored by Validate).  Add names here when a stock widget
-- shows up in a strict test.
M.FOREIGN = {}

local function KindOk(v, kind)
    if kind == "any" then return true end
    if type(kind) == "table" then
        for _, k in ipairs(kind) do if KindOk(v, k) then return true end end
        return false
    end
    return type(v) == kind
end

-- Returns nil when `value` fits the channel's schema, else a string saying what is wrong.
function M.Check(name, value)
    local sc = M.SCHEMA[name]
    if not sc then return "unknown WG channel '" .. tostring(name) .. "' (add it to wg_channels.lua SCHEMA and WG_CHANNELS.md)" end
    if value == nil then return nil end
    if not KindOk(value, sc.kind) then return "WG." .. name .. " should be a " .. sc.kind .. ", got " .. type(value) end
    if sc.kind == "table" and sc.fields then
        for k, v in pairs(value) do
            local fk = sc.fields[k]
            if fk == nil then
                if not sc.open then return "WG." .. name .. "." .. tostring(k) .. " is not in the schema" end
            elseif v ~= nil and not KindOk(v, fk) then
                return "WG." .. name .. "." .. tostring(k) .. " should be a " .. tostring(fk) .. ", got " .. type(v)
            end
        end
    end
    return nil
end

-- Check every channel currently in WG; returns a list of problems (empty = fine).  Unknown top-level keys are problems too.
function M.Validate(WG)
    local bad = {}
    if type(WG) ~= "table" then return bad end
    for name, value in pairs(WG) do
        local sc = M.SCHEMA[name]
        if sc then
            local why = M.Check(name, value)
            if why then bad[#bad + 1] = why end
        elseif M.STRICT and not M.FOREIGN[name] then
            bad[#bad + 1] = "unknown WG channel '" .. tostring(name) .. "'"
        end
    end
    return bad
end

-- Publish a channel.  Under STRICT a malformed value is an error (so a test fails); otherwise it is published anyway.
function M.Publish(WG, name, value)
    if M.STRICT then
        local why = M.Check(name, value)
        if why then error(why, 2) end
    end
    if WG then WG[name] = value end
    return value
end

-- ---- getters (nil-safe) ----------------------------------------------------------------------------------------------

local EMPTY = setmetatable({}, { __newindex = function() error("WG_CHANNELS: the empty channel table is read-only", 2) end })
M.EMPTY = EMPTY

-- The unit controller's read-out.  Always a table, so `mb.intel` needs no `WG and WG.MetalBot and` chain.
function M.MetalBot(WG) return (WG and WG.MetalBot) or EMPTY end
function M.Strategy(WG) return WG and WG.Strategy or nil end
function M.Spine(WG) return WG and WG.Spine or nil end
function M.BombPlan(WG) return WG and WG.BombPlan or nil end
function M.LabBroker(WG) return WG and WG.LabBroker or nil end
function M.ConBroker(WG) return WG and WG.ConBroker or nil end
function M.StatsTracker(WG) return WG and WG.StatsTracker or nil end

-- The current stance's plan table ({} when there is no strategy or it has no plan).
function M.Plan(WG)
    local st = WG and WG.Strategy
    if st and st.Plan then return st:Plan() or EMPTY end
    return EMPTY
end

-- true while the macro still owes air lab `labID` constructors (the lab controller then adds nothing ahead of them).
function M.TileLabHeld(WG, labID)
    local f = WG and WG.TileLabHold
    return (f and f(labID)) and true or false
end

-- The anti-nuke cover plan's wanted mobile anti-nukes, or nil when defense_crew publishes none.
function M.SaviorWant(WG)
    local a = WG and WG.AntiNuke
    return a and a.saviorWant or nil
end

-- All finished sink labs { [labID] = { id, x, z, ready, decoys, decoyMax, unit, spot } }: WG.SinkLabs (metal_sink.lua), else the
-- older DragonLabs / single DragonLab channels.
function M.SinkLabs(WG)
    if not WG then return EMPTY end
    if WG.SinkLabs then return WG.SinkLabs end
    if WG.DragonLabs then return WG.DragonLabs end
    local d = WG.DragonLab
    if d and d.id then return { [d.id] = d } end
    return EMPTY
end
M.DragonLabs = M.SinkLabs

-- The line's decoy labs { [labID] = { id, x, z, ready, decoys, decoyMax, line } } (line_transition/line_decoy.lua), or an empty table.
function M.DecoyLabs(WG)
    return (WG and WG.DecoyLabs) or EMPTY
end

return M
