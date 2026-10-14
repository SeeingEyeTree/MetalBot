-- tests/test_bot_config.lua     python tests/run_lua.py tests/test_bot_config.lua
-- bar_framework/bot_config.lua: merge + log, typo warnings, presets; and every key in bar_framework/presets/*.lua is a real option
-- of its module (a typo inside a preset would otherwise be applied silently as "unknown").

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local rows = {}
BC.ECHO = function(s) rows[#rows + 1] = s end
local function Rows() local r = rows; rows = {}; return r end

-- Apply: merges in place, logs what changed (sorted), names unknown options, skips declared nil options
do
    local d = { A = 1, B = false, C = "x" }
    local r = BC.Apply("mod", d, { B = true, A = 1, Z = 5, N = 2 }, "BOT", { "N" })
    check(r == d and d.B == true and d.Z == 5 and d.N == 2 and d.A == 1, "overrides are merged into the defaults table in place")
    local out = Rows()
    check(#out == 2, "one 'changed' row plus one unknown-option row (got " .. #out .. ")")
    check(out[1]:find("mod (BOT): 3 changed", 1, true) and out[1]:find("B=true", 1, true) and out[1]:find("N=2", 1, true)
          and out[1]:find("Z=5", 1, true) and not out[1]:find("A=1", 1, true), "the row lists changed keys only (A=1 was already the default)")
    check(out[2]:find("'Z'", 1, true) ~= nil and not out[2]:find("'N'", 1, true), "Z is warned about, the declared nil option N is not")
    BC.Apply("mod", { A = 1 }, { A = 1 })
    check(#Rows() == 0, "nothing changed: no row")
    check(BC.Apply("mod", d, nil) == d and #Rows() == 0, "no overrides: untouched, silent")
    BC.Apply("mod", { T = {} }, { T = { f0 = 1, f1 = 2 } })
    check(Rows()[1]:find("T={f0=1,f1=2}", 1, true) ~= nil, "table values print readably")
end

-- Merge / Preset
do
    check(BC.Merge({ a = 1, b = 2 }, { b = 3 }, nil, { c = 4 }).b == 3, "Merge: later wins")
    VFS_orig = VFS.Include
    local fake = { ONE = { X = 1, Y = 1 }, TWO = { Y = 2 } }
    VFS.Include = function(path) if path:find("presets/fakemod.lua", 1, true) then return fake end return VFS_orig(path) end
    local p = BC.Preset("fakemod", "ONE", "TWO", { Z = 9 })
    check(p.X == 1 and p.Y == 2 and p.Z == 9, "Preset: named groups then plain tables, later wins")
    BC.Preset("fakemod", "NOPE")
    check(Rows()[1]:find("unknown preset 'NOPE'", 1, true) ~= nil, "an unknown preset name is reported")
    VFS.Include = VFS_orig
end

-- every preset key is an option of its module (defaults or the module's NIL_OPTIONS)
do
    local modules = { line_transition = "line_transition", click_army = "click_army" }
    for mod, file in pairs(modules) do
        local M = VFS.Include("LuaUI/Widgets/bar_framework/" .. file .. ".lua")
        local presets = VFS.Include("LuaUI/Widgets/bar_framework/presets/" .. mod .. ".lua")
        local known = {}
        for k in pairs(M.CFG or {}) do known[k] = true end
        for _, k in ipairs(M.NIL_OPTIONS or {}) do known[k] = true end
        check(next(known) ~= nil, mod .. ": module exposes CFG defaults")
        for name, group in pairs(presets) do
            for k in pairs(group) do
                check(known[k], string.format("preset %s.%s: '%s' is not an option of the module", mod, name, k))
            end
        end
    end
end

print(string.format("bot_config: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
