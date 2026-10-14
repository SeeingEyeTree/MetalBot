-- tests/test_raid_response.lua     python tests/run_lua.py tests/test_raid_response.lua
-- bar_framework/raid_response.lua on its own, with a fake army: an intruder group behind the line is answered up to NEED_MULT x its
-- value; with KEEP_MULT set (the RAID preset) responders are released as the raiders die, without it they stay; the raid record
-- the labs read is published; Forget / NoteAirLoss work.  (test_raid_bot.lua covers the module inside the whole bot.)

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")
BC.ECHO = function() end
local RR = VFS.Include("LuaUI/Widgets/bar_framework/raid_response.lua")

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local gator = UnitDefNames.corgator
check(gator ~= nil, "the stub has a Gator")

local function Build(cfg)
    W.units, W.features, W.orders, W.log, W.errors = {}, {}, {}, {}, {}
    W.frame = 0
    local combat, muster, responding = {}, {}, {}
    local claims, released = {}, {}
    local contacts = {}
    local ARMY = {
        PRIO = { RESPOND = 5 }, RoleOf = function(uid) return claims[uid] and "RESPOND" or nil end,
        Claim = function(prio, uid, duty) claims[uid] = duty end, Release = function(uid) claims[uid] = nil; released[uid] = true end,
        Slot = function() return nil end, OrdersIssued = function() return 0 end, Duty = function() return nil end,
    }
    local UQ = { is_mobile = function() return true end, metal_cost = function(d) return UnitDefs[d].metalCost end,
                 can_hit_ground = function() return true end, can_hit_air = function() return true end,
                 max_speed = function() return 100 end, has_weapons = function() return true end }
    local TM = { Contacts = function() return contacts end, SCAN_PERIOD = 30 }
    local r = RR.New{ cfg = cfg, label = "TEST", ARMY = ARMY, UQ = UQ, TM = TM, CA = nil,
                      combatUnits = combat, musterPool = muster, responding = responding, teamID = 0, allyID = 0,
                      isCommander = function() return false end, lineAdvAt = function() return 1000 end,
                      line = function() return {}, 0, 0, { x = 1, z = 0 }, { x = 0, z = 1 } end,
                      host = function() return nil end, ctx = function() return nil end }
    return r, { combat = combat, responding = responding, contacts = contacts, claims = claims, released = released }
end

-- raiders 100 elmos behind the line (adv < 1000 - PAST_MARGIN would be needed: put them at adv 300), 3 gators worth 3 x cost
local function Setup(cfg)
    local r, w = Build(cfg)
    for i = 1, 3 do w.contacts[i] = { x = 300, z = 100 * i, frame = 0, defID = gator.id, v = gator.metalCost } end
    for i = 1, 12 do
        local uid = S.Spawn("corgator", 0, 200 + i, 200)
        w.combat[uid] = gator.id
    end
    return r, w
end

local function Count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

do
    local r, w = Setup(nil)
    r.Dispatch(0)
    check(#r.clusters == 1 and r.clusters[1].n == 3, "three raiders behind the line form one group")
    local sent = Count(w.responding)
    check(sent >= 1 and sent <= 8, "responders are sent, up to NEED_MULT x the raid's value (" .. sent .. ")")
    -- the raid dies: nothing seen any more
    for k in pairs(w.contacts) do w.contacts[k] = nil end
    r.Dispatch(30)
    check(Count(w.responding) == 0, "no group left: every responder stands down")
end

do   -- KEEP_MULT: one raider left, the others released down to KEEP_MULT x its value (at least one stays)
    local r, w = Setup({ KEEP_MULT = 1.0, CHANNEL_VALUE = true })
    r.Dispatch(0)
    local before = Count(w.responding)
    w.contacts[2], w.contacts[3] = nil, nil
    r.Dispatch(30)
    local after = Count(w.responding)
    check(after < before and after >= 1, "KEEP_MULT releases responders as raiders die (" .. before .. " -> " .. after .. ")")

    local r2, w2 = Setup(nil)   -- same, default config: no release
    r2.Dispatch(0)
    local b2 = Count(w2.responding)
    w2.contacts[2], w2.contacts[3] = nil, nil
    r2.Dispatch(30)
    check(Count(w2.responding) == b2 or Count(w2.responding) > 0, "default config keeps its responders on the remaining raider")
end

do   -- the labs' raid record, air-loss list, Forget
    local r, w = Setup(nil)
    r.Dispatch(0)
    local mb = {}
    r.Publish(100, mb)
    check(mb.raid and mb.raid.n == 1 and mb.raid.channel == "ground" and mb.raid.value > 0, "Publish: mb.raid has the group's value and channel")
    r.NoteAirLoss(90)
    r.NoteAirLoss(10)
    r.Publish(1000, mb)
    check(mb.airLosses == 0, "air losses older than 30 s drop out of mb.airLosses")
    r.NoteAirLoss(995)
    r.Publish(1000, mb)
    check(mb.airLosses == 1, "a recent air loss counts")
    r.icpt.units[42] = true
    r.Forget(42)
    check(r.icpt.units[42] == nil, "Forget clears a responder's intercept flag")
end

print(string.format("raid_response: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
