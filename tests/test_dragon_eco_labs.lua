-- tests/test_dragon_eco_labs.lua: candidates/DRAGON_ECO/lab_controller.lua on the lab broker (tests/spring_stub.lua).
-- Run from the repo root: python tests/run_lua.py tests/test_dragon_eco_labs.lua
--   * a spine lab gets the spine's con first, then the stance's units (paid from the army budget);
--   * before the Dragon lab stands no decoy commanders; once it stands the T2 bot lab makes decoys up to the want, and the Dragon
--     lab makes Dragons, nothing else; a finished decoy guards (assists) the Dragon lab;
--   * scouts (2) from the T1 air lab and one radar plane from a grid T2 air lab; otherwise the air labs get nothing; a ground raid puts Shurikens / Wasps ahead in them (not the Dragon lab),
--     and the Shuriken floor (from 2:00) tops the T1 air lab up.
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
local function Id(n) return UnitDefNames[n].id end

-- the stub has no decoy commander: a T2 bot-lab builder that can assist
local dec = UnitDefNames.cordecom
dec.speed, dec.canMove, dec.isBuilder, dec.buildSpeed, dec.metalCost = 37.5, true, true, 300, 750
table.insert(UnitDefNames.coralab.buildOptions, dec.id)

-- spine + strategy stand-ins
local spineLabs, conFor = {}, {}
WG.Spine = {
    CFG = { QUEUE_DEPTH = 3 },
    IsLab = function(id) return spineLabs[id] == true end,
    IsLeaving = function() return false end,
    Share = function() return 0.2 end,
    NextOrder = function(id) local c = conFor[id]; conFor[id] = nil; return c end,
}
local picks = 0
WG.Strategy = {
    Pick = function(self, can) picks = picks + 1; if can(Id("corsumo")) then return Id("corsumo") end end,
    Note = function() end,
    Name = function() return "mammoth_hold" end,
}

-- the stub runs (and clears) W.orders every frame: keep our own record
local sent = {}
local origGive = Spring.GiveOrderToUnit
Spring.GiveOrderToUnit = function(id, cmd, params, opts)
    sent[#sent + 1] = { id = id, cmd = cmd, params = params }
    return origGive(id, cmd, params, opts)
end
S.LoadWidget("candidates/DRAGON_ECO/lab_controller.lua")
S.Callin("Initialize")
local alab = S.Spawn("coralab", 0, 3000, 3000)
local apAir = S.Spawn("corap", 0, 2000, 2000)
local gridAap = S.Spawn("coraap", 0, 5000, 5000)
local vp = S.Spawn("corvp", 0, 3400, 3000)
spineLabs[alab], spineLabs[vp] = true, true
conFor[alab] = Id("corck")

local function OrdersTo(id)
    local out = {}
    for _, o in ipairs(sent) do
        local c = o.cmd
        if c == CMD.INSERT then c = o.params[2] end
        if o.id == id and c < 0 then out[#out + 1] = -c end
    end
    return out
end
local function Count(list, defID) local n = 0 for _, d in ipairs(list) do if d == defID then n = n + 1 end end return n end

-- income 1200 m/s, full metal bank (the army budget is free)
local res = { metal = { 9000, 10000, 0, 1200, 0 }, energy = { 50000, 100000, 0, 20000, 0 } }
Spring.GetTeamResources = function(team, kind) local r = res[kind]; return r[1], r[2], r[3], r[4], r[5] end

local frame = 0
local function Run(n) for _ = 1, n do frame = frame + 60; S.Frame(frame) end end
Run(1)
local o = OrdersTo(alab)
check(o[1] == Id("corck"), "the spine's con goes first (" .. tostring(o[1]) .. ")")
check(Count(o, Id("corsumo")) >= 1, "then the stance's Mammoths")
check(Count(o, dec.id) == 0, "no decoys before the Dragon lab stands")
local ov = OrdersTo(vp)
check(Count(ov, Id("corlevlr")) >= 1, "transition: a vehicle plant the T2 stance has nothing for keeps making Pounders")
for _ = 1, 6 do Run(1) end
ov = OrdersTo(vp)
check(Count(ov, Id("cormist")) >= 1 and Count(ov, Id("corlevlr")) > Count(ov, Id("cormist")),
      "transition: mostly Pounders, a Lasher now and then (" .. Count(ov, Id("corlevlr")) .. "/" .. Count(ov, Id("cormist")) .. ")")
-- the stub finishes a unit the moment it is ordered, and the radar plane the T2 air lab made counts as a scout too, so room for
-- "2 scouts" may leave only 1 Fink: the invariant is that the T1 air lab makes nothing but scouts, and no more than 2 of them
local nAir, nFink = #OrdersTo(apAir), Count(OrdersTo(apAir), Id("corfink"))
check(nAir == nFink and nFink >= 1 and nFink <= 2,
      "before 2:00 and with no raid the T1 air lab makes only scouts, at most 2 (" .. nFink .. " Finks of " .. nAir .. " orders)")
check(Count(OrdersTo(gridAap), Id("corawac")) == 1 and #OrdersTo(gridAap) == 1, "one grid T2 air lab makes the radar plane, nothing else")

-- the Dragon lab stands (the vehicle plant has been reclaimed by now)
S.Kill(vp)
local dlab = S.Spawn("coraap", 0, 3800, 3000)
WG.DragonLab = { id = dlab, x = 3800, z = 3000, ready = true, decoys = {} }
sent = {}
Run(4)
local d = OrdersTo(dlab)
check(#d >= 1 and Count(d, Id("corcrwh")) == #d, "the Dragon lab makes Dragons only (" .. #d .. " orders)")
local da = OrdersTo(alab)
check(Count(da, dec.id) >= 1, "the T2 bot lab makes decoy commanders once the Dragon lab stands")
check(#OrdersTo(gridAap) == 0, "a grid T2 air lab still gets nothing")
-- decoys stop at the want: min(0.9 x 1200 / 12.75 = 84, 60 per Dragon lab x 1) = 60
local ordered = 0
for _ = 1, 40 do sent = {}; Run(1); ordered = ordered + Count(OrdersTo(alab), dec.id) end
check(ordered + Count(da, dec.id) <= 60, "decoy orders capped at 60 per Dragon lab (" .. (ordered + Count(da, dec.id)) .. ")")

-- a finished decoy from the lab guards the Dragon lab
sent = {}
local decoy = S.Spawn("cordecom", 0, 3000, 3100, { builder = alab })
local guard = false
for _, ord in ipairs(sent) do if ord.id == decoy and ord.cmd == 25 and ord.params[1] == dlab then guard = true end end
check(guard, "a finished decoy guards the Dragon lab")
check(WG.DragonLab.decoys[decoy] == true, "the decoy is listed in WG.DragonLab.decoys")

-- a second Dragon lab (WG.DragonLabs): it makes Dragons too, and new decoys go to it (it has the fewest)
do
    local dlab2 = S.Spawn("coraap", 0, 4400, 3000)
    WG.DragonLabs = { [dlab] = WG.DragonLab, [dlab2] = { id = dlab2, x = 4400, z = 3000, ready = true, decoys = {} } }
    sent = {}
    Run(2)
    check(Count(OrdersTo(dlab2), Id("corcrwh")) >= 1, "a second Dragon lab makes Dragons")
    local d2 = S.Spawn("cordecom", 0, 3000, 3150, { builder = alab })
    local g2 = false
    for _, ord in ipairs(sent) do if ord.id == d2 and ord.cmd == 25 and ord.params[1] == dlab2 then g2 = true end end
    check(g2 and WG.DragonLabs[dlab2].decoys[d2], "a new decoy guards the Dragon lab with the fewest decoys")
    WG.DragonLabs = nil
    S.Kill(dlab2)
end

-- a ground raid: Shurikens from the T1 air lab, Wasps from the grid T2 air lab, nothing extra from the Dragon lab
WG.MetalBot = { raid = { frame = frame, value = 1000, channel = "ground" } }
sent = {}
for _ = 1, 3 do WG.MetalBot.raid.frame = frame; Run(1) end
check(Count(OrdersTo(apAir), Id("corbw")) >= 1, "raid: the T1 air lab makes Shurikens")
check(Count(OrdersTo(gridAap), Id("corape")) >= 1, "raid: the grid T2 air lab makes Wasps")
check(Count(OrdersTo(dlab), Id("corape")) == 0, "raid: the Dragon lab makes no Wasps")
check(#S.Log("%[LabCtrl%].*raid ON") == 1, "the raid is logged")
-- enough air already standing (Shurikens + Wasps >= 0.5 x the raid): no more raid air
do
    local wasps = {}
    for i = 1, 6 do wasps[i] = S.Spawn("corape", 0, 3000 + i * 20, 3300, { silent = true }) end   -- 6 x stub Wasp cost vs raid 1000
    local waspV = 6 * UnitDefNames.corape.metalCost
    WG.MetalBot.raid = { frame = frame, value = math.floor(waspV / 0.5) - 1, channel = "ground" }   -- the standing air is just over half
    sent = {}
    for _ = 1, 3 do WG.MetalBot.raid.frame = frame; Run(1) end
    check(Count(OrdersTo(gridAap), Id("corape")) == 0 and Count(OrdersTo(apAir), Id("corbw")) == 0,
          "raid: no more raid air once the standing Shurikens + Wasps are worth 0.5x the raid")
    for _, w in ipairs(wasps) do S.Kill(w) end
end
-- the raid ends: no more Wasps; the Shuriken floor (after 2:00) still tops the T1 air lab up
WG.MetalBot.raid.frame = -1e9
for _ = 1, 5 do Run(1) end
sent = {}
while frame < 9 * 1800 do Run(1) end
check(Count(OrdersTo(gridAap), Id("corape")) == 0, "after the raid no more Wasps")
check(Count(OrdersTo(apAir), Id("corbw")) >= 1, "the Shuriken floor keeps the T1 air lab making Shurikens")

check(#W.errors == 0, "no Lua errors (" .. tostring(W.errors[1]) .. ")")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
