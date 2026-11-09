-- bar_framework/lrpc_fire.lua  (unit side: what our long-range plasma cannons shoot -- user 2026-11-08)
-- User: "The main goal of the proxy lab is to defend itself and build as many Basilisk as possible to start killing the enemy ... The basilisk should
-- target shields first then bp, then fussions/afus then labs."
--
-- Every TICK frames, each of our LRPCs (ROLES "lrpc": the Basilisk, "lrpc_t3": the Calamity) keeps its target while it is alive and not over its shot budget, else takes the
-- best enemy building in range from enemy_intel's records (remembered buildings too: an ATTACK on the remembered spot works on a ghost):
--   tier 1 shields  2 build power (static builders: nanos -- not labs)  3 fusions / AFUS (energy >= FUSION_E)  4 labs  5 other eco  6 any building
-- inside a tier the most valuable first, nearer a little better.  A target takes GUNS_PER guns per volley it needs (its health / the shell's damage /
-- VOLLEYS), so a big gun line splits over targets instead of all hitting one.  KILL CONFIRMATION (kill_confirm.lua): a wreck at its spot, its radar dot
-- gone, or its death in sight -> enemy_intel forgets it, the guns move on.  With no confirmation after SHOTS_MULT x the shots it should take (counted
-- from the guns' reload while they fire at it, and from our shells' impacts where BAR reports them), it is "probably dead": it drops to the last tier
-- until it is seen again.
--
--   local LF = VFS.Include("LuaUI/Widgets/bar_framework/lrpc_fire.lua")
--   LF.Init{ cfg, EI, UQ, KC = kill_confirm instance, teamID, Clock }
--   LF.Update(frame)   LF.OnFinished(uid, defID)   LF.OnDestroyed(uid)   LF.Summary() -> string
-- Log rows [LRPC].

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = {}

M.CFG = {
    TICK       = 30,
    FUSION_E   = 700,     -- energy make: a fusion (850) or AFUS (3000)
    VOLLEYS    = 3,       -- a target takes enough guns to kill it in this many volleys
    SHOTS_MULT = 2.0,     -- no confirmation after this x the shots it should take: probably dead
    RANGE_FRAC = 0.97,
    DIST_W     = 0.3,     -- inside a tier: value / (1 + DIST_W x distance / range)
    LOG_EVERY  = 1800,
}

local CMD_ATTACK, CMD_STOP = 20, 0
local O, C = {}, {}
local guns = {}           -- [uid] = { defID, range, dmg, reload, target, since }
local targets = {}        -- [eid] = { shots (estimated), guns, since, tier }
local probable = {}       -- [eid] = frame it was given up on (back in play once seen after that)
local stats = { kills = {}, probable = 0, orders = 0 }
local logF, kills0 = -1e9, nil

local function Clock(f) return O.Clock and O.Clock(f) or string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end

function M.Init(o)
    O = o or {}
    C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(O.cfg or {}) do
        if M.CFG[k] == nil then Spring.Echo("[LRPC] option '" .. tostring(k) .. "' is not an lrpc_fire option (typo?)") end
        C[k] = v
    end
    guns, targets, probable = {}, {}, {}
    stats = { kills = {}, probable = 0, orders = 0 }
end

local function Weapon(defID)
    local d = UnitDefs[defID]
    local w = d and d.weapons and d.weapons[1]
    local wd = w and WeaponDefs and WeaponDefs[w.weaponDef]
    if not wd then return 4950, 1500, 10 end
    local dmg = wd.damages and (wd.damages[0] or wd.damages[1]) or 1500
    return wd.range or 4950, math.max(1, dmg), math.max(0.5, wd.reload or 10)
end

-- (the Calamity too, user 2026-11-08: "Calamities are on hold fire by default just give them the same targeting as Basilisk so they shoot": every gun is set
-- to fire at will)
function M.OnFinished(uid, defID)
    local d = UnitDefs[defID]
    if not (d and (d.name == ROLES.Get("lrpc") or d.name == ROLES.Get("lrpc_t3"))) then return end
    local range, dmg, reload = Weapon(defID)
    guns[uid] = { defID = defID, range = range, dmg = dmg, reload = reload }
    Spring.GiveOrderToUnit(uid, (CMD and CMD.FIRE_STATE) or 45, { 2 }, {})
    Spring.Echo(string.format("[LRPC] %s %s %d up (range %.0f, %.0f damage every %.1fs)", Clock(Spring.GetGameFrame()),
        d.name == ROLES.Get("lrpc") and "Basilisk" or "Calamity", uid, range, dmg, reload))
end

function M.OnDestroyed(uid) guns[uid] = nil end

local function Tier(rec)
    local c = rec.c
    if not c or c.mobile then return nil end
    local d = UnitDefs[rec.defID]
    if c.shield then return 1 end
    if (c.bp or 0) > 0 and not c.factory and not c.commander then return 2 end
    if d and (d.energyMake or 0) >= C.FUSION_E then return 3 end
    if c.factory then return 4 end
    if c.eco then return 5 end
    return 6
end

local function Health(rec)
    local d = UnitDefs[rec.defID]
    return (d and d.health) or 2000
end

function M.Update(frame)
    if frame % C.TICK ~= 0 or not next(guns) then return end
    local EI, KC = O.EI, O.KC
    if KC then KC.Tick(frame) end
    local recs = EI and EI.Records() or {}
    -- confirmed kills: forget them
    for eid, t in pairs(targets) do
        local why = KC and KC.Dead(eid)
        local rec = recs[eid]
        if why or not rec then
            if why then
                stats.kills[why] = (stats.kills[why] or 0) + 1
                Spring.Echo(string.format("[LRPC] %s KILL confirmed (%s): %s %d (tier %d) after ~%d shots", Clock(frame), why,
                    (rec and UnitDefs[rec.defID] and UnitDefs[rec.defID].name) or "?", eid, t.tier or 0, math.floor(t.shots)))
                if EI and EI.OnDestroyed then EI.OnDestroyed(eid) end
            end
            if KC then KC.Unwatch(eid) end
            targets[eid] = nil
        end
    end
    -- shots so far (by the guns' reload) and the probably-dead rule
    for uid, g in pairs(guns) do
        if not Spring.GetUnitDefID(uid) then guns[uid] = nil
        elseif g.target and targets[g.target] then
            local t = targets[g.target]
            t.shots = t.shots + C.TICK / 30 / g.reload
        end
    end
    for eid, t in pairs(targets) do
        local rec = recs[eid]
        local need = math.ceil(Health(rec) / math.max(1, t.dmg or 1500))
        local shots = math.max(t.shots, KC and KC.Hits(eid) or 0)
        if shots >= C.SHOTS_MULT * need + 2 then
            probable[eid] = frame
            stats.probable = stats.probable + 1
            Spring.Echo(string.format("[LRPC] %s %s %d probably dead: ~%d shots (it needs %d), no wreck or dot seen", Clock(frame),
                (UnitDefs[rec.defID] or {}).name or "?", eid, math.floor(shots), need))
            if KC then KC.Unwatch(eid) end
            targets[eid] = nil
        end
    end
    for eid, f in pairs(probable) do
        local rec = recs[eid]
        if not rec then probable[eid] = nil elseif rec.frame > f then probable[eid] = nil end      -- seen again: back in play
    end
    -- each gun: keep its target, else the best one in range that still wants guns
    local count = {}
    for _, g in pairs(guns) do if g.target and targets[g.target] then count[g.target] = (count[g.target] or 0) + 1 end end
    for uid, g in pairs(guns) do
        if not (g.target and targets[g.target]) and not Spring.GetUnitIsBeingBuilt(uid) then
            g.target = nil
            local gx, _, gz = Spring.GetUnitPosition(uid)
            local best, bs
            if gx then
                for eid, rec in pairs(recs) do
                    local tier = Tier(rec)
                    if tier and rec.x then
                        if probable[eid] then tier = 7 end
                        local d = Dist(gx, gz, rec.x, rec.z)
                        local wantGuns = math.max(1, math.ceil(Health(rec) / g.dmg / C.VOLLEYS))
                        if d <= g.range * C.RANGE_FRAC and (count[eid] or 0) < wantGuns then
                            local s = tier * 1e7 - (rec.c.value or 0) / (1 + C.DIST_W * d / g.range)
                            if not bs or s < bs then best, bs = rec, s end
                        end
                    end
                end
            end
            if best then
                local eid = best.uid
                g.target, g.since = eid, frame
                count[eid] = (count[eid] or 0) + 1
                local t = targets[eid]
                if not t then
                    t = { shots = 0, since = frame, tier = Tier(best), dmg = g.dmg, x = best.x, z = best.z }
                    targets[eid] = t
                    if O.KC then O.KC.Watch(eid, best.defID, best.x, best.z, frame) end
                end
                local y = Spring.GetGroundHeight(best.x, best.z) or 0
                Spring.GiveOrderToUnit(uid, CMD_ATTACK, { best.x, y, best.z }, {})
                stats.orders = stats.orders + 1
                Spring.Echo(string.format("[LRPC] %s gun %d -> %s %d (tier %d%s) at %d,%d, %.0f away", Clock(frame), uid, (UnitDefs[best.defID] or {}).name or "?",
                    eid, Tier(best) or 0, probable[eid] and ", probably dead" or "", best.x, best.z, Dist(gx, gz, best.x, best.z)))
            elseif g.firing then
                Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
            end
            g.firing = best ~= nil
        end
    end
    if frame - logF >= C.LOG_EVERY then
        logF = frame
        local tk = O.KC and O.KC.TeamKills()
        kills0 = kills0 or tk
        Spring.Echo(string.format("[LRPC] %s %s | team unitsKilled %s (+%s since the first gun)", Clock(frame), M.Summary(), tostring(tk), tk and kills0 and tostring(tk - kills0) or "?"))
    end
end

-- where the guns are firing (user 2026-11-08: the scouts "try and get vision in range of the lrpcs, and check where they are firing"): { {x, z}, ... }
function M.TargetPoints()
    local out = {}
    for _, t in pairs(targets) do if t.x then out[#out + 1] = { x = t.x, z = t.z } end end
    table.sort(out, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.z < b.z end)
    return out
end

function M.Summary()
    local ng, nt = 0, 0
    for _ in pairs(guns) do ng = ng + 1 end
    for _ in pairs(targets) do nt = nt + 1 end
    local k = {}
    for why, n in pairs(stats.kills) do k[#k + 1] = why .. " " .. n end
    return string.format("%d guns on %d targets; kills confirmed: %s; probably dead %d; %d target orders", ng, nt, #k > 0 and table.concat(k, ", ") or "none", stats.probable, stats.orders)
end

return M
