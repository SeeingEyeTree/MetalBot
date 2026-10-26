-- bar_framework/fsm.lua
-- Data-driven state machines for CORE: a STANCE machine (which stance is on) and an ARMY-SHARE machine (how much of income goes to
-- army), both read from one machines/<name>.lua file and edited in machine_editor.html.  Spec format: machines/README.md.
--
--   local FSM = VFS.Include("LuaUI/Widgets/bar_framework/fsm.lua")
--   local spec = FSM.Load("core_default")                   -- machines/core_default.lua (nil, err on failure)
--   local problems = FSM.Validate(spec, { stanceExists = function(n) ... end })
--   local B = FSM.Bundle(spec, { Signals = ..., hookFactories = { match_enemy = H.match_enemy, v16_share = H.v16_share }, log = Spring.Echo })
--   B.switch(state, strat) -> stance name | nil            -- a strategy.lua `switch` hook
--   B.army_share(state, strat) -> 0..1 | nil               -- a strategy.lua `army_share` hook
--
-- A machine = nodes + edges.  An edge fires when its condition tree is true (and has been for hold_s, and the node has been
-- entered for min_stay_s); of several that can fire the highest prio wins, then the first listed.  any_edges apply from every node.
-- Conditions: { sig=, op=, val= } leaves (no op = the signal is true / present), combined by { all = {..} } / { any = {..} } /
-- { ["not"] = cond }.  A test on an unknown (nil) signal is false.

local M = {}

local SIGMOD = "LuaUI/Widgets/bar_framework/signals.lua"

-- ---------------------------------------------------------------------------------------------------------- conditions

local OPS = {
    [">"]  = function(a, b) return type(a) == "number" and type(b) == "number" and a > b end,
    [">="] = function(a, b) return type(a) == "number" and type(b) == "number" and a >= b end,
    ["<"]  = function(a, b) return type(a) == "number" and type(b) == "number" and a < b end,
    ["<="] = function(a, b) return type(a) == "number" and type(b) == "number" and a <= b end,
    ["=="] = function(a, b) return a ~= nil and a == b end,
    ["!="] = function(a, b) return a ~= nil and a ~= b end,
}
M.OPS = OPS

-- get(name) -> value
local function Eval(c, get)
    if c == nil then return true end
    if c.all then
        for _, k in ipairs(c.all) do if not Eval(k, get) then return false end end
        return true
    elseif c.any then
        for _, k in ipairs(c.any) do if Eval(k, get) then return true end end
        return false
    elseif c["not"] then
        return not Eval(c["not"], get)
    elseif c.sig then
        local v = get(c.sig)
        if c.op == nil then return v ~= nil and v ~= false and v ~= 0 end
        local f = OPS[c.op]
        return f ~= nil and f(v, c.val) or false
    end
    return true
end
M.Eval = Eval

local function Fmt(v)
    if type(v) == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.2f", v)
    end
    return tostring(v)
end

-- readable text of a condition with the signals' current values: "army_ratio=1.52 > 1.4 AND NOT bad_trade"
local function Explain(c, get)
    if c == nil then return "always" end
    if c.all or c.any then
        local parts = {}
        for _, k in ipairs(c.all or c.any) do parts[#parts + 1] = Explain(k, get) end
        local s = table.concat(parts, c.all and " AND " or " OR ")
        return #parts > 1 and ("(" .. s .. ")") or s
    elseif c["not"] then
        return "NOT " .. Explain(c["not"], get)
    elseif c.sig then
        local v = get and get(c.sig)
        if c.op == nil then return c.sig end
        return string.format("%s=%s %s %s", c.sig, v == nil and "?" or Fmt(v), c.op, Fmt(c.val))
    end
    return "?"
end
M.Explain = Explain

-- the signal names a condition uses
local function Collect(c, out)
    if c == nil then return out end
    if c.all or c.any then for _, k in ipairs(c.all or c.any) do Collect(k, out) end
    elseif c["not"] then Collect(c["not"], out)
    elseif c.sig then out[#out + 1] = c.sig end
    return out
end

-- ---------------------------------------------------------------------------------------------------------- validation

-- Returns a list of problem strings (empty = fine).  o.known(name) -> bool for signals (default: signals.lua),
-- o.stanceExists(name) -> bool (default: any), o.isShare tells the share machine's node rules.
function M.ValidateMachine(m, label, o)
    local probs = {}
    local function P(s) probs[#probs + 1] = label .. ": " .. s end
    if type(m) ~= "table" then P("missing"); return probs end
    local nodes = m.nodes or {}
    if not next(nodes) then P("no nodes"); return probs end
    if not m.initial or not nodes[m.initial] then P("initial node '" .. tostring(m.initial) .. "' does not exist") end
    for name, nd in pairs(nodes) do
        if label == "stance_machine" then
            if not nd.stance then P("node '" .. name .. "' has no stance")
            elseif o.stanceExists and not o.stanceExists(nd.stance) then P("node '" .. name .. "': stance '" .. nd.stance .. "' not found") end
        else
            if nd.share == nil and not nd.hook then P("node '" .. name .. "' has neither share nor hook")
            elseif nd.hook and not (o.hookFactories and o.hookFactories[nd.hook]) then P("node '" .. name .. "': unknown share hook '" .. tostring(nd.hook) .. "'") end
        end
    end
    local function CheckEdge(e, i, tag)
        if not nodes[e.to] then P(tag .. " " .. i .. ": target '" .. tostring(e.to) .. "' does not exist") end
        if tag == "edge" and not nodes[e.from] then P(tag .. " " .. i .. ": source '" .. tostring(e.from) .. "' does not exist") end
        for _, sg in ipairs(Collect(e.when, {})) do
            if not o.known(sg) then P(tag .. " " .. i .. ": unknown signal '" .. sg .. "'") end
        end
        local function Ops(c)
            if not c then return end
            if c.all or c.any then for _, k in ipairs(c.all or c.any) do Ops(k) end
            elseif c["not"] then Ops(c["not"])
            elseif c.sig and c.op and not OPS[c.op] then P(tag .. " " .. i .. ": unknown operator '" .. tostring(c.op) .. "'") end
        end
        Ops(e.when)
    end
    for i, e in ipairs(m.edges or {}) do CheckEdge(e, i, "edge") end
    for i, e in ipairs(m.any_edges or {}) do CheckEdge(e, i, "any_edge") end
    -- reachability (warning only, still reported)
    if m.initial and nodes[m.initial] then
        local seen, stack = { [m.initial] = true }, { m.initial }
        local hasAny = {}
        for _, e in ipairs(m.any_edges or {}) do hasAny[e.to] = true end
        for n in pairs(hasAny) do if not seen[n] then seen[n] = true; stack[#stack + 1] = n end end
        while #stack > 0 do
            local n = table.remove(stack)
            for _, e in ipairs(m.edges or {}) do
                if e.from == n and nodes[e.to] and not seen[e.to] then seen[e.to] = true; stack[#stack + 1] = e.to end
            end
        end
        for name in pairs(nodes) do if not seen[name] then P("node '" .. name .. "' is unreachable") end end
    end
    return probs
end

function M.Validate(spec, o)
    o = o or {}
    if not o.known then
        local okS, S = pcall(VFS.Include, SIGMOD)
        o.known = (okS and S and S.Known) or function() return true end
    end
    local probs = {}
    if type(spec) ~= "table" then return { "spec is not a table" } end
    if spec.stance_machine then
        for _, p in ipairs(M.ValidateMachine(spec.stance_machine, "stance_machine", o)) do probs[#probs + 1] = p end
    end
    if spec.share_machine then
        for _, p in ipairs(M.ValidateMachine(spec.share_machine, "share_machine", o)) do probs[#probs + 1] = p end
    end
    return probs
end

-- ---------------------------------------------------------------------------------------------------------- loading

function M.Load(name)
    local ok, spec = pcall(VFS.Include, "LuaUI/Widgets/machines/" .. name .. ".lua")
    if not ok then ok, spec = pcall(VFS.Include, "machines/" .. name .. ".lua") end
    if not ok or type(spec) ~= "table" then return nil, tostring(spec) end
    return spec
end

-- ---------------------------------------------------------------------------------------------------------- one machine

-- m: { initial, nodes, edges, any_edges }.  o: { label, log, get(name)->value (set per Tick through :Tick) }
function M.NewMachine(m, o)
    o = o or {}
    local self = { spec = m, cur = m.initial, enterF = nil, label = o.label or "machine", since = {}, lastLogF = -1e9, edgeCount = 0 }
    local log = o.log or function() end

    local function Candidates(cur)
        local list = {}
        for i, e in ipairs(m.edges or {}) do
            if e.from == cur then list[#list + 1] = { e = e, key = "e" .. i, n = i, tag = "edge" } end
        end
        for i, e in ipairs(m.any_edges or {}) do
            if e.to ~= cur then list[#list + 1] = { e = e, key = "a" .. i, n = i, tag = "any" } end
        end
        return list
    end

    -- evaluate the current node's edges; returns the node name now current
    function self:Tick(frame, get)
        local best
        local seenKeys = {}
        for idx, c in ipairs(Candidates(self.cur)) do
            local e = c.e
            seenKeys[c.key] = true
            local ok = Eval(e.when, get)
            if ok and e.hold_s and e.hold_s > 0 then
                self.since[c.key] = self.since[c.key] or frame
                ok = frame - self.since[c.key] >= e.hold_s * 30
            elseif not ok then
                self.since[c.key] = nil
            end
            if ok and e.min_stay_s and self.enterF and frame - self.enterF < e.min_stay_s * 30 then ok = false end
            if ok and (not best or (e.prio or 0) > (best.e.prio or 0)) then best = c end
        end
        for k in pairs(self.since) do if not seenKeys[k] then self.since[k] = nil end end
        if best then
            local from = self.cur
            self.cur, self.enterF, self.since = best.e.to, frame, {}
            self.edgeCount = self.edgeCount + 1
            local s = math.floor(frame / 30)
            log(string.format("[FSM] %s %d:%02d %s -> %s | %s %d | %s%s", self.label, math.floor(s / 60), s % 60, from, self.cur,
                best.tag == "any" and "any_edge" or "edge", best.n, Explain(best.e.when, get), best.e.note and (" | " .. best.e.note) or ""))
        end
        return self.cur
    end

    function self:AgeS(frame) return self.enterF and (frame - self.enterF) / 30 or frame / 30 end
    return self
end

-- ---------------------------------------------------------------------------------------------------------- bundle

-- spec: a loaded machine file.  o: { Signals (module), hookFactories, log }
function M.Bundle(spec, o)
    o = o or {}
    local log = o.log or function() end
    local okS, S = pcall(VFS.Include, SIGMOD)
    local Signals = o.Signals or (okS and S) or nil
    local B = { spec = spec }
    local cross = { share = nil, share_node = nil, share_age_s = 0, stance = nil, stance_age_s = 0, stance_army = nil, stance_plan_share = 0 }
    local stateNow
    local function Get(name)
        local cv = cross[name]
        if cv ~= nil then return cv end
        if Signals and Signals.byName[name] and Signals.byName[name].cross then return nil end
        return Signals and Signals.Get(name, stateNow or {}) or nil
    end
    B.Get = Get

    local sm = spec.stance_machine and M.NewMachine(spec.stance_machine, { label = "stance", log = log }) or nil
    local hm = spec.share_machine and M.NewMachine(spec.share_machine, { label = "share", log = log }) or nil
    B.stanceMachine, B.shareMachine = sm, hm

    function B.StanceNames()
        local out, seen = {}, {}
        if not sm then return out end
        local init = spec.stance_machine.nodes[spec.stance_machine.initial]
        if init then out[1], seen[init.stance] = init.stance, true end
        local names = {}
        for _, nd in pairs(spec.stance_machine.nodes) do names[#names + 1] = nd.stance end
        table.sort(names)
        for _, n in ipairs(names) do if n and not seen[n] then seen[n] = true; out[#out + 1] = n end end
        return out
    end
    function B.InitialStance()
        local nd = sm and spec.stance_machine.nodes[spec.stance_machine.initial]
        return nd and nd.stance
    end

    local function UpdateCross(frame, strat)
        if strat then
            cross.stance = strat:Name()
            local pl = strat:Plan() or {}
            cross.stance_army, cross.stance_plan_share = pl.army, pl.share or 0
        end
        if sm then cross.stance_age_s = sm:AgeS(frame) end
        if hm then cross.share_node, cross.share_age_s = hm.cur, hm:AgeS(frame) end
    end

    -- a switch hook: the stance of the stance machine's current node
    function B.switch(state, strat)
        if not sm then return nil end
        stateNow = state
        local f = state.frame or 0
        UpdateCross(f, strat)
        local node = sm:Tick(f, Get)
        local nd = spec.stance_machine.nodes[node]
        UpdateCross(f, strat)
        return nd and nd.stance or nil
    end

    -- army_share hook: the current share node's share (a number, or another hook's value), eased by ramp_s
    local hookInst, lastShare, lastF = {}, nil, nil
    function B.army_share(state, strat)
        if not hm then return nil end
        stateNow = state
        local f = state.frame or 0
        UpdateCross(f, strat)
        local node = hm:Tick(f, Get)
        local nd = spec.share_machine.nodes[node]
        if not nd then return nil end
        local target
        if nd.hook then
            local inst = hookInst[node]
            if not inst then
                local fac = o.hookFactories and o.hookFactories[nd.hook]
                inst = fac and fac(nd.cfg or {}) or function() return nil end
                hookInst[node] = inst
            end
            target = inst(state, strat)
        else
            target = tonumber(nd.share)
        end
        if target == nil then return nil end
        local out = target
        if nd.ramp_s and nd.ramp_s > 0 and lastShare and lastF then
            local maxStep = (f - lastF) / 30 / nd.ramp_s
            out = lastShare + math.max(-maxStep, math.min(maxStep, target - lastShare))
        end
        lastShare, lastF = out, f
        cross.share = out
        if f - hm.lastLogF >= 1800 then
            hm.lastLogF = f
            log(string.format("[FSM] share f=%d node=%s share=%.2f stance=%s", f, node, out, tostring(cross.stance)))
        end
        return out
    end

    return B
end

return M
