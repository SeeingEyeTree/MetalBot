-- bar_framework/signals.lua
-- The named facts a state machine (fsm.lua, machines/*.lua) may test.  Every signal is { name, type, doc, unit, fn(state) -> value }.
-- `state` is the table game_state.Collect builds (once a second).  A signal whose source is not known yet returns nil, and a test
-- on nil is false (so `army_ratio > 1.4` is false while no enemy army is known; `not (army_ratio > 1.4)` is then true).
-- The two machines also see each other through the extra signals the Bundle (fsm.lua) adds: stance, stance_age_s, stance_army,
-- stance_plan_share, share, share_node, share_age_s -- listed in M.CROSS below so the editor shows them too.
-- Pure data + small functions with no includes: fsm_index.py loads this file to give the editor its signal list.
--
-- Add a signal: one line in M.list.  The editor picks it up after `python fsm_index.py`.

local M = {}

local function Tr(s) return s.trade or {} end
local function EnemyValue(s) return (s.enemyGround or 0) + (s.enemyAir or 0) end
local function Intel(s) return s.intel or {} end
local function Raid(s) return s.airRaid end

-- type: "number" | "bool" | "string"
M.list = {
    -- time and economy
    { "minute",          "number", "game time", "min", function(s) return s.minute end },
    { "metal_income",    "number", "metal income", "m/s", function(s) return s.metal and s.metal.income end },
    { "energy_income",   "number", "energy income", "e/s", function(s) return s.energy and s.energy.income end },
    { "metal_fill",      "number", "metal bank, 0..1 of storage", "", function(s) return s.metal and s.metal.fill end },
    { "energy_fill",     "number", "energy bank, 0..1 of storage", "", function(s) return s.energy and s.energy.fill end },
    { "floating",        "bool",   "both banks above 90% (resources are not being spent)", "", function(s) return s.floating end },
    { "stalling",        "bool",   "metal bank empty while pull exceeds income", "", function(s) return s.stalling end },
    { "cap_frac",        "number", "own units / unit cap", "", function(s) return s.capFrac end },
    -- our army
    { "army_value",      "number", "metal value of our combat units (incl. ground AA, Dragons)", "metal", function(s) return s.armyValue end },
    { "army_count",      "number", "number of combat units", "", function(s) return s.armyCount end },
    { "army_ground",     "number", "value of our armed ground units", "metal", function(s) return s.armyGround end },
    { "army_air",        "number", "value of our armed air units", "metal", function(s) return s.armyAir end },
    -- idle value (user 2026-10-29; bar_framework/idle_value.lua): a unit not within 15 s of a comparable amount of enemy value is idle, and an
    -- idle unit's worth decays with an 80 s time constant
    { "army_idle_frac",  "number", "share of our army value that is idle (no comparable enemy value within 15 s of travel)", "", function(s) return s.armyIdleFrac end },
    { "army_value_eff",  "number", "our army value with idle units' worth decayed (80 s time constant)", "metal", function(s) return s.armyEffValue end },
    { "army_wasted",     "number", "army value lost to idling so far (cumulative)", "metal", function(s) return s.armyWasted end },
    -- the enemy as scouted
    { "enemy_located",   "bool",   "an enemy unit has been seen at least once", "", function(s) return s.located end },
    { "enemy_ground",    "number", "scouted enemy ground army value", "metal", function(s) return s.enemyGround end },
    { "enemy_air",       "number", "scouted enemy air army value", "metal", function(s) return s.enemyAir end },
    { "enemy_value",     "number", "scouted enemy army value (ground + air)", "metal", function(s) return EnemyValue(s) end },
    { "enemy_air_share", "number", "enemy air / (air + ground), nil if nothing known", "", function(s) return s.enemyAirShare end },
    { "army_ratio",      "number", "our ground value / scouted enemy ground value (nil while none known)", "", function(s) return s.armyRatio end },
    { "enemy_vs_army",   "number", "scouted enemy value / our army value (nil until the enemy is located)",  "",
      function(s) local own = s.armyValue; if s.located and own and own > 0 then return EnemyValue(s) / own end end },
    { "enemy_known_units","number", "enemy units seen so far (how good the scouting is)", "", function(s) return Intel(s).known end },
    { "enemy_scouted",   "bool",   "a good scout: the enemy is located and >= 12 of its units were seen", "", function(s) return s.located == true and (Intel(s).known or 0) >= 12 end },
    { "enemy_labs",      "number", "scouted enemy factories", "", function(s) return Intel(s).labs end },
    { "enemy_air_labs",  "number", "scouted enemy air factories", "", function(s) return Intel(s).airLabs end },
    { "enemy_t2_labs",   "number", "scouted enemy T2 factories", "", function(s) return Intel(s).t2Labs end },
    { "enemy_silos",     "number", "scouted enemy nuke silos", "", function(s) return Intel(s).silos end },
    { "enemy_antinuke",  "bool",   "enemy has an anti-nuke", "", function(s) return s.enemyHasAntiNuke end },
    { "enemy_radar",     "bool",   "enemy has radar", "", function(s) return s.enemyRadar end },
    -- user 2026-10-29 (the BM_akumar6 game: an 11x army "lead" while the enemy had 3.5x our income in mexes, towers and a T3 gantry): what the
    -- enemy put its metal into besides its army.  Mex yields are Full Metal Plate's (knowledge/economy_numbers.md: T1 2.37, T2 9.48 m/s);
    -- only scouted mexes count, so the income is a LOWER bound and eco_ratio an upper one
    { "enemy_def",       "number", "scouted enemy static defence value (towers, flak, artillery)", "metal", function(s) return s.facts and s.facts.staticDef or 0 end },
    { "enemy_mexes",     "number", "scouted enemy metal extractors (T1 + T2)", "", function(s) local f = s.facts or {}; return (f.mexes or 0) + (f.mexesT2 or 0) end },
    { "enemy_income_est","number", "enemy metal income estimated from the scouted mexes (a lower bound; nil while none seen)", "m/s",
      function(s) local f = s.facts or {}; local n1, n2 = f.mexes or 0, f.mexesT2 or 0
          if n1 + n2 == 0 then return nil end
          return n1 * 2.37 + n2 * 9.48 end },
    { "eco_ratio",       "number", "our metal income / enemy_income_est (nil while no enemy mex is seen; an upper bound)", "",
      function(s) local f = s.facts or {}; local e = (f.mexes or 0) * 2.37 + (f.mexesT2 or 0) * 9.48
          local inc = s.metal and s.metal.income
          if e <= 0 or not inc then return nil end
          return inc / e end },
    -- army-value derivatives (av_rates.lua; nil until ~25 s of samples)
    { "own_av_rate",     "number", "d(our ground army value)/dt over ~60 s (net of losses)", "m/s", function(s) return s.avOwnRate end },
    { "enemy_av_rate",   "number", "rough enemy reinforcement rate: d(scouted enemy ground value)/dt + what we killed, ~60 s", "m/s", function(s) return s.avEnemyRate end },
    { "proj_ratio",      "number", "our ground / enemy ground value 60 s ahead, each projected with its own rate (nil without rates or a scouted enemy)", "",
      function(s) return s.avProjRatio end },
    -- fights
    { "trade_killed",    "number", "enemy value our raids killed (click_army trade window)", "metal", function(s) return Tr(s).killed end },
    { "trade_lost",      "number", "own value the raids lost (same window)", "metal", function(s) return Tr(s).lost end },
    { "trade_ratio",     "number", "killed / lost over the window (nil until something was lost)", "", function(s) return s.trade and s.trade.ratio end },
    { "bad_ends",        "number", "raid groups spent killing little, recently", "", function(s) return Tr(s).badEnds end },
    { "bad_trade",       "bool",   "the raids trade badly: lost >= 1000 and killed < 0.5 x lost, or 2+ bad group ends (game_plan's rule)", "",
      function(s) local t = s.trade; if not t then return nil end
          return ((t.lost or 0) >= 1000 and (t.ratio or 1) < 0.5) or (t.badEnds or 0) >= 2 end },
    -- air
    { "air_superior",    "bool",   "our air >= 1.5 x scouted enemy air and air kills >= air lost", "", function(s) return s.airSuperior end },
    { "air_alarm",       "bool",   "bombers are heading for the base (air alarm)", "", function(s) return s.airAlarm ~= nil end },
    { "air_raid",        "bool",   "enemy bombers seen in our half of the map", "", function(s) local r = Raid(s); return r ~= nil and (r.n or 0) > 0 end },
    { "air_raid_rush",   "bool",   "a LARGE air raid is on (built-in rule: labs flush queues for AA, share 1.0)", "", function(s) local r = Raid(s); return r ~= nil and r.rush == true end },
    { "air_raid_bombers","number", "bombers counted in the current air raid", "", function(s) local r = Raid(s); return r and r.n or 0 end },
    { "air_lost",        "number", "own air value lost, last 120 s", "metal", function(s) return s.airLost end },
    { "air_kills",       "number", "enemy air value killed, last 120 s", "metal", function(s) return s.airKills end },
    -- attacks on us (raid_response's intruder groups inside our territory, held 10 s).  With raid_response THREAT_HOME the value is the record's `home`:
    -- only groups near the eco footprint, scouts at SCOUT_WEIGHT (user 2026-10-29: Rovers on our half held the share at 1.0 and recalled every raid)
    { "enemy_near_base", "number", "value of enemy groups inside our territory right now (near the spine's build power); 0 when none", "metal",
      function(s) local r = s.raid; if r and (s.frame or 0) - (r.frame or -1e9) <= 300 then return r.home or r.value or 0 end return 0 end },
    { "under_attack",    "bool",   "a REAL attack on us: enemy groups worth >= 800 inside our territory within the last 10 s", "",
      function(s) local r = s.raid; return r ~= nil and (s.frame or 0) - (r.frame or -1e9) <= 300 and (r.home or r.value or 0) >= 800 end },
    -- ground raids / urgency
    { "raid_active",     "bool",   "an enemy ground/air raid group is at our base (raid_response record)", "", function(s) return s.raid ~= nil end },
    { "raid_value",      "number", "value of the raid at the base", "metal", function(s) return s.raid and s.raid.value or 0 end },
    { "urgency",         "string", "production urgency: none | build | rush", "", function(s) return s.urgency end },
    { "threats",         "number", "intruder clusters in our territory", "", function(s) return s.threats and #s.threats or 0 end },
    { "hunt",            "bool",   "the game is won; bombers hunt the commander", "", function(s) return s.hunt end },
    -- army mode (unit_runtime ArmyMode, published as mb.pushMode)
    { "push_mode",       "string", "army mode of a defend plan: defend | push | raid", "", function(s) return s.pushMode end },
}

-- Extra signals the Bundle (fsm.lua) provides so the stance and share machines can read each other.
M.CROSS = {
    { "stance",            "string", "current stance (the stance machine's node's stance)", "", true },
    { "stance_age_s",      "number", "seconds in the current stance", "s", true },
    { "stance_army",       "string", "the current stance's plan.army (raid | hold | defend | ...)", "", true },
    { "stance_plan_share", "number", "the current stance's plan.share floor (0 if none)", "", true },
    { "share",             "number", "current army share, 0..1 (the share machine's output)", "", true },
    { "share_node",        "string", "current share-machine node", "", true },
    { "share_age_s",       "number", "seconds in the current share node", "s", true },
}

M.byName = {}
for _, r in ipairs(M.list) do
    M.byName[r[1]] = { name = r[1], type = r[2], doc = r[3], unit = r[4], fn = r[5] }
end
for _, r in ipairs(M.CROSS) do
    M.byName[r[1]] = { name = r[1], type = r[2], doc = r[3], unit = r[4], cross = true }
end

-- value of one named signal from a game_state table (nil when unknown or the fn errors)
function M.Get(name, state)
    local sg = M.byName[name]
    if not sg or not sg.fn then return nil end
    local ok, v = pcall(sg.fn, state)
    if ok then return v end
    return nil
end

function M.Known(name) return M.byName[name] ~= nil end

return M
