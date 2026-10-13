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
--   }
-- Missing sources leave their fields nil/0; nothing here errors on a stub.

local M = {}

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
    local mb = o.MB or (WG and WG.MetalBot) or {}
    s.armyCount = o.armyCount or mb.armyCount or 0
    s.armyValue = o.armyValue or mb.armyValue
    s.armyByDef = o.armyByDef
    s.urgency, s.threats = mb.urgency, mb.threats or {}
    s.intel = mb.intel
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
    return s
end

return M
