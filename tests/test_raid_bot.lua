-- tests/test_raid_bot.lua     python tests/run_lua.py tests/test_raid_bot.lua
-- candidates/RAID_BOT's three widgets against the stub (game review 2026-10-13):
--   * no Lua errors; the raid_open stance and the RAID_CA click_army options are live;
--   * a small group launches early (before 6:00, on a handful of units);
--   * no slow group: slow_front never logs;
--   * a Demon kites at the edge of its range (range_kite via the stance), in the field;
--   * a ground raid on the base: raid ON, Wasps from the T2 air lab, (guard) no air/T2 con orders while it is live, responders
--     are released as the raiders die (down to 3x the raid's ground value);
--   * a switch to the hold stance puts click_army in hold mode.
-- The stub teleports units and builds instantly, so this checks wiring and decisions, not play.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- units the RAID_BOT stances name that the stub does not define (mobile and armed here)
local nextId = 9100
local function MobileDef(name, cost, speed, energy, weaponDef)
    local d = { id = nextId, name = name, humanName = name, translatedHumanName = name, speed = speed,
                canFly = false, isBuilder = false, isFactory = false, metalCost = cost, energyCost = energy or cost * 10,
                buildTime = cost * 10, buildSpeed = 0, buildDistance = 0, xsize = 4, zsize = 4,
                weapons = { { weaponDef = weaponDef or 1, onlyTargets = (weaponDef == 2) and { vtol = true } or {} } },
                buildOptions = {}, customParams = {},
                modCategories = {}, canMove = true }
    UnitDefs[d.id], UnitDefNames[name] = d, d
    nextId = nextId + 1
    return d
end
MobileDef("correap", 690, 69)
MobileDef("cordemon", 6000, 63, 90000, 7)     -- long range (stub missile, 700): it outranges a Raider
MobileDef("corshiva", 1600, 48)
MobileDef("corban", 1000, 54)
MobileDef("corjugg", 20000, 20)
MobileDef("corsent", 470, 69, 10500, 2)       -- ground flak (AA only)
MobileDef("coraak", 650, 35, 6200, 2)

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 800, 2000, 300, 100
local dir = "candidates/RAID_BOT"
S.LoadWidget(dir .. "/macro_controller.lua")
S.LoadWidget(dir .. "/lab_controller.lua")
S.LoadWidget(dir .. "/unit_controller.lua")
S.Callin("Initialize")
local hx, hz = W.start[0][1], W.start[0][2]
local ex, ez = W.start[1][1], W.start[1][2]
S.Spawn("corcom", 0, hx, hz)
S.Spawn("corcom", 1, ex, ez)
S.Spawn("cormex", 1, ex - 150, ez, { silent = true })
S.Spawn("cornanotc", 1, ex + 150, ez, { silent = true })
local aap = S.Spawn("coraap", 0, hx + 300, hz + 200)       -- T2 air lab (UnitFinished: the lab controller sees it)

-- count air / T2 con orders (corca / coraca), by frame
local conOrders = {}
local giveOrder = Spring.GiveOrderToUnit
local conIds = { [UnitDefNames.corca.id] = true, [UnitDefNames.coraca.id] = true }
Spring.GiveOrderToUnit = function(id, cmd, params, opts)
    local d = cmd and cmd < 0 and -cmd
    if cmd == CMD.INSERT and params and params[2] and params[2] < 0 then d = -params[2] end
    if d and conIds[d] then conOrders[#conOrders + 1] = W.frame end
    return giveOrder(id, cmd, params, opts)
end

local demon, raiders, raidOn, raidEnd = nil, {}, 9 * 1800, 10 * 1800
local flak, shuri = {}, nil
for f = 0, 14 * 1800, 10 do
    W.res.metal.cur = 800
    if f == 4 * 1800 then
        for i = 1, 8 do S.Spawn("corgator", 0, hx + 400 + i * 12, hz + 400) end
        shuri = S.Spawn("corbw", 0, 6000, 6000)             -- a Shuriken far from home: it should go home
    end
    if f == 8 * 1800 then
        for i = 1, 5 do flak[i] = S.Spawn("corsent", 0, hx + 300 + i * 12, hz + 300) end
    end
    if f == 7 * 1800 - 300 then
        -- fill the home garrison (at most 8 ground units stay home) so the Demon below is a field unit, not a guard
        for i = 1, 40 do S.Spawn("corgator", 0, hx + 500 + (i % 10) * 12, hz + 500 + math.floor(i / 10) * 12) end
    end
    if f == 7 * 1800 then
        -- a Demon in the open field with an enemy raider closing inside its range (stub laser: 300; edge 255)
        S.Spawn("corraid", 1, 6200, 6000, { silent = true })
        demon = S.Spawn("cordemon", 0, 6000, 6000)
    end
    if f == raidOn then
        -- a ground raid right by our base (behind the contact line)
        for i = 1, 10 do raiders[#raiders + 1] = S.Spawn("corak", 1, hx - 250 + i * 15, hz - 80) end
        for i = 1, 12 do S.Spawn("corgator", 0, hx + 200 + i * 12, hz + 200) end
    end
    if f == raidOn + 30 * 30 then
        for i = 1, 8 do S.Kill(raiders[i]) end            -- the raid is mostly dead: 2 Grunts left
    end
    if f == raidEnd then
        for i = 9, 10 do S.Kill(raiders[i]) end
    end
    -- the game plan switches to hold (the switch hook decides every tick, so it is replaced, not overridden by Set)
    if f == 11 * 1800 and WG.Strategy then WG.Strategy.hooks.switch = function() return "hold" end end
    S.Frame(f)
    if #W.errors > 0 then break end
end
Spring.GiveOrderToUnit = giveOrder

for _, e in ipairs(W.errors) do print("LUA ERROR: " .. e) end
check(#W.errors == 0, "RAID_BOT widgets run 14 minutes without Lua errors")
check(#S.Log("%[STRAT%] stance raid_open") >= 1, "the raid_open stance is loaded")
check(WG.Strategy and WG.Strategy:Plan() ~= nil, "the strategy publishes a plan")
check(#S.Log("%[SF%]") == 0 and #S.Log("slow group") == 0, "no slow group")

local launches = S.Log("%[CK%] (%d+):(%d+) group #1 launch: (%d+) units")
local early = false
for _, l in ipairs(launches) do
    local m, s, n = l:match("%[CK%] (%d+):(%d+) group #1 launch: (%d+) units")
    if tonumber(m) < 6 and tonumber(n) >= 3 then early = true end
end
check(early, "a group of >= 3 units launches before 6:00 (" .. tostring(launches[1]) .. ")")

local rk = S.Log("%[RKITE%]")
check(#rk >= 1, "the Demon range-kites an enemy inside its range (stance behaviour)")
if rk[1] then print(rk[1]) end

check(#S.Log("%[LabCtrl%] 9:%d+ raid ON") >= 1, "the ground raid is seen by the labs")
local wasps = S.Log("%[LabCtrl%] 9:%d+ raid%-air +corape")
check(#wasps >= 1, "the T2 air lab answers the ground raid with Wasps (" .. #wasps .. " orders)")
local during = 0
for _, f in ipairs(conOrders) do if f >= raidOn + 300 and f <= raidOn + 600 then during = during + 1 end end
-- (the stub orders no cons around 9:00 anyway, so this is only a guard; CON_HOLD itself: tests/test_con_hold.lua)
check(during == 0, "no air / T2 con orders while the ground raid is live (" .. during .. ")")
print(string.format("con orders: %d in the game, %d during the raid", #conOrders, during))
local rel = S.Log("%[INTERCEPT%] .*release")
check(#rel >= 1, "responders are released as the raiders die")
if rel[1] then print(rel[1]) end

check(#S.Log("%[CK%] 11:%d+ mode %-> hold") == 1, "the hold stance puts click_army in hold mode")

-- second T1 air lab on the line (the stub line is all mexes: the block with the fewest is reclaimed)
-- (started, not finished: with the grid gate counting helpers as idle the stub's nanos stay on the grids and its lab frame never gets
-- built; in real RAID_BOT vacuum games the lab site is done 20-50 s after the start, 12:00 -> ~12:30)
check(#S.Log("%[LT%] .*second air lab due") == 1, "the second T1 air lab falls due on the line (at 12:00)")
check(#S.Log("lab2 [1-9]") >= 1, "...and a con is ordered for it when none is free (the stub lab never delivers it)")
-- standing Shuriken force at home
local function D(id, x, z) local u = W.units[id]; return u and math.sqrt((u.x - x) ^ 2 + (u.z - z) ^ 2) or nil end
local cx, cz = hx, hz
for id, u in pairs(W.units) do if u.team == 0 and UnitDefs[u.defID].name == "corcom" then cx, cz = u.x, u.z end end
check(shuri and D(shuri, cx, cz) and D(shuri, cx, cz) < 800, "a Shuriken is kept at home (" .. tostring(shuri and D(shuri, cx, cz)) .. " from the commander)")
-- ground AA: a screen round the base, the rest with the army
local onRing, away = 0, 0
for _, id in ipairs(flak) do
    local d = D(id, hx, hz)
    if d and math.abs(d - 1100) < 150 then onRing = onRing + 1 elseif d and d > 1400 then away = away + 1 end
end
check(onRing == 2 and away == 3, string.format("ground AA: 2 of 5 on the base screen ring, 3 with the army (%d / %d)", onRing, away))
-- a standing pool of Hawks from the T2 air lab
check(#S.Log("radar%-pool +corawac") >= 1, "the T2 air lab keeps a pool of Hawks (" .. #S.Log("radar%-pool") .. " orders)")
check(#S.Log("%[STRAT%] stance hold") == 1, "the hold stance is taken")

local CB_ = VFS.Include("LuaUI/Widgets/bar_framework/con_broker.lua")
-- the air-con broker (con_broker.lua): every air con alive is managed exactly once, owned by a registered job (or an outside owner)
do
    local cbk = WG.ConBroker
    check(cbk ~= nil, "the con broker is published on WG")
    if cbk then
        local alive, managed, orphan = 0, 0, 0
        for id, u in pairs(W.units) do
            local d = UnitDefs[u.defID]
            if u.team == 0 and d.isBuilder and d.canFly and not d.isFactory then
                alive = alive + 1
                if CB_.IsManaged(cbk, id) then managed = managed + 1 end
            end
        end
        for _, c in ipairs(cbk.list) do
            if not W.units[c.id] then orphan = orphan + 1 end
            if c.owner and not cbk.byName[c.owner] and c.owner ~= "spine" and c.owner ~= "cover" and c.owner ~= "assist" and c.owner ~= "line" and c.owner ~= "rez" and c.owner ~= "defense" then orphan = orphan + 1 end
        end
        check(alive > 0 and managed == alive, "every air con alive is managed (" .. managed .. " of " .. alive .. ")")
        local line = 0
        for _, c in ipairs(cbk.list) do if c.owner == "line" then line = line + 1 end end
        check(line >= 1, "the starter-lab cons are claimed by the line in the broker (" .. line .. ")")
        check(orphan == 0, "no dead con and no unknown owner in the broker (" .. orphan .. ")")
        check(#S.Log("%[CB%]") >= 5, "the broker logs its holdings")
        print(S.Log("%[CB%]")[#S.Log("%[CB%]")])
    end
end
do  -- every WG channel the bot published fits bar_framework/wg_channels.lua SCHEMA
    local CHK = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")
    local bad = CHK.Validate(WG)
    check(#bad == 0, "WG channels match the schema" .. (bad[1] and (": " .. bad[1]) or ""))
end
print(string.format("raid_bot: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
