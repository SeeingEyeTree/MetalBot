-- bar_framework/game_state.lua
-- One plain table describing the game as the bot sees it, built about once a second, so strategy hooks decide from a
-- single place instead of each reading WG, Spring and module internals.  Hooks (strategy.lua) get this table and can
-- be tested with a hand-made one.
--
--   state = {
--     frame, minute,
--     metal  = { cur, stor, pull, income, expense, fill },    energy = { same }
--     floating, stalling,            both resources above 90% full / metal below 5% full with pull > income
--     units, cap, capFrac,           own unit count and the cap
--     armyCount, armyValue,          from the caller (o.armyCount / o.armyValue) or WG.MetalBot.armyCount
--     armyByDef,                     { [defID] = count } from the caller, for seeding a new stance's ledger
--     urgency, threats,              WG.MetalBot: production urgency and the intruder clusters (list)
--     intel,                         WG.MetalBot.intel (enemy_intel Summary: airValue, groundValue, labs, t2Labs, ...)
--     enemyAir, enemyGround,         shortcuts to intel.airValue / groundValue (0 when unknown)
--     enemyAirShare,                 enemyAir / (enemyAir + enemyGround), nil when nothing is known
--     facts,                         enemy facts from enemy_intel.Facts: antiNuke (count), aaValue / aaStatic / aaMobile /
--                                    aaDedicated, radars, jammers, ecoValue, ecoStructs, staticDef, t2Units, airFactories
--     ei,                            the enemy_intel module (o.EI) for queries a number cannot carry: RadarCovers(x, z),
--                                    AntiNukeCovers(x, z), EcoTargets(n), Blobs(frame, r), RaidTargets(frame), ArmyCentroid
--     enemyHasAntiNuke, enemyRadar   booleans from facts
--     ecoTargets, blobs              the best 5 eco structures and the enemy ground blobs (only when o.EI is given)
--     spine,                         spine.Status() when the caller passes o.Spine
--     airAlarm, raid, airLosses,     WG.MetalBot fields passed through (nil until published): bombers heading for the base,
--     airRaid, pushMode,            enemy bombers in our half {n, value, rush, ...}; the defend plan's army mode (fsm signals)
--     hunt, scoutWant,               the labs' raid record, own air units shot down, game-won bomber hunt, and the scout /
--     ringRadarWant, callScouts      ring-radar / called-Hawk counts the labs keep;  home / foe = {x, z}, foeDist
--   }
-- Missing sources leave their fields nil/0; nothing here errors on a stub.

local M = {}

local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")

local function Res(team, kind)
    local cur, stor, pull, inc, exp = Spring.GetTeamResources(team, kind)
    cur, stor, pull, inc, exp = cur or 0, stor or 0, pull or 0, inc or 0, exp or 0
    return { cur = cur, stor = stor, pull = pull, income = inc, expense = exp, fill = stor > 0 and cur / stor or 0 }
end

-- o: { team, armyCount, armyValue, armyByDef, Spine }
function M.Collect(frame, o)
    o = o or {}
    local team = o.team or Spring.GetMyTeamID()
    local s = { frame = frame, minute = frame / 1800 }
    s.metal, s.energy = Res(team, "metal"), Res(team, "energy")
    s.floating = s.metal.fill > 0.9 and s.energy.fill > 0.9
    s.stalling = s.metal.fill < 0.05 and s.metal.pull > s.metal.income
    s.units = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(team) or 0
    local ok, cap = pcall(function() return Spring.GetTeamMaxUnits(team) end)   -- returns (max, current)
    s.cap = ok and tonumber(cap) or nil
    s.capFrac = (s.cap and s.cap > 0) and s.units / s.cap or 0
    -- o.MB: the caller's own WG.MetalBot.  In --server single the widgets' WG is a per-team shim that a VFS.Include'd
    -- module does not see, so the global WG.MetalBot read here is empty there.
    local mb = o.MB or CH.MetalBot(WG)
    s.armyCount = o.armyCount or mb.armyCount or 0
    s.armyValue = o.armyValue or mb.armyValue
    s.armyByDef = o.armyByDef
    s.urgency, s.threats = mb.urgency, mb.threats or {}
    s.intel = mb.intel
    s.located = (s.intel and s.intel.located) or false      -- the enemy has been seen at least once (enemy_intel.Located)
    s.enemyAir = s.intel and s.intel.airValue or 0
    s.enemyGround = s.intel and s.intel.groundValue or 0
    local tot = s.enemyAir + s.enemyGround
    s.enemyAirShare = tot > 0 and s.enemyAir / tot or nil
    s.facts = (s.intel and s.intel.facts) or (o.EI and o.EI.Facts and o.EI.Facts(frame)) or {}
    s.enemyHasAntiNuke = (s.facts.antiNuke or 0) > 0
    s.enemyRadar = (s.facts.radars or 0) > 0
    s.ei = o.EI
    if o.EI then
        s.ecoTargets = o.EI.EcoTargets and o.EI.EcoTargets(5) or {}
        s.blobs = o.EI.Blobs and o.EI.Blobs(frame) or {}
    end
    s.spine = o.Spine and o.Spine.Status and o.Spine.Status() or nil
    -- RAID_BOT (published by its unit controller; nil elsewhere):
    --   armyGround / armyAir   value of our armed ground / air units
    --   armyRatio              armyGround / scouted enemy ground value (nil while no enemy ground is known)
    --   trade                  click_army.TradeSummary: { killed, lost, ratio, badEnds, ends } over its window
    --   airKills / airLost     enemy air value killed / own air value lost, last 120 s
    --   airSuperior            our armed air >= 1.5 x the scouted enemy air AND airKills >= airLost
    s.armyGround, s.armyAir = mb.armyGround, mb.armyAir
    if s.armyGround and s.enemyGround > 0 then s.armyRatio = s.armyGround / s.enemyGround end
    s.trade = mb.trade
    -- the rest of WG.MetalBot a hook may want (all nil until the unit controller publishes them)
    s.airAlarm, s.raid, s.airLosses, s.hunt = mb.airAlarm, mb.raid, mb.airLosses, mb.hunt
    s.scoutWant, s.ringRadarWant, s.callScouts = mb.scoutWant, mb.ringRadarWant, mb.callScouts
    s.home = mb.homeX and { x = mb.homeX, z = mb.homeZ } or nil
    s.foe = mb.foeX and { x = mb.foeX, z = mb.foeZ } or nil
    s.foeDist = mb.foeDist
    s.airKills, s.airLost = mb.airKills, mb.airLost
    s.avOwnRate, s.avEnemyRate, s.avProjRatio = mb.avOwnRate, mb.avEnemyRate, mb.avProjRatio   -- av_rates (unit_runtime): army-value derivatives, nil until ~25 s of samples
    s.airRaid, s.pushMode = mb.airRaid, mb.pushMode      -- bombers in our half (unit_runtime AIRDEF); army mode defend | push | raid
    s.armyEffValue, s.armyIdleFrac, s.armyWasted = mb.armyEffValue, mb.armyIdleFrac, mb.armyWasted   -- idle_value (unit_runtime NET.iv)
    if s.armyAir then
        s.airSuperior = s.armyAir > 0 and s.armyAir >= 1.5 * s.enemyAir and (s.airKills or 0) >= (s.airLost or 0)
    end
    return s
end

return M
