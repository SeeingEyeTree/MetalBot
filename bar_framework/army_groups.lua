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
--   AG.PoolShort(kind) -> name, have, need, deficit | nil  -- an element with min_frac whose pool is under that share of n (unit_runtime's launch gate); deficit = what the groups out lack
-- Logs [SUP] rows.  Published as WG.ArmyGroups.

local M = {}

M.CFG = {
    LOG_EVERY = 900,      -- frames between [SUP] record rows
}
M.ELEMENTS = { "aa", "arty", "stop", "t1stop", "spam", "rez", "antinuke", "jammer", "scout" }      -- the checklist, in the order a unit is offered to them
-- HOME records (2026-11-02, support/t1stop.lua): kind "home", ids -1..-3, one per sector of the base (in front along the axis, then the two flanks at
-- +-HOME_ANG radians), HOME_R from the eco footprint's centre.  An element with HomeGroups() says how many stand; they come first in the hand-out.
M.HOME_R, M.HOME_ANG = 1300, { 0, -0.95, 0.95 }
M.DENSITY_R = 1000        -- RANK = "density" elements: enemy ground units this close to a record count for it
local homeN = 0
-- arty / stop: the slow element a group escorts (click_army ESCORT reads rec.arty; one of the two per bot)
-- 2026-11-01: support is ordered through WG.LabOrders when lab_rules publishes it (SUPPORT_ORDERS): one high-tier request per element, n = want - have.
-- Elements whose units come from elsewhere (spam: its own lab; rez: adopted) are not requested.
M.NO_REQUEST = { spam = true, rez = true, scout = true }
M.ESCORT_MIN = 2          -- a group with an arty element and fewer landed Quakers than this is a reserve group (click_army: out on the map, no dives)
M.AA_RESERVE_N = 2        -- ...as is one under raidAir with fewer than this many AA with it (game 2026-11-01: half of 6 kept all three groups passive 4 min)
M.AA_NEAR_R = 1500        -- AA this close to the group's core is with it (pace, reserve)

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
local offSince = {}       -- [el] = frame its want fell to 0 (O.offGrace)
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
-- A paced claim (2026-11-01): the goal leads a moving unit a little and is re-sent at 1 Hz once it moved PACE_EPS, so the unit keeps moving at the
-- pace of what it follows (the engine's ctrl-move speed cap is not open to widgets: a 4th MOVE param and the ctrl option both do nothing from Lua)
M.PACE_EPS = 60
local function ClaimPaced(uid, role, cmd, x, z, frame)
    if O.HOST and O.HOST:IsHeld(uid, frame) then return false end
    return O.ARMY.Claim(O.ARMY.PRIO.LINE, uid, { role = role, cmd = cmd, x = x, z = z, eps = M.PACE_EPS, urgent = true }, frame)
end
-- velocity (elmos/s) of a point tracked in t.prev, clamped to vmax
local function Velocity(t, key, x, z, frame, vmax)
    local p = t[key]
    local vx, vz = 0, 0
    if p and frame > p.f then
        local dt = (frame - p.f) / 30
        vx, vz = (x - p.x) / dt, (z - p.z) / dt
        local v = math.sqrt(vx * vx + vz * vz)
        if v > vmax then vx, vz = vx / v * vmax, vz / v * vmax end
    end
    t[key] = { x = x, z = z, f = frame }
    return vx, vz
end

local function Load(name)
    local ok, r = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/support/" .. name .. ".lua")
    if ok and r then return r end
    Spring.Echo("[SUP] ERROR loading support element " .. name .. ": " .. tostring(r))
    return nil
end

function M.Init(o)
    O = o or {}
    E, records, order, owner, made, born, spec, wants, lastLog, offSince = {}, {}, {}, {}, {}, {}, {}, {}, -1e9, {}
    ctx = { ARMY = O.ARMY, CA = O.CA, MM = O.MM, EI = O.EI, SN = O.SN, RB = O.RB, RC = O.RC, UQ = O.UQ, HOST = O.HOST, WG = O.WG,
            LIFT = O.LIFT, TakeEscortAA = O.takeEscortAA,
            CMD_MOVE = CMD_MOVE, CMD_FIGHT = CMD_FIGHT, RecordOf = M.RecordOf, Clock = Clock, Spot = Spot, Claim = Claim, ClaimPaced = ClaimPaced }
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
    for _, kind in ipairs({ "raid", "slow", "home", "stage" }) do
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
    if kind == "home" then return homeN end
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
            rec.screenOk = g.screenOk                  -- click_army escort mode: the screen stands in front of the Quakers
            rec.screenV = g.escortOn and g.coreValue or nil   -- ... and what it is worth (support/arty.lua: pull back only when the screen cannot protect)
            rec.posture = g.escortOn and g.posture or nil     -- the group's one decision: "advance" | "back" (screen, escorted units and AA step back together)
            rec.vx, rec.vz = Velocity(rec, "corePrev", g.cx, g.cz, frame, 120)   -- the core's velocity (support/aa.lua: its post leads by it)
            live[g.id] = true
        end
    end
    -- home records: as many as the home elements want (t1stop's raid pressure), each a sector of the base
    homeN = 0
    for name, c in pairs(spec.home or {}) do
        local el = E[name]
        if el and el.HomeGroups then homeN = math.max(homeN, el.HomeGroups(c, ctx) or 0) end
    end
    if homeN > 0 and O.MM and O.MM.Ready() then
        local bx, bz = O.MM.Base()
        local ax, az = O.MM.Axis()
        for i = 1, math.min(homeN, #M.HOME_ANG) do
            local id = -i
            local rec = records[id]
            if not rec then
                rec = { id = id, kind = "home", since = frame, n = 0 }
                records[id] = rec
                Spring.Echo(string.format("[SUP] %s home group %d up (sector %d)", Clock(frame), id, i))
            end
            local a = M.HOME_ANG[i]
            local hx, hz = ax * math.cos(a) - az * math.sin(a), ax * math.sin(a) + az * math.cos(a)
            rec.cx, rec.cz = O.MM.Clamp(bx + hx * M.HOME_R, bz + hz * M.HOME_R, 300)
            rec.homeDx, rec.homeDz, rec.target = hx, hz, nil
            live[id] = true
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
        if rec.kind == "home" then
            rec.dx, rec.dz = rec.homeDx, rec.homeDz
            local v = 0                                   -- what stands in it (support/arty.lua's danger check, the order below)
            for uid, o in pairs(owner) do if o.rec == id then v = v + ((UnitDefs[o.defID] and UnitDefs[o.defID].metalCost) or 0) end end
            rec.value = v
        else
            rec.dx, rec.dz = Axis(rec)
        end
        rec.want = spec[rec.kind] or {}
        if id ~= 0 then order[#order + 1] = rec end
    end
    -- home records first (a defending group gets its Tzars before a raid group), then attack groups by value
    table.sort(order, function(a, b)
        local ha, hb = a.kind == "home", b.kind == "home"
        if ha ~= hb then return ha end
        if a.value ~= b.value then return a.value > b.value end return a.id < b.id end)
    order[#order + 1] = st

    -- dead units out; the labs' wants
    for uid in pairs(owner) do if not Alive(uid) then owner[uid] = nil end end
    wants = {}
    for name, el in pairs(E) do
        local want = 0
        for kind, els in pairs(spec) do
            local c = els[name]
            if c then want = want + (el.WantTotal and el.WantTotal(c, Slots(kind)) or (c.n or 0) * Slots(kind)) end
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
        -- an element nobody wants any more: its units go back to their usual owner (after O.offGrace frames: raidAir flickers off and on)
        if want > 0 then offSince[name] = nil end
        if want == 0 and have > 0 then
            offSince[name] = offSince[name] or frame
            if frame - offSince[name] >= (O.offGrace or 0) then
                for uid, o in pairs(owner) do if o.el == name then GiveBack(uid) end end
                wants[name].have = 0
                Spring.Echo(string.format("[SUP] %s %s: not wanted any more, %d unit(s) handed back", Clock(frame), name, have))
            end
        end
    end
    -- a pool unit its element no longer accepts (the aa element went to flak trucks only: a Lasher) goes back to its usual owner (elements that
    -- say so: spam's Accept needs the unit's builder, which only a new unit has)
    for uid, o in pairs(owner) do
        local el = E[o.el]
        if o.rec == 0 and not o.adopt and el and el.Accept and el.REJECT_POOL then
            local c
            for _, els in pairs(spec) do c = c or els[o.el] end
            if c and not el.Accept(o.defID, nil, c, ctx) then GiveBack(uid); if wants[o.el] then wants[o.el].have = wants[o.el].have - 1 end end
        end
    end
    -- adopted elements (rez bots; GROUND_AA escorts for aa): borrow more while short of the want
    for name, el in pairs(E) do
        local w = wants[name]
        if el.Adopt and w.want > w.have then
            local c
            for _, els in pairs(spec) do c = c or els[name] end
            for _, uid in ipairs(el.Adopt(ctx, c, w.want - w.have) or {}) do
                if w.have >= w.want then break end
                if not owner[uid] and Alive(uid) then
                    owner[uid] = { el = name, rec = 0, defID = Spring.GetUnitDefID(uid), adopt = not el.ADOPT_OWNS }
                    w.have = w.have + 1
                    made[name] = (made[name] or 0) + 1
                end
            end
        elseif el.Adopt and not el.ADOPT_OWNS and w.have > w.want then
            local extra = w.have - w.want
            for uid, o in pairs(owner) do
                if extra <= 0 then break end
                if o.el == name and o.rec == 0 then GiveBack(uid); extra = extra - 1; w.have = w.have - 1 end
            end
        end
    end

    -- an element with RANK = "density" (the Tzars, user 2026-11-02: "proritize going to groups that are fighting high unit density, that is where they can
    -- get the most value") is handed out to the records with the most enemy ground units within DENSITY_R of them first (seen in the last 300 frames)
    local function Density(rec)
        if not (O.EI and O.EI.Records and rec.cx) then return 0 end
        local n, r2 = 0, M.DENSITY_R * M.DENSITY_R
        for _, er in pairs(O.EI.Records()) do
            local c = er.c
            if c and c.mobile and c.armed and not c.air and not c.scout and frame - er.frame <= 300 and Dist2(er.x, er.z, rec.cx, rec.cz) <= r2 then n = n + 1 end
        end
        return n
    end
    for _, rec in ipairs(order) do rec.density = (rec.id ~= 0) and Density(rec) or 0 end
    local byDensity = {}
    for _, rec in ipairs(order) do byDensity[#byDensity + 1] = rec end
    table.sort(byDensity, function(a, b)
        if (a.density or 0) ~= (b.density or 0) then return (a.density or 0) > (b.density or 0) end
        local ha, hb = a.kind == "home", b.kind == "home"
        if ha ~= hb then return ha end
        return a.id < b.id end)

    -- hand the pool out: each attack group fills each element up to n from the pool (nearest first); a group over n gives the surplus back
    local function HandOut(rec, name, c)
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
                        Spring.Echo(string.format("[SUP] %s group %d (%s) %s +%d from the pool (%d / %d, %d enemy units near)", Clock(frame), rec.id, rec.kind, name, k,
                            #mine + k, n, rec.density or 0))
                    end
                end
    end
    for _, rec in ipairs(order) do
        if rec.id ~= 0 then
            for name, c in pairs(rec.want) do
                if not (E[name] and E[name].RANK == "density") then HandOut(rec, name, c) end
            end
        end
    end
    for _, rec in ipairs(byDensity) do
        if rec.id ~= 0 then
            for name, c in pairs(rec.want) do
                if E[name] and E[name].RANK == "density" then HandOut(rec, name, c) end
            end
        end
    end
    for _, rec in ipairs(order) do
        if rec.id ~= 0 then
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
    -- the labs: one request per element through the lab-order layer (lab_rules SUPPORT_ORDERS publishes WG.LabOrders), n read live (Offer bumps have)
    local LO = O.WG and O.WG.LabOrders
    if LO then
        for name, w in pairs(wants) do
            if not M.NO_REQUEST[name] and w.picks and #w.picks > 0 and w.want > 0 then
                local c
                for _, els in pairs(spec) do c = c or els[name] end
                LO.Request("support:" .. name, { picks = w.picks, tier = (c and c.tier) or "high",
                    n = function() local x = wants[name]; return x and (x.want - x.have) or 0 end })
            end
        end
    end
end

-- ── units in and out ──────────────────────────────────────────────────────────

-- The first element of `kind` whose pool holds fewer than min_frac x n units (the next group of that kind should wait for them): name, have, need.
-- A fourth value: what the groups already out are short of this element -- a new unit goes to them (nearest first) before it stays in the pool, so
-- to get `need` into the pool the labs must make need + that much (the first forced test: group 1 at 1/12 took every Lasher, the pool stayed 0 for 150 s).
function M.PoolShort(kind)
    for name, c in pairs(spec[kind] or {}) do
        if c.min_frac and (c.n or 0) > 0 then
            local need, have = math.ceil(c.min_frac * c.n), 0
            local mine = {}
            for uid, o in pairs(owner) do
                if o.el == name and Alive(uid) then
                    if o.rec == 0 then have = have + 1 else mine[o.rec] = (mine[o.rec] or 0) + 1 end
                end
            end
            if have < need then
                local deficit = 0
                for id, rec in pairs(records) do
                    if id ~= 0 and rec.kind == kind then deficit = deficit + math.max(0, c.n - (mine[id] or 0)) end
                end
                return name, have, need, deficit
            end
        end
    end
    return nil
end

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

-- A finished unit an element would have taken went to another owner (unit_runtime: the base AA screen comes first): the order that made it is
-- over, so the element's books count it as made (it stays out of `have`, so the labs order another one).  Without this the order stayed "pending"
-- for 3 minutes (lab_rules SupportRooms) and the labs stopped ordering AA while a raid group waited for it (game B, 2026-10-31: pool stuck at 5 / 6).
function M.NoteBypass(defID)
    for _, name in ipairs(M.ELEMENTS) do
        local el, w = E[name], wants[name]
        if el and el.Accept and w and w.want > w.have then
            local c
            for _, els in pairs(spec) do c = c or els[name] end
            if c and el.Accept(defID, nil, c, ctx) then
                made[name] = (made[name] or 0) + 1
                if O.WG and O.WG.MetalBot and O.WG.MetalBot.support and O.WG.MetalBot.support[name] then
                    O.WG.MetalBot.support[name].made = made[name]
                end
                return
            end
        end
    end
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
            rec.arty = nil                                -- set again by the escorted element (arty / stop) when it has units with this group
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
    -- click_army: each group's support -- escort mode round its landed Quakers, reserve (out on the map, no dives) while its Quakers are on the
    -- way or its AA is short under air pressure, and where its AA is (pace)
    local CA = O.CA
    if CA and CA.SetSupport then
        local ra = O.WG and O.WG.MetalBot and O.WG.MetalBot.raidAir
        local air = ra ~= nil and ra.active == true
        for _, rec in ipairs(order) do
            if rec.id > 0 then                           -- click_army's groups only (not the stage, not the home records)
                local info = { arty = rec.arty, air = air }
                local a = rec.arty
                if (rec.want.arty or rec.want.stop) and a and (a.total or 0) > 0 and (a.n or 0) < M.ESCORT_MIN then info.reserve = rec.want.stop and "stop" or "arty" end
                -- the group's AA that is WITH it (within AA_NEAR_R, not in the air or waiting for a lift): pace and reserve count only these
                -- (game 2026-11-01: a flak truck still at home 8.6 km back held its group "waiting for its AA")
                local aaUnits = lists[rec.id .. ":aa"]
                local k = 0
                if aaUnits and #aaUnits > 0 and rec.cx then
                    local sx, sz = 0, 0
                    for _, uid in ipairs(aaUnits) do
                        if not (O.LIFT and (O.LIFT.Busy(uid) or O.LIFT.Waiting(uid))) then
                            local x, _, z = Spring.GetUnitPosition(uid)
                            if x and (x - rec.cx) ^ 2 + (z - rec.cz) ^ 2 <= M.AA_NEAR_R * M.AA_NEAR_R then sx, sz, k = sx + x, sz + z, k + 1 end
                        end
                    end
                    if k > 0 then
                        local cx, cz = sx / k, sz / k
                        local vx, vz = Velocity(rec, "aaPrev", cx, cz, frame, 90)
                        info.aa = { cx = cx, cz = cz, n = k, vx = vx, vz = vz }
                    end
                end
                local cw = rec.want.aa
                if air and cw and (cw.n or 0) > 0 and k < math.min(M.AA_RESERVE_N, cw.n) then info.reserve = info.reserve or "aa" end
                CA.SetSupport(rec.id, info)
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

-- The fewest raid groups the elements on now ask for (the arty element's `groups`; unit_runtime raises click_army MAX_GROUPS to it), else 0.
function M.MinGroups()
    local n = 0
    for _, c in pairs(spec.raid or {}) do
        if c.groups then n = math.max(n, c.groups) end
    end
    return n
end

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
