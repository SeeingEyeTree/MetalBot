-- metalbot_stats_tracker.lua
-- General-purpose stats tracker. Give every bot its own copy: it reports only what
-- THIS process can see (its own team's economy, units and losses, plus whatever enemy
-- units are visible to it). It never queries the other team's economy or unit list, so
-- the numbers mean the same thing in headless matches and in real games, and a bot's
-- scouting gaps show up as gaps in `intel` rather than being papered over.
--
-- Output is one line per record on the infolog, key=value pairs, no spaces in values:
--   [TRK] init   frame team spec fullview start_x start_z
--   [TRK] def    name=... engine unit-definition facts used by the classifier (once)
--   [TRK] eco    metal/energy stored, income, pull, waste, stall/float fractions, unit cap
--   [TRK] units  counts + metal value per role, build power, idle build power, AA/ground
--                capability of what is standing
--   [TRK] army   n mv hp spread dist_base groups main_share comp=name:count,...
--   [TRK] cmdr   commander hp, distance from base, enemies/friends/AA/anti-nuke near it
--   [TRK] intel  visible enemies (air/ground/nuke/lrpc), radar-only blips (moving, decodable),
--                map LOS/radar/explored
--   [TRK] combat losses (lost_* = all, incl. our own reclaims; lost_enemy_* = enemy-attributed),
--                what killed us (killers=name:count,...), damage, kills seen
--   [TRK] event  name=<milestone> [extra key=value ...]
-- All counters are cumulative unless the key says otherwise; diff consecutive rows for
-- rates. bot_testing.py parses these into result["tracker_timeline"];
-- find_weakness.py reads them.
--
-- Events (each fires once unless noted):
--   first_mex first_energy first_factory first_t2_factory first_con first_army
--   first_defense first_aa            our first static defence / first DEDICATED anti-air
--   first_loss first_kill first_damage_taken
--   first_enemy_seen first_enemy_air first_enemy_ground   (dist=, def=)
--   first_enemy_near_base   (def=, warned_dist=, lead_frames=): warned_dist is how far
--                           away THAT unit was when first seen; ~NEAR_BASE means no warning
--   first_radar_contact / first_radar_moving   radar-only blip appeared / its speed is known
--                           (speed=, cands= the unit types moving at that speed: either/or)
--   first_enemy_nuke first_enemy_lrpc first_enemy_antinuke   strategic weapons seen
--   mex_10 mex_25 mex_50 commander_lost   (commander_lost carries killer=; "?" = self/unknown)
--   cons_all_dead / cons_restored   (repeat; cons_restored carries waited=frames)

local SAMPLE_EVERY  = 900      -- game frames between full snapshots (30 game-seconds)
local PROBE_EVERY   = 30       -- game frames between cheap stall/float + threat probes
local LOS_EVERY     = 300      -- game frames between map-coverage samples
local NEAR_BASE     = 1500     -- elmos; "enemy near my base" radius
local STALL_FRAC    = 0.02     -- metal/energy below this fraction of storage = stalled
local FLOAT_FRAC    = 0.90     -- above this fraction of storage = floating (wasting)
local MAP_GRID      = 32       -- coverage grid is MAP_GRID x MAP_GRID cells over the map
local AA_COVER_R    = 800      -- elmos: an air-capable unit/defence this close covers a target
local CMDR_NEAR     = 800      -- elmos: "enemy near the commander" / "friends near the commander"
local PIECE_R       = 600      -- elmos: friendly army within this of a dying army unit = support
local PIECE_ISOLATED = 2       -- a unit that died with this many friends or fewer nearby was isolated
local PIECE_BUDGET  = 8        -- support lookups per frame (deaths arrive in bursts)
local GROUP_CELL    = 800      -- elmos: army units in the same/adjacent cells form one group
local BLIP_MOVING   = 12       -- elmos/s: a radar blip slower than this is treated as stationary
local BLIP_TOL      = 0.08     -- candidate unit speeds within this fraction of the measured speed
local BLIP_MIN_DT   = 60       -- frames between position samples used for a speed estimate
local LRPC_RANGE    = 2000     -- elmos: a static ground-attack weapon this long counts as a "LRPC"
local WRECK_RADIUS  = 1500     -- elmos round the base within which wreck metal is summed

local myTeam, myAlly, startX, startZ = nil, nil, 0, 0
local firstSeenEnemy = -1
local gameOver = false
local disabled = {}            -- name -> true once a sub-tracker has errored

-- interval probes
local probes = 0
local stallM, stallE, floatM, floatE = 0, 0, 0, 0

-- cumulative counters, updated from callbacks
-- `lost` counts EVERY loss, including our own reclaims and retrofits.  `enemy_*` counts only
-- losses with a known enemy attacker, which is what "the enemy is killing us" means.
local lost = {n = 0, mv = 0, army_n = 0, army_mv = 0, eco_n = 0, eco_mv = 0, distSum = 0,
              cons = 0, byAir = 0, enemy_n = 0, enemy_mv = 0, enemy_eco_n = 0, enemy_eco_mv = 0,
              enemy_army_n = 0, enemy_army_mv = 0}
local kills = {n = 0, mv = 0}
local killers = {}             -- attacker def name -> count of our units it killed
local finishedByRole = {}
local milestones = {}
local mexFinished = 0
local conAlive, conEverAlive, conDeadSince = 0, false, nil

local seenEnemy, nSeen = {}, 0 -- uid -> {f=frame first seen, d=distance from base then}

-- map coverage
local mapX, mapZ = 0, 0
local losFrac, radarFrac, exploredFrac = 0, 0, 0
local explored, exploredN = {}, 0

local defRole, defCaps = {}, {} -- unitDefID -> role / {hitsAir, hitsGround}
local teamStats              -- defined below; the probes need it

local stratCache = {}          -- unitDefID -> {kind or false, range}
local blips = {}               -- radar-only enemy contacts: uid -> {f0,f,x,z,last,v,n}
local pm = {n = 0, iso = 0, support = 0}   -- piecemeal: sampled deaths of our army units
local pmBudget = PIECE_BUDGET
local speedList = nil          -- mobile unit defs sorted by speed, built lazily
local cmdrUid = nil

local function isCommanderDef(d)
    if d.customParams and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil) then
        return true
    end
    return d.name ~= nil and string.find(string.lower(d.name), "commander") ~= nil
end

-- Role of a unit definition. Order matters: the first match wins.  Builders are decided
-- BEFORE the energy test: a mobile builder must never be mistaken for a generator.
local function roleOf(defID)
    local r = defRole[defID]
    if r then return r end
    local d = UnitDefs[defID]
    if not d then return "other" end
    if isCommanderDef(d) then r = "commander"
    elseif (d.extractsMetal or 0) > 0 then r = "mex"
    elseif d.isFactory then r = "factory"
    elseif d.isBuilder and not d.canMove then r = "nano"          -- static builders
    elseif d.isBuilder then r = "con"                             -- mobile builders
    elseif (d.energyMake or 0) > 0 or (d.energyUpkeep or 0) < 0
        or (d.windGenerator or 0) > 0 or (d.tidalGenerator or 0) > 0 then r = "energy"
    elseif d.canMove and d.weapons and #d.weapons > 0 then r = "army"
    elseif d.canMove then r = "utility"                           -- scouts, transports...
    elseif d.weapons and #d.weapons > 0 then r = "defense"
    else r = "other" end
    defRole[defID] = r
    return r
end

-- What can this unit shoot at?  Uses the weapons' own targeting restrictions:
--   onlyTargets.vtol    -> anti-air only        onlyTargets.surface -> cannot hit air
--   canAttackGround=false -> cannot hit ground  otherwise (notsub, none) -> both
-- Returns hitsAir, hitsGround, aaOnly (dedicated anti-air: hits air but not ground).
local function capsOf(defID)
    local c = defCaps[defID]
    if c then return c[1], c[2], c[3] end
    local air, gnd = false, false
    local d = UnitDefs[defID]
    if d and d.weapons then
        for i = 1, #d.weapons do
            local w = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            local only = w and w.onlyTargets or {}
            local groundOK = not (wd and wd.canAttackGround == false)
            if only.vtol then
                air = true
            else
                if not only.surface and not only.notair then air = true end
                if groundOK then gnd = true end
            end
        end
    end
    defCaps[defID] = {air, gnd, air and not gnd}
    return air, gnd, air and not gnd
end

local function techLevel(defID)
    local d = UnitDefs[defID]
    local t = d and d.customParams and tonumber(d.customParams.techlevel)
    return t or 1
end

local function cost(defID)
    local d = UnitDefs[defID]
    return d and d.metalCost or 0
end

local function name(defID)
    local d = defID and UnitDefs[defID]
    return d and d.name or "?"
end

local function commandCount(uid)
    if Spring.GetUnitCommandCount then return Spring.GetUnitCommandCount(uid) or 0 end
    local q = Spring.GetUnitCommands(uid, 0)
    return type(q) == "number" and q or (q and #q or 0)
end

-- Is this builder or factory doing nothing?  A factory's build queue is NOT its command
-- queue, so it is asked separately; everything else is idle when it is neither building
-- nor holding an order.
local function isIdle(uid, role)
    if Spring.GetUnitIsBuilding and Spring.GetUnitIsBuilding(uid) then return false end
    if role == "factory" then
        if Spring.GetFactoryCommands then
            local q = Spring.GetFactoryCommands(uid, 0)
            if type(q) == "number" then return q == 0 end
        end
        return true
    end
    return commandCount(uid) == 0
end

local function dist2d(x, z, x2, z2)
    local dx, dz = x - x2, z - z2
    return math.sqrt(dx * dx + dz * dz)
end

-- ── Strategic weapons ────────────────────────────────────────────────────────
-- "nuke" (missile silo), "antinuke" (interceptor), "lrpc" (static long-range ground gun).
-- Weapon flags are read from the engine, with a short name list as a fallback; the [TRK] def
-- lines log what the engine reports so this can be corrected against real data.
local STRAT_NAMES = { corsilo = "nuke", armsilo = "nuke", corfmd = "antinuke", armamd = "antinuke" }

local function stratOf(defID)
    local c = stratCache[defID]
    if c then return c[1], c[2] end
    local kind, range = nil, 0
    local d = UnitDefs[defID]
    if d then
        kind = STRAT_NAMES[d.name]
        local ws = d.weapons or {}
        for i = 1, #ws do
            local w = ws[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            if wd then
                local r = wd.range or 0
                if wd.interceptor and wd.interceptor ~= 0 then
                    kind = kind or "antinuke"
                    range = math.max(range, wd.coverageRange or r)
                elseif wd.targetable and wd.targetable ~= 0 then
                    kind = kind or "nuke"
                elseif not d.canMove and r >= LRPC_RANGE and wd.canAttackGround ~= false then
                    kind = kind or "lrpc"
                    range = math.max(range, r)
                end
            end
        end
        if kind == "antinuke" and range == 0 then range = 2000 end
    end
    stratCache[defID] = { kind or false, range }
    return kind or false, range
end

-- ── Army shape ───────────────────────────────────────────────────────────────
-- How many separate groups does the army form, and what share is in the biggest?  Units in
-- the same or neighbouring GROUP_CELL squares are one group.  Many small groups = piecemeal.
local function groupStats(pos)
    local n = #pos
    if n == 0 then return 0, 0 end
    local cells, keys = {}, {}
    for i = 1, n do
        local gx, gz = math.floor(pos[i][1] / GROUP_CELL), math.floor(pos[i][2] / GROUP_CELL)
        local k = gx * 1000 + gz
        if not cells[k] then cells[k] = { gx = gx, gz = gz, n = 0 }; keys[#keys + 1] = k end
        cells[k].n = cells[k].n + 1
    end
    local seen, groups, biggest = {}, 0, 0
    for _, k0 in ipairs(keys) do
        if not seen[k0] then
            groups = groups + 1
            local total, stack = 0, { k0 }
            seen[k0] = true
            while #stack > 0 do
                local k = table.remove(stack)
                local c = cells[k]
                total = total + c.n
                for dx = -1, 1 do
                    for dz = -1, 1 do
                        local k2 = (c.gx + dx) * 1000 + (c.gz + dz)
                        if cells[k2] and not seen[k2] then seen[k2] = true; stack[#stack + 1] = k2 end
                    end
                end
            end
            if total > biggest then biggest = total end
        end
    end
    return groups, biggest / n
end

-- ── Radar blips ──────────────────────────────────────────────────────────────
-- A radar-only contact has no unit type, but if it moves its speed can be measured, and every
-- unit type has a known speed.  Several types share a speed, so the answer is a LIST: treat it
-- as "either/or" until the unit is actually seen.  (Builders are left out: they are rarely
-- what a moving radar contact turns out to be, and including them only widens the list.)
local function buildSpeedList()
    local list = {}
    for id, d in pairs(UnitDefs) do
        if type(id) == "number" and d.canMove and (d.speed or 0) > 0 and not d.isBuilder then
            list[#list + 1] = { speed = d.speed, name = d.name, fly = d.canFly and true or false }
        end
    end
    table.sort(list, function(a, b) return a.speed < b.speed end)
    speedList = list
end

local function decodeSpeed(speed)
    if not speedList then buildSpeedList() end
    local out, lo, hi = {}, speed * (1 - BLIP_TOL), speed * (1 + BLIP_TOL)
    for i = 1, #speedList do
        local e = speedList[i]
        if e.speed > hi then break end
        if e.speed >= lo then out[#out + 1] = e end
    end
    return out
end

local function trackBlip(uid, f, x, z)
    local b = blips[uid]
    if not b then
        blips[uid] = { f0 = f, f = f, x = x, z = z, last = f, n = 0 }
        return true
    end
    b.last = f
    if f - b.f >= BLIP_MIN_DT then
        local sp = dist2d(x, z, b.x, b.z) / ((f - b.f) / 30)
        b.v = b.v and (0.6 * b.v + 0.4 * sp) or sp
        b.n = b.n + 1
        b.f, b.x, b.z = f, x, z
    end
    return false
end

local function emit(kind, frame, fields)
    Spring.Echo(string.format("[TRK] %s frame=%d team=%d %s", kind, frame, myTeam, fields))
end

-- Once-only milestone; `extra` is optional " key=value ..." text.
local function event(frame, evName, extra)
    if milestones[evName] then return end
    milestones[evName] = frame
    emit("event", frame, "name=" .. evName .. (extra and (" " .. extra) or ""))
end

-- Run a sub-tracker; a bug in one must never take the bot or the other trackers down.
local function safe(label, fn, ...)
    if disabled[label] then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        disabled[label] = true
        Spring.Echo("[TRK] error name=" .. label .. " " .. (tostring(err):gsub("%s+", "_")))
    end
end

function widget:GetInfo()
    return {
        name    = "Stats Tracker",
        desc    = "Logs own-team economy, units, intel and losses as [TRK] lines",
        author  = "MetalBot",
        layer   = 1000,
        enabled = true,
    }
end

function widget:Initialize()
    myTeam = Spring.GetMyTeamID()
end

local function dumpDefs()
    -- Engine facts the classifier depends on, logged once so role logic can be checked
    -- against real fields instead of assumed.
    for _, n in ipairs({"corcom", "corck", "corca", "cornanotc", "corlab", "corap", "corcrwh",
                        "coraak", "corak", "corthud", "corrl", "corllt", "corwin", "corveng",
                        "corfink", "corsilo", "corfmd", "armsilo", "armamd", "corint", "armbrtha",
                        "corbuzz", "armvulc"}) do
        local d = UnitDefNames and UnitDefNames[n]
        if d then
            local air, gnd = capsOf(d.id)
            local sk, sr = stratOf(d.id)
            local w1 = d.weapons and d.weapons[1]
            local wd = w1 and w1.weaponDef and WeaponDefs and WeaponDefs[w1.weaponDef] or {}
            emit("def", 0, string.format(
                "name=%s role=%s xsize=%s isBuilder=%s canMove=%s canFly=%s buildSpeed=%s "
                .. "energyMake=%s energyUpkeep=%s hitsAir=%s hitsGround=%s speed=%s strat=%s "
                .. "stratRange=%.0f w1_range=%s w1_interceptor=%s w1_targetable=%s w1_stockpile=%s",
                n, roleOf(d.id), tostring(d.xsize), tostring(d.isBuilder), tostring(d.canMove),
                tostring(d.canFly), tostring(d.buildSpeed), tostring(d.energyMake),
                tostring(d.energyUpkeep), tostring(air), tostring(gnd), tostring(d.speed),
                tostring(sk), sr, tostring(wd.range), tostring(wd.interceptor),
                tostring(wd.targetable), tostring(wd.stockpile)))
        end
    end
end

function widget:GameStart()
    myTeam = Spring.GetMyTeamID()
    myAlly = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    mapX = (Game and Game.mapSizeX) or 0
    mapZ = (Game and Game.mapSizeZ) or 0
    local sx, _, sz = Spring.GetTeamStartPosition(myTeam)
    startX, startZ = sx or 0, sz or 0
    -- Ground truth on what this process can see: bot_testing.py sets fullview=1 but
    -- that has not been trusted to work headless. If fullview reads 0 here, believe it.
    local spec, fullview = Spring.GetSpectatingState()
    safe("defs", dumpDefs)
    -- Helpers a bot can call: turn a radar blip's measured speed into candidate unit types.
    if WG then
        WG.StatsTracker = { DecodeSpeed = decodeSpeed, Blips = blips, GroupStats = groupStats }
    end
    emit("init", 0, string.format("spec=%d fullview=%d start_x=%.0f start_z=%.0f map_x=%d map_z=%d",
        spec and 1 or 0, fullview and 1 or 0, startX, startZ, mapX, mapZ))
end

-- ── Callbacks that keep cumulative counters ──────────────────────────────────

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeam then return end
    local role = roleOf(unitDefID)
    finishedByRole[role] = (finishedByRole[role] or 0) + 1
    local f = Spring.GetGameFrame()
    local _, _, aaOnly = capsOf(unitDefID)
    if role == "mex" then
        mexFinished = mexFinished + 1
        event(f, "first_mex")
        if mexFinished >= 10 then event(f, "mex_10") end
        if mexFinished >= 25 then event(f, "mex_25") end
        if mexFinished >= 50 then event(f, "mex_50") end
    elseif role == "factory" then
        event(f, "first_factory")
        if techLevel(unitDefID) >= 2 then event(f, "first_t2_factory") end
    elseif role == "energy" then
        event(f, "first_energy")
    elseif role == "con" then
        event(f, "first_con")
        conAlive, conEverAlive = conAlive + 1, true
        if conDeadSince then
            emit("event", f, "name=cons_restored waited=" .. (f - conDeadSince))
            conDeadSince = nil
        end
    elseif role == "army" then
        event(f, "first_army")
    elseif role == "defense" then
        event(f, "first_defense", "def=" .. name(unitDefID))
    end
    if aaOnly and (role == "army" or role == "defense") then
        event(f, "first_aa", "def=" .. name(unitDefID))
    end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID,
                            projectileID, attackerID, attackerDefID, attackerTeam)
    if milestones.first_damage_taken or not myTeam then return end
    if unitTeam == myTeam and attackerTeam and attackerTeam ~= myTeam
       and not Spring.AreTeamsAllied(attackerTeam, myTeam) then
        event(Spring.GetGameFrame(), "first_damage_taken",
            string.format("victim=%s attacker=%s", name(unitDefID), name(attackerDefID)))
    end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID, attackerDefID, attackerTeamID)
    if not myTeam or not unitDefID then return end
    local f = Spring.GetGameFrame()
    if teamID == myTeam then
        local role, mv = roleOf(unitDefID), cost(unitDefID)
        if role == "commander" then
            event(f, "commander_lost", "killer=" .. name(attackerDefID)
                  .. (attackerTeamID and (" by_team=" .. tostring(attackerTeamID)) or ""))
            return
        end
        local wasFinished = not Spring.GetUnitIsBeingBuilt(unitID)
        lost.n, lost.mv = lost.n + 1, lost.mv + mv
        if role == "army" then
            lost.army_n, lost.army_mv = lost.army_n + 1, lost.army_mv + mv
        else
            lost.eco_n, lost.eco_mv = lost.eco_n + 1, lost.eco_mv + mv
        end
        local byEnemy = attackerTeamID ~= nil and attackerTeamID ~= myTeam
                        and not Spring.AreTeamsAllied(attackerTeamID, myTeam)
        if byEnemy then
            lost.enemy_n, lost.enemy_mv = lost.enemy_n + 1, lost.enemy_mv + mv
            if role == "army" then
                lost.enemy_army_n, lost.enemy_army_mv = lost.enemy_army_n + 1, lost.enemy_army_mv + mv
            else
                lost.enemy_eco_n, lost.enemy_eco_mv = lost.enemy_eco_n + 1, lost.enemy_eco_mv + mv
            end
        end
        -- Piecemeal test: when one of our army units is killed, how many of our army were near?
        -- Losing units with almost nobody around means they fought in ones and twos.
        if role == "army" and byEnemy and pmBudget > 0 then
            pmBudget = pmBudget - 1
            local dx, _, dz = Spring.GetUnitPosition(unitID)
            if dx then
                local near = Spring.GetUnitsInCylinder(dx, dz, PIECE_R, myTeam) or {}
                local friends = 0
                for i = 1, #near do
                    local nd = Spring.GetUnitDefID(near[i])
                    if near[i] ~= unitID and nd and roleOf(nd) == "army" then friends = friends + 1 end
                end
                pm.n, pm.support = pm.n + 1, pm.support + friends
                if friends <= PIECE_ISOLATED then pm.iso = pm.iso + 1 end
            end
        end
        if attackerDefID and byEnemy then
            local an = name(attackerDefID)
            killers[an] = (killers[an] or 0) + 1
            local ad = UnitDefs[attackerDefID]
            if ad and ad.canFly then lost.byAir = lost.byAir + 1 end
        end
        if role == "con" and wasFinished then
            lost.cons = lost.cons + 1
            conAlive = math.max(0, conAlive - 1)
            if conAlive == 0 and conEverAlive and not conDeadSince then
                conDeadSince = f
                emit("event", f, "name=cons_all_dead")
            end
        end
        local x, _, z = Spring.GetUnitPosition(unitID)
        if x then lost.distSum = lost.distSum + dist2d(x, z, startX, startZ) end
        -- Only an enemy kill is a "loss" milestone: the bot reclaims its own buildings.
        if byEnemy then event(f, "first_loss", "def=" .. name(unitDefID)) end
    elseif attackerTeamID == myTeam and not Spring.AreTeamsAllied(teamID, myTeam) then
        -- Only fires for kills of units this process could see; it is a lower bound.
        kills.n, kills.mv = kills.n + 1, kills.mv + cost(unitDefID)
        event(f, "first_kill")
    end
end

-- ── Cheap once-a-second probes ───────────────────────────────────────────────

local function probeEconomy()
    -- The widget UnitDamaged callin does not reach this widget in headless, so first damage
    -- is read from the engine's own per-team damage counter (updates every ~15 game-s).
    if not milestones.first_damage_taken then
        local s = teamStats and teamStats()
        if s and (s.damageReceived or 0) > 0 then
            event(Spring.GetGameFrame(), "first_damage_taken", "source=team_stats")
        end
    end
    local m, ms = Spring.GetTeamResources(myTeam, "metal")
    local e, es = Spring.GetTeamResources(myTeam, "energy")
    if not m then return end
    probes = probes + 1
    if ms and ms > 0 then
        if m < ms * STALL_FRAC then stallM = stallM + 1 end
        if m > ms * FLOAT_FRAC then floatM = floatM + 1 end
    end
    if es and es > 0 and e then
        if e < es * STALL_FRAC then stallE = stallE + 1 end
        if e > es * FLOAT_FRAC then floatE = floatE + 1 end
    end
end

-- Watch every visible enemy: when did we FIRST see it and how far away was it, so that
-- "the first raider reached the base and we had no warning" is a number, not a guess.
local function scanThreats(f)
    -- icons=true: include radar-only contacts, which have no unit type (defID == nil).
    local list = Spring.GetVisibleUnits(Spring.ENEMY_UNITS or -4, nil, true)
    if not list then return end
    if nSeen > 4000 then seenEnemy, nSeen = {}, 0 end
    for i = 1, #list do
        local uid = list[i]
        local defID = Spring.GetUnitDefID(uid)   -- nil for radar-only blips
        if defID then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local dd = dist2d(x, z, startX, startZ)
                local s = seenEnemy[uid]
                if not s then
                    s = { f = f, d = dd }
                    seenEnemy[uid] = s
                    nSeen = nSeen + 1
                    local d = UnitDefs[defID]
                    local info = string.format("dist=%.0f def=%s", dd, name(defID))
                    if firstSeenEnemy < 0 then firstSeenEnemy = f end
                    event(f, "first_enemy_seen", info)
                    if d and d.canFly then event(f, "first_enemy_air", info)
                    elseif d and d.canMove and d.weapons and #d.weapons > 0 then
                        event(f, "first_enemy_ground", info)
                    end
                    local sk = stratOf(defID)
                    if sk == "nuke" then event(f, "first_enemy_nuke", info)
                    elseif sk == "lrpc" then event(f, "first_enemy_lrpc", info)
                    elseif sk == "antinuke" then event(f, "first_enemy_antinuke", info) end
                end
                if dd <= NEAR_BASE then
                    local d = UnitDefs[defID]
                    if d and d.weapons and #d.weapons > 0 then
                        event(f, "first_enemy_near_base", string.format(
                            "def=%s warned_dist=%.0f lead_frames=%d", name(defID), s.d, f - s.f))
                    end
                end
            end
        else
            -- Radar-only contact: no type.  Track its position and measure its speed.
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local isNew = trackBlip(uid, f, x, z)
                local b = blips[uid]
                if isNew then
                    event(f, "first_radar_contact", string.format("dist=%.0f", dist2d(x, z, startX, startZ)))
                end
                if b.v and b.n >= 2 and b.v >= BLIP_MOVING and not milestones.first_radar_moving then
                    local c = decodeSpeed(b.v)
                    local names = {}
                    for i = 1, math.min(3, #c) do names[i] = c[i].name end
                    event(f, "first_radar_moving", string.format("speed=%.0f n_cands=%d cands=%s dist=%.0f",
                        b.v, #c, #names > 0 and table.concat(names, "/") or "-",
                        dist2d(x, z, startX, startZ)))
                end
            end
        end
    end
    -- forget blips not seen for 10 game-seconds
    for uid, b in pairs(blips) do
        if b.last < f - 300 then blips[uid] = nil end
    end
end

-- Map awareness: what share of the map is in LOS / radar right now, and what share has
-- ever been in LOS.  This is the scouting signal: a bot that never looks cannot respond.
local function scanCoverage()
    if mapX <= 0 or mapZ <= 0 or not Spring.IsPosInLos then return end
    local los, radar, n = 0, 0, MAP_GRID * MAP_GRID
    for gz = 0, MAP_GRID - 1 do
        local z = (gz + 0.5) * mapZ / MAP_GRID
        for gx = 0, MAP_GRID - 1 do
            local x = (gx + 0.5) * mapX / MAP_GRID
            if Spring.IsPosInLos(x, 0, z, myAlly) then
                los = los + 1
                local key = gz * MAP_GRID + gx
                if not explored[key] then explored[key] = true; exploredN = exploredN + 1 end
            end
            if Spring.IsPosInRadar and Spring.IsPosInRadar(x, 0, z, myAlly) then radar = radar + 1 end
        end
    end
    losFrac, radarFrac, exploredFrac = los / n, radar / n, exploredN / n
end

-- ── Snapshots ────────────────────────────────────────────────────────────────

teamStats = function()
    -- The engine's own per-team tally: production, waste, damage. Own team only.
    if not Spring.GetTeamStatsHistory then return nil end
    local n = Spring.GetTeamStatsHistory(myTeam)
    if type(n) ~= "number" or n < 1 then return nil end
    local h = Spring.GetTeamStatsHistory(myTeam, n, n)
    return h and h[1]
end

local function snapshotEco(f)
    local m, ms, mp, mi, _, _, _, _, mx = Spring.GetTeamResources(myTeam, "metal")
    local e, es, ep, ei, _, _, _, _, ex = Spring.GetTeamResources(myTeam, "energy")
    if not m then return end
    local p = math.max(probes, 1)
    local s = teamStats() or {}
    local cap, total = 0, 0
    if Spring.GetTeamMaxUnits then cap = Spring.GetTeamMaxUnits(myTeam) or 0 end
    if Spring.GetTeamUnitCount then total = Spring.GetTeamUnitCount(myTeam) or 0 end
    -- Metal lying around as wrecks near the base: free metal a reclaimer could take.
    local wreck = 0
    if Spring.GetFeaturesInCylinder and Spring.GetFeatureResources then
        for _, fid in ipairs(Spring.GetFeaturesInCylinder(startX, startZ, WRECK_RADIUS) or {}) do
            wreck = wreck + (Spring.GetFeatureResources(fid) or 0)
        end
    end
    emit("eco", f, string.format(
        "metal=%.0f metal_cap=%.0f metal_inc=%.2f metal_pull=%.2f metal_excess=%.0f "
        .. "energy=%.0f energy_cap=%.0f energy_inc=%.1f energy_pull=%.1f energy_excess=%.0f "
        .. "metal_produced=%.0f metal_used=%.0f energy_produced=%.0f energy_used=%.0f "
        .. "stall_m=%.2f stall_e=%.2f float_m=%.2f float_e=%.2f units_total=%d unit_cap=%d "
        .. "wreck_metal=%.0f",
        m, ms or 0, mi or 0, mp or 0, mx or 0, e or 0, es or 0, ei or 0, ep or 0, ex or 0,
        s.metalProduced or 0, s.metalUsed or 0, s.energyProduced or 0, s.energyUsed or 0,
        stallM / p, stallE / p, floatM / p, floatE / p, total, cap, wreck))
    probes, stallM, stallE, floatM, floatE = 0, 0, 0, 0, 0
end

local function snapshotUnits(f)
    local count, value, inProgress = {}, {}, 0
    local bp, bpIdle, facN, facBusy = 0, 0, 0, 0
    local t2 = 0
    local armyN, armyMv, hpSum, cx, cz = 0, 0, 0, 0, 0
    local armyAir, armyGnd, defAir, defGnd, aaDedicated = 0, 0, 0, 0, 0
    local armyPos, comp = {}, {}
    local facPos, aaPos, antiPos = {}, {}, {}   -- for coverage of factories / commander
    local fighters, siloN, lrpcN, antiN = 0, 0, 0, 0
    cmdrUid = nil

    for _, uid in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID then
            local role = roleOf(defID)
            if role == "commander" then cmdrUid = uid end
            if role ~= "commander" then
                if Spring.GetUnitIsBeingBuilt(uid) then
                    inProgress = inProgress + 1
                else
                    count[role] = (count[role] or 0) + 1
                    value[role] = (value[role] or 0) + cost(defID)
                    if role == "factory" and techLevel(defID) >= 2 then t2 = t2 + 1 end

                    if role == "con" or role == "nano" or role == "factory" then
                        local buildSpeed = UnitDefs[defID].buildSpeed or 0
                        local idle = isIdle(uid, role)
                        if role == "factory" then
                            facN = facN + 1
                            if not idle then facBusy = facBusy + 1 end
                            local fx, _, fz = Spring.GetUnitPosition(uid)
                            if fx then facPos[#facPos + 1] = { fx, fz } end
                        end
                        bp = bp + buildSpeed
                        if idle then bpIdle = bpIdle + buildSpeed end
                    end

                    if role == "army" or role == "defense" then
                        local air, gnd, aaOnly = capsOf(defID)
                        if aaOnly then aaDedicated = aaDedicated + 1 end
                        if air then
                            local ax, _, az = Spring.GetUnitPosition(uid)
                            if ax then aaPos[#aaPos + 1] = { ax, az, aaOnly } end
                        end
                        if aaOnly and role == "army" and UnitDefs[defID].canFly then
                            fighters = fighters + 1
                        end
                        local sk, sr = stratOf(defID)
                        if sk == "nuke" then siloN = siloN + 1
                        elseif sk == "lrpc" then lrpcN = lrpcN + 1
                        elseif sk == "antinuke" then
                            antiN = antiN + 1
                            local nx, _, nz = Spring.GetUnitPosition(uid)
                            if nx then antiPos[#antiPos + 1] = { nx, nz, sr } end
                        end
                        if role == "army" then
                            if air then armyAir = armyAir + 1 end
                            if gnd then armyGnd = armyGnd + 1 end
                        else
                            if air then defAir = defAir + 1 end
                            if gnd then defGnd = defGnd + 1 end
                        end
                    end

                    if role == "army" then
                        local x, _, z = Spring.GetUnitPosition(uid)
                        local hp, maxHp = Spring.GetUnitHealth(uid)
                        armyN, armyMv = armyN + 1, armyMv + cost(defID)
                        if hp and maxHp and maxHp > 0 then hpSum = hpSum + hp / maxHp end
                        if x then
                            cx, cz = cx + x, cz + z
                            armyPos[#armyPos + 1] = {x, z}
                        end
                        local un = UnitDefs[defID].name
                        comp[un] = (comp[un] or 0) + 1
                    end
                end
            end
        end
    end

    -- How many factories have air cover / anti-nuke cover?  "Dedicated" = a unit or defence
    -- built only to shoot air, as opposed to a generalist that merely can.
    local facAA, facAAded, facAnti = 0, 0, 0
    for _, fp in ipairs(facPos) do
        local anyAA, dedAA, anti = false, false, false
        for _, a in ipairs(aaPos) do
            if dist2d(fp[1], fp[2], a[1], a[2]) <= AA_COVER_R then
                anyAA = true
                if a[3] then dedAA = true; break end
            end
        end
        for _, a in ipairs(antiPos) do
            if dist2d(fp[1], fp[2], a[1], a[2]) <= a[3] then anti = true; break end
        end
        if anyAA then facAA = facAA + 1 end
        if dedAA then facAAded = facAAded + 1 end
        if anti then facAnti = facAnti + 1 end
    end

    local function c(r) return count[r] or 0 end
    local function v(r) return value[r] or 0 end
    emit("units", f, string.format(
        "mex=%d mex_mv=%.0f energy=%d energy_mv=%.0f factory=%d factory_t2=%d "
        .. "con=%d nano=%d army=%d army_mv=%.0f defense=%d defense_mv=%.0f utility=%d "
        .. "in_progress=%d bp=%.0f bp_idle=%.0f fac_idle=%d fac_busy=%d "
        .. "army_hits_air=%d army_hits_ground=%d def_hits_air=%d def_hits_ground=%d aa_dedicated=%d "
        .. "fighters=%d silo=%d lrpc=%d antinuke=%d fac_aa_cover=%d fac_aa_ded_cover=%d "
        .. "fac_antinuke_cover=%d "
        .. "built_mex=%d built_energy=%d built_con=%d built_army=%d built_factory=%d",
        c("mex"), v("mex"), c("energy"), v("energy"), c("factory"), t2,
        c("con"), c("nano"), c("army"), v("army"), c("defense"), v("defense"), c("utility"),
        inProgress, bp, bpIdle, facN - facBusy, facBusy,
        armyAir, armyGnd, defAir, defGnd, aaDedicated,
        fighters, siloN, lrpcN, antiN, facAA, facAAded, facAnti,
        finishedByRole.mex or 0, finishedByRole.energy or 0, finishedByRole.con or 0,
        finishedByRole.army or 0, finishedByRole.factory or 0))

    -- Army shape: `spread` is mean distance from the army's centroid, the number that
    -- shows a stretched-out army; `dist_base` shows whether it is at home or forward.
    local spread, distBase = 0, 0
    if armyN > 0 then
        cx, cz = cx / armyN, cz / armyN
        for _, p in ipairs(armyPos) do spread = spread + dist2d(p[1], p[2], cx, cz) end
        spread = spread / math.max(#armyPos, 1)
        distBase = dist2d(cx, cz, startX, startZ)
    end
    local names = {}
    for n in pairs(comp) do names[#names + 1] = n end
    table.sort(names, function(a, b) return comp[a] > comp[b] end)
    local top = {}
    for i = 1, math.min(6, #names) do top[i] = names[i] .. ":" .. comp[names[i]] end
    local groups, mainShare = groupStats(armyPos)
    emit("army", f, string.format(
        "n=%d mv=%.0f hp=%.2f spread=%.0f dist_base=%.0f groups=%d main_share=%.2f comp=%s",
        armyN, armyMv, armyN > 0 and hpSum / armyN or 0, spread, distBase, groups, mainShare,
        #top > 0 and table.concat(top, ",") or "-"))

    -- The commander: losing it ends the game, so how exposed is it?
    if cmdrUid and Spring.GetUnitDefID(cmdrUid) then
        local x, _, z = Spring.GetUnitPosition(cmdrUid)
        local hp, maxHp = Spring.GetUnitHealth(cmdrUid)
        if x then
            local enemies = Spring.GetUnitsInCylinder(x, z, CMDR_NEAR, Spring.ENEMY_UNITS or -4) or {}
            local nearOwn, friends = Spring.GetUnitsInCylinder(x, z, CMDR_NEAR, myTeam) or {}, 0
            for i = 1, #nearOwn do
                local nd = Spring.GetUnitDefID(nearOwn[i])
                local r = nd and roleOf(nd)
                if nearOwn[i] ~= cmdrUid and (r == "army" or r == "defense") then friends = friends + 1 end
            end
            local aaAny, aaDed, anti = 0, 0, 0
            for _, a in ipairs(aaPos) do
                if dist2d(x, z, a[1], a[2]) <= AA_COVER_R then
                    aaAny = 1
                    if a[3] then aaDed = 1 end
                end
            end
            for _, a in ipairs(antiPos) do
                if dist2d(x, z, a[1], a[2]) <= a[3] then anti = 1 end
            end
            emit("cmdr", f, string.format(
                "hp=%.2f dist_base=%.0f enemy_near=%d friends_near=%d aa_cover=%d aa_ded_cover=%d "
                .. "antinuke_cover=%d",
                (hp and maxHp and maxHp > 0) and hp / maxHp or 0, dist2d(x, z, startX, startZ),
                #enemies, friends, aaAny, aaDed, anti))
        end
    end
end

local function snapshotIntel(f)
    local visN, visMv, visAir, visAirMv, visGnd, near, closest = 0, 0, 0, 0, 0, 0, -1
    local visNuke, visLrpc = 0, 0
    for _, uid in ipairs(Spring.GetVisibleUnits(Spring.ENEMY_UNITS or -4, nil, false) or {}) do
        local defID = Spring.GetUnitDefID(uid)   -- nil for radar-only blips
        if defID then
            local d = UnitDefs[defID]
            visN, visMv = visN + 1, visMv + cost(defID)
            local sk = stratOf(defID)
            if sk == "nuke" then visNuke = visNuke + 1 elseif sk == "lrpc" then visLrpc = visLrpc + 1 end
            if d and d.canFly then visAir, visAirMv = visAir + 1, visAirMv + cost(defID)
            elseif d and d.canMove then visGnd = visGnd + 1 end
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local dd = dist2d(x, z, startX, startZ)
                if dd <= NEAR_BASE then near = near + 1 end
                if closest < 0 or dd < closest then closest = dd end
            end
        end
    end
    -- Radar-only contacts: how many are there, how many are moving, and how ambiguous is
    -- their decoded type (average number of unit types matching the measured speed).
    local bN, bMove, bCand, bCandN = 0, 0, 0, 0
    for _, b in pairs(blips) do
        if b.last >= f - 90 then
            bN = bN + 1
            if b.v and b.n >= 2 and b.v >= BLIP_MOVING then
                bMove = bMove + 1
                bCand, bCandN = bCand + #decodeSpeed(b.v), bCandN + 1
            end
        end
    end
    emit("intel", f, string.format(
        "vis_n=%d vis_mv=%.0f vis_air=%d vis_air_mv=%.0f vis_ground=%d vis_nuke=%d vis_lrpc=%d "
        .. "near_base=%d closest=%.0f first_seen=%d los_frac=%.3f radar_frac=%.3f explored_frac=%.3f "
        .. "blip_n=%d blip_moving=%d blip_cands_avg=%.1f",
        visN, visMv, visAir, visAirMv, visGnd, visNuke, visLrpc, near, closest, firstSeenEnemy,
        losFrac, radarFrac, exploredFrac, bN, bMove, bCandN > 0 and bCand / bCandN or 0))
end

local function snapshotCombat(f)
    local s = teamStats() or {}
    local names = {}
    for n in pairs(killers) do names[#names + 1] = n end
    table.sort(names, function(a, b) return killers[a] > killers[b] end)
    local top = {}
    for i = 1, math.min(5, #names) do top[i] = names[i] .. ":" .. killers[names[i]] end
    emit("combat", f, string.format(
        "lost_n=%d lost_mv=%.0f lost_army_n=%d lost_army_mv=%.0f lost_eco_n=%d lost_eco_mv=%.0f "
        .. "lost_enemy_n=%d lost_enemy_mv=%.0f lost_enemy_eco_n=%d lost_enemy_eco_mv=%.0f "
        .. "lost_enemy_army_n=%d lost_enemy_army_mv=%.0f "
        .. "lost_dist_base=%.0f lost_cons=%d lost_to_air=%d cons_alive=%d "
        .. "pm_deaths=%d pm_isolated=%d pm_support_avg=%.1f "
        .. "kills_seen_n=%d kills_seen_mv=%.0f dmg_dealt=%.0f dmg_recv=%.0f killers=%s",
        lost.n, lost.mv, lost.army_n, lost.army_mv, lost.eco_n, lost.eco_mv,
        lost.enemy_n, lost.enemy_mv, lost.enemy_eco_n, lost.enemy_eco_mv,
        lost.enemy_army_n, lost.enemy_army_mv,
        lost.n > 0 and lost.distSum / lost.n or 0, lost.cons, lost.byAir, conAlive,
        pm.n, pm.iso, pm.n > 0 and pm.support / pm.n or 0,
        kills.n, kills.mv, s.damageDealt or 0, s.damageReceived or 0,
        #top > 0 and table.concat(top, ",") or "-"))
end

-- After GameOver the engine keeps ticking for a while (autoquit); sampling then would log
-- an empty, dead team as if it were part of the game.
function widget:GameOver()
    gameOver = true
end

function widget:GameFrame(n)
    if gameOver or not myTeam then return end
    pmBudget = PIECE_BUDGET
    if n % PROBE_EVERY == 0 then
        safe("probe", probeEconomy)
        safe("threats", scanThreats, n)
    end
    if n % LOS_EVERY == 0 then safe("coverage", scanCoverage) end
    if n > 0 and n % SAMPLE_EVERY == 0 then
        safe("eco", snapshotEco, n)
        safe("units", snapshotUnits, n)
        safe("intel", snapshotIntel, n)
        safe("combat", snapshotCombat, n)
    end
end
