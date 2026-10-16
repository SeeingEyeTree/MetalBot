-- tests/test_defence_bot.lua     python tests/run_lua.py tests/test_defence_bot.lua
-- candidates/DEFENCE_BOT (CORE + the maneuver-defence stances) against the stub: a wiring check.
--   * no Lua errors and no widget removed, through 14 game-minutes;
--   * standard_t1_defence is the opening stance and standard_t2_defence is taken once, when income holds;
--   * Brutes and Pounders that appear go to maneuver_defence (blobs / backstop), a Rascal with the shadow behaviour goes to the
--     behaviour host (MOVE orders, not in the blobs) and click_army launches nothing;
--   * the army value the share hook reads counts the blobs and the shadows.
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 800, 2000, 300, 100
local dir = "candidates/DEFENCE_BOT"
S.LoadWidget(dir .. "/macro_controller.lua")
S.LoadWidget(dir .. "/lab_controller.lua")
S.LoadWidget(dir .. "/unit_controller.lua")
S.Callin("Initialize")
local hx, hz = W.start[0][1], W.start[0][2]
local ex, ez = W.start[1][1], W.start[1][2]
S.Spawn("corcom", 0, hx, hz)
S.Spawn("corcom", 1, ex, ez)
S.Spawn("corlab", 1, ex - 200, ez, { silent = true })

local movedIds = {}                -- units that got a MOVE (the stub drains W.orders every frame, so the order sink is wrapped)
local giveOrig = Spring.GiveOrderToUnit
Spring.GiveOrderToUnit = function(id, cmd, ...)
    if cmd == 10 then movedIds[id] = true end
    return giveOrig(id, cmd, ...)
end
local brutes, pounders, rascals = {}, {}, {}
local armyValueSeen = 0
local movedBefore, nRascals = 0, 0
for f = 0, 14 * 1800, 10 do
    if f == 9 * 1800 - 10 then    -- before the T2 switch: which Rascals has the shadow behaviour moved?
        for id, u in pairs(W.units) do
            if u.defID == UnitDefNames.corfav.id then
                nRascals = nRascals + 1
                if movedIds[id] then movedBefore = movedBefore + 1 end
            end
        end
    end
    if f == 12 * 1800 then        -- leave the maneuver plan: the army is released to the new stance (here a raid stance)
        WG.Strategy.hooks.switch = nil
        WG.Strategy.stances.raid_open = WG.Strategy.loader.Load("raid_open")
        WG.Strategy.stances.raid_open.name = "raid_open"
        WG.Strategy:Set("raid_open")
    end
    W.res.metal.cur = 800
    W.res.metal.income = (f < 9 * 1800 and 300) or 1500
    if f == 5 * 1800 then
        S.Spawn("corvp", 0, hx + 300, hz + 300, { silent = true })
        for i = 1, 12 do brutes[#brutes + 1] = S.Spawn("corraid", 0, hx + 400 + i * 15, hz + 400) end
        for i = 1, 3 do pounders[#pounders + 1] = S.Spawn("corlevlr", 0, hx + 400 + i * 15, hz + 450) end
        for i = 1, 2 do rascals[#rascals + 1] = S.Spawn("corfav", 0, hx + 400 + i * 15, hz + 500) end
    end
    S.Frame(f)
    if f == 6 * 1800 then armyValueSeen = (WG.MetalBot and WG.MetalBot.armyValue) or 0 end
end

check(#W.errors == 0, "no Lua errors (" .. tostring(W.errors[1]) .. ")")
check(#S.Log("Removed widget") == 0, "no widget removed")
check(#S.Log("%[STRAT%] stance standard_t1_defence") >= 1, "the opening stance is standard_t1_defence")
check(#S.Log("%[STRAT%].*switching to stance standard_t2_defence") == 1, "standard_t2_defence is taken once, when income holds")
check(#S.Log("%[MD%].*blobs") >= 1, "maneuver_defence logs its blobs")
local nBlobUnits = 0
for _, row in ipairs(S.Log("%[MD%].*blobs")) do
    local n = tonumber(row:match("(%d+) units"))
    if n and n > nBlobUnits then nBlobUnits = n end
end
check(nBlobUnits >= 15, "the 12 Brutes and 3 Pounders are in maneuver_defence (" .. nBlobUnits .. " units in the largest [MD] row)")
local moved, nR = movedBefore, nRascals
check(moved >= 1 and moved <= 3, "the Rascals with the shadow behaviour are moved by the behaviour host: " .. moved .. " of " .. nR .. " (max = 3)")
do
    local rows = S.Log("%[UnitCtrl%].*stance standard_t1_defence %-> standard_t2_defence")
    local n = rows[1] and tonumber(rows[1]:match(": (%d+) units released"))
    check(n and n >= 15 and rows[1]:find("maneuver plan"), "T1 -> T2 defence: the units are released and taken by the T2 stance (" .. tostring(rows[1]) .. ")")
    local out = S.Log("%[UnitCtrl%].*stance standard_t2_defence %-> raid_open")
    local m = out[1] and tonumber(out[1]:match(": (%d+) units released"))
    check(m and m >= 15 and out[1]:find("click_army plan"), "leaving the maneuver plan releases the army to click_army (" .. tostring(out[1]) .. ")")
    local after = 0
    for _, row in ipairs(S.Log("%[MD%].*blobs")) do
        local min = tonumber(row:match("^(%d+):"))
        if min and min >= 13 then after = after + 1 end
    end
    check(after == 0, "maneuver_defence stops running once the plan is left")
end
check(#S.Log("%[CA%] .*launch") == 0, "click_army launches nothing under the maneuver plan")
check(armyValueSeen >= 12 * 235, "the army value counts the blobs (" .. armyValueSeen .. ")")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
