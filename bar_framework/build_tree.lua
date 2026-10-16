-- bar_framework/build_tree.lua   (C1, 2026-10-16)
-- THE BUILD TREE: one answer, cached per defID, to "who can build what".  Before this the same questions were answered in a dozen places
-- (metal_sink.LabDef / AirCanPlace, line_transition.FindAirLabDef / FindAirConDef, slot_spine.Enablers / HasConSource / NextOrder,
-- lab_rules + DRAGON_ECO CanBuildSet, blueprint_placer.CanBuild, DRAGON_ECO FindConBotDefID ...), each with its own predicate for "a ground con"
-- (they disagreed about the commander) and its own cache.
--
--   BT.Options(defID)              set { [buildable defID] = true } of a builder / lab
--   BT.CanBuild(builderDef, defID) can that builder place that unit
--   BT.IsGroundCon(def[, o])       a mobile ground constructor (o.commander = true keeps commanders)
--   BT.IsAirCon(def)  BT.IsNano(def)  BT.IsLab(def)  BT.Tier(def)       (techlevel custom param: 1, 2, 3)
--   BT.LabsFor(unitDef[, allow])   labs that make a unit, cheapest first; allow = optional set of lab names / ids to restrict to
--   BT.CheapestLab(unitDef[, allow])
--   BT.Placers(labDef)             { air = { builder defIDs }, ground = { ... } }: who can place that lab
--   BT.NeedsAir(labDef)            only an AIR con can place it (the T2 air plant)
--   BT.ConsMadeBy(labDef[, o])     the cons a lab can make (ground by default; o.air = true for air cons), cheapest first
--   BT.ConMadeBy(labDef[, o])      the cheapest of those; o.name picks one by name, o.canPlace = a defID the con must be able to place
--   BT.EnablerLab(targetLab[, allow])  the cheapest lab (cheaper than the target) that makes a ground con able to place the target
--   BT.Prereq(targetLab[, allow])  the chain of enabler labs a lab needs, nearest first (T3 <- T2 <- T1), at most 3
--   BT.Reset()                     forget everything (tests that patch buildOptions call it)
-- A name or an id is accepted wherever a def is asked for.

local M = {}

-- Caches.  Unit defs never change in a game, but tests patch buildOptions and every VFS.Include of this file is its own instance (own caches), so
-- a cache entry remembers how many build options the defs it was made from had, and is rebuilt when that number moves.  Reset() forgets all.
local optCache, labsForCache, placersCache = {}, {}, {}
local builderList                                   -- every def that has build options (the set of defs itself is fixed)

function M.Reset() optCache, labsForCache, placersCache, builderList = {}, {}, {}, nil end

local function Builders()
    if not builderList then
        builderList = {}
        for _, d in pairs(UnitDefs) do if d.buildOptions then builderList[#builderList + 1] = d end end
        table.sort(builderList, function(a, b) return a.id < b.id end)
    end
    return builderList
end
local function Stamp()                              -- total number of build options over all builders
    local n = 0
    for _, d in ipairs(Builders()) do n = n + #d.buildOptions end
    return n
end

local function Def(x)
    if type(x) == "table" then return x end
    if type(x) == "string" then return UnitDefNames and UnitDefNames[x] end
    return x and UnitDefs and UnitDefs[x] or nil
end
local function Id(x)
    if type(x) == "number" then return x end
    local d = Def(x)
    return d and d.id or nil
end
M.Def, M.Id = Def, Id

-- ── what a builder can place ──────────────────────────────────────────────────────────────────────

function M.Options(defID)
    defID = Id(defID)
    if not defID then return {} end
    local d = UnitDefs and UnitDefs[defID]
    local n = d and d.buildOptions and #d.buildOptions or 0
    local e = optCache[defID]
    if not e or e.n ~= n then
        local set = {}
        for _, o in ipairs(d and d.buildOptions or {}) do set[o] = true end
        e = { n = n, set = set }
        optCache[defID] = e
    end
    return e.set
end

function M.CanBuild(builderDef, defID)
    builderDef, defID = Id(builderDef), Id(defID)
    if not builderDef or not defID then return false end
    return M.Options(builderDef)[defID] == true
end

-- ── predicates (one definition each) ──────────────────────────────────────────────────────────────

function M.IsGroundCon(d, o)
    d = Def(d)
    if not (d and d.isBuilder and not d.isFactory and (d.speed or 0) > 0 and not d.canFly) then return false end
    if d.customParams and d.customParams.iscommander and not (o and o.commander) then return false end
    return true
end
function M.IsAirCon(d)
    d = Def(d)
    return d ~= nil and d.isBuilder == true and d.canFly == true and not d.isFactory and (d.speed or 0) > 0
end
function M.IsNano(d)
    d = Def(d)
    return d ~= nil and d.isBuilder == true and not d.isFactory and not d.canFly and (d.speed == nil or d.speed == 0)
end
function M.IsLab(d)
    d = Def(d)
    return d ~= nil and d.isFactory == true
end
function M.Tier(d)
    d = Def(d)
    return d and tonumber(d.customParams and d.customParams.techlevel) or 1
end

-- ── labs that make a unit ─────────────────────────────────────────────────────────────────────────

local function Allowed(allow, d)
    if not allow then return true end
    return allow[d.name] == true or allow[d.id] == true
end

-- Labs that have the unit in their build options, cheapest first (ties by id, so the answer does not depend on `pairs` order).
function M.LabsFor(unit, allow)
    local uid = Id(unit)
    if not uid then return {} end
    local stamp = Stamp()
    local c = labsForCache[uid]
    local all = c and c.stamp == stamp and c.list or nil
    if not all then
        all = {}
        for _, d in ipairs(Builders()) do
            if d.isFactory then
                for _, o in ipairs(d.buildOptions) do
                    if o == uid then all[#all + 1] = d; break end
                end
            end
        end
        table.sort(all, function(a, b)
            if (a.metalCost or 0) ~= (b.metalCost or 0) then return (a.metalCost or 0) < (b.metalCost or 0) end
            return a.id < b.id
        end)
        labsForCache[uid] = { stamp = stamp, list = all }
    end
    if not allow then return all end
    local out = {}
    for _, d in ipairs(all) do if Allowed(allow, d) then out[#out + 1] = d end end
    return out
end

function M.CheapestLab(unit, allow) return M.LabsFor(unit, allow)[1] end

-- ── who can place a lab ───────────────────────────────────────────────────────────────────────────

-- Mobile builders (any tier) that have the lab in their options: { air = { defIDs }, ground = { defIDs } }, each cheapest first.
function M.Placers(lab)
    local lid = Id(lab)
    if not lid then return { air = {}, ground = {} } end
    local stamp = Stamp()
    local c = placersCache[lid]
    local r = c and c.stamp == stamp and c.r or nil
    if not r then
        r = { air = {}, ground = {} }
        for _, d in ipairs(Builders()) do
            if d.isBuilder and not d.isFactory and (d.speed or 0) > 0 then
                for _, o in ipairs(d.buildOptions) do
                    if o == lid then
                        local list = d.canFly and r.air or (not (d.customParams and d.customParams.iscommander) and r.ground or nil)
                        if list then list[#list + 1] = d end
                        break
                    end
                end
            end
        end
        local function ByCost(a, b)
            if (a.metalCost or 0) ~= (b.metalCost or 0) then return (a.metalCost or 0) < (b.metalCost or 0) end
            return a.id < b.id
        end
        table.sort(r.air, ByCost)
        table.sort(r.ground, ByCost)
        placersCache[lid] = { stamp = stamp, r = r }
    end
    return r
end

function M.NeedsAir(lab)
    local p = M.Placers(lab)
    return #p.ground == 0 and #p.air > 0
end

-- ── what a lab makes ──────────────────────────────────────────────────────────────────────────────

-- The constructors a lab can make, cheapest first (ground cons; o.air = true: air cons).
function M.ConsMadeBy(lab, o)
    local d = Def(lab)
    local out = {}
    if not (d and d.buildOptions) then return out end
    local air = o and o.air
    for _, opt in ipairs(d.buildOptions) do
        local od = UnitDefs[opt]
        if od and ((air and M.IsAirCon(od)) or (not air and M.IsGroundCon(od, o))) then out[#out + 1] = od end
    end
    table.sort(out, function(a, b)
        if (a.metalCost or 0) ~= (b.metalCost or 0) then return (a.metalCost or 0) < (b.metalCost or 0) end
        return a.id < b.id
    end)
    return out
end

-- The cheapest con a lab makes (o.name: that one by name; o.canPlace = a defID it must be able to place).  Returns the def.
function M.ConMadeBy(lab, o)
    local list = M.ConsMadeBy(lab, o)
    local want = o and o.canPlace and Id(o.canPlace)
    for _, d in ipairs(list) do
        if (not (o and o.name) or d.name == o.name) and (not want or M.CanBuild(d.id, want)) then return d end
    end
    return nil
end

-- ── prerequisites ─────────────────────────────────────────────────────────────────────────────────

-- A lab nobody can place yet needs a lab that makes a con able to: the cheapest `allow`ed lab, cheaper than the target, whose ground con places it.
function M.EnablerLab(target, allow)
    local t = Def(target)
    if not t then return nil end
    local best
    for _, d in ipairs(Builders()) do
        if d.isFactory and Allowed(allow, d) and (d.metalCost or 0) < (t.metalCost or 0) and d.id ~= t.id then
            if M.ConMadeBy(d, { canPlace = t.id }) and (not best or (d.metalCost or 0) < (best.metalCost or 0)
               or (d.metalCost == best.metalCost and d.id < best.id)) then
                best = d
            end
        end
    end
    return best
end

-- The enabler chain of a lab, nearest first: a T3 lab <- the T2 lab that makes its con <- the T1 lab that makes that con's builder.  Stops at 3.
function M.Prereq(target, allow)
    local chain, cur = {}, Def(target)
    for _ = 1, 3 do
        local e = cur and M.EnablerLab(cur, allow)
        if not e then break end
        chain[#chain + 1] = e
        cur = e
    end
    return chain
end

return M
