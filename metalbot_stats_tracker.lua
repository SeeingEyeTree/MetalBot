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
-- find_weakness.py and bot_score.py read them.
--
-- Ability to act (units row), used by bot_score.py's spendable_rate:
--   fac_bp          build speed of factories + nanos within reach of a factory
--   fac_bp_open     the same, only at factories whose units can get out (air labs, ground
--                   labs with a path; a boxed-in lab counts half if there are air transports)
--   army_ev / defense_ev / mex_ev / energy_ev   ENERGY cost of the same units as *_mv
--                   (game_mechanics 2.3 values a unit at metal + energy/70)
--   fac_bp_useful   fac_bp_open with each lab's support BP capped at what builds its typical
--                   army unit in 2.5 s (game_mechanics 2.5: more just waits for the exit)
--   nano_idle_bp    build power of nano turrets with nothing to do (stranded; 2.4)
--   home_guard_gnd_mv / home_guard_air_mv   armed units + defences within NEAR_BASE of the
--                   start that can hit ground / air: the local reserve raids meet (7.1)
--   rez, util_intel units that can resurrect; unarmed mobile radar/jammer units (7)
--   max_tech        highest tech level among our factories (4)
-- Economy (eco row): metal_pull_avg / energy_pull_avg / metal_inc_avg / energy_inc_avg
--                   averaged over the interval's probes: pull is what the builders are
--                   spending (game_mechanics 1.1); a single reading is too noisy
--   mob_bp          build speed of mobile builders incl. the commander
--   army_em         energy per metal of the standing army (else of what the factories offer)
--   army_m_per_bp   metal per build-power-second of the same (metalCost / buildTime)
--   build_sites / build_tested   sample points next to builders where a T1 ground factory fits
--   ground_fac, fac_exit_ok, fac_exit_unknown   ground factories; how many have a path to open
--                   ground (Spring.RequestPath); unknown = the engine gave no answer
--   stuck_units     army units >STUCK_AGE after finishing, still at their factory, not moving
--   air_trans       air transports (can lift units out of a boxed-in factory)
-- Awareness (intel row):
--   fresh_home/corridor/enemy/mex   age-weighted knowledge of each zone, 0-1 (-1 = no such zone);
--                   enemy start from start positions if readable, else mirrored (init foe_src)
--   believed_n/mv   enemy units seen in the last MEMORY_FRAMES and not seen to die
--   arrivals_n / arrivals_warned_n / lead_med   armed enemies that reached NEAR_BASE; how many
--                   had been contacted (LOS or radar) >= WARN_LEAD frames earlier; median lead
-- Surprise (combat row):
--   lost_unseen_n/mv   enemy-attributed losses whose killer was not in sight in the last SEEN_RECENT
--   lost_noattr_n/mv   finished units lost with NO attacker: self-destructs, or kills whose
--                      attacker the engine hid from this process (diagnostic; see scoring.md)
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
--   first_enemy_t2          first enemy unit of tech level 2+ seen (def=)
--   mex_10 mex_25 mex_50 commander_lost   (commander_lost carries killer=; "?" = self/unknown)
--   cons_all_dead / cons_restored   (repeat; cons_restored carries waited=frames)
--   fac_boxed               (once per factory) a ground lab with no path out (def= x= z= facing= best_path=)

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
local FRESH_TAU     = 1350     -- frames: knowledge of a map cell decays as exp(-age / FRESH_TAU)
local ZONE_R        = 2500     -- elmos: "home" / "enemy" zone radius round each start
local CORRIDOR_W    = 1500     -- elmos: half-width of the corridor between the two starts
local WARN_LEAD     = 600      -- frames: an arrival first contacted this much earlier was "warned"
local MEMORY_FRAMES = 9000     -- frames: forget an enemy unit not seen for this long
local SEEN_RECENT   = 300      -- frames: an attacker seen this recently was "seen" when it killed
local STUCK_AGE     = 1800     -- frames after finishing: an army unit still at its factory door...
local STUCK_R       = 250      -- ...within this many elmos of it, and not moving, is stuck
local SITE_BUILDERS = 6        -- builders sampled per snapshot for free factory sites
local SITE_DIRS     = 8        -- sample points per builder
local EXIT_FACS     = 8        -- factories path-tested per snapshot

local myTeam, myAlly, startX, startZ = nil, nil, 0, 0
local firstSeenEnemy = -1
local gameOver = false
local disabled = {}            -- name -> true once a sub-tracker has errored

-- interval probes
local probes = 0
local stallM, stallE, floatM, floatE = 0, 0, 0, 0
local pullM, pullE, incM, incE = 0, 0, 0, 0   -- summed over probes, averaged per snapshot

-- cumulative counters, updated from callbacks
-- `lost` counts EVERY loss, including our own reclaims and retrofits.  `enemy_*` counts only
-- losses with a known enemy attacker, which is what "the enemy is killing us" means.
local lost = {n = 0, mv = 0, army_n = 0, army_mv = 0, eco_n = 0, eco_mv = 0, distSum = 0,
              cons = 0, byAir = 0, enemy_n = 0, enemy_mv = 0, enemy_eco_n = 0, enemy_eco_mv = 0,
              enemy_army_n = 0, enemy_army_mv = 0, unseen_n = 0, unseen_mv = 0,
              noattr_n = 0, noattr_mv = 0}
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

-- awareness
local foeX, foeZ, foeSrc = nil, nil, "none"   -- enemy start: read if possible, else mirrored
local lastLos, lastRadar, cellZone = {}, {}, nil   -- cell -> frame last in LOS / radar; zone
local contact, nContact = {}, 0   -- enemy uid -> first frame of ANY contact (LOS or radar)
local known = {}                  -- enemy uid -> {mv, last}: what we believe is out there
local arrived = {}                -- enemy uid -> true once it has reached our base
local arrivals = {n = 0, warned = 0, leads = {}}

-- ability to act
local born = {}                   -- own uid -> {fx, fz, f}: factory that built it, finish frame
local labDefID = nil              -- our ground T1 factory def, for the free-site test
local siteOffset, exitOffset = 0, 0

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

-- The enemy start, for the awareness zones.  Enemy start positions are usually not readable,
-- so the mirror of our own is the fallback (same rule as bar_framework/map_model.lua).
local function resolveFoe()
    if Spring.GetTeamList and Spring.GetTeamInfo then
        for _, t in ipairs(Spring.GetTeamList() or {}) do
            local _, _, _, _, _, allyID = Spring.GetTeamInfo(t)
            if t ~= myTeam and allyID ~= myAlly and t ~= (Spring.GetGaiaTeamID and Spring.GetGaiaTeamID()) then
                local x, _, z = Spring.GetTeamStartPosition(t)
                if x and x > 0 and z and z > 0 then return x, z, "start_pos" end
            end
        end
    end
    return mapX - startX, mapZ - startZ, "mirror"
end

function widget:GameStart()
    myTeam = Spring.GetMyTeamID()
    myAlly = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    mapX = (Game and Game.mapSizeX) or 0
    mapZ = (Game and Game.mapSizeZ) or 0
    local sx, _, sz = Spring.GetTeamStartPosition(myTeam)
    startX, startZ = sx or 0, sz or 0
    foeX, foeZ, foeSrc = resolveFoe()
    -- Ground truth on what this process can see: bot_testing.py sets fullview=1 but
    -- that has not been trusted to work headless. If fullview reads 0 here, believe it.
    local spec, fullview = Spring.GetSpectatingState()
    safe("defs", dumpDefs)
    -- Helpers a bot can call: turn a radar blip's measured speed into candidate unit types.
    if WG then
        WG.StatsTracker = { DecodeSpeed = decodeSpeed, Blips = blips, GroupStats = groupStats }
    end
    emit("init", 0, string.format("spec=%d fullview=%d start_x=%.0f start_z=%.0f map_x=%d map_z=%d "
        .. "foe_x=%.0f foe_z=%.0f foe_src=%s",
        spec and 1 or 0, fullview and 1 or 0, startX, startZ, mapX, mapZ, foeX, foeZ, foeSrc))
end

-- ── Callbacks that keep cumulative counters ──────────────────────────────────

-- Remember which factory built each unit, for the "stuck at the factory door" test.
function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if teamID ~= myTeam or not builderID then return end
    local bd = Spring.GetUnitDefID(builderID)
    if bd and roleOf(bd) == "factory" then
        local x, _, z = Spring.GetUnitPosition(builderID)
        if x then born[unitID] = { fx = x, fz = z } end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeam then return end
    local role = roleOf(unitDefID)
    finishedByRole[role] = (finishedByRole[role] or 0) + 1
    local f = Spring.GetGameFrame()
    if born[unitID] then born[unitID].f = f end
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
        born[unitID] = nil
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
            -- Surprise: the killer was not in sight in the last SEEN_RECENT frames.
            local k = attackerID and known[attackerID]
            if not (k and f - k.last <= SEEN_RECENT) then
                lost.unseen_n, lost.unseen_mv = lost.unseen_n + 1, lost.unseen_mv + mv
            end
        elseif attackerTeamID == nil and wasFinished then
            -- No attacker at all. Reclaims name the reclaimer, so this is a self-destruct or a
            -- kill whose attacker the engine hid from this process (knowledge/scoring.md).
            lost.noattr_n, lost.noattr_mv = lost.noattr_n + 1, lost.noattr_mv + mv
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
    else
        known[unitID] = nil            -- seen to die: no longer part of the enemy we believe in
        if attackerTeamID == myTeam and not Spring.AreTeamsAllied(teamID, myTeam) then
            -- Only fires for kills of units this process could see; it is a lower bound.
            kills.n, kills.mv = kills.n + 1, kills.mv + cost(unitDefID)
            event(f, "first_kill")
        end
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
    local m, ms, mp, mi = Spring.GetTeamResources(myTeam, "metal")
    local e, es, ep, ei = Spring.GetTeamResources(myTeam, "energy")
    if not m then return end
    probes = probes + 1
    pullM, pullE = pullM + (mp or 0), pullE + (ep or 0)
    incM, incE = incM + (mi or 0), incE + (ei or 0)
    if ms and ms > 0 then
        if m < ms * STALL_FRAC then stallM = stallM + 1 end
        if m > ms * FLOAT_FRAC then floatM = floatM + 1 end
    end
    if es and es > 0 and e then
        if e < es * STALL_FRAC then stallE = stallE + 1 end
        if e > es * FLOAT_FRAC then floatE = floatE + 1 end
    end
end

-- Enemy units this process has in LOS or on radar (radar-only ones have no unit type).
-- NOT Spring.GetVisibleUnits: that is culled to the CAMERA's view, and a headless process has
-- no real camera. Every match logged before 2026-09-23 saw at most one enemy per snapshot and
-- no radar blips at all while losing dozens of units to named killers. Same approach as
-- bar_framework/threat_map.lua.
local gaiaTeam = Spring.GetGaiaTeamID and Spring.GetGaiaTeamID()
local function enemyUnits()
    local out = {}
    local all = Spring.GetAllUnits and Spring.GetAllUnits() or {}
    for i = 1, #all do
        local uid = all[i]
        local a = Spring.GetUnitAllyTeam(uid)
        if a and a ~= myAlly and Spring.GetUnitTeam(uid) ~= gaiaTeam then out[#out + 1] = uid end
    end
    return out
end

-- Watch every visible enemy: when did we FIRST see it and how far away was it, so that
-- "the first raider reached the base and we had no warning" is a number, not a guess.
local function scanThreats(f)
    local list = enemyUnits()
    if nSeen > 4000 then seenEnemy, nSeen = {}, 0 end
    if nContact > 8000 then contact, arrived, nContact = {}, {}, 0 end
    for i = 1, #list do
        local uid = list[i]
        if not contact[uid] then contact[uid] = f; nContact = nContact + 1 end
        local defID = Spring.GetUnitDefID(uid)   -- nil for radar-only blips
        if defID then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local dd = dist2d(x, z, startX, startZ)
                local k = known[uid]
                if k then k.last = f else known[uid] = { mv = cost(defID), last = f } end
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
                    if techLevel(defID) >= 2 then event(f, "first_enemy_t2", info) end
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
                        -- Every armed arrival, not just the first: how long before it got
                        -- here did we have ANY contact with it (radar counts)?
                        if not arrived[uid] then
                            arrived[uid] = true
                            local lead = f - (contact[uid] or f)
                            arrivals.n = arrivals.n + 1
                            if lead >= WARN_LEAD then arrivals.warned = arrivals.warned + 1 end
                            if #arrivals.leads < 2000 then arrivals.leads[#arrivals.leads + 1] = lead end
                        end
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
-- Zones make coverage mean something: a lit empty corner is worth less than the corridor
-- raiders use.  home / enemy = within ZONE_R of each start; corridor = within CORRIDOR_W of
-- the line between them; mex = any other cell with metal in it.  Other cells: no zone.
local function hasMetal(x0, z0, w, h)
    if not Spring.GetMetalAmount then return false end
    for i = 0, 4 do
        for j = 0, 4 do
            local mx = math.floor((x0 + (i + 0.5) * w / 5) / 16)
            local mz = math.floor((z0 + (j + 0.5) * h / 5) / 16)
            if (Spring.GetMetalAmount(mx, mz) or 0) > 0 then return true end
        end
    end
    return false
end

local function buildZones()
    cellZone = {}
    local cw, ch = mapX / MAP_GRID, mapZ / MAP_GRID
    local ax, az = foeX - startX, foeZ - startZ
    local len2 = math.max(ax * ax + az * az, 1)
    for gz = 0, MAP_GRID - 1 do
        for gx = 0, MAP_GRID - 1 do
            local x, z = (gx + 0.5) * cw, (gz + 0.5) * ch
            local t = math.max(0, math.min(1, ((x - startX) * ax + (z - startZ) * az) / len2))
            local zone
            if dist2d(x, z, startX, startZ) <= ZONE_R then zone = "home"
            elseif dist2d(x, z, foeX, foeZ) <= ZONE_R then zone = "enemy"
            elseif dist2d(x, z, startX + t * ax, startZ + t * az) <= CORRIDOR_W then zone = "corridor"
            elseif hasMetal(gx * cw, gz * ch, cw, ch) then zone = "mex" end
            if zone then cellZone[gz * MAP_GRID + gx] = zone end
        end
    end
end

local function scanCoverage(f)
    if mapX <= 0 or mapZ <= 0 or not Spring.IsPosInLos then return end
    if not cellZone then buildZones() end
    local los, radar, n = 0, 0, MAP_GRID * MAP_GRID
    for gz = 0, MAP_GRID - 1 do
        local z = (gz + 0.5) * mapZ / MAP_GRID
        for gx = 0, MAP_GRID - 1 do
            local x = (gx + 0.5) * mapX / MAP_GRID
            local key = gz * MAP_GRID + gx
            if Spring.IsPosInLos(x, 0, z, myAlly) then
                los = los + 1
                lastLos[key] = f
                if not explored[key] then explored[key] = true; exploredN = exploredN + 1 end
            end
            if Spring.IsPosInRadar and Spring.IsPosInRadar(x, 0, z, myAlly) then
                radar = radar + 1
                lastRadar[key] = f
            end
        end
    end
    losFrac, radarFrac, exploredFrac = los / n, radar / n, exploredN / n
end

-- Age-weighted knowledge per zone: each cell counts exp(-age / FRESH_TAU) since it was last
-- in LOS, or half that for radar only (radar shows that something is there, not what).
-- -1 = the zone has no cells on this map.
local function freshness(f)
    local sum, cnt = {}, {}
    for key, zone in pairs(cellZone or {}) do
        local a = lastLos[key] and math.exp(-(f - lastLos[key]) / FRESH_TAU) or 0
        local r = lastRadar[key] and 0.5 * math.exp(-(f - lastRadar[key]) / FRESH_TAU) or 0
        sum[zone] = (sum[zone] or 0) + math.max(a, r)
        cnt[zone] = (cnt[zone] or 0) + 1
    end
    return function(zone) return cnt[zone] and sum[zone] / cnt[zone] or -1 end
end

-- ── Ability to act ───────────────────────────────────────────────────────────
-- Could this team turn income into army right now, and add production if it had to?  Build
-- power that reaches a factory, the energy/metal cost of what it builds, free ground for a new
-- factory next to a builder, and whether ground factories have a way out.  bot_score.py turns
-- these into `spendable_rate` = the scarcest of metal, energy and build power.

local airLabCache, groundOptCache, exitCache, boxedLogged = {}, {}, {}, {}
local mainBtCache = {}

-- Build time of a factory's typical army unit (median over its armed buildoptions).
-- game_mechanics 2.5: support BP beyond what builds that unit in ~2.5 s mostly waits for
-- units to walk out, so it is not production capacity.
local LAB_ABSORB_S = 2.5
local function mainBuildTime(defID)
    local c = mainBtCache[defID]
    if c then return c end
    local bts = {}
    for _, o in ipairs(UnitDefs[defID] and UnitDefs[defID].buildOptions or {}) do
        if roleOf(o) == "army" and UnitDefs[o].buildTime then bts[#bts + 1] = UnitDefs[o].buildTime end
    end
    table.sort(bts)
    c = #bts > 0 and bts[math.ceil(#bts / 2)] or 0
    mainBtCache[defID] = c
    return c
end
local FACING = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }

local function isAirLab(defID)
    local c = airLabCache[defID]
    if c ~= nil then return c end
    local opts = UnitDefs[defID] and UnitDefs[defID].buildOptions or {}
    c = #opts > 0
    for i = 1, #opts do
        local o = UnitDefs[opts[i]]
        if o and not o.canFly then c = false; break end
    end
    airLabCache[defID] = c
    return c
end

-- The first ground unit a factory makes: its move type is what has to get out of the door.
local function groundOption(defID)
    local c = groundOptCache[defID]
    if c == nil then
        c = false
        for _, o in ipairs(UnitDefs[defID] and UnitDefs[defID].buildOptions or {}) do
            local od = UnitDefs[o]
            if od and od.canMove and not od.canFly and od.moveDef and od.moveDef.name then c = od; break end
        end
        groundOptCache[defID] = c
    end
    return c or nil
end

-- A ground T1 factory one of our builders can make: the footprint for the free-site test.
local function findLabDef(builderDefs)
    for defID in pairs(builderDefs) do
        for _, o in ipairs(UnitDefs[defID].buildOptions or {}) do
            local od = UnitDefs[o]
            if od and od.isFactory and techLevel(o) < 2 and not isAirLab(o) then return o end
        end
    end
end

-- Can a unit from this factory reach open ground?  Paths are asked from just outside the
-- factory door towards three goals 1500 elmos out (map centre, enemy start, straight ahead):
-- open if any path reaches its goal or gets EXIT_FAR from the door.  Several goals, because
-- one goal can sit inside our own building field and fail although the door is clear.
-- Returns true / false, or nil when the engine gives no answer (RequestPath missing or
-- erroring), which is logged as fac_exit_unknown, never as trapped.  The second value is a
-- short description of the best attempt, for the fac_boxed event.
local EXIT_FAR = 1000
local function exitOK(uid, defID, x, z)
    if not Spring.RequestPath then return nil end
    local od = groundOption(defID)
    if not od then return nil end
    local fd = UnitDefs[defID]
    local dir = FACING[(Spring.GetUnitBuildFacing and Spring.GetUnitBuildFacing(uid)) or 0] or FACING[0]
    local half = ((dir[1] ~= 0) and (fd.xsize or 0) or (fd.zsize or 0)) * 4
    local sx, sz = x + dir[1] * (half + 24), z + dir[2] * (half + 24)
    local sy = Spring.GetGroundHeight(sx, sz)
    local goals = { { mapX / 2 - x, mapZ / 2 - z }, { (foeX or mapX / 2) - x, (foeZ or mapZ / 2) - z },
                    { dir[1], dir[2] } }
    local answered, best = false, 0
    for _, g in ipairs(goals) do
        local d = math.sqrt(g[1] * g[1] + g[2] * g[2])
        if d > 1 then
            local gx = math.max(64, math.min(mapX - 64, x + g[1] / d * 1500))
            local gz = math.max(64, math.min(mapZ - 64, z + g[2] / d * 1500))
            local ok, path = pcall(Spring.RequestPath, od.moveDef.name, sx, sy, sz,
                                   gx, Spring.GetGroundHeight(gx, gz), gz, 64)
            if ok then
                answered = true
                if path then
                    local ok2, wps = pcall(function() return path:GetPathWayPoints() end)
                    if ok2 and type(wps) == "table" and #wps > 0 then
                        local last = wps[#wps]
                        local out = dist2d(last[1], last[3], sx, sz)
                        if dist2d(last[1], last[3], gx, gz) <= 400 or out >= EXIT_FAR then
                            return true
                        end
                        if out > best then best = out end
                    end
                end
            end
        end
    end
    if not answered then return nil end
    return false, string.format("def=%s x=%.0f z=%.0f facing=%d best_path=%.0f",
        fd.name, x, z, (Spring.GetUnitBuildFacing and Spring.GetUnitBuildFacing(uid)) or -1, best)
end

local function newAbility()
    return { mobBp = 0, nanos = {}, facs = {}, builders = {}, builderDefs = {},
             armyE = 0, armyM = 0, armyBT = 0, airTrans = 0, stuck = 0,
             nanoIdleBp = 0, guardGnd = 0, guardAir = 0, rez = 0, utilIntel = 0, maxTech = 1 }
end

-- Called for every finished unit of ours (and the commander) during the units snapshot.
local function collectOne(ab, uid, defID, role, f)
    local d = UnitDefs[defID]
    if role == "con" or role == "commander" then
        ab.mobBp = ab.mobBp + (d.buildSpeed or 0)
        local x, _, z = Spring.GetUnitPosition(uid)
        if x then ab.builders[#ab.builders + 1] = { x, z, d.buildDistance or 128 } end
        ab.builderDefs[defID] = true
    elseif role == "nano" or role == "factory" then
        local x, _, z = Spring.GetUnitPosition(uid)
        if x then
            local list = role == "nano" and ab.nanos or ab.facs
            list[#list + 1] = { x, z, d.buildSpeed or 0, d.buildDistance or 128, uid, defID }
        end
        -- Stranded build power: a nano with nothing to do (game_mechanics 2.4: relocate it).
        if role == "nano" and isIdle(uid, role) then ab.nanoIdleBp = ab.nanoIdleBp + (d.buildSpeed or 0) end
        if role == "factory" then ab.maxTech = math.max(ab.maxTech, techLevel(defID)) end
    elseif role == "army" then
        ab.armyE = ab.armyE + (d.energyCost or 0)
        ab.armyM = ab.armyM + (d.metalCost or 0)
        ab.armyBT = ab.armyBT + (d.buildTime or 0)
        local b = born[uid]
        if b and b.f and f - b.f >= STUCK_AGE then
            local x, _, z = Spring.GetUnitPosition(uid)
            local _, _, _, sp = Spring.GetUnitVelocity(uid)
            if x and dist2d(x, z, b.fx, b.fz) <= STUCK_R and (sp or 0) < 1 then ab.stuck = ab.stuck + 1 end
        end
    end
    if d.canFly and (d.transportCapacity or 0) > 0 then ab.airTrans = ab.airTrans + 1 end
    -- Home guard (game_mechanics 7.1: raids are met by a LOCAL reserve): armed units and
    -- defences near the start, by what they can hit.
    if role == "army" or role == "defense" then
        local x, _, z = Spring.GetUnitPosition(uid)
        if x and dist2d(x, z, startX, startZ) <= NEAR_BASE then
            local air, gnd = capsOf(defID)
            if gnd then ab.guardGnd = ab.guardGnd + cost(defID) end
            if air then ab.guardAir = ab.guardAir + cost(defID) end
        end
    end
    -- Roles game_mechanics 7 calls for that the role classifier does not separate.
    if d.canResurrect then ab.rez = ab.rez + 1 end
    if d.canMove and not (d.weapons and #d.weapons > 0) and not d.isBuilder
       and ((d.radarRadius or 0) > 0 or (d.jammerRadius or 0) > 0) then
        ab.utilIntel = ab.utilIntel + 1
    end
end

-- A bug here must not take the whole units row down with it (safe() would disable it).
local function abilityCollect(ab, uid, defID, role, f)
    if ab.err then return end
    local ok, err = pcall(collectOne, ab, uid, defID, role, f)
    if not ok then ab.err = err end
end

local function abilityFields(ab)
    if ab.err then error(ab.err) end
    -- Build power that reaches a factory: the factories themselves + nanos in range of one
    -- (each nano counted once, at the first factory it reaches).  Kept per factory, so a
    -- boxed-in lab only takes its OWN build power out of fac_bp_open below.
    local facBp, perFac = 0, {}
    for i, fa in ipairs(ab.facs) do facBp = facBp + fa[3]; perFac[i] = fa[3] end
    for _, nn in ipairs(ab.nanos) do
        for i, fa in ipairs(ab.facs) do
            local fd = UnitDefs[fa[6]]
            local half = math.max(fd.xsize or 0, fd.zsize or 0) * 4
            if dist2d(nn[1], nn[2], fa[1], fa[2]) <= nn[4] + half then
                facBp, perFac[i] = facBp + nn[3], perFac[i] + nn[3]
                break
            end
        end
    end
    -- Energy/metal cost of what we build: the standing army, else what the factories offer.
    local E, M, BT = ab.armyE, ab.armyM, ab.armyBT
    if M <= 0 then
        for _, fa in ipairs(ab.facs) do
            for _, o in ipairs(UnitDefs[fa[6]].buildOptions or {}) do
                if roleOf(o) == "army" then
                    local od = UnitDefs[o]
                    E, M, BT = E + (od.energyCost or 0), M + (od.metalCost or 0), BT + (od.buildTime or 0)
                end
            end
        end
    end
    -- Free ground for a factory next to a builder (a rotating sample of builders).
    labDefID = labDefID or findLabDef(ab.builderDefs)
    local sites, tested = 0, 0
    if labDefID and #ab.builders > 0 and Spring.TestBuildOrder then
        local ld = UnitDefs[labDefID]
        local half = math.max(ld.xsize or 0, ld.zsize or 0) * 4
        local nb = math.min(SITE_BUILDERS, #ab.builders)
        for i = 1, nb do
            local b = ab.builders[(siteOffset + i - 1) % #ab.builders + 1]
            local r = b[3] + half + 32
            for k = 0, SITE_DIRS - 1 do
                local a = k * 2 * math.pi / SITE_DIRS
                local x, z = b[1] + r * math.cos(a), b[2] + r * math.sin(a)
                if x > half and z > half and x < mapX - half and z < mapZ - half then
                    tested = tested + 1
                    local ok = Spring.TestBuildOrder(labDefID, x, Spring.GetGroundHeight(x, z), z, 0)
                    if ok and ok ~= 0 then sites = sites + 1 end
                end
            end
        end
        siteOffset = siteOffset + nb
    end
    -- Ground factories with a way out.  At most EXIT_FACS path tests per snapshot; the rest
    -- use their last answer.
    local groundFac, exitOk, exitUnknown, tests = 0, 0, 0, 0
    local nf = #ab.facs
    for i = 1, nf do
        local fa = ab.facs[(exitOffset + i - 1) % nf + 1]
        if not isAirLab(fa[6]) then
            groundFac = groundFac + 1
            if tests < EXIT_FACS then
                tests = tests + 1
                local r, why = exitOK(fa[5], fa[6], fa[1], fa[2])
                exitCache[fa[5]] = (r == nil) and "?" or r
                -- First time a lab reads as boxed in: say where, so a replay can confirm it.
                if r == false and not boxedLogged[fa[5]] then
                    boxedLogged[fa[5]] = true
                    emit("event", Spring.GetGameFrame(), "name=fac_boxed " .. (why or ""))
                end
            end
            local r = exitCache[fa[5]]
            if r == true then exitOk = exitOk + 1 elseif r == nil or r == "?" then exitUnknown = exitUnknown + 1 end
        end
    end
    exitOffset = exitOffset + EXIT_FACS
    -- fac_bp_open: build power at factories whose units can get out (air labs, ground labs
    -- with a path or not yet tested).  A boxed lab counts half with air transports around.
    local facBpOpen, facBpUseful = 0, 0
    for i, fa in ipairs(ab.facs) do
        local r = exitCache[fa[5]]
        local share = (isAirLab(fa[6]) or r ~= false) and 1 or (ab.airTrans > 0 and 0.5 or 0)
        facBpOpen = facBpOpen + share * perFac[i]
        -- fac_bp_useful: the same, with support BP capped at what the lab can absorb
        local bt = mainBuildTime(fa[6])
        local support = perFac[i] - fa[3]
        if bt > 0 then support = math.min(support, bt / LAB_ABSORB_S) end
        facBpUseful = facBpUseful + share * (fa[3] + support)
    end
    return string.format(
        " fac_bp=%.0f fac_bp_open=%.0f fac_bp_useful=%.0f mob_bp=%.0f army_em=%.2f army_m_per_bp=%.4f "
        .. "build_sites=%d build_tested=%d ground_fac=%d fac_exit_ok=%d fac_exit_unknown=%d "
        .. "stuck_units=%d air_trans=%d nano_idle_bp=%.0f home_guard_gnd_mv=%.0f home_guard_air_mv=%.0f "
        .. "rez=%d util_intel=%d max_tech=%d",
        facBp, facBpOpen, facBpUseful, ab.mobBp, M > 0 and E / M or 0, BT > 0 and M / BT or 0,
        sites, tested, groundFac, exitOk, exitUnknown, ab.stuck, ab.airTrans,
        ab.nanoIdleBp, ab.guardGnd, ab.guardAir, ab.rez, ab.utilIntel, ab.maxTech)
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
        .. "wreck_metal=%.0f metal_pull_avg=%.2f energy_pull_avg=%.1f metal_inc_avg=%.2f "
        .. "energy_inc_avg=%.1f",
        m, ms or 0, mi or 0, mp or 0, mx or 0, e or 0, es or 0, ei or 0, ep or 0, ex or 0,
        s.metalProduced or 0, s.metalUsed or 0, s.energyProduced or 0, s.energyUsed or 0,
        stallM / p, stallE / p, floatM / p, floatE / p, total, cap, wreck,
        pullM / p, pullE / p, incM / p, incE / p))
    probes, stallM, stallE, floatM, floatE = 0, 0, 0, 0, 0
    pullM, pullE, incM, incE = 0, 0, 0, 0
end

local function snapshotUnits(f)
    local count, value, inProgress = {}, {}, 0
    local evalue = {}   -- energy cost per role (game_mechanics 2.3: value = metal + energy/70)
    local bp, bpIdle, facN, facBusy = 0, 0, 0, 0
    local t2 = 0
    local armyN, armyMv, hpSum, cx, cz = 0, 0, 0, 0, 0
    local armyAir, armyGnd, defAir, defGnd, aaDedicated = 0, 0, 0, 0, 0
    local armyPos, comp = {}, {}
    local facPos, aaPos, antiPos = {}, {}, {}   -- for coverage of factories / commander
    local fighters, siloN, lrpcN, antiN = 0, 0, 0, 0
    local ab = newAbility()
    cmdrUid = nil

    for _, uid in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if defID then
            local role = roleOf(defID)
            if role == "commander" then
                cmdrUid = uid
                abilityCollect(ab, uid, defID, role, f)
            end
            if role ~= "commander" then
                if Spring.GetUnitIsBeingBuilt(uid) then
                    inProgress = inProgress + 1
                else
                    count[role] = (count[role] or 0) + 1
                    value[role] = (value[role] or 0) + cost(defID)
                    evalue[role] = (evalue[role] or 0) + (UnitDefs[defID].energyCost or 0)
                    abilityCollect(ab, uid, defID, role, f)
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
    local okA, abStr = pcall(abilityFields, ab)
    if not okA then
        Spring.Echo("[TRK] error name=ability " .. (tostring(abStr):gsub("%s+", "_")))
        abStr = ""
    end
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
        finishedByRole.army or 0, finishedByRole.factory or 0)
        .. string.format(" army_ev=%.0f defense_ev=%.0f mex_ev=%.0f energy_ev=%.0f",
            evalue.army or 0, evalue.defense or 0, evalue.mex or 0, evalue.energy or 0)
        .. abStr)

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
    for _, uid in ipairs(enemyUnits()) do
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
    -- What we believe the enemy has: every unit seen in the last MEMORY_FRAMES and not seen
    -- to die.  bot_score.py divides it by the enemy's own count (privileged, offline only).
    local belN, belMv = 0, 0
    for uid, k in pairs(known) do
        if f - k.last > MEMORY_FRAMES then known[uid] = nil
        else belN, belMv = belN + 1, belMv + k.mv end
    end
    local leads = {}
    for i = 1, #arrivals.leads do leads[i] = arrivals.leads[i] end
    table.sort(leads)
    local fr = freshness(f)
    emit("intel", f, string.format(
        "vis_n=%d vis_mv=%.0f vis_air=%d vis_air_mv=%.0f vis_ground=%d vis_nuke=%d vis_lrpc=%d "
        .. "near_base=%d closest=%.0f first_seen=%d los_frac=%.3f radar_frac=%.3f explored_frac=%.3f "
        .. "blip_n=%d blip_moving=%d blip_cands_avg=%.1f "
        .. "fresh_home=%.3f fresh_corridor=%.3f fresh_enemy=%.3f fresh_mex=%.3f "
        .. "believed_n=%d believed_mv=%.0f arrivals_n=%d arrivals_warned_n=%d lead_med=%d",
        visN, visMv, visAir, visAirMv, visGnd, visNuke, visLrpc, near, closest, firstSeenEnemy,
        losFrac, radarFrac, exploredFrac, bN, bMove, bCandN > 0 and bCand / bCandN or 0,
        fr("home"), fr("corridor"), fr("enemy"), fr("mex"),
        belN, belMv, arrivals.n, arrivals.warned, #leads > 0 and leads[math.ceil(#leads / 2)] or 0))
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
        .. "kills_seen_n=%d kills_seen_mv=%.0f dmg_dealt=%.0f dmg_recv=%.0f "
        .. "lost_unseen_n=%d lost_unseen_mv=%.0f lost_noattr_n=%d lost_noattr_mv=%.0f killers=%s",
        lost.n, lost.mv, lost.army_n, lost.army_mv, lost.eco_n, lost.eco_mv,
        lost.enemy_n, lost.enemy_mv, lost.enemy_eco_n, lost.enemy_eco_mv,
        lost.enemy_army_n, lost.enemy_army_mv,
        lost.n > 0 and lost.distSum / lost.n or 0, lost.cons, lost.byAir, conAlive,
        pm.n, pm.iso, pm.n > 0 and pm.support / pm.n or 0,
        kills.n, kills.mv, s.damageDealt or 0, s.damageReceived or 0,
        lost.unseen_n, lost.unseen_mv, lost.noattr_n, lost.noattr_mv,
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
    if n % LOS_EVERY == 0 then safe("coverage", scanCoverage, n) end
    if n > 0 and n % SAMPLE_EVERY == 0 then
        safe("eco", snapshotEco, n)
        safe("units", snapshotUnits, n)
        safe("intel", snapshotIntel, n)
        safe("combat", snapshotCombat, n)
    end
end
