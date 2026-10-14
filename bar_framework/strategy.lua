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
                             log = o.log ~= false, switchedF = -1e9 }, Strategy)
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
function Strategy:Pick(canBuild, skip, positiveOnly)
    if not self.current then return nil end
    return self.loader.Pick(self.current, self.ledger, canBuild, skip, positiveOnly, self.weights)
end

function Strategy:Note(defID, n)
    if self.current and self.current.byDef[defID] then self.loader.Note(self.ledger, defID, n) end
end

-- The behaviours the current stance names for this unit type: names, overrides (or nil).
function Strategy:BehaviorsFor(defID)
    local u = self.current and self.current.byDef[defID]
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
    for _, u in ipairs(self.current.units) do
        local w = (self.weights and self.weights[u.n]) or 1
        out[#out + 1] = { defID = u.defID, share = u.share * w }
        sum = sum + u.share * w
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
