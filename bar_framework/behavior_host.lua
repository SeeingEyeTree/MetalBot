-- bar_framework/behavior_host.lua
-- Plug-and-play unit behaviours.  The unit-control counterpart of blueprint_placer: a behaviour is a plain table in
-- bar_framework/behaviors/<name>.lua, the host is the engine that owns membership, ordering and de-duplication, and
-- the caller owns the host (a plain table from New), so several hosts can run side by side.
--
-- A behaviour:
--   return {
--     name = "kite",
--     cfg  = { ...defaults... },                 -- every tunable lives here, overridable per assignment
--     Init   = function(st) end,                 -- optional: fill the per-cohort state table
--     Update = function(st, group, ctx, frame, host) return claimed end,
--     Describe = function(cfg) return "text" end -- optional, for docs / logs
--   }
--   group  = { cfg = <merged tunables>, list = { {uid, x, z, v, def, hp}, ... }, cx, cz, value }
--   claimed: nil/false = this behaviour did not act, so the next behaviour in the unit's list may;
--            true = it acted for the whole group; { [uid]=true } = it acted for those units.
--
-- Assign(uid, "kite", {step = 400})            one behaviour, tunables overridden for this unit
-- Assign(uid, {"kite", "advance"}, {kite = {step = 400}})   a stack: the first behaviour that claims the unit wins
-- Units with the same behaviour AND the same overrides form one cohort and are updated together (they move as a
-- formation); a unit with different tunables is a separate cohort, so one behaviour is shared by different units
-- (Lasher step 400, Pounder step 150) without copying code.
--
-- ctx is whatever the caller passes to Update (a read-only snapshot per tick: enemy queries, map model, plan,
-- resources).  Behaviours read it and never reach for module globals.  Orders go out through host:Order / host:Stand,
-- which drop a repeat of the last order, or through the optional o.give(uid, cmd, params) sink (tests, army_broker).

local M = {}

M.CFG = {
    HEARTBEAT   = 450,   -- frames after which an identical order is repeated anyway
    REISSUE_EPS = 40,    -- elmos: a move to within this of the last target is "the same order"
    REISSUE_GAP = 30,    -- frames: minimum gap before a changed order of the same kind
    SPREAD_R    = 300,   -- formation offsets longer than this are pulled in (stragglers rejoin the core)
}

local CMD_MOVE, CMD_FIGHT = 10, 16
M.CMD_MOVE, M.CMD_FIGHT = CMD_MOVE, CMD_FIGHT

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Value(defID)
    local d = defID and UnitDefs and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end
M.Value = Value

local function Copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end

-- A stable string for an override table (cohort key).
local function KeyOf(over)
    if not over then return "" end
    local ks = {}
    for k in pairs(over) do ks[#ks + 1] = tostring(k) end
    if #ks == 0 then return "" end
    table.sort(ks)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = k .. "=" .. tostring(over[k]) end
    return table.concat(parts, ",")
end

-- o.cfg: override M.CFG; o.give: order sink; o.load(name) -> behaviour table (default VFS.Include of behaviors/<name>)
function M.New(o)
    o = o or {}
    local h = {
        cfg = Copy(M.CFG), reg = {}, units = {}, last = {}, state = {}, stats = {}, holdUntil = {},
        give = o.give, loader = o.load,
    }
    for k, v in pairs(o.cfg or {}) do h.cfg[k] = v end
    return setmetatable(h, { __index = M.Host })
end

M.Host = {}
local H = M.Host

-- ── Registry ──────────────────────────────────────────────────────────────────

function H:Register(b)
    assert(type(b) == "table" and b.name and b.Update, "behaviour needs a name and an Update")
    self.reg[b.name] = b
    return b
end

-- The behaviour called `name`, loaded from bar_framework/behaviors/<name>.lua on first use.
function H:Use(name)
    local b = self.reg[name]
    if b then return b end
    if self.loader then b = self.loader(name)
    elseif VFS and VFS.Include then
        local ok, res = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/behaviors/" .. name .. ".lua")
        if ok then b = res else Spring.Echo("[BH] cannot load behaviour " .. name .. ": " .. tostring(res)) end
    end
    if b then return self:Register(b) end
    return nil
end

function H:Behaviours()
    local out = {}
    for name in pairs(self.reg) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- ── Membership ────────────────────────────────────────────────────────────────

function H:Assign(uid, names, over)
    if type(names) == "string" then names, over = { names }, { [names] = over } end
    local a = { names = {}, cfg = {}, key = {} }
    for _, name in ipairs(names) do
        local b = self:Use(name)
        if b then
            local cfg = Copy(b.cfg)
            for k, v in pairs((over and over[name]) or {}) do cfg[k] = v end
            a.names[#a.names + 1] = name
            a.cfg[name] = cfg
            a.key[name] = KeyOf(over and over[name])
        end
    end
    if #a.names == 0 then self.units[uid] = nil; return false end
    self.units[uid] = a
    return true
end

function H:Remove(uid)
    self.units[uid], self.last[uid], self.holdUntil[uid] = nil, nil, nil
end

-- A behaviour that moved a unit on purpose (kite's step back) holds it until `untilFrame`: other controllers that
-- order the same unit (slow_front's advance) ask IsHeld and keep their hands off.
function H:Hold(uid, untilFrame) self.holdUntil[uid] = untilFrame end
function H:IsHeld(uid, frame)
    local h = self.holdUntil[uid]
    return h ~= nil and frame < h
end

function H:Has(uid) return self.units[uid] ~= nil end
function H:Behaviours_Of(uid) local a = self.units[uid]; return a and a.names or nil end

function H:Count()
    local n = 0
    for uid in pairs(self.units) do if Spring.GetUnitDefID(uid) then n = n + 1 end end
    return n
end

-- ── Orders ────────────────────────────────────────────────────────────────────

-- One order, de-duplicated: the same command to (nearly) the same place is not repeated until the heartbeat.
function H:Order(frame, uid, cmd, x, z, tid)
    local c, l = self.cfg, self.last[uid]
    if l and l.cmd == cmd and l.tid == tid then
        if frame - l.f < c.HEARTBEAT and (tid or Dist(x, z, l.x, l.z) <= c.REISSUE_EPS) then return false end
        if not tid and frame - l.f < c.REISSUE_GAP then return false end
    end
    local params = tid and { tid } or { x, (Spring.GetGroundHeight and Spring.GetGroundHeight(x, z)) or 0, z }
    if self.give then self.give(uid, cmd, params) else Spring.GiveOrderToUnit(uid, cmd, params, {}) end
    self.last[uid] = { cmd = cmd, x = x, z = z, tid = tid, f = frame }
    return true
end

-- Stop where it stands and fire: a FIGHT order onto its own spot.
function H:Stand(frame, u)
    return self:Order(frame, u.uid, CMD_FIGHT, u.x, u.z)
end

function H:LastOrder(uid) return self.last[uid] end

-- Move every unit by (ux,uz)*step but keep its place in the formation: target = core + dir*step + its offset from the
-- core (a straggler is pulled to the core).  clamp(x, z) -> x, z keeps targets on the map.
function H:Translate(frame, list, cx, cz, ux, uz, step, cmd, clamp)
    local bx, bz, spread = cx + ux * step, cz + uz * step, self.cfg.SPREAD_R
    for _, u in ipairs(list) do
        local ox, oz = u.x - cx, u.z - cz
        local od = math.sqrt(ox * ox + oz * oz)
        if od > spread then ox, oz = ox / od * spread * 0.5, oz / od * spread * 0.5 end
        local x, z = bx + ox, bz + oz
        if clamp then x, z = clamp(x, z) end
        self:Order(frame, u.uid, cmd, x, z)
    end
end

-- ── Driver ────────────────────────────────────────────────────────────────────

local function Member(uid)
    local x, _, z = Spring.GetUnitPosition(uid)
    if not x then return nil end
    local hp, mhp = Spring.GetUnitHealth(uid)
    local def = Spring.GetUnitDefID(uid)
    return { uid = uid, x = x, z = z, def = def, v = Value(def),
             hp = (hp and mhp and mhp > 0) and hp / mhp or 1 }
end

-- Run every behaviour once.  A unit goes through its list in order; once a behaviour claims it, the rest are skipped
-- for it this tick.  Returns { [uid] = name of the behaviour that acted } (units nobody claimed are absent).
function H:Update(frame, ctx)
    local members, dead = {}, {}
    for uid in pairs(self.units) do
        if Spring.GetUnitDefID(uid) then
            local m = Member(uid)
            if m then members[uid] = m else dead[#dead + 1] = uid end
        else
            dead[#dead + 1] = uid
        end
    end
    for _, uid in ipairs(dead) do self:Remove(uid) end

    local acted = {}
    -- depth d = position in the unit's list; behaviours are processed depth by depth so a stack falls through
    local depth = 1
    while true do
        local cohorts, any = {}, false
        for uid, a in pairs(self.units) do
            local name = a.names[depth]
            if name and not acted[uid] and members[uid] then
                any = true
                local ck = name .. "|" .. a.key[name]
                local c = cohorts[ck]
                if not c then c = { name = name, key = a.key[name], cfg = a.cfg[name], list = {} }; cohorts[ck] = c end
                c.list[#c.list + 1] = members[uid]
            end
        end
        if not any then break end
        local keys = {}
        for ck in pairs(cohorts) do keys[#keys + 1] = ck end
        table.sort(keys)                                   -- deterministic order across runs
        for _, ck in ipairs(keys) do
            local c = cohorts[ck]
            local b = self.reg[c.name]
            local st = self.state[ck]
            if not st then
                st = { cfg = c.cfg }
                if b.Init then b.Init(st) end
                self.state[ck] = st
            end
            table.sort(c.list, function(p, q) return p.uid < q.uid end)
            local sx, sz, sv = 0, 0, 0
            for _, u in ipairs(c.list) do sx, sz, sv = sx + u.x * u.v, sz + u.z * u.v, sv + u.v end
            local group = { cfg = c.cfg, list = c.list, value = sv }
            if sv > 0 then group.cx, group.cz = sx / sv, sz / sv
            else group.cx, group.cz = c.list[1].x, c.list[1].z end
            local ok, claimed = pcall(b.Update, st, group, ctx, frame, self)
            if not ok then
                self.stats.errors = (self.stats.errors or 0) + 1
                if frame - (self.errF or -1e9) > 900 then
                    self.errF = frame
                    Spring.Echo("[BH] " .. c.name .. " failed: " .. tostring(claimed))
                end
            elseif claimed == true then
                for _, u in ipairs(c.list) do acted[u.uid] = c.name end
            elseif type(claimed) == "table" then
                for uid in pairs(claimed) do acted[uid] = c.name end
            end
        end
        depth = depth + 1
    end
    return acted
end

return M
