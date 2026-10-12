-- bar_framework/eco_planner.lua
-- Look-ahead for grid builders: what to build NEXT -- a mex, a wind or a nano -- found by simulating the economy.
--
-- The economy here is linear and deterministic (no randomness but the wind), so instead of threshold rules it is
-- simulated: for each split of the team's useful build power between mex / wind / nano (steps of 0.2), roll the next
-- HORIZON seconds forward with the real unit costs (metal, energy, build time from UnitDefs):
--   * build power spends  cost / buildTime  per build-power-second, scaled down when the bank cannot pay (a stall),
--   * mexes add metal income but draw energy upkeep (their output falls with the energy shortage),
--   * winds add energy income, nanos add build power.
-- The score of a split is  metal bank at the end + TAIL x metal income at the end  (floating metal is worth only its
-- face value, invested metal is worth its income).  The best split gives shares a_mex, a_wind, a_nano; each builder's
-- next item is the class furthest below its best share (decayed count of recent picks), among classes it still has
-- items for.  So: metal-starved with spare build power -> mexes (and the winds that carry them); energy-starved ->
-- winds; money piling up unspent -> nanos, because only then does build power limit the next HORIZON seconds.
--
-- Constants measured per game: income per mex and per wind (from the team's own income / counts).
-- PLAN_EFF is the share of the team's nominal build power that actually works on grid items (assist range, travel,
-- idle cons); it is the one number to tune on the bench.

local P = {}

P.CFG = {
    HORIZON = 90, DT = 3, TAIL = 120, STEP = 0.1, RESERVE_S = 20, SPEND_PER_BP = 0.045, SPEND_W = 1.0,
    NANO_SHARES = { 0, 0.02, 0.05, 0.1, 0.2, 0.35 },
    EFF = 0.30,                 -- useful share of nominal build power
    HALF_LIFE = 12,             -- seconds: memory of recent picks
    REPLAN_FRAMES = 30,
    LOG_EVERY = 450,
}

local spGetTeamUnitsByDefs = Spring.GetTeamUnitsByDefs
local spGetTeamUnits       = Spring.GetTeamUnits

function P.New(teamID, cfg)
    local S = { teamID = teamID, cfg = {}, planFrame = -1e9, bpFrame = -1e9, bp = 0,
                recent = { energy = 0, metal = 0, nano = 0 }, recentFrame = 0,
                a = { metal = 0.6, energy = 0.4, nano = 0 }, info = "" }
    for k, v in pairs(P.CFG) do S.cfg[k] = v end
    for k, v in pairs(cfg or {}) do S.cfg[k] = v end
    local function def(name) return UnitDefNames[name] end
    local mex, wind, nano = def("cormex"), def("corwin"), def("cornanotc")
    S.ok = mex and wind and nano
    if S.ok then
        S.ids = { metal = mex.id, energy = wind.id, nano = nano.id }
        S.cost = {}
        for cls, d in pairs({ metal = mex, energy = wind, nano = nano }) do
            S.cost[cls] = { m = d.metalCost or 0, e = d.energyCost or 0, t = math.max(d.buildTime or 1, 1) }
        end
        S.uMex = mex.energyUpkeep or 3
        S.bpNano = nano.buildSpeed or 200
    end
    return S
end

local function Count(S, cls)
    local l = spGetTeamUnitsByDefs and spGetTeamUnitsByDefs(S.teamID, { S.ids[cls] })
    return l and #l or 0
end

-- Nominal build power: every builder that is not a factory (cons, nanos, commander).
local function TotalBP(S, frame)
    if frame - S.bpFrame < 90 then return S.bp end
    S.bpFrame = frame
    local bp = 0
    for _, uid in ipairs(spGetTeamUnits(S.teamID) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and d.isBuilder and not d.isFactory and (d.buildSpeed or 0) > 0 and not Spring.GetUnitIsBeingBuilt(uid) then
            bp = bp + d.buildSpeed
        end
    end
    S.bp = bp
    return bp
end

-- One rollout.  a = {metal=, energy=, nano=} shares of useful build power.
local function Rollout(S, st, a)
    local cfg = S.cfg
    local M, E = st.M, st.E
    local nm, nw, nnew = st.nm, st.nw, 0
    local dt = cfg.DT
    local spendM, spendE
    local built = { metal = 0, energy = 0, nano = 0 }
    local Im, sat = 0, 1
    for _ = 1, math.floor(cfg.HORIZON / dt) do
        local cap = (st.bp + nnew * S.bpNano) * st.eff       -- build-power-seconds per second
        local items = {}
        spendM, spendE = 0, 0
        for cls, share in pairs(a) do
            local c = S.cost[cls]
            local rate = cap * share / c.t                     -- items per second at full supply
            if st.supply and st.supply[cls] and (built[cls] or 0) >= st.supply[cls] then rate = 0 end   -- nothing left to place
            items[cls] = rate
            spendM = spendM + rate * c.m
            spendE = spendE + rate * c.e
        end
        Im = st.baseM + nm * st.ym * sat
        local Ie = st.baseE + nw * st.yw
        local upkeep = nm * S.uMex
        local sM = (spendM > 0) and math.min(1, (M + Im * dt) / (spendM * dt)) or 1
        local sE = (spendE > 0) and math.min(1, math.max(E + (Ie - upkeep) * dt, 0) / (spendE * dt)) or 1
        local s = math.min(sM, sE)
        M = math.min(st.mCap, math.max(M + (Im - spendM * s) * dt, 0))
        E = math.min(st.eCap, E + (Ie - upkeep - spendE * s) * dt)
        if E < 0 then E = 0 end
        for cls, r in pairs(items) do built[cls] = built[cls] + r * s * dt end
        nm = nm + items.metal * s * dt
        nw = nw + items.energy * s * dt
        nnew = nnew + items.nano * s * dt
        -- energy shortage throttles the mexes (upkeep not met) once the energy bank is empty
        if E <= 1 and Ie < nm * S.uMex then sat = math.max(0.1, Ie / math.max(nm * S.uMex, 1e-3)) else sat = 1 end
    end
    -- Metal above a reserve (RESERVE_S seconds of income) is floating: it is worth nothing until something spends it.
    local Imend = st.baseM + nm * st.ym * sat
    -- Income only counts as far as the build power can spend it (SPEND_PER_BP metal per build-power-second, ~ a T1 army
    -- unit's cost / build time): W weights the spendable part on top of the income itself.
    local spendable = math.min(Imend, (st.bp + nnew * S.bpNano) * st.eff * cfg.SPEND_PER_BP)
    return math.min(M, cfg.RESERVE_S * Imend) + cfg.TAIL * (Imend + cfg.SPEND_W * spendable)
end

function P.Plan(S, res, frame)
    if not S.ok or frame - S.planFrame < S.cfg.REPLAN_FRAMES then return S.a end
    S.planFrame = frame
    local nm, nw = Count(S, "metal"), Count(S, "energy")
    local mi = res.metalIncomeS or res.metalIncome or 0
    local ei = res.energyIncomeS or res.energyIncome or 0
    local st = { M = res.metal or 0, E = res.energy or 0, mCap = res.metalStorage or 1e9, eCap = res.energyStorage or 1e9,
                 nm = nm, nw = nw, baseM = 2, baseE = 30, bp = TotalBP(S, frame) }
    st.ym = (nm >= 4) and math.max(1, math.min(6, (mi - st.baseM) / nm)) or 2.0
    st.yw = (nw >= 8) and math.max(5, math.min(40, (ei - st.baseE) / nw)) or 20
    -- Calibrate EFF from what the builders actually ask for: the measured energy pull (less mex upkeep) over the
    -- energy a build-power-second of the recent mix costs.  Capacity is then whatever draws the energy we see.
    if S.cfg.CALIBRATE ~= false and st.bp > 0 then
        local ep = res.energyPullS or res.energyPull or 0
        local drain = math.max(0, ep - nm * S.uMex)
        local tot = S.recent.metal + S.recent.energy + S.recent.nano
        local perBP = 0
        for cls, c in pairs(S.cost) do
            local w = (tot > 0) and (S.recent[cls] / tot) or (1 / 3)
            perBP = perBP + w * c.e / c.t
        end
        if perBP > 0 then
            local obs = math.max(0.03, math.min(1, drain / (st.bp * perBP)))
            S.eff = S.eff and (S.eff + 0.2 * (obs - S.eff)) or obs
        end
    end
    st.eff = S.eff or S.cfg.EFF
    st.supply = S.supplyFn and S.supplyFn() or nil
    local best, bestV = S.a, -1e18
    local step = S.cfg.STEP
    local n = math.floor(1 / step + 0.5)
    for _, ns in ipairs(S.cfg.NANO_SHARES) do
        local rest = 1 - ns
        for i = 0, n do
            local mexShare = rest * i / n
            local a = { metal = mexShare, energy = rest - mexShare, nano = ns }
            local v = Rollout(S, st, a)
            if v > bestV then best, bestV = a, v end
        end
    end
    S.a = best
    S.info = string.format("plan mex %.1f wind %.1f nano %.1f (score %.0f) | mex %d wind %d bp %.0f x%.2f | ym %.2f yw %.1f | bank M %.0f E %.0f",
        best.metal, best.energy, best.nano, bestV, nm, nw, st.bp, st.eff, st.ym, st.yw, st.M, st.E)
    if S.cfg.LOG_EVERY > 0 and frame - (S.logFrame or -1e9) >= S.cfg.LOG_EVERY then
        S.logFrame = frame
        Spring.Echo(string.format("[PLAN] %d:%02d %s", math.floor(frame / 1800), math.floor(frame / 30) % 60, S.info))
    end
    return best
end

local function HasTask(state, cls)
    for _, item in ipairs(state.queue) do
        if item.cls == cls and not item.built and not item.released then return true end
    end
    return false
end

local function Decay(S, frame)
    local dt = (frame - S.recentFrame) / 30
    if dt > 0 then
        local k = 0.5 ^ (dt / S.cfg.HALF_LIFE)
        for c, v in pairs(S.recent) do S.recent[c] = v * k end
        S.recentFrame = frame
    end
end

-- Class this builder should build next ("metal" | "energy" | "nano"), or nil to leave it to the blueprint order.
function P.Pick(S, state, res, frame)
    if not S.ok then return nil end
    local a = P.Plan(S, res, frame)
    local tot = S.recent.metal + S.recent.energy + S.recent.nano
    local best, bestScore = nil, -1e9
    for _, cls in ipairs({ "energy", "metal", "nano" }) do
        if HasTask(state, cls) then
            local score = a[cls] - (tot > 0 and S.recent[cls] / tot or 0)
            if a[cls] > 0 and score > bestScore then best, bestScore = cls, score end
        end
    end
    return best
end

function P.Commit(S, cls, frame)
    Decay(S, frame)
    S.recent[cls] = S.recent[cls] + 1
end

-- Interrupt list for blueprint_placer: one per class, all lowest-priority and non-preempting.
function P.Interrupts(S)
    local list = {}
    for _, cls in ipairs({ "energy", "metal", "nano" }) do
        list[#list + 1] = {
            name = "plan_" .. cls, priority = 0.5, buildType = cls, noPreempt = true,
            check = function(state, res, frame) return P.Pick(S, state, res, frame) == cls end,
            onIssue = function(state, task, frame) P.Commit(S, cls, frame or 0) end,
        }
    end
    return list
end

return P
