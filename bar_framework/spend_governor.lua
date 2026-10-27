-- bar_framework/spend_governor.lua
-- Makes the army share a number that CONTROLS spending (eco bench, 2026-10-09).
--
-- WHY: the spine's army_share only decided how many spine nanos to release for army.  The grids kept spending whatever
-- they could, labs outside the spine kept building their floor units, and capacity was built late, so a bench that asked
-- for 0 / 30 / 80 / 100% got 17 / 28 / 35 / 17% of the metal spent on units.
--
-- WHAT IT DOES (once per second):
--   * Measures where the metal is actually going: for every builder with a target, rate = buildSpeed x current build power
--     x target metalCost / target buildTime.  The target is "army" when it is a mobile non-builder unit, "eco" otherwise
--     (grids, retrofits, spine cells -- infrastructure counts as eco).  realized = army / (army + eco), smoothed.
--   * Share target alpha = spine.Share().
--   * Too much army (realized > alpha + TOL): the spine's demand multiplier ("boost") is lowered.
--   * Too little army (realized < alpha - TOL):
--       - metal is contended (bank under CONTEND_FRAC of storage): the eco pipeline is PAUSED (no new grid cells, grid
--         builders stopped, no retrofits / consolidation) until the army catches up or the bank refills;
--       - the boost is raised, so the spine asks for more nanos / lab time.
--   * Metal floating (bank above FLOAT_FRAC) always un-pauses the eco side: wasting metal is worse than missing the share,
--     and it means the army side is capacity-limited, which the bench reports separately.
--   * alpha == 0: eco never paused, boost reset.
--
-- Used from line_transition (LT.CFG.SHARE_GOV = true); the spine must be on.

local SG = {}

SG.CFG = {
    EVERY        = 30,       -- frames between control ticks
    MEASURE_EVERY = 60,      -- frames between full builder scans (they walk every nano)
    TOL          = 0.05,     -- share error that triggers an action
    CONTEND_FRAC = 0.12,     -- bank / storage under this = metal is contended
    STARVED      = 0.85,     -- army builders pulling under this share of what they could = starved of metal
    FLOAT_FRAC   = 0.35,     -- ... over this = floating
    SMOOTH       = 0.35,     -- EMA weight per scan for the measured rates
    BOOST_MIN    = 0.25, BOOST_MAX = 4.0, BOOST_UP = 1.06, BOOST_DOWN = 0.93,
    LOG_EVERY    = 900,
}

function SG.New(T)
    return { T = T, builders = {}, a = 0, e = 0, realized = nil, boost = 1, paused = false, lastScan = -1e9,
             lastLog = -1e9, pauseFrames = 0, scans = 0 }
end

function SG.OnUnitFinished(G, uid, defID)
    local d = UnitDefs[defID]
    if d and (d.isBuilder or d.isFactory) and (d.buildSpeed or 0) > 0 then G.builders[uid] = defID end
end

function SG.OnUnitDestroyed(G, uid) G.builders[uid] = nil end

local function IsArmyTarget(d)
    return d and d.canMove and not d.isBuilder and not d.isFactory
end

-- -> army m/s, eco m/s being pulled right now
local function Scan(G)
    local a, e, aPot = 0, 0, 0
    local getTarget, getBP = Spring.GetUnitIsBuilding, Spring.GetUnitCurrentBuildPower
    for uid, defID in pairs(G.builders) do
        local t = getTarget(uid)
        if t then
            local td = UnitDefs[Spring.GetUnitDefID(t) or -1]
            local bd = UnitDefs[defID]
            if td and bd and (td.buildTime or 0) > 0 then
                local cur = getBP and getBP(uid) or 1
                local rate = (bd.buildSpeed or 0) * (cur or 1) * (td.metalCost or 0) / td.buildTime
                if IsArmyTarget(td) then
                    a = a + rate
                    aPot = aPot + (bd.buildSpeed or 0) * (td.metalCost or 0) / td.buildTime    -- what it would pull unstarved
                else
                    e = e + rate
                end
            end
        elseif not Spring.GetUnitDefID(uid) then
            G.builders[uid] = nil
        end
    end
    return a, e, aPot
end

local function StopEcoBuilders(T)
    local function stop(id)
        if id and Spring.GetUnitDefID(id) then Spring.GiveOrderToUnit(id, 0, {}, {}) end    -- CMD.STOP
    end
    for _, gs in ipairs(T.gridStates) do stop(gs.builderID); gs.currentTask = nil end
    for _, us in ipairs(T.upgradeStates) do stop(us.builderID); us.currentTask = nil end
    for _, cs in ipairs(T.consolidateJobs) do stop(cs.builderID); cs.currentTask = nil end
end

function SG.Update(G, frame, res)
    local T, K = G.T, SG.CFG
    local spine = T.spineMod
    if not (T.spineOn and spine and spine.Share) then return end
    if frame % K.EVERY ~= 0 then return end
    local alpha = spine.Share()
    -- SHARE_GOV_ALPHA_CAP: the governor never asks for more than this share (the machine's start / attack share is 1.0, which would stop the eco altogether);
    -- SHARE_GOV_MIN_ALPHA: below this share it does nothing (the quiet hold shares are left to the labs' own budget)
    if T.CFG.SHARE_GOV_ALPHA_CAP then alpha = math.min(alpha, T.CFG.SHARE_GOV_ALPHA_CAP) end
    if alpha < (T.CFG.SHARE_GOV_MIN_ALPHA or 0) then alpha = 0 end
    -- SHARE_GOV_ALPHA_FLOOR: the governor always asks for at least this share of ACTUAL spending (user 2026-10-27: 35% actual army spend is what is needed), whatever the machine says
    if T.CFG.SHARE_GOV_ALPHA_FLOOR and alpha < T.CFG.SHARE_GOV_ALPHA_FLOOR then alpha = T.CFG.SHARE_GOV_ALPHA_FLOOR end
    if frame - G.lastScan >= K.MEASURE_EVERY then
        G.lastScan = frame
        local a, e, aPot = Scan(G)
        G.aPot = (G.aPot or 0) * (1 - K.SMOOTH) + aPot * K.SMOOTH
        G.a = G.a * (1 - K.SMOOTH) + a * K.SMOOTH
        G.e = G.e * (1 - K.SMOOTH) + e * K.SMOOTH
        G.scans = G.scans + 1
        local tot = G.a + G.e
        G.realized = tot > 1 and G.a / tot or nil
    end
    local bank = (res.metalStorage or 0) > 0 and res.metal / res.metalStorage or 0
    local wasPaused = G.paused
    if alpha <= 0 then
        G.paused, G.boost, G.hold = false, 1, false
    elseif G.realized then
        local err = G.realized - alpha
        if err > K.TOL then
            G.boost = math.max(K.BOOST_MIN, G.boost * K.BOOST_DOWN)
            G.paused = false
            G.hold = true
        elseif err < -K.TOL then
            G.hold = false
            G.boost = math.min(K.BOOST_MAX, G.boost * K.BOOST_UP)
            -- Pause eco only when the army's builders are starved of metal; if they are not, the army is limited by
            -- capacity (labs / nanos standing) and holding the grids back would only waste the metal.
            if bank <= K.CONTEND_FRAC and G.a < K.STARVED * (G.aPot or 0) then G.paused = true end
        else
            G.paused = G.paused and bank <= K.FLOAT_FRAC
        end
        if bank > K.FLOAT_FRAC then G.paused = false end
    end
    if spine.SetBoost then spine.SetBoost(G.boost) end
    if spine.SetHold then spine.SetHold(G.hold) end
    T.ecoPaused = G.paused
    if G.paused then G.pauseFrames = G.pauseFrames + K.EVERY end
    if G.paused and not wasPaused then StopEcoBuilders(T) end
    if frame % 150 == 0 then
        Spring.Echo(string.format("[TRK] sg frame=%d team=%d alpha=%.2f realized=%.3f army=%.1f eco=%.1f boost=%.2f paused=%d",
            frame, T.teamID or 0, alpha, G.realized or -1, G.a, G.e, G.boost, G.paused and 1 or 0))
    end
    if frame - G.lastLog >= K.LOG_EVERY then
        G.lastLog = frame
        Spring.Echo(string.format("[SG] %d:%02d alpha=%.0f%% realized=%s army=%.0f eco=%.0f m/s boost=%.2f bank=%.0f%% %s",
            math.floor(frame / 1800), math.floor(frame / 30) % 60, alpha * 100,
            G.realized and string.format("%.0f%%", G.realized * 100) or "-", G.a, G.e, G.boost, bank * 100,
            G.paused and "ECO PAUSED" or ""))
    end
end

return SG
