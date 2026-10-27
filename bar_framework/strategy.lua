-- bar_framework/strategy.lua
-- A strategy = stances (what to build, and how each unit is controlled) + run-time decisions (how much to spend, which
-- stance, how to tilt the mix).  The unit-and-spend counterpart of blueprint_placer: stances and hooks are data and
-- small functions; this module is the engine, owned by the caller.
--
--   local ST = VFS.Include("LuaUI/Widgets/bar_framework/strategy.lua")
--   local strat = ST.New{
--       stances = { "T1_raid", "Late_game" },      -- stances/<name>.lua, exported by stance_editor.html
--       initial = "T1_raid",
--       hooks = {                                  -- every hook is optional; each gets (state, strat)
--           switch      = function(state, strat) if state.minute > 16 then return "Late_game" end end,
--           army_share  = function(state, strat) return state.floating and 1 or 0.25 end,
--           weights     = function(state, strat)   -- multipliers on the stance's unit shares, by unit name
--               if (state.enemyAirShare or 0) > 0.3 then return { corvamp = 3 } end
--           end,
--       },
--   }
--   strat:Tick(frame, GS.Collect(frame, {...}))   -- about once a second: runs the hooks
--   strat:Pick(canBuild)                          -- lab controller: which unit next (value-deficit rule, weighted)
--   strat:Note(defID)                             -- after ordering it
--   strat:Assign(host, uid, defID)                -- on UnitFinished: attach the stance's behaviours (behavior_host)
--   strat:InstallSpine(Spine)                     -- the army share becomes a spine policy
--
-- Stance files may carry, per unit, behaviors = {"kite"} and cfg = {kite = {step = 400}}; those are what Assign hands
-- to the host.  A unit with no behaviours in the stance gets none (the bot's own controller moves it).

local SL = (VFS and VFS.Include and select(2, pcall(VFS.Include, "LuaUI/Widgets/bar_framework/stance_loader.lua"))) or nil

local M = {}
M.DEFAULT_SHARE = 0.20     -- army share when neither a hook nor the stance says otherwise

local Strategy = {}
Strategy.__index = Strategy

local function Clamp01(x) return math.max(0, math.min(1, x)) end

-- o.stances: list of names (loaded) or { [name] = stance table }; o.initial; o.hooks; o.loader (default stance_loader)
function M.New(o)
    local loader = o.loader or SL
    assert(loader, "stance_loader not available")
    local s = setmetatable({ loader = loader, stances = {}, hooks = o.hooks or {}, ledger = nil, weights = nil,
                             log = o.log ~= false, switchedF = -1e9, capFilter = o.capFilter }, Strategy)
    local list = o.stances or {}
    for k, v in pairs(list) do
        local name, st
        if type(k) == "number" then name, st = v, loader.Load(v) else name, st = k, loader.Load(v) end
        if st then st.name = name; s.stances[name] = st
        else Spring.Echo("[STRAT] stance not loaded: " .. tostring(name)) end
    end
    s.share = o.defaultShare or M.DEFAULT_SHARE
    if o.initial then s:Set(o.initial) end
    return s
end

function Strategy:Stance() return self.current end
function Strategy:Name() return self.current and self.current.name or nil end
function Strategy:Share() return self.share end
-- The current stance's game plan ({ army = "raid"|"hold", bombers = 0..1 }, stance file `plan`), or nil.
function Strategy:Plan() return self.current and self.current.plan or nil end

-- Switch stance.  A new stance starts with a fresh ledger, seeded from the army that already exists.
function Strategy:Set(name, state)
    local st = self.stances[name]
    if not st or st == self.current then return false end
    self.prev, self.prevLedger = self.current, self.ledger      -- kept for PickPrev (labs waiting to be swapped keep building these)
    self.current = st
    self.ledger = self.loader.NewLedger()
    if state and state.armyByDef then
        for defID, n in pairs(state.armyByDef) do
            if st.byDef[defID] then self.loader.Note(self.ledger, defID, n) end
        end
    end
    if self.log then Spring.Echo(string.format("[STRAT] stance %s: %s", name, self.loader.Names(st))) end
    return true
end

-- Run the hooks.  Order: switch (may change stance), army_share, weights.
function Strategy:Tick(frame, state)
    local h = self.hooks
    state = state or {}
    if h.switch then
        local ok, name = pcall(h.switch, state, self)
        if ok and name then self:Set(name, state)
        elseif not ok then self:Fail("switch", name, frame) end
    end
    local share
    if h.army_share then
        local ok, v = pcall(h.army_share, state, self)
        if ok then share = tonumber(v) else self:Fail("army_share", v, frame) end
    end
    if not share and self.current and self.current.suggestedShare then share = self.current.suggestedShare / 100 end
    -- plan.share (optional, AIR_TIMING 2026-10-25): a floor under the hook's share while this stance is current (a burst stance)
    local plan = self.current and self.current.plan
    if plan and tonumber(plan.share) then share = math.max(share or 0, tonumber(plan.share)) end
    if self.capFilter and state.capFrac then         -- the unit-cap filter (see CapFiltered), with a little hysteresis
        local was = self.capTight
        if state.capFrac >= self.capFilter then self.capTight = true
        elseif state.capFrac < self.capFilter - 0.05 then self.capTight = false end
        if self.log and was ~= self.capTight and (was ~= nil or self.capTight) then
            Spring.Echo(string.format("[STRAT] unit cap %.0f%% full: T1 combat units %s the stances", 100 * state.capFrac,
                self.capTight and "dropped from" or "back in"))
        end
    end
    self.share = Clamp01(share or M.DEFAULT_SHARE)
    if h.weights then
        local ok, w = pcall(h.weights, state, self)
        if ok then self.weights = w else self:Fail("weights", w, frame) end
    else
        self.weights = nil
    end
    if self.slotSpine then
        self.slotSpine.SetUnits(self:UnitList())
        self.slotSpine.SetShare(self.share)
    end
end

function Strategy:Fail(hook, err, frame)
    self.errors = (self.errors or 0) + 1
    if frame - (self.errF or -1e9) > 900 then
        self.errF = frame
        Spring.Echo("[STRAT] hook " .. hook .. " failed: " .. tostring(err))
    end
end

-- canBuild(defID) -> truthy.  Returns defID or nil.
-- Unit-cap filter (user 2026-10-25: ~600 Grunts held unit cap late in a game that could have been Tigers, Demons or eco).  Once the
-- unit cap is a concern (state.capFrac >= capFilter, off again 0.05 below), the stances' T1 combat units (tech level 1, armed, mobile,
-- not a builder) are dropped from the comp and from the picks.  Scouts and the other lab rules are not stance picks.  A stance that is
-- nothing but T1 combat units keeps its comp (the labs then make nothing new of it).
local function IsT1Combat(defID)
    local d = UnitDefs and UnitDefs[defID]
    if not d or d.isBuilder or d.isFactory or not d.weapons or #d.weapons == 0 or (d.speed or 0) <= 0 then return false end
    local tl = d.customParams and tonumber(d.customParams.techlevel)
    return tl == 1
end
M.IsT1Combat = IsT1Combat

-- A stance unit with `max = n` (user 2026-10-26: flak in most comps at 5% would pile up, since it never dies): once n of it are alive
-- (finished or in production: Spring.GetTeamUnitDefCount) it is dropped from the picks and from UnitList, so the others take its share.
-- Orders already in a lab's queue can still finish, so the count can pass n by about a queue.
local function Alive(defID)
    local team = Spring.GetMyTeamID and Spring.GetMyTeamID()
    return (team and Spring.GetTeamUnitDefCount and Spring.GetTeamUnitDefCount(team, defID)) or 0
end
function Strategy:AtMax(u) return u ~= nil and u.max ~= nil and Alive(u.defID) >= u.max end

local function MaxCanBuild(self, canBuild)
    local cur = self.current
    local any = false
    for _, u in ipairs(cur and cur.units or {}) do if u.max then any = true; break end end
    if not any then return canBuild end
    local byDef = cur.byDef
    return function(d)
        local u = byDef and byDef[d]
        return not (u and u.max and Alive(d) >= u.max) and (canBuild == nil or canBuild(d))
    end
end

function Strategy:CapFiltered(defID) return self.capTight == true and IsT1Combat(defID) end

local function CapCanBuild(self, canBuild)
    if not self.capTight then return canBuild end
    return function(d) return not IsT1Combat(d) and (canBuild == nil or canBuild(d)) end
end

function Strategy:Pick(canBuild, skip, positiveOnly)
    if not self.current then return nil end
    return self.loader.Pick(self.current, self.ledger, MaxCanBuild(self, CapCanBuild(self, canBuild)), skip, positiveOnly, self.weights)
end

-- A unit of the PREVIOUS stance the lab can build (slot_spine WAVE_SWAP: a lab that is about to be replaced keeps producing, so unit
-- production never dips during a swap).  Nil without a previous stance.
function Strategy:PickPrev(canBuild)
    if not (self.prev and self.prevLedger) then return nil end
    local defID = self.loader.Pick(self.prev, self.prevLedger, CapCanBuild(self, canBuild), nil, nil, nil)   -- (max is not applied to the previous stance)
    if defID and self.prev.byDef[defID] then self.loader.Note(self.prevLedger, defID, 1) end
    return defID
end

function Strategy:Note(defID, n)
    if self.current and self.current.byDef[defID] then self.loader.Note(self.ledger, defID, n) end
end

-- The behaviours the current stance names for this unit type: names, overrides (or nil).
-- A stance unit without behaviours falls through to the stance's extras (2026-10-25: raid_late builds Dragons as 64% of its comp with
-- no behaviours, so the sink's Dragon waves -- SINK_EXTRAS dragon_raid / dragon_defend -- were never attached and the Dragons sat
-- at their labs).
function Strategy:BehaviorsFor(defID)
    local cur = self.current
    if not cur then return nil end
    local u = cur.byDef[defID]
    if not (u and u.behaviors and #u.behaviors > 0) then u = cur.extraByDef and cur.extraByDef[defID] end
    if not (u and u.behaviors and #u.behaviors > 0) then return nil end
    return u.behaviors, u.cfg
end

-- Attach the stance's behaviours to a unit.  Returns true when it got any.
function Strategy:Assign(host, uid, defID)
    local names, over = self:BehaviorsFor(defID)
    if not names then return false end
    return host:Assign(uid, names, over)
end

-- The strategy's share becomes the spine's army share (it replaces the schedule policy's number; the threat / float /
-- cap policies after it still apply).
function Strategy:InstallSpine(Spine, index)
    Spine.RemovePolicy("strategy")
    Spine.AddPolicy("strategy", function(_, _) return self.share end, index or 1)
end

-- The current comp as { {defID =, share =}, ... } with the weights applied (renormalised): what slot_spine plans labs from.
function Strategy:UnitList()
    local out, sum = {}, 0
    if not self.current then return out end
    local drop = false
    if self.capTight then                          -- the cap filter, unless it would leave nothing
        for _, u in ipairs(self.current.units) do if not IsT1Combat(u.defID) then drop = true; break end end
    end
    for _, u in ipairs(self.current.units) do
        if not (drop and IsT1Combat(u.defID)) and not self:AtMax(u) then
            local w = (self.weights and self.weights[u.n]) or 1
            out[#out + 1] = { defID = u.defID, share = u.share * w }
            sum = sum + u.share * w
        end
    end
    if sum > 0 then for _, u in ipairs(out) do u.share = u.share / sum end end
    return out
end

-- Hand the comp and the army share to the slot spine (bar_framework/slot_spine.lua) every Tick, so its labs follow the
-- stance: a switch of stance changes which labs the slots hold.
function Strategy:InstallSlotSpine(SS)
    self.slotSpine = SS
    SS.SetUnits(self:UnitList())
    SS.SetShare(self.share)
end

function Strategy:Describe()
    local parts = {}
    for name in pairs(self.stances) do parts[#parts + 1] = name end
    table.sort(parts)
    return string.format("stance %s, share %.2f, stances: %s", tostring(self:Name()), self.share, table.concat(parts, ", "))
end

return M
