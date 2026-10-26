-- tests/test_rez_broker.lua     python tests/run_lua.py tests/test_rez_broker.lua
-- bar_framework/rez_broker.lua with rez_crew's finders, the map model and army_broker replaced by fakes: jobs by priority, a bot
-- HOLDS its job (no flip-flop), reservations (one wreck / friend
-- per bot), identical claims for a held job, dead bots release what they held, AddJob for new logic; and lab_broker's lab.only.

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- ── fake world ──
local units, features = {}, {}
local bank = 0.8
Spring = {
    Echo = function() end,
    GetUnitDefID = function(id) return units[id] and 1 or nil end,
    GetUnitHealth = function(id) local u = units[id]; if u then return u.hp, 100 end end,
    GetUnitPosition = function(id) local u = units[id]; if u then return u.x, 0, u.z end end,
    ValidFeatureID = function(id) return features[id] ~= nil end,
    GetMyTeamID = function() return 0 end,
    GetTeamResources = function() return bank * 1000, 1000 end,
    GetFeatureResources = function(id) return features[id] and features[id].metal or 0 end,
}
local claims = {}
local ARMY = { PRIO = { HOME_GUARD = 4 }, Claim = function(prio, uid, spec, frame) claims[uid] = spec end }
local MM = { Ready = function() return true end, Home = function() return 0, 0 end, Axis = function() return 1, 0 end,
             Perp = function() return 0, 1 end, Clamp = function(x, z) return x, z end }
local crew = {}
local friends = {}          -- the unit DamagedFriend() starts a repair on: { [botID] = friendID }
local RC = {
    REPAIR_RADIUS = 900, TRAIL = 700, TRAIL_SPREAD = 250, RECLAIM_FIRST = true,
    Members = function() local t = {}; for id in pairs(crew) do if units[id] then t[#t + 1] = id end end; table.sort(t); return t end,
    RefreshNanos = function() end,
    HealPoint = function() return 10, 20, "nano" end,
    DamagedFriend = function(uid) return friends[uid] end,
    BestWreck = function(frame, uid, x, z, busy, noRez)
        local best
        for fid, f in pairs(features) do
            if (not busy[fid] or busy[fid] == uid) and f.safe ~= false and (not best or fid < best) then best = fid end
        end
        if best then
            local cmd = features[best].cmd or 90
            if cmd == 125 and noRez then cmd = 90 end       -- the real finder reclaims what it would not resurrect
            return best, cmd
        end
    end,
}

local RB = dofile("bar_framework/rez_broker.lua")
local function Fresh()
    units, features, claims, crew, friends = {}, {}, {}, {}, {}
    RB.Init{ RC = RC, MM = MM, ARMY = ARMY }
end
local function Bot(id, hp) units[id] = { hp = hp or 100, x = 1000, z = 1000 }; crew[id] = true end
local frame = 0
local function Pass(n) frame = frame + (n or 60); RB.Update(frame, 3000, 1000) end

-- 1. nothing to do: trail ------------------------------------------------------------------
Fresh(); frame = 0
Bot(1)
Pass()
check(claims[1] and claims[1].cmd == 10 and claims[1].role == "REZ", "no job: the bot trails the front (MOVE)")
check(claims[1].x == 2300, "...at the front minus TRAIL")

-- 2. a wreck is taken, held, and not swapped for a better one that appears --------------------
features[5] = { metal = 50 }
Pass()
check(claims[1].cmd == 90 and claims[1].targetID == 5 + 32000, "a wreck outranks trailing (reclaim claim, feature id offset)")
features[3] = { metal = 500, cmd = 125 }
Pass()
check(claims[1].targetID == 5 + 32000, "a better wreck appearing does not pull a bot off the one it is working (no flip-flop)")
Pass(); Pass()
check(claims[1].targetID == 5 + 32000, "...still working it later")
features[5] = nil
Pass()
check(claims[1].targetID == 3 + 32000 and claims[1].cmd == 125, "the wreck gone: the next pick is the other wreck (resurrect)")

-- 3. repair is lower than a safe wreck; a friend is repaired up to REPAIR_STOP -------------------
Fresh(); frame = 0
Bot(1); units[9] = { hp = 80, x = 1100, z = 1000 }
friends[1] = 9
Pass()
check(claims[1].cmd == 40 and claims[1].targetID == 9, "a damaged friend and no wreck: repair")
friends[1] = nil                      -- rez_crew's start threshold no longer reports it ...
units[9].hp = 90
Pass()
check(claims[1].cmd == 40 and claims[1].targetID == 9, "...the repair continues while the friend is below REPAIR_STOP")
units[9].hp = 100
Pass()
check(claims[1].cmd == 10, "...and ends when the friend is healed (back to trailing)")
-- a wreck (higher) appears while repairing: after MIN_HOLD it takes the bot
units[9].hp = 50; friends[1] = 9
Pass()
check(claims[1].cmd == 40, "repairing again")
features[2] = { metal = 80 }
Pass(30)
check(claims[1].cmd == 40, "a wreck does not preempt a job held under MIN_HOLD")
Pass(200)
check(claims[1].cmd == 90, "...but does once MIN_HOLD has passed (the higher-priority job)")

-- 4. reclaim by default; RESURRECT only with a full-enough bank --------------------------------------
Fresh(); frame = 0
bank = 0.3
Bot(1); features[3] = { metal = 500, cmd = 125 }
Pass()
check(claims[1].cmd == 90, "bank at 30%: an armed wreck is reclaimed, not resurrected")
bank = 0.8
features[3].metal = 500
Fresh(); frame = 0
Bot(1); features[3] = { metal = 500, cmd = 125 }
Pass()
check(claims[1].cmd == 125, "bank at 80%: the same wreck is resurrected")
bank = 0.45
Pass()
check(claims[1].cmd == 125, "bank dips to 45% (between KEEP and BANK): the resurrect under way continues")
bank = 0.2
Pass()
check(claims[1].cmd == 90, "bank under RESURRECT_KEEP: the bot swaps to reclaiming that wreck")
bank = 0.45
Fresh(); frame = 0
Bot(1); features[3] = { metal = 500, cmd = 125 }
Pass()
check(claims[1].cmd == 90, "bank at 45% (under RESURRECT_BANK): a new job reclaims")
bank = 0.8

-- 5. reservations ----------------------------------------------------------------------------
Fresh(); frame = 0
Bot(1); Bot(2); features[7] = { metal = 100 }
Pass()
check(claims[1].targetID == 7 + 32000, "bot 1 takes the only wreck")
check(claims[2].cmd == 10, "bot 2 trails: the wreck is reserved")
features[8] = { metal = 100 }
Pass()
check(claims[2].targetID == 8 + 32000, "a second wreck: bot 2 takes it")
-- two bots, one hurt friend
Fresh(); frame = 0
Bot(1); Bot(2); units[9] = { hp = 50, x = 1000, z = 1000 }; friends[1], friends[2] = 9, 9
Pass()
check(claims[1].cmd == 40 and claims[2].cmd == 10, "one hurt friend: one repairer (SPREAD_FRIENDS), the other trails")
-- a dead bot frees its wreck
Fresh(); frame = 0
Bot(1); Bot(2); features[7] = { metal = 100 }
Pass()
units[1] = nil; crew[1] = nil
Pass()
check(claims[2].targetID == 7 + 32000, "the bot that held a wreck died: the other takes it")

-- 6. a held job re-claims an identical spec (army_broker then issues nothing new) -------------------
Fresh(); frame = 0
Bot(1); features[7] = { metal = 100 }
Pass(); local a = claims[1]; claims[1] = nil
Pass(); local b = claims[1]
check(a.cmd == b.cmd and a.targetID == b.targetID and a.role == b.role, "a held job claims the same thing every pass")

-- 7. new logic is one AddJob ----------------------------------------------------------------------
Fresh(); frame = 0
Bot(1)
local want = nil
RB.AddJob{ name = "guard-lab", prio = 70,
    find = function(bot) if want then return { x = want } end end,
    valid = function(bot, st) return want ~= nil end,
    claim = function(bot, st) return { role = "REZ", cmd = 10, x = st.target.x, z = 0 } end }
Pass()
check(claims[1].cmd == 10 and claims[1].x ~= 777, "a registered job that finds nothing does nothing")
want = 777
Pass(200)
check(claims[1].x == 777, "a registered job outranks the built-ins and takes the bot")
want = nil
Pass()
check(claims[1].x ~= 777, "...and releases it when it is no longer valid")
check(not pcall(RB.AddJob, { name = "guard-lab", find = function() end, claim = function() end }), "a job name registers once")

-- 8. lab_broker: lab.only ---------------------------------------------------------------------------
do
    local LB = dofile("bar_framework/lab_broker.lua")
    local log, q = {}, 0
    local lb = LB.New{ queueLen = function() return q end, order = function(id, d) log[#log + 1] = d end,
                       insert = function(id, d) log[#log + 1] = d end, echo = function() end, unitName = tostring }
    LB.AddWant(lb, { name = "rez-lab", prio = 200, mode = "topup", depth = 2, applies = function(l) return l.isRezLab end,
                     pick = function() return 11 end })
    LB.AddWant(lb, { name = "scout", prio = 50, mode = "empty", pick = function() return 22 end })
    LB.Service(lb, { id = 1, defID = 1, isRezLab = true, only = "rez-lab" }, 0)
    check(#log == 2 and log[1] == 11 and log[2] == 11, "lab.only: the owning want fills the lab to its depth")
    log = {}
    local lb2 = LB.New{ queueLen = function() return 0 end, order = function(id, d) log[#log + 1] = d end,
                        insert = function() end, echo = function() end, unitName = tostring }
    LB.AddWant(lb2, { name = "rez-lab", prio = 200, mode = "topup", applies = function() return false end, pick = function() return 11 end })
    LB.AddWant(lb2, { name = "scout", prio = 50, mode = "empty", pick = function() return 22 end })
    LB.Service(lb2, { id = 1, defID = 1, only = "rez-lab" }, 0)
    check(#log == 0, "lab.only: no other want (the scout rule) may order the lab, even when the owner has nothing")
    LB.Service(lb2, { id = 2, defID = 1 }, 200)
    check(log[1] == 22, "a lab without `only` is served by every want as before")
end

print(string.format("rez_broker: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
