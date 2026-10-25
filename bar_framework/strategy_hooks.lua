-- bar_framework/strategy_hooks.lua
-- Ready-made hooks for strategy.lua (army_share / weights / switch).  A hook is `function(state, strat)`; these are
-- factories that return one, so a bot picks and tunes them in its config instead of writing code.

local M = {}

-- The army share spine.lua's policies gave LINE_CLICK_v16: nothing before `start`, `floor` after, lifted to the
-- threat level while the unit controller sees one (held `hold` frames after the last sighting), 1 near the unit cap.
function M.v16_share(o)
    o = o or {}
    local start, floor, hold = o.start or 5400, o.floor or 0.20, o.hold or 900
    local rush, build, seen = o.rush or 1.0, o.build or 0.6, o.seen or 0.5
    local capSlack = o.cap_slack or 150
    local level, lastF = 0, -1e9
    return function(state)
        local f = state.frame or 0
        local share = f < start and 0 or floor
        local sig = 0
        if state.urgency == "rush" then sig = rush
        elseif state.urgency == "build" then sig = build
        elseif #(state.threats or {}) > 0 then sig = seen end
        if sig > 0 then
            if sig >= level or f - lastF > hold then level = sig end
            lastF = f
        elseif f - lastF > hold then
            level = 0
        end
        share = math.max(share, level)
        if state.cap and state.units and (state.cap - state.units) <= capSlack then share = 1 end
        return share
    end
end

-- Rough metal value of the army a competent opponent has by game minute (linear between points); only used, scaled by
-- `expect`, as a floor under what we have scouted, so an unscouted enemy is not read as no enemy.
local EXPECTED_ENEMY = { {3, 300}, {5, 1500}, {8, 5000}, {12, 14000}, {20, 40000}, {30, 90000} }
local function ExpectedEnemy(minute)
    local pts = EXPECTED_ENEMY
    if minute <= pts[1][1] then return pts[1][2] * minute / pts[1][1] end
    for i = 2, #pts do
        if minute <= pts[i][1] then
            local a, b = pts[i - 1], pts[i]
            return a[2] + (b[2] - a[2]) * (minute - a[1]) / (b[1] - a[1])
        end
    end
    return pts[#pts][2]
end

-- v16_share (without its threat lifts) plus a "keep up with the enemy" rule, for games against people (two bots using it would chase each other's
-- share up).  From `start` the share rises as our army value (state.armyValue) falls short of
-- ratio x max(scouted enemy army value, expect x the time curve): base + shortfall / (income x horizon), so 1.0 once we are a
-- minute of income short, back to the base once we match.  Metal and energy both floating -> 1.0 (spend it all).  Smoothed: it rises at once, falls at `fall`/s.
--   o.ratio 1.1, o.expect 0.5, o.horizon 60 (s of income), o.lead 1.5 + o.ahead_floor 0.05 (share when ahead), o.fall 0.02, o.float 0.9 (fill), o.log true; the rest goes to v16_share.
function M.match_enemy(o)
    o = o or {}
    local base0 = M.v16_share(o)
    -- Threat sightings do not lift the share here (v16_share raises it to 0.5-1.0 on any contact): with the slot spine a
    -- share of 1 sizes nanos for all of income, which starved the mex grids while our army was already ahead.  Being
    -- behind the scouted enemy lifts it below; raids are answered by the lab controller's defence floor, not the share.
    local function base(state)
        local st = setmetatable({ urgency = "none", threats = {} }, { __index = state })
        return base0(st)
    end
    local ratio, expect, fall, floatFill = o.ratio or 1.1, o.expect or 0.5, o.fall or 0.02, o.float or 0.9
    local lead, aheadFloor = o.lead or 1.5, o.ahead_floor or 0.05   -- army >= lead x target -> share ahead_floor
    local horizon = o.horizon or 60     -- seconds of income that a shortfall may cost before the share is 1
    local start = o.start or 5400
    local cur, lastLog = 0, -1e9
    return function(state)
        local f = state.frame or 0
        local share = base(state)
        if f >= start and state.armyValue then
            local known = (state.enemyGround or 0) + (state.enemyAir or 0)
            local enemy = math.max(known, expect * ExpectedEnemy(f / 1800))
            local target = ratio * enemy
            -- the shortfall in seconds of income: a 165-metal gap at 3:00 (income ~40) is a few seconds of eco, not "no army"
            local want = 0
            local inc = math.max((state.metal and state.metal.income) or 0, 20)
            if target > state.armyValue then
                want = math.min(1, share + (target - state.armyValue) / (inc * horizon))
            elseif state.armyValue >= lead * target and share <= (o.floor or 0.20) + 1e-9 then
                share = aheadFloor      -- well ahead of what we have scouted: eco gets the rest
            end
            if state.metal and state.energy and state.metal.fill >= floatFill and state.energy.fill >= floatFill then
                want = 1
            end
            cur = want >= cur and want or math.max(want, cur - fall)
            share = math.max(share, cur)
            if o.log ~= false and f - lastLog >= 300 then
                lastLog = f
                Spring.Echo(string.format("[SHARE] f=%d own=%.0f enemy=%.0f (known %.0f) target=%.0f share=%.2f",
                    f, state.armyValue, enemy, known, target, share))
            end
        end
        return share
    end
end

-- Tilt the mix toward anti-air once enemy air shows up: unit names in `aa` are multiplied by `mult` while the enemy's
-- air value is at least `frac` of what we know of its army.
function M.aa_weights(o)
    local aa, frac, mult = o.aa or {}, o.frac or 0.25, o.mult or 3
    return function(state)
        if (state.enemyAirShare or 0) < frac then return nil end
        local w = {}
        for _, n in ipairs(aa) do w[n] = mult end
        return w
    end
end

-- switch hook: once the unit cap is filling (capFrac >= cap_frac, not before `minute`), take the stance `late` for the rest of the game.
-- With the cap nearly full every slot should hold the most value (bigger, costlier units: stances/Late_game.lua), not cheap T1 bodies.
--   hooks = { switch = H.cap_switch{ late = "Late_game", cap_frac = 0.75, minute = 12 } }   (the stance must be in strategy.stances)
function M.cap_switch(o)
    o = o or {}
    local late, capFrac, minute = o.late or "Late_game", o.cap_frac or 0.75, o.minute or 12
    local on = false
    return function(state)
        if not on and (state.minute or 0) >= minute and (state.capFrac or 0) >= capFrac then
            on = true
            Spring.Echo(string.format("[STRAT] unit cap %.0f%% full at %.1f min: switching to stance %s",
                100 * (state.capFrac or 0), state.minute or 0, late))
        end
        if on then return late end
    end
end

-- switch hook (DRAGON_ECO, user 2026-10-14): once metal income has held at `income` m/s or more for `hold_s` seconds, take the
-- stance `to` for the rest of the game.  The income is smoothed (EMA, `smooth` per call; strategy ticks once a second).
--   hooks = { switch = H.income_switch{ to = "mammoth_hold", income = 1100, hold_s = 20 } }
function M.income_switch(o)
    o = o or {}
    local to, income, holdF, smooth = o.to, o.income or 1100, (o.hold_s or 20) * 30, o.smooth or 0.2
    local on, ema, since = false, nil, nil
    return function(state)
        if on then return to end
        local inc = (state.metal and state.metal.income) or 0
        ema = ema and (ema + smooth * (inc - ema)) or inc
        local f = state.frame or 0
        if ema >= income then
            since = since or f
            if f - since >= holdF then
                on = true
                Spring.Echo(string.format("[STRAT] metal income %.0f >= %d for %d s at %.1f min: switching to stance %s",
                    ema, income, holdF / 30, state.minute or f / 1800, tostring(to)))
                return to
            end
        else
            since = nil
        end
    end
end

-- switch hook (HAMMER_ANVIL, 2026-10-25): a one-off burst.  Nothing (the current stance stays) until smoothed metal income has
-- held `income` for `hold_s` seconds and the minute is at least `minute`; then the stance `to` until the army value has risen by
-- `spend` metal since the burst began (state.armyValue, its highest rise) or `burst_s` seconds have passed; then the stance `back`
-- for the rest of the game.  Spend, not time, ends it: the burst's labs are often not standing yet when it starts (eco_sim: the
-- spine's air labs stood 60-75 s into a 90 s window).  The user's T1_bombing_run intent: "spend a lot quickly and then go back
-- into eco".  The burst's army share comes from its stance (plan.share, strategy.lua), not from here.
-- With unit + count it ends once `count` of `unit` are alive instead (spend is then not used).
--   hooks = { switch = H.burst_switch{ to = "anvil_burst", back = "anvil_hold", income = 250, hold_s = 20, unit = "corshad", count = 30, burst_s = 300 } }
function M.burst_switch(o)
    o = o or {}
    local to, back = o.to, o.back
    local income, holdF, smooth = o.income or 250, (o.hold_s or 20) * 30, o.smooth or 0.2
    local burstF, minute, spend = (o.burst_s or 240) * 30, o.minute or 0, o.spend
    -- unit + count (HAMMER_ANVIL: 30 Shadows): the burst ends once that many of the unit are alive -- the burst's own units, not
    -- the whole army (by army value the ground army's growth ended the first burst after 48 s).  o.count_fn(state) -> n for tests.
    local countFn = o.count_fn
    if not countFn and o.unit then
        countFn = function(state)
            local ud = UnitDefNames and UnitDefNames[o.unit]
            local team = state.team or (Spring.GetMyTeamID and Spring.GetMyTeamID())
            return (ud and team and Spring.GetTeamUnitDefCount and Spring.GetTeamUnitDefCount(team, ud.id)) or 0
        end
    end
    local phase, ema, since, startF, startAV, rise = "wait", nil, nil, nil, nil, 0
    return function(state)
        local f = state.frame or 0
        if phase == "wait" then
            local inc = (state.metal and state.metal.income) or 0
            ema = ema and (ema + smooth * (inc - ema)) or inc
            if ema >= income and (state.minute or f / 1800) >= minute then
                since = since or f
                if f - since >= holdF then
                    phase, startF, startAV = "burst", f, state.armyValue or 0
                    Spring.Echo(string.format("[STRAT] burst: metal income %.0f >= %d for %d s at %.1f min: stance %s (spend %s, at most %d s)",
                        ema, income, holdF / 30, state.minute or f / 1800, tostring(to), tostring(spend), burstF / 30))
                end
            else
                since = nil
            end
        end
        if phase == "burst" then
            rise = math.max(rise, (state.armyValue or startAV) - startAV)
            local n = countFn and o.count and countFn(state) or nil
            if (n and n >= o.count) or (not countFn and spend and rise >= spend) or f - startF >= burstF then
                phase = "done"
                Spring.Echo(string.format("[STRAT] burst over at %.1f min after %d s, army value +%.0f, %s %s: stance %s",
                    state.minute or f / 1800, math.floor((f - startF) / 30), rise, tostring(n or "-"), tostring(o.unit or ""), tostring(back)))
            end
        end
        if phase == "burst" then return to end
        if phase == "done" then return back end
    end
end

-- Several switch hooks in order: the first that names a stance wins (put cap_switch first -- once on, it holds).
function M.chain_switch(list)
    return function(state, strat)
        for _, h in ipairs(list) do
            local name = h(state, strat)
            if name then return name end
        end
    end
end

-- switch hook (RAID_BOT, game review 2026-10-13): change the game plan from the game state.
--   raid -> hold  our ground army is under hold_ratio x the scouted enemy ground (state.armyRatio) AND the raids trade badly:
--                 killed < trade_ratio x lost with at least min_lost lost, or the last bad_ends groups were spent killing
--                 little (state.trade from click_army.TradeSummary).  At 9:30 in that game: ratio 0.81, 0 kills / 1484 lost.
--   hold -> raid  armyRatio >= resume_ratio for resume_for frames.
-- At least min_stay frames in a plan before switching again.  Needs state.armyRatio / state.trade (nil = no switch).
function M.game_plan(o)
    o = o or {}
    local raid, hold = o.raid or "raid_open", o.hold or "hold"
    local holdRatio, tradeRatio = o.hold_ratio or 0.85, o.trade_ratio or 0.5
    local minLost, badEnds = o.min_lost or 1000, o.bad_ends or 2
    local resumeRatio, resumeFor = o.resume_ratio or 1.4, o.resume_for or 1800
    local minStay = o.min_stay or 2700
    local cur, since, goodF = raid, -1e9, nil
    local function Log(f, from, to, state, why)
        local s = math.floor(f / 30)
        local t = state.trade or {}
        Spring.Echo(string.format("[PLAN] %d:%02d %s -> %s: %s | army ratio %.2f (own ground %.0f vs enemy %.0f), trade %.0f/%.0f (%d bad ends), air superior %s",
            math.floor(s / 60), s % 60, from, to, why, state.armyRatio or -1, state.armyGround or 0, state.enemyGround or 0,
            t.killed or 0, t.lost or 0, t.badEnds or 0, tostring(state.airSuperior)))
    end
    return function(state)
        local f = state.frame or 0
        local ratio, t = state.armyRatio, state.trade
        if cur == hold then
            if ratio and ratio >= resumeRatio then goodF = goodF or f else goodF = nil end
        end
        if f - since >= minStay then
            if cur == raid then
                local bad = t and ((t.lost >= minLost and t.ratio < tradeRatio) or (t.badEnds or 0) >= badEnds)
                if ratio and ratio < holdRatio and bad then
                    Log(f, raid, hold, state, "behind and the raids are trading badly")
                    cur, since, goodF = hold, f, nil
                end
            elseif goodF and f - goodF >= resumeFor then
                Log(f, hold, raid, state, string.format("ahead for %ds", math.floor((f - goodF) / 30)))
                cur, since, goodF = raid, f, nil
            end
        end
        return cur
    end
end

-- weights hook: units tagged "mass" (cheap bodies, so the army can spread) get most of the share at low income and little at
-- high income; units tagged "quality" (the most cost-effective heavies) the other way round.  Linear in metal income from
-- lo to hi; untagged units keep weight 1.  Weights are renormalised by the stance loader.  nil when the stance has no tags.
--   o.lo 150, o.hi 1000 (m/s), o.mass_lo 2.0, o.mass_hi 0.3, o.quality_lo 0.5, o.quality_hi 2.0
function M.income_mix(o)
    o = o or {}
    local lo, hi = o.lo or 150, o.hi or 1000
    local massLo, massHi = o.mass_lo or 2.0, o.mass_hi or 0.3
    local qLo, qHi = o.quality_lo or 0.5, o.quality_hi or 2.0
    return function(state, strat)
        local st = strat and strat.Stance and strat:Stance()
        if not st then return nil end
        local inc = (state.metal and state.metal.income) or 0
        local k = math.max(0, math.min(1, (inc - lo) / (hi - lo)))
        local w, any = {}, false
        for _, u in ipairs(st.units) do
            if u.tag == "mass" then w[u.n] = massLo + (massHi - massLo) * k; any = true
            elseif u.tag == "quality" then w[u.n] = qLo + (qHi - qLo) * k; any = true end
        end
        return any and w or nil
    end
end

return M
