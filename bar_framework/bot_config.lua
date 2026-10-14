-- bar_framework/bot_config.lua  (how a bot configures framework modules: named presets, one log row, typo warnings)
--
-- Every module has a defaults table (LT.CFG, click_army's CFG, ...) and takes per-bot overrides through `cfg = {...}`.  Overrides used
-- to be one long inline table per bot, applied by a copy loop in each module: nothing said which flags a game ran with, and a
-- misspelt key was silently ignored.  Now:
--
--   BC.Apply(module, defaults, overrides, label, nilOptions)   merge overrides into the defaults table (in place) and LOG what changed:
--        [CFG] line_transition (RAID_BOT): 31 changed -- AIR_CON_AT_BACK=true ECELL_FIRST=true GRID_CAP_FRAC=0.6 ...
--        [CFG] click_army (RAID_BOT): unknown option 'EARLY_LAUNHC' (not in the defaults: typo?)
--      A key that is not in the defaults is still applied but is named in a warning, unless the module lists it in `nilOptions`
--      (options whose default is nil on purpose: "off unless set").
--
--   BC.Preset(module, ...)   merge named groups of options for a module, later wins.  Presets live in
--      bar_framework/presets/<module>.lua (a table name -> options), so a flag group is defined once, named for what it does, and a
--      bot lists the groups it wants.  An argument may also be a plain table (this bot's own tweaks and closures):
--
--          cfg = BC.Preset("line_transition", "RETROFIT", "ENERGY_PUSH", "GRID_RECOVER", { CON_HOLD = ConHold })
--
--   BC.Merge(...)   merge plain tables, later wins (the building block of Preset).
--
-- Presets are documentation as much as code: each carries a comment saying what the group does and which game it came from.

local BC = {}

BC.ECHO = function(s) Spring.Echo(s) end   -- replaceable (tests)

local Show
Show = function(v)
    local t = type(v)
    if t == "function" then return "<fn>" end
    if t == "table" then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. Show(x) end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(v)
end

function BC.Merge(...)
    local out = {}
    for i = 1, select("#", ...) do
        local t = select(i, ...)
        if t then for k, v in pairs(t) do out[k] = v end end
    end
    return out
end

local presetFiles = {}
local function PresetTable(module)
    local p = presetFiles[module]
    if p == nil then
        local ok, r = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/presets/" .. module .. ".lua")
        if ok and type(r) == "table" then p = r
        else
            BC.ECHO("[CFG] no presets for " .. module .. ((ok and "") or (": " .. tostring(r))))
            p = false
        end
        presetFiles[module] = p
    end
    return p or {}
end

-- BC.Preset("line_transition", "RETROFIT", { EXTRA = 1 }) -> merged options table
function BC.Preset(module, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if type(a) == "string" then
            local t = PresetTable(module)[a]
            if not t then BC.ECHO(string.format("[CFG] %s: unknown preset '%s'", module, a))
            else parts[#parts + 1] = t end
        elseif type(a) == "table" then
            parts[#parts + 1] = a
        end
    end
    return BC.Merge(unpack(parts))
end

-- Merge `overrides` into `defaults` (in place) and log one row.  Returns `defaults`.
function BC.Apply(module, defaults, overrides, label, nilOptions)
    if not overrides then return defaults end
    local nilOk = {}
    for _, k in ipairs(nilOptions or {}) do nilOk[k] = true end
    local keys = {}
    for k in pairs(overrides) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local changed, unknown = {}, {}
    for _, k in ipairs(keys) do
        local v = overrides[k]
        if defaults[k] == nil and not nilOk[k] then unknown[#unknown + 1] = tostring(k) end
        if defaults[k] ~= v then changed[#changed + 1] = tostring(k) .. "=" .. Show(v) end
        defaults[k] = v
    end
    local who = label and (module .. " (" .. label .. ")") or module
    if #changed > 0 then
        BC.ECHO(string.format("[CFG] %s: %d changed -- %s", who, #changed, table.concat(changed, " ")))
    end
    for _, k in ipairs(unknown) do
        BC.ECHO(string.format("[CFG] %s: option '%s' is not in the defaults (typo, or default nil?)", who, k))
    end
    return defaults
end

return BC
