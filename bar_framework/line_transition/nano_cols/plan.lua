-- bar_framework/line_transition/nano_cols/plan.lua
-- What the nano-column block should build next: metal or energy (user 2026-11-04: "balancing out mexs and fusions and adding some kind of look
-- ahead system.  If it is floating m and stalling on e it clearly should have made less mex rows and more fusion rows").  The build fronts'
-- block kind (mex vs wind / gap) and the retro fronts' target (moho vs energy) read X.NcPlan instead of a fixed ratio (LT.CFG NC_PLAN).
--
--   TARGET   energy per metal to aim at: the ledger's EnergyTarget (eco_ledger.lua) -- the metal sink's unit once the sink is wanted ("once the sink
--            turns on that can set the main energy ratio"), else army share x the spine comp's E per metal + (1 - share) x NC_PLAN_ECO_RATIO (what
--            eco buildings cost); NC_E_RATIO without a ledger figure.
--   LOOK AHEAD  over NC_PLAN_HORIZON seconds:
--            Mfut  = metal income + the blocks in flight (T1 mex blocks, moho retrofits) + NC_PLAN_PLANNED_W x the T1 mex blocks still to retrofit
--                    + the income trend (d income / dt over the last minute x the horizon, at most NC_PLAN_TREND_MAX x income)
--            Eneed = target x Mfut + upkeep (every moho standing or being retrofitted 20 E/s, every T1 mex 3: the unit defs' energyUpkeep)
--            Efut  = energy income + the energy blocks in flight (wind blocks, energy retrofits) - the winds being reclaimed under retrofits
--                    + NC_PLAN_PLANNED_W x the energy gaps waiting for a T2 con
--            short = (Eneed - Efut) / Eneed     (> 0: energy short)
--   BANKS    what really happens: energy stalling (bank < 10%, pull >= income) while metal floats (bank > NC_PLAN_FLOAT_S of income), held NC_SKIP_HOLD
--            frames -> severe = "energy"; metal stalling while energy floats -> severe = "metal".  Then the fronts skip the other kind (fronts.lua).
--   WANT     "energy" when short > NC_PLAN_BAND or severe energy; "metal" when short < -NC_PLAN_BAND or severe metal; inside the band the kind with
--            fewer blocks in flight -- frames of both kinds stand, so the nano focus (nanos.lua) always has one of the type the economy needs.
-- Part of line_transition (installed before nano_cols/fronts.lua).  Log rows "[NC] plan ...".

local M = {}

function M.Install(X)
    local Clock = X.Clock
    local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
    local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")
    local LAYOUT = VFS.Include("LuaUI/Widgets/bar_framework/line_transition/nano_cols/layout.lua")

    local function Def(role) return UnitDefNames[ROLES.Get(role)] end
    local function WindE()
        local ud = Def("wind")
        local cap = ud and ud.windGenerator or 25
        local lo, hi = (Game and Game.windMin) or 0, (Game and Game.windMax) or cap
        return math.min(cap, (lo + hi) / 2)
    end
    local function Extract(role)               -- metal/s of one extractor of a block (projection: Full Metal Plate, knowledge/economy_numbers.md)
        return role == "moho" and 9.48 or 2.37
    end
    local function Upkeep(role) local d = Def(role); return d and math.max(0, d.energyUpkeep or 0) or 0 end
    local function EnergyBlockE(T)
        local unit = T.CFG.NC_ENERGY_UNIT
        local ud = Def(unit)
        return (ud and ud.energyMake or 0) * (LAYOUT.UNITS[unit] or 0)
    end
    local function CountOf(T, role)
        local d = Def(role)
        return d and #(Spring.GetTeamUnitsByDefs(T.teamID, { d.id }) or {}) or 0
    end

    -- ── the eco forecast (user 2026-11-04: "take into account the spending on eco falling off, so as that happens that spending goes into bp for
    -- the sink ... base it on unitcap for eco taken up") ─────────────────────────────────────────────────────────────────────────────────
    -- remaining = the metal the block still has to spend to reach its final state: new blocks the eco-unit budget still has room for (at the final cost
    -- of a moho / energy block, by the plan's energy share), the T1 blocks waiting for a retrofit, half of what is in flight.  spend = how fast that falls
    -- (smoothed).  Over the next h seconds the eco can spend at most remaining / h: once the backlog runs short its spending falls, and the metal sink
    -- (metal_sink.lua SINK_FORECAST) sizes itself for that before it happens.  eco_sim 2026-11-04: the block reached its budget at 18-20 min and its
    -- spending fell by ~2k m/s within 2 min some 5-7 min later.
    local function BlockCost(kind)
        local n = LAYOUT.UNITS[kind] or 0
        local d = Def(kind == "moho" and "moho" or kind)
        return n * ((d and d.metalCost) or 0)
    end
    local function Remaining(T, nc, P)
        local K = T.CFG
        local c, run = nc.count, nc.run
        local moho, energy = BlockCost("moho") + BlockCost("mex"), BlockCost(K.NC_ENERGY_UNIT)
        local cap = (Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)) or 3000
        local room = math.max(0, K.NC_UNIT_FRAC * cap - (nc.ecoUnits or 0))
        local open = false
        for _, f in ipairs(nc.fronts) do if f.kind == "build" and not f.done then open = true; break end end
        -- the budget room at a fixed cost per eco unit (pricing it by the plan's energy share made the figure jump by 600k when the share moved)
        local newBlocks = open and room / K.NC_FORECAST_BLOCK_UNITS or 0
        local rem = (open and room or 0) * K.NC_FORECAST_UNIT_COST
                  + c.mexT1 * BlockCost("moho") + (c.windT1 + c.gap) * energy
                  + 0.5 * (run.moho * BlockCost("moho") + run.energy * energy + run.mex * BlockCost("mex"))
        return rem, room, newBlocks
    end
    -- eco spending NOW, measured: the build progress of our eco frames (extractors, energy, storage, nanos) x their metal cost since the last tick
    -- (a frame that finished counts its last part).  (Reading it off the change in `remaining` was tried: work moves between budget room and
    -- retrofit backlog without any metal spent, and the figure swung between 0 and 12k m/s.)
    local ECO, ECO_IDS = nil, nil
    local function EcoDefs()
        if ECO then return ECO, ECO_IDS end
        ECO, ECO_IDS = {}, {}
        for _, role in ipairs({ "mex", "moho", "wind", "fusion", "afus", "nano", "storage" }) do
            local d = Def(role)
            if d then ECO[d.id] = d.metalCost or 0; ECO_IDS[#ECO_IDS + 1] = d.id end
        end
        return ECO, ECO_IDS
    end
    local function MeasureSpend(T, F, frame)
        local defs, ids = EcoDefs()
        local last = F.prog or {}
        local now, spent = {}, 0
        for _, uid in ipairs(Spring.GetTeamUnitsByDefs(T.teamID, ids) or {}) do
            local being, p = Spring.GetUnitIsBeingBuilt(uid)
            local cost = defs[Spring.GetUnitDefID(uid) or -1] or 0
            if being then
                now[uid] = p or 0
                spent = spent + math.max(0, (p or 0) - (last[uid] or 0)) * cost
            elseif last[uid] then
                spent = spent + math.max(0, 1 - last[uid]) * cost          -- finished since the last tick
            end
        end
        F.prog = now
        local dt = F.measF and (frame - F.measF) / 30 or nil
        F.measF = frame
        if dt and dt > 0 then F.spend = (F.spend or 0) + 0.25 * (spent / dt - (F.spend or 0)) end      -- smoothed over ~4 ticks
    end
    local function Forecast(T, nc, frame, P)
        local K = T.CFG
        local rem, room, newBlocks = Remaining(T, nc, P)
        local F = nc.forecast or {}
        MeasureSpend(T, F, frame)
        F.spend = F.spend or 0
        F.remaining, F.room, F.newBlocks, F.frame = rem, room, newBlocks, frame
        nc.forecast = F
        if T.WG then
            LEDGER.Register(T.WG, "eco", { forecast = function(hz)
                local G = nc.forecast
                if not G then return nil end
                hz = hz or K.NC_PLAN_HORIZON
                local cap = (Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)) or 3000
                return { spendNow = G.spend, spendFut = math.min(G.spend, G.remaining / math.max(1, hz)), remaining = G.remaining,
                         incFut = (nc.plan and nc.plan.mFut and nc.plan.mFut - (nc.plan.trend or 0)) or nil,      -- (the blocks in flight, not the trend)
                         room = G.room, used = (nc.ecoUnits or 0) / math.max(1, K.NC_UNIT_FRAC * cap) }
            end })
        end
        return F
    end

    local function Compute(T, nc, frame, res)
        local K = T.CFG
        local mi = res.metalIncomeS or res.metalIncome or 0
        local ei = res.energyIncomeS or res.energyIncome or 0
        local share = (T.spineMod and T.spineMod.Share and T.spineMod.Share()) or 0
        local R, src = LEDGER.EnergyTarget(T.WG, nil, { share = share, ecoRatio = K.NC_PLAN_ECO_RATIO })
        if not R then R, src = K.NC_E_RATIO, "fixed" end
        -- the income trend
        nc.planHist = nc.planHist or {}
        local h = nc.planHist
        h[#h + 1] = { f = frame, m = mi }
        while #h > 1 and frame - h[1].f > 1800 do table.remove(h, 1) end
        local slope = (#h > 1 and frame > h[1].f) and (mi - h[1].m) / ((frame - h[1].f) / 30) or 0
        local H, W = K.NC_PLAN_HORIZON, K.NC_PLAN_PLANNED_W
        local c, run = nc.count, nc.run
        local n = LAYOUT.UNITS
        local FW = K.NC_PLAN_FLIGHT_W          -- blocks in flight count this much of their output
        local mexMore, mohoMore = FW * run.mex * n.mex * Extract("mex"), FW * run.moho * n.moho * (Extract("moho") - Extract("mex"))
        -- the trend past what the blocks in flight already add (most of a rising income IS those blocks finishing: eco_sim 2026-11-04, counting both
        -- put the projection at 2.5x the income at 7-8 min and the block built energy it did not need)
        local trend = math.max(0, math.min(K.NC_PLAN_TREND_MAX * mi, slope * H - mexMore - mohoMore))
        local mFut = mi + mexMore + mohoMore + W * c.mexT1 * n.moho * (Extract("moho") - Extract("mex")) + trend
        local mohos, mexes = CountOf(T, "moho") + run.moho * n.moho, CountOf(T, "mex")
        local upkeep = mohos * Upkeep("moho") + mexes * Upkeep("mex")
        local eNeed = R * mFut + upkeep
        local eb = EnergyBlockE(T)
        local windBlock = n.wind * WindE()
        local eFut = ei + FW * (run.wind * windBlock + run.energy * eb - run.windOut * windBlock) + W * c.gap * eb
        local short = (eNeed - eFut) / math.max(1, eNeed)
        -- the banks
        local eFrac = (res.energyStorage or 0) > 0 and res.energy / res.energyStorage or 0.5
        local mFrac = (res.metalStorage or 0) > 0 and res.metal / res.metalStorage or 0.5
        local ePull = res.energyPullS or res.energyPull or 0
        local mPull = res.metalPullS or res.metalPull or 0
        -- (a metal bank near 0 is normal: everything is spent.  Metal is SHORT only while the builders want clearly more than comes in, and energy
        -- floats only while its bank is full; eco_sim 2026-11-04: "metal stalls" at pull >= income skipped 26 wind blocks and energy then ran 44% short)
        local eStall = eFrac < 0.10 and ePull >= 0.95 * ei
        local mStall = mFrac < 0.05 and mPull >= K.NC_PLAN_MSTALL_PULL * mi
        local mFloat = (res.metal or 0) > K.NC_PLAN_FLOAT_S * math.max(1, mi)
        local eFloat = eFrac > 0.95
        local short0 = (eNeed - eFut) / math.max(1, eNeed)
        -- severe only when the projection agrees (energy short / energy surplus)
        -- severe metal only when the projection agrees (an empty metal bank is normal); an energy stall with metal piling up is a fact
        local sevNow = (eStall and mFloat and "energy") or (mStall and eFloat and short0 < 0 and "metal") or nil
        local P = nc.plan or {}
        if sevNow and P.sevKind == sevNow then
            -- held: P.sevSince stays
        elseif sevNow then P.sevKind, P.sevSince = sevNow, frame
        else P.sevKind, P.sevSince = nil, nil end
        local severe = (P.sevKind and frame - P.sevSince >= K.NC_SKIP_HOLD) and P.sevKind or nil
        -- a bank at either end nudges the projection (it says what the projection missed)
        -- a bank at either end nudges the projection (it says what the projection missed).  (Overriding it on every energy stall was tried: brief
        -- early stalls are common, and the block overbuilt energy -- eco_sim 2026-11-04, metal spent -8% at 0% army, energy wasted 5x)
        if eStall then short = short + 0.1 elseif eFloat and mFrac < 0.05 then short = short - 0.1 end
        local want
        if severe then want = severe
        elseif short > K.NC_PLAN_BAND then want = "energy"
        elseif short < -K.NC_PLAN_BAND then want = "metal"
        else
            local eRun, mRun = run.wind + run.energy, run.mex + run.moho
            want = (eRun < mRun) and "energy" or "metal"
        end
        P.R, P.src, P.mFut, P.eNeed, P.eFut, P.short, P.severe, P.want, P.upkeep, P.trend, P.frame = R, src, mFut, eNeed, eFut, short, severe, want, upkeep, trend, frame
        nc.plan = P
        local F = Forecast(T, nc, frame, P)
        if frame - (P.logF or -1e9) >= (K.NC_PLAN_LOG_EVERY or 900) or (severe and severe ~= P.loggedSevere) then
            P.logF, P.loggedSevere = frame, severe
            Spring.Echo(string.format("[NC] %s forecast: eco spends %.0f m/s, %.0fk metal of eco work left (budget room %d units ~ %.1f blocks) -> over %ds at most %.0f m/s",
                Clock(frame), F.spend, F.remaining / 1000, math.floor(F.room), F.newBlocks, K.NC_PLAN_HORIZON, math.min(F.spend, F.remaining / K.NC_PLAN_HORIZON)))
            Spring.Echo(string.format("[NC] %s plan: want %s%s | E/M target %.1f (%s, army share %.2f) | metal %.0f -> %.0f (trend +%.0f) | energy need %.0f (upkeep %.0f) vs %.0f -> short %+.0f%% | in flight mex %d wind %d moho %d energy %d windOut %d, gaps %d | banks M %.0f%% E %.0f%% | skips %d",
                Clock(frame), want, severe and (" [SEVERE " .. severe .. "]") or "", R, tostring(src), share, mi, mFut, trend, eNeed, upkeep, eFut, 100 * short,
                run.mex, run.wind, run.moho, run.energy, run.windOut, c.gap, 100 * mFrac, 100 * eFrac, nc.skips or 0))
        end
        return P
    end

    -- the plan for this tick (recomputed every NC_PLAN_EVERY frames); nil when NC_PLAN is off
    function X.NcPlan(T, nc, res)
        if not T.CFG.NC_PLAN then return nil end
        local frame = T.frame or 0
        local P = nc.plan
        if not P or not P.frame or frame - P.frame >= (T.CFG.NC_PLAN_EVERY or 60) then
            res = res or T.lastRes
            if not res then return P end
            P = Compute(T, nc, frame, res)
        end
        return P
    end
end

return M
