-- bar_framework/army_groups.lua  (army groups as a structure, and the support elements each one opts into)
--
-- User 2026-10-30: "you don't want to build tons of them you just want 'enough' ... a fixed number that slowly gets filled in and when there
-- are like 6 for a group it has enough aa support".  Support units used to be a stance share (built all game: the flat 10% flak) or belonged
-- to systems that knew nothing about the groups.  Here the army is a set of GROUP RECORDS -- one per click_army attack group (kind "raid", or
-- "slow" for the slow group) plus the stage (kind "stage": the home blob between launches) -- and each kind opts into a checklist of SUPPORT
-- ELEMENTS (bar_framework/support/<name>.lua), each with a fixed size:
--
--   SUPPORT = {                                       -- unit_runtime option (the bot's default); a stance's plan.group_support replaces it
--       raid  = { aa = { n = 4 }, spam = { n = 6 }, scout = { every_s = 30 } },
--       slow  = { aa = { n = 6 }, rez = { n = 3 }, antinuke = { n = 1 }, jammer = { n = 1 } },
--       stage = { },
--   }
--   (an element may also be written `aa = 4` (n) or `aa = true` (the element's own CFG.N); unknown keys go to the element as its cfg)
--
-- What the stance makes fills the groups (click_army, unchanged); the elements are extra units this module OWNS (army_broker role SUP_<NAME>, so
-- click_army's Members() leaves them alone).  The labs build an element up to its want and stop: want = n x the number of group slots of that
-- kind (raid = click_army MAX_GROUPS, slow = 1 while the slow group is on, stage = 1), published as WG.MetalBot.support for lab_rules'
-- "group-support" want.  Groups come and go; their elements do not: a group that falls hands its support units to the pool (the stage record),
-- and a group that launches fills from the pool first, nearest units first.  An element no record wants any more hands its units back to their
-- usual owner (unit_runtime's giveBack: AA -> the GROUND_AA escort, grunts -> the army, Savior -> defense_crew).
--
-- An element module: { name, CFG = { N = ... }, Init(ctx)?, Gate(cfg, ctx) -> bool?, Accept(defID, born, cfg, ctx) -> bool?,
--   Adopt(ctx) -> { uid, ... }? (units it borrows from another owner instead of taking new ones: rez bots), Picks(cfg) -> { names }? (what the
--   labs build for it), Update(rec, units, cfg, frame, ctx) }.  A new element is one file in support/ plus its name in M.ELEMENTS.
--
--   AG.Init{ ARMY, CA, MM, EI, SN, RB, RC, UQ, HOST, WG, cfg = SUPPORT, giveBack = function(uid, defID, el), plan = function() -> plan }
--   AG.Sync(frame)  AG.Update(frame)            -- after click_army's tick
--   AG.NoteCreated(uid, builderID)              -- UnitCreated (the spam lab's grunts are known by their builder)
--   AG.Offer(uid, defID) -> bool                -- UnitFinished: true = an element took the unit (no other owner gets it)
--   AG.OnDestroyed(uid)  AG.Owns(uid)  AG.Units() -> { [uid] = { el, rec } }  AG.Groups()  AG.Wants()  AG.SpamWanted()  AG.RecordOf(uid)
-- Logs [SUP] rows.  Published as WG.ArmyGroups.

local M = {}

M.CFG = {
    LOG_EVERY = 900,      -- frames between [SUP] record rows
}
M.ELEMENTS = { "aa", "spam", "rez", "antinuke", "jammer", "scout" }      -- the checklist, in the order a unit is offered to them

local CMD_MOVE, CMD_FIGHT = 10, 16

local O = {}              -- Init options
local E = {}              -- [name] = element module
local records = {}        -- [id] = record; id 0 = the stage
local order = {}          -- the records, the stage last, attack groups by value
local owner = {}          -- [uid] = { el = name, rec = id, defID = defID, adopt = bool }
local made = {}           -- [el] = units ever taken
local born = {}           -- [uid] = builderID (UnitCreated), until the unit finishes
local spec = {}           -- [kind] = { [el] = cfg } this tick
local wants = {}          -- [el] = { want, have, made, picks }
local lastLog = -1e9
local ctx = {}

local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end

-- Where unit i of n stands: `along` elmos ahead of the record's centre (negative = behind, toward home) on its axis, on a golden-angle
-- spiral of `spread` x sqrt(i) round that point (the GROUND_AA escort's geometry), clamped to the map.
local function Spot(rec, along, i, spread)
    local x, z = rec.cx + (rec.dx or 0) * along, rec.cz + (rec.dz or 0) * along
    local a, r = i * 2.4, (spread or 60) * math.sqrt(i)
    x, z = x + math.cos(a) * r, z + math.sin(a) * r
    if O.MM then x, z = O.MM.Clamp(x, z, 200) end
    return x, z
end

-- A claim for one of our units, unless a stance behaviour is stepping it (range_kite: the host holds it until the step is done).
local function Claim(uid, role, cmd, x, z, frame)
    if O.HOST and O.HOST:IsHeld(uid, frame) then return false end
    return O.ARMY.Claim(O.ARMY.PRIO.LINE, uid, { role = role, cmd = cmd, x = x, z = z }, frame)
end

local function Load(name)
    local ok, r = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/support/" .. name .. ".lua")
    if ok and r then return r end
    Spring.Echo("[SUP] ERROR loading support element " .. name .. ": " .. tostring(r))
    return nil
end

function M.Init(o)
    O = o or {}
    E, records, order, owner, made, born, spec, wants, lastLog = {}, {}, {}, {}, {}, {}, {}, {}, -1e9
    ctx = { ARMY = O.ARMY, CA = O.CA, MM = O.MM, EI = O.EI, SN = O.SN, RB = O.RB, RC = O.RC, UQ = O.UQ, HOST = O.HOST, WG = O.WG,
            CMD_MOVE = CMD_MOVE, CMD_FIGHT = CMD_FIGHT, RecordOf = M.RecordOf, Clock = Clock, Spot = Spot, Claim = Claim }
    for _, name in ipairs(M.ELEMENTS) do
        local el = Load(name)
        if el then
            E[name] = el
            made[name] = 0
            if el.Init then el.Init(ctx) end
        end
    end
    records[0] = { id = 0, kind = "stage", units = {} }
    if O.WG then
        O.WG.ArmyGroups = { Groups = M.Groups, Owns = M.Owns, Wants = M.Wants, SpamWanted = M.SpamWanted, RecordOf = M.RecordOf }
    end
    local parts = {}
    for _, kind in ipairs({ "raid", "slow", "stage" }) do
        local els = {}
        for el in pairs((O.cfg or {})[kind] or {}) do els[#els + 1] = el end
        table.sort(els)
        parts[#parts + 1] = kind .. "=" .. (#els > 0 and table.concat(els, ",") or "-")
    end
    Spring.Echo("[SUP] army groups on: " .. table.concat(parts, " "))
end

-- ── opt-ins ───────────────────────────────────────────────────────────────────

-- An element entry -> its cfg table (n filled in), or nil when off.
local function ElCfg(name, v)
    local el = E[name]
    if not el or v == nil or v == false then return nil end
    local c = {}
    for k, x in pairs(el.CFG or {}) do c[k] = x end
    if type(v) == "number" then c.n = v
    elseif type(v) == "table" then for k, x in pairs(v) do c[k] = x end end
    if c.n == nil then c.n = c.N or 0 end
    return c
end

local warned = {}
local function Spec()
    local plan = O.plan and O.plan()
    local src = (plan and plan.group_support) or O.cfg or {}
    local out = {}
    for kind, els in pairs(src) do
        out[kind] = {}
        for name, v in pairs(els) do
            if E[name] then
                local c = ElCfg(name, v)
                if c and (not E[name].Gate or E[name].Gate(c, ctx)) then out[kind][name] = c end
            elseif not warned[name] then
                warned[name] = true
                Spring.Echo("[SUP] unknown support element '" .. tostring(name) .. "' (not in army_groups.ELEMENTS)")
            end
        end
    end
    return out
end

-- How many records of each kind the labs build for: raid = the fast group cap, slow = 1 while the slow group is on, stage = 1.
local function Slots(kind)
    local CA = O.CA
    if kind == "stage" then return 1 end
    if not (CA and CA.CFG) then return 0 end
    if kind == "slow" then return ((CA.CFG.SLOW_SPEED or 0) > 0) and 1 or 0 end
    if kind == "raid" then return CA.CFG.MAX_GROUPS or 0 end
    return 0
end

-- ── records ───────────────────────────────────────────────────────────────────

local function Axis(rec)
    local MM = O.MM
    local tx, tz
    if rec.target and rec.target.x then tx, tz = rec.target.x, rec.target.z
    elseif MM then tx, tz = MM.Foe() end
    if tx and rec.cx then
        local dx, dz = tx - rec.cx, tz - rec.cz
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 1 then return dx / d, dz / d end
    end
    if MM then return MM.Axis() end
    return 0, 0
end

local function Dist2(ax, az, bx, bz) return (ax - bx) ^ 2 + (az - bz) ^ 2 end

local function ToPool(uid)
    local o = owner[uid]
    if o then o.rec = 0 end
end

local function GiveBack(uid)
    local o = owner[uid]
    if not o then return end
    owner[uid] = nil
    if O.ARMY and O.ARMY.RoleOf(uid) and O.ARMY.RoleOf(uid):sub(1, 4) == "SUP_" then O.ARMY.Release(uid) end
    if not o.adopt and O.giveBack and Alive(uid) then O.giveBack(uid, o.defID, o.el) end
end

function M.Sync(frame)
    local CA = O.CA
    spec = Spec()
    -- live records: click_army's attacking groups + the stage
    local live = { [0] = true }
    for _, g in ipairs((CA and CA.Groups and CA.Groups()) or {}) do
        if g.state == "attack" and g.cx then
            local rec = records[g.id]
            if not rec then
                rec = { id = g.id, kind = g.slow and "slow" or "raid", since = frame }
                records[g.id] = rec
                Spring.Echo(string.format("[SUP] %s group %d (%s) up, value %.0f", Clock(frame), g.id, rec.kind, g.value or 0))
            end
            rec.cx, rec.cz, rec.value, rec.n, rec.target = g.cx, g.cz, g.value or 0, g.n or 0, g.target
            live[g.id] = true
        end
    end
    local st = records[0]
    local sx, sz = nil, nil
    if CA and CA.StagePoint then sx, sz = CA.StagePoint() end
    if not sx and O.MM and O.MM.Ready() then sx, sz = O.MM.Base() end
    st.cx, st.cz, st.value, st.n = sx, sz, 0, 0
    for id, rec in pairs(records) do
        if not live[id] then
            local n = 0
            for uid, o in pairs(owner) do if o.rec == id then ToPool(uid); n = n + 1 end end
            records[id] = nil
            Spring.Echo(string.format("[SUP] %s group %d (%s) gone: %d support unit(s) back to the pool", Clock(frame), id, rec.kind, n))
        end
    end
    order = {}
    for id, rec in pairs(records) do
        rec.dx, rec.dz = Axis(rec)
        rec.want = spec[rec.kind] or {}
        if id ~= 0 then order[#order + 1] = rec end
    end
    table.sort(order, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.id < b.id end)
    order[#order + 1] = st

    -- dead units out; the labs' wants
    for uid in pairs(owner) do if not Alive(uid) then owner[uid] = nil end end
    wants = {}
    for name, el in pairs(E) do
        local want = 0
        for kind, els in pairs(spec) do
            local c = els[name]
            if c then want = want + (c.n or 0) * Slots(kind) end
        end
        local have = 0
        for _, o in pairs(owner) do if o.el == name then have = have + 1 end end
        local picks
        if el.Picks then
            local c
            for _, els in pairs(spec) do c = c or els[name] end
            picks = c and el.Picks(c, ctx) or nil
        end
        wants[name] = { want = want, have = have, made = made[name] or 0, picks = picks }
        -- an element nobody wants any more: its units go back to their usual owner
        if want == 0 and have > 0 then
            for uid, o in pairs(owner) do if o.el == name then GiveBack(uid) end end
            wants[name].have = 0
            Spring.Echo(string.format("[SUP] %s %s: not wanted any more, %d unit(s) handed back", Clock(frame), name, have))
        end
    end
    -- adopted elements (rez bots): borrow more while short of the want
    for name, el in pairs(E) do
        local w = wants[name]
        if el.Adopt and w.want > w.have then
            for _, uid in ipairs(el.Adopt(ctx) or {}) do
                if w.have >= w.want then break end
                if not owner[uid] and Alive(uid) then
                    owner[uid] = { el = name, rec = 0, defID = Spring.GetUnitDefID(uid), adopt = true }
                    w.have = w.have + 1
                    made[name] = (made[name] or 0) + 1
                end
            end
        elseif el.Adopt and w.have > w.want then
            local extra = w.have - w.want
            for uid, o in pairs(owner) do
                if extra <= 0 then break end
                if o.el == name and o.rec == 0 then GiveBack(uid); extra = extra - 1; w.have = w.have - 1 end
            end
        end
    end

    -- hand the pool out: each attack group fills each element up to n from the pool (nearest first); a group over n gives the surplus back
    for _, rec in ipairs(order) do
        if rec.id ~= 0 then
            for name, c in pairs(rec.want) do
                local mine, pool = {}, {}
                for uid, o in pairs(owner) do
                    if o.el == name then
                        if o.rec == rec.id then mine[#mine + 1] = uid elseif o.rec == 0 then pool[#pool + 1] = uid end
                    end
                end
                local n = c.n or 0
                if #mine > n then
                    table.sort(mine)
                    for i = n + 1, #mine do ToPool(mine[i]) end
                elseif #mine < n and #pool > 0 and rec.cx then
                    local d = {}
                    for _, uid in ipairs(pool) do
                        local x, _, z = Spring.GetUnitPosition(uid)
                        d[uid] = x and Dist2(x, z, rec.cx, rec.cz) or math.huge
                    end
                    table.sort(pool, function(a, b) if d[a] ~= d[b] then return d[a] < d[b] end return a < b end)
                    local k = 0
                    for i = 1, math.min(n - #mine, #pool) do owner[pool[i]].rec = rec.id; k = k + 1 end
                    if k > 0 then
                        Spring.Echo(string.format("[SUP] %s group %d (%s) %s +%d from the pool (%d / %d)", Clock(frame), rec.id, rec.kind, name, k,
                            #mine + k, n))
                    end
                end
            end
            -- an element this group no longer opts into: its units go to the pool
            for uid, o in pairs(owner) do
                if o.rec == rec.id and not rec.want[o.el] then ToPool(uid) end
            end
        end
    end
    if O.WG and O.WG.MetalBot then
        local pub = {}
        for name, w in pairs(wants) do
            if w.want > 0 or w.have > 0 then pub[name] = { want = w.want, have = w.have, made = w.made, picks = w.picks } end
        end
        O.WG.MetalBot.support = pub
    end
end

-- ── units in and out ──────────────────────────────────────────────────────────

function M.NoteCreated(uid, builderID)
    local lab = O.WG and O.WG.SpamLab
    if builderID and lab and lab.id == builderID then born[uid] = builderID end     -- only the spam lab's units need their builder
end

-- A finished unit: the first element (M.ELEMENTS order) that accepts it and is short of its want takes it, into the pool.
function M.Offer(uid, defID)
    local b = born[uid]
    born[uid] = nil
    local frame = Spring.GetGameFrame()
    for _, name in ipairs(M.ELEMENTS) do
        local el = E[name]
        local w = wants[name]
        if el and el.Accept and w and w.want > w.have then
            local c
            for _, els in pairs(spec) do c = c or els[name] end
            if c and el.Accept(defID, b, c, ctx) then
                owner[uid] = { el = name, rec = 0, defID = defID }
                w.have = w.have + 1
                made[name] = (made[name] or 0) + 1
                if O.WG and O.WG.MetalBot and O.WG.MetalBot.support and O.WG.MetalBot.support[name] then
                    O.WG.MetalBot.support[name].have, O.WG.MetalBot.support[name].made = w.have, made[name]
                end
                local d = UnitDefs[defID]
                Spring.Echo(string.format("[SUP] %s %s takes %s %d (%d / %d)", Clock(frame), name, d and d.name or "?", uid, w.have, w.want))
                return true
            end
        end
    end
    return false
end

function M.OnDestroyed(uid)
    owner[uid] = nil
    born[uid] = nil
end

-- ── the elements' orders ──────────────────────────────────────────────────────

function M.Update(frame)
    local lists = {}
    for uid, o in pairs(owner) do
        local key = o.rec .. ":" .. o.el
        lists[key] = lists[key] or {}
        lists[key][#lists[key] + 1] = uid
    end
    for _, rec in ipairs(order) do
        if rec.cx then
            for name, el in pairs(E) do
                local units = lists[rec.id .. ":" .. name]
                if units then table.sort(units) end
                local c = rec.want[name]
                if not c then for _, els in pairs(spec) do c = c or els[name] end end   -- the pool's units take any kind's settings
                if c and (units or (el.NoUnits and rec.id ~= 0)) then
                    local ok, err = pcall(el.Update, rec, units or {}, c, frame, ctx)
                    if not ok then Spring.Echo("[SUP] " .. name .. " error: " .. tostring(err)) end
                end
            end
        end
    end
    if frame - lastLog >= M.CFG.LOG_EVERY then
        lastLog = frame
        for _, rec in ipairs(order) do
            local parts = {}
            local names = {}
            for name in pairs(E) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local units = lists[rec.id .. ":" .. name]
                local c = rec.want[name]
                if E[name].NoUnits then
                    if c and rec.id ~= 0 then parts[#parts + 1] = string.format("%s every %ds", name, c.every_s or 0) end
                elseif c or units then
                    parts[#parts + 1] = string.format("%s %d/%d", name, units and #units or 0, c and c.n or 0)
                end
            end
            Spring.Echo(string.format("[SUP] %s %s %d value %.0f n %d | %s", Clock(frame), rec.kind, rec.id, rec.value or 0, rec.n or 0,
                #parts > 0 and table.concat(parts, " ") or "-"))
        end
        local parts = {}
        for name, w in pairs(wants) do
            if w.want > 0 or w.have > 0 then parts[#parts + 1] = string.format("%s %d/%d made %d", name, w.have, w.want, w.made) end
        end
        table.sort(parts)
        if #parts > 0 then Spring.Echo("[SUP] " .. Clock(frame) .. " wants: " .. table.concat(parts, ", ")) end
    end
end

-- ── queries ───────────────────────────────────────────────────────────────────

function M.Owns(uid) return owner[uid] ~= nil end
function M.Units() return owner end
function M.Groups() return order end
function M.Wants() return wants end
function M.SpamWanted() return wants.spam ~= nil and wants.spam.want > 0 end
-- The record a unit works for (the stage for the pool), or nil when the unit is not ours.
function M.RecordOf(uid)
    local o = owner[uid]
    return o and records[o.rec] or nil
end

return M
