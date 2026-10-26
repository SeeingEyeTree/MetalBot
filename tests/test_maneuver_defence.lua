-- tests/test_maneuver_defence.lua: bar_framework/maneuver_defence.lua (blobs on a perimeter, intercept ~2x, return to post).
-- Run: python tests/run_lua.py tests/test_maneuver_defence.lua
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local MD   = VFS.Include("LuaUI/Widgets/bar_framework/maneuver_defence.lua")
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
local MAP = 12288
local function D(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end
local BRUTE, POUND = UnitDefNames.corraid.id, UnitDefNames.corlevlr.id

-- ── pure: blob count ──
local K = MD.CFG
check(select(1, MD.BlobCount(5000, 72, 24, K)) == 6, "24 brutes on a 5000 line: 6 blobs (min blob 4)")
check(select(1, MD.BlobCount(5000, 72, 8, K)) == 2, "8 brutes: 2 blobs, fewer than the line needs")
check(select(2, MD.BlobCount(5000, 72, 8, K)) == 7, "the full spacing needs ceil(5000 / 720) = 7 slots")
check(select(1, MD.BlobCount(5000, 72, 400, K)) == 7, "a big army is capped by the 10 s spacing")
check(select(1, MD.BlobCount(5000, nil, 0, K)) == 0, "no movers: no blobs")

local function Setup(nBrute, nPound, opts)
    W.units, W.orders = {}, {}
    S.Spawn("corwin", 0, 6000, 6000, { silent = true })
    S.Spawn("corwin", 0, 6400, 6000, { silent = true })
    local contacts = {}
    local md = MD.New{ ARMY = ARMY, teamID = 0, mapX = MAP, mapZ = MAP, enemyBase = function() return 11500, 6000 end,
                       contacts = function() return contacts end, cfg = opts }
    local brutes, pounders = {}, {}
    for i = 1, nBrute do
        local id = S.Spawn("corraid", 0, 6200 + i * 5, 6200, { silent = true })
        brutes[#brutes + 1] = id; MD.Add(md, id, BRUTE)
    end
    for i = 1, nPound do
        local id = S.Spawn("corlevlr", 0, 6200 + i * 5, 6300, { silent = true })
        pounders[#pounders + 1] = id; MD.Add(md, id, POUND)
    end
    return md, contacts, brutes, pounders
end
local frame = 0
local function Step(md, n, each)
    for _ = 1, n or 1 do
        frame = frame + 30; W.frame = frame
        if each then each() end
        ARMY.Sweep(frame); MD.Update(md, frame)
    end
end
local function LastOrder(id) for i = #W.orders, 1, -1 do if W.orders[i].id == id then return W.orders[i] end end end
local function Put(id, x, z) W.units[id].x, W.units[id].z = x, z end

-- ── blobs: 10 s apart ──
local md, contacts, brutes, pounders = Setup(24, 4)
Step(md, 1)
check(#md.blobs == 6, "24 brutes: 6 blobs (" .. #md.blobs .. ")")
local maxGap = 0
for i = 1, #md.blobs - 1 do
    local a, b = md.blobs[i], md.blobs[i + 1]
    maxGap = math.max(maxGap, D(a.x, a.z, b.x, b.z))
end
check(maxGap <= 72 * 10 + 1, "neighbouring blobs are at most 10 s of brute speed apart (" .. math.floor(maxGap) .. " <= 720)")
local per = {}
for _, id in ipairs(brutes) do per[md.units[id].blob] = (per[md.units[id].blob] or 0) + 1 end
local lo, hi = 99, 0
for _, n in pairs(per) do lo, hi = math.min(lo, n), math.max(hi, n) end
check(hi - lo <= 1, "blobs are balanced (" .. lo .. ".." .. hi .. ")")
for _, id in ipairs(pounders) do
    local h = md.homeOf(id)
    local nearest = 1e9
    for _, b in ipairs(md.blobs) do nearest = math.min(nearest, D(h.x, h.z, b.x, b.z)) end
    check(h and nearest < 300 and D(h.x, h.z, md.centre.x, md.centre.z) > 400, "the backstop Pounder holds the line with a blob (" .. math.floor(nearest) .. " from its post), not the base centre")
end
local usedBlobs = {}
for _, id in ipairs(pounders) do
    local h = md.homeOf(id)
    for i, b in ipairs(md.blobs) do if D(h.x, h.z, b.x, b.z) < 300 then usedBlobs[i] = true end end
end
local nUsed = 0
for _ in pairs(usedBlobs) do nUsed = nUsed + 1 end
check(nUsed >= 3, "the 4 Pounders are spread over different blobs (" .. nUsed .. ")")
local o = LastOrder(brutes[1])
check(o and o.cmd == ARMY.CMD_FIGHT, "a brute FIGHTs at its post")

-- ── a small army: fewer, fatter blobs on the enemy side ──
local md2 = Setup(8, 0)
Step(md2, 1)
check(#md2.blobs == 2, "8 brutes: 2 blobs (" .. #md2.blobs .. ")")
local facing = true
for _, b in ipairs(md2.blobs) do if b.x < md2.centre.x - 50 then facing = false end end
check(facing, "the two blobs are on the enemy (east) side")

-- ── a raid: ~2x, nearest first, pounders stay ──
md, contacts, brutes, pounders = Setup(24, 4)
Step(md, 2)
local homes = {}
for _, id in ipairs(brutes) do homes[id] = md.homeOf(id); Put(id, homes[id].x, homes[id].z) end
for _, id in ipairs(pounders) do local hp = md.homeOf(id); Put(id, hp.x, hp.z) end
Step(md, 1)
check(next(md.responding) == nil, "units standing at their posts are neither out nor returning")
local function Group(x, z, n)
    for i = 1, n do contacts[#contacts + 1] = { x = x + (i % 3) * 30, z = z + math.floor(i / 3) * 30, defID = BRUTE, frame = frame, v = 1, air = false } end
end
local function Fresh() for _, c in pairs(contacts) do c.frame = frame end end
Group(7800, 6000, 3)                                       -- 1400 east of the base: 3 x 235 = 705 -> need 1410 = 6 brutes
Step(md, 1, Fresh)
local out, outV = 0, 0
for uid, r in pairs(md.responding) do if r.state == "out" then out = out + 1; outV = outV + md.units[uid].v end end
check(out >= 5 and out <= 8, "about 2x the group's value goes: " .. out .. " units (" .. outV .. " of need 1410)")
check(out < 24, "never the whole army")
for _, id in ipairs(pounders) do check(md.responding[id] == nil, "a Pounder never intercepts") end
local mv = 0
for uid, r in pairs(md.responding) do local l = LastOrder(uid); if l and l.cmd == ARMY.CMD_MOVE then mv = mv + 1 end end
check(mv == out, "a group not yet in contact: the responders MOVE to meet it (" .. mv .. "/" .. out .. ")")
check(#S.Log("%[MD%].*group of") >= 1, "the dispatch is logged")
local between = 0
for uid, r in pairs(md.responding) do
    local l = LastOrder(uid)
    if l and l.cmd == ARMY.CMD_MOVE and l.params[1] < 7800 and l.params[1] > 6400 then between = between + 1 end
end
check(between == out, "the meeting points are ahead of the group, between it and the base (" .. between .. "/" .. out .. ")")

-- the group walks at 85/s toward the base; the responders keep up and stay between it and the base
for _ = 1, 6 do
    Step(md, 1, function()
        for _, c in pairs(contacts) do c.x = c.x - 85; c.frame = frame end
        for uid, r in pairs(md.responding) do
            local l = LastOrder(uid)
            if l and r.state == "out" then Put(uid, l.params[1], l.params[3]) end
        end
    end)
end
check(next(md.responding) ~= nil, "the responders stay on the group while it is in sight")
-- the group stops dead (as if engaged): the responders still only MOVE, to a point in front of it -- never FIGHT
for _ = 1, 4 do Step(md, 1, function() for _, c in pairs(contacts) do c.frame = frame end end) end
local fights, moves2, front = 0, 0, 0
local gx0
for _, c in pairs(contacts) do gx0 = gx0 and math.min(gx0, c.x) or c.x end
for uid, r in pairs(md.responding) do
    if r.state == "out" then
        local l = LastOrder(uid)
        if l and l.cmd == ARMY.CMD_FIGHT then fights = fights + 1 end
        if l and l.cmd == ARMY.CMD_MOVE then moves2 = moves2 + 1; if l.params[1] < gx0 + 40 then front = front + 1 end end
    end
end
check(fights == 0 and moves2 >= out - 1, "interception never uses FIGHT, also against a stopped group (" .. fights .. " fights, " .. moves2 .. " moves)")
check(front >= moves2 - 1, "...the MOVE points are on the base side of the group (" .. front .. "/" .. moves2 .. ")")

-- ── it is destroyed: after GONE_S the responders are released and go back to their posts ──
for k in pairs(contacts) do contacts[k] = nil end
Step(md, MD.CFG.GONE_S + 2)
local back = 0
for uid in pairs(homes) do
    local r = md.responding[uid]
    if r and r.state == "return" then back = back + 1 end
end
check(back == out, "all " .. out .. " responders are released when the group is gone (" .. back .. ")")
check(md.released >= out, "released is counted")
for uid in pairs(md.responding) do
    local l = LastOrder(uid)
    check(l and l.cmd == ARMY.CMD_MOVE, "a returning unit MOVEs (does not FIGHT, so it does not chase)")
    break
end
Step(md, 1, function() for uid in pairs(md.responding) do local h = md.homeOf(uid); Put(uid, h.x, h.z) end end)
Step(md, 1)
check(next(md.responding) == nil, "once home, nobody is out or returning")
check(md.returned >= out, "returns are counted (" .. md.returned .. ")")

-- ── a unit that drifts (chases something) is pulled back ──
local d1 = brutes[3]
local h = md.homeOf(d1)
Put(d1, h.x + 1500, h.z)
Step(md, 4)                                                 -- (the broker re-orders a unit at most every 90 frames)
check(md.responding[d1] and md.responding[d1].state == "return", "a unit 1500 from its post is pulled back")
local l = LastOrder(d1)
check(l and l.cmd == ARMY.CMD_MOVE and D(l.params[1], l.params[3], h.x, h.z) < 160, "...by a MOVE to its post")

-- ── scouts are no threat; a group camping outside the ring is no raid ──
md, contacts, brutes, pounders = Setup(24, 4)
Step(md, 2)
for _, id in ipairs(brutes) do local hh = md.homeOf(id); Put(id, hh.x, hh.z) end
for _, id in ipairs(pounders) do local hh = md.homeOf(id); Put(id, hh.x, hh.z) end
Step(md, 1)
for i = 1, 3 do contacts[#contacts + 1] = { x = 7800 + i * 20, z = 6000, defID = UnitDefNames.corfav.id, frame = frame, v = 1, air = false } end
Step(md, 1, Fresh)
check(next(md.responding) == nil and md.intercepts == 0, "three Rascal-class contacts (value < 80 each) are scouts: nobody goes")
for k in pairs(contacts) do contacts[k] = nil end
Group(7800, 6000, 3)
Step(md, 1, Fresh)
local campOut = 0
for _, r in pairs(md.responding) do if r.state == "out" then campOut = campOut + 1 end end
check(campOut >= 5, "a real group outside the ring is met (" .. campOut .. ")")
local ic0 = md.intercepts
Step(md, MD.CFG.STAY_S + 3, Fresh)                       -- it just stands there
campOut = 0
for _, r in pairs(md.responding) do if r.state == "out" then campOut = campOut + 1 end end
check(campOut == 0, "after STAY_S a group camping outside the ring is no raid: its responders are released (" .. campOut .. " still out)")
check(md.intercepts == ic0, "...and it is not met again while it stands still")
for _, c in pairs(contacts) do c.x = c.x - 300 end         -- it moves again
Step(md, 2, function() for _, c in pairs(contacts) do c.x = c.x - 100; c.frame = frame end end)
campOut = 0
for _, r in pairs(md.responding) do if r.state == "out" then campOut = campOut + 1 end end
check(campOut >= 5, "...but once it moves it is met again (" .. campOut .. ")")

-- ── radar dots (contacts with no unit type) ──
md, contacts, brutes, pounders = Setup(24, 4)
Step(md, 2)
for _, id in ipairs(brutes) do local hh = md.homeOf(id); Put(id, hh.x, hh.z) end
for _, id in ipairs(pounders) do local hh = md.homeOf(id); Put(id, hh.x, hh.z) end
Step(md, 1)
contacts[9001] = { x = 7800, z = 6000, frame = frame, v = 0, air = false }          -- no defID: a radar dot
Step(md, 1, function() contacts[9001].frame = frame end)
check(next(md.responding) == nil, "a single radar dot is not a group worth meeting")
contacts[9002] = { x = 7830, z = 6020, frame = frame, v = 0, air = false }
contacts[9003] = { x = 7860, z = 5980, frame = frame, v = 0, air = false }
Step(md, 1, function() for _, c in pairs(contacts) do c.frame = frame end end)
local dots = 0
for _, r in pairs(md.responding) do if r.state == "out" then dots = dots + 1 end end
check(dots >= 1 and dots <= 3, "three radar dots (3 x 60) are met with ~2x that: " .. dots .. " units")
check(#md.clusters == 1 and md.clusters[1].v == 180, "...and they form one group worth 180 (" .. tostring(md.clusters[1] and md.clusters[1].v) .. ")")

-- ── outmatched ──
md, contacts, brutes, pounders = Setup(8, 0)
Step(md, 2)
Group(7800, 6000, 20)                                       -- 4700 value: needs 9400, we have 1880
Step(md, 1, Fresh)
local n1 = 0
for _, r in pairs(md.responding) do if r.state == "out" then n1 = n1 + 1 end end
check(n1 == 0, "outside the ring and outmatched: hold, do not feed the army in piecemeal (" .. n1 .. ")")
for k in pairs(contacts) do contacts[k] = nil end
Group(6600, 6100, 20)
Step(md, 1, Fresh)
local n2 = 0
for _, r in pairs(md.responding) do if r.state == "out" then n2 = n2 + 1 end end
check(n2 == 8, "the same group inside the ring: everyone defends (" .. n2 .. ")")

-- ── SUPPORT_ROLE: Sheldons never intercept; they post behind the screen and fire from ~their range on a raid ──
do
    local SHEL = UnitDefNames.cormort.id
    UnitDefNames.cormort.maxWeaponRange = 850
    check(MD.SupportRange({ SUPPORT_ROLE = false, SCREEN_NAMES = {}, SUPPORT_NAMES = { cormort = true } }, UnitDefNames.cormort) == nil,
          "support role off: a Sheldon is no support")
    local md2, cont2, br2 = Setup(16, 0, { SUPPORT_ROLE = true })
    local shels = {}
    for i = 1, 4 do
        local id = S.Spawn("cormort", 0, 6200 + i * 5, 6400, { silent = true })
        shels[#shels + 1] = id; MD.Add(md2, id, SHEL)
    end
    check(md2.units[shels[1]].support == 850 and md2.units[shels[1]].back, "a Sheldon is support (range 850) and held back")
    check(MD.SupportRange(md2.K, UnitDefNames.corsumo) == nil, "a Mammoth is screen, not support")
    Step(md2, 1)
    for _, id in ipairs(br2) do local h = md2.homeOf(id); Put(id, h.x, h.z) end
    for _, id in ipairs(shels) do local h = md2.homeOf(id); Put(id, h.x, h.z) end
    Step(md2, 1)
    -- the support posts are further behind their blob than the backstop's 150
    local behind = 0
    for _, id in ipairs(shels) do
        local h = md2.homeOf(id)
        local nb = 1e9
        for _, b in ipairs(md2.blobs) do nb = math.min(nb, D(h.x, h.z, b.x, b.z)) end
        if nb > 200 and nb < 500 then behind = behind + 1 end
    end
    check(behind == #shels, "the Sheldons post ~SUPPORT_BACK behind a blob (" .. behind .. "/" .. #shels .. ")")
    for i = 1, 3 do cont2[#cont2 + 1] = { x = 7400 + (i % 3) * 30, z = 6000, defID = BRUTE, frame = frame, v = 1, air = false } end
    local function Fresh2() for _, c in pairs(cont2) do c.frame = frame end end
    Step(md2, 2, Fresh2)
    local fired, standoff = 0, 0
    for _, id in ipairs(shels) do
        check(not (md2.responding[id] and md2.responding[id].state == "out"), "a Sheldon never intercepts")
        local l = LastOrder(id)
        if l and l.cmd == ARMY.CMD_FIGHT then
            local h = md2.homeOf(id)
            local dGroup = D(l.params[1], l.params[3], 7430, 6000)
            if dGroup > 500 and dGroup < 850 and D(l.params[1], l.params[3], h.x, h.z) > 50 then
                fired = fired + 1
                if l.params[1] < 7430 then standoff = standoff + 1 end
            end
        end
    end
    check(fired >= 1, "a raid near the post: Sheldons FIGHT from ~85% of their range (" .. fired .. " of " .. #shels .. ")")
    check(standoff == fired, "...from our side of the group")
end

-- ── MAX_GROUP_SPEED: a group faster than the cap (air the contacts did not flag, very fast raiders) is not chased ──
do
    local md3, cont3 = Setup(16, 0, { MAX_GROUP_SPEED = 150 })
    Step(md3, 2)
    for i = 1, 3 do cont3[#cont3 + 1] = { x = 7400 + i * 30, z = 6000, defID = BRUTE, frame = frame, v = 1, air = false } end
    Step(md3, 1, function() for _, c in pairs(cont3) do c.frame = frame end end)
    -- now move the group 260 elmos/s (it was at ~7460; one tick = 1 s)
    Step(md3, 1, function() for _, c in pairs(cont3) do c.x, c.frame = c.x - 260, frame end end)
    Step(md3, 1, function() for _, c in pairs(cont3) do c.x, c.frame = c.x - 260, frame end end)
    local fast
    for _, cl in ipairs(md3.clusters) do fast = cl end
    check(fast and (fast.speed or 0) > 150, "the group is fast (" .. tostring(fast and math.floor(fast.speed or 0)) .. " elmos/s)")
    local outNow = 0
    for uid, r in pairs(md3.responding) do if r.state == "out" and r.cid == (fast and fast.id) then outNow = outNow + 1 end end
    check(outNow == 0 or md3.intercepts <= 1, "a 260 elmos/s group gets no new interceptors (" .. outNow .. ")")
end

check(#W.errors == 0, "no Lua errors")
print(string.format("test_maneuver_defence: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
