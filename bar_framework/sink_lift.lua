-- bar_framework/sink_lift.lua  (user 2026-11-04: "air lift nanos to bring in bp fast, make sure the air lifted bp gets replaced in the cols, slowly
-- phase it out as decoy coms get built and can take over for bp")
-- The metal sink's air lift.  A decoy commander is 33000 build time: the decoys the sink needs in the ramp (100-120 a minute in eco_sim, 2026-11-04)
-- cannot be built fast enough, so build power comes by air instead -- nanos of the nano-column block carried to the sink sites by our own light
-- transports (bar_framework/air_transport.lua does the moves), and given back as the decoys arrive.
--
--   WHAT A SITE WANTS  a proxy base (proxy_base.lua, kind "proxy"): its `want` (4), first; a decoy site (the sink's T2 bot lab): SINK_DECOY_START_NANOS (16) until its own SINK_DECOY_OWN decoys stand -- they are
--             set down while the frame is up and build it in seconds, then guard the lab; a sink lab: SINK_RAMP_NANOS until its decoys stand.
--             Each decoy assisting a site's lab stands in for decoy BP / nano BP (1.5) of its nanos.
--   WHICH NANOS  nano-column nanos (nc.LiftPick, nano_cols/nanos.lua): the ones the block's reclaim rule would take anyway first, then parked,
--             then any; never more than SINK_LIFT_KEEP_FRAC of the block's nanos away at once, nor SINK_LIFT_NANOS_MAX in all.  A nano leaves
--             the block's registry (nc.Forget) when it is picked: its spot reads empty, so the block's recovery rebuilds it while a block in its
--             reach still needs build power.
--   PHASE OUT  every SINK_LIFT_BALANCE frames a site with more nanos than it wants gives them up: to a site that is short first, else a
--             neighbouring nano reclaims them (the unit cap, and the metal back; user's choice).
--   TRANSPORTS  our own pool (WG.SinkLiftTids; air_lift.lua leaves them alone), asked of the labs through WG.LabOrders (normal tier, not from a
--             lab held for the macro's air cons), up to SINK_LIFT_TRANSPORTS, one per nano the sites are short of.
--   OTHER UNITS  LIFT.Carry(uid, x, z, prio, onDone): any unit the transports can lift (the T1 bot con that places a decoy lab).
--   CONVOY  a site with `convoy = { go = bool }` (the proxy base, user 2026-11-08: "It should come in one wave ... The air trans should move as one group
--             and be escorted by the fighters"): all the nanos it wants are picked at once and wait until there is an idle transport for each (or
--             CONVOY PICK_S with what it has); then they are all loaded (air_transport hold) and fly to a rally point RALLY_D short of the site on our
--             side -- all this while the beachhead is taken -- and once the site is `go` and they are all there (and, at most ROUTE_WAIT_S, the route
--             is clear of enemy AA: WG.AirLift.RouteClear) they are set down in the same tick.
--             Published as WG.ProxyConvoy = { state = "loading" | "rally" | "flying", x, z (the transports' centre), tx, tz, n, frame } for the fighters'
--             escort (air_wing.lua).
-- Orders to nanos go through the nano broker (nano_broker.lua): PRIO.LIFT while picked up / carried, PRIO.SINK at the site.
--
--   LIFT.Init{ teamID, Clock, CB (con_broker module), trans = fn -> line_transition state, WG, cfg = metal_sink's K }
--   LIFT.Update(frame, sites)    every 30 frames; sites = metal_sink M.Sites(): { key, x, z, facing, kind, frameID, labID, decoys, lab }
--   LIFT.Carry(uid, x, z, prio, onDone(uid, ok))    LIFT.Busy(uid)    LIFT.Cancel(uid)
--   LIFT.OnFinished(uid, defID)  (transports join the pool)
-- Logs [SINK] lift rows.

local AT = VFS.Include("LuaUI/Widgets/bar_framework/air_transport.lua")
local ER = VFS.Include("LuaUI/Widgets/bar_framework/edge_route.lua")
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = {}

local E, K = {}, {}
local tids = {}            -- transports in the pool, in the order they joined
local items = {}           -- [uid] = { uid, kind = "nano" | "unit", site, slot, x, z, state = "wait" | "fly" | "placed" | "reclaim", prio, since, fails, onDone }
local slots = {}           -- [site key] = { list = { {x, z}, ... }, used = { [k] = uid } }
local ordered, orderF = 0, -1e9
local stats = { lifted = 0, done = 0, failed = 0, back = 0, moved = 0, reclaimed = 0 }
local lastLog = -1e9
local nurseryShortF = -1e9 -- last frame the block could not fill a flight (SINK_NURSERY)
local lastShort = nil      -- the short sites of the last Fill pass: { {site, n} } (the transport pool is sized from it)
local noCarryLogged = false
local convoys = {}         -- [site key] = { state, tids = { tid, ... }, f, rx, rz, tx, tz, routeF }
local CONVOY = { LOAD_S = 60, RALLY_D = 2500, RALLY_R = 450, RALLY_S = 150, ROUTE_WAIT_S = 45, TIMEOUT_S = 300, PICK_S = 60 }
local convoyGoF = {}       -- [site key] = the frame the site went `go` (a convoy leaves with all the nanos it wants; with what it has only PICK_S after go:
                           -- game 1, 2026-11-08, waves of 2 left during the beachhead)

local function Clock(f) return E.Clock and E.Clock(f) or string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
local function Echo(frame, fmt, ...) Spring.Echo(string.format("[SINK] %s lift: " .. fmt, Clock(frame), ...)) end
local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
local function TransportDef() return UnitDefNames[ROLES.Get("transport_air")] end
local function NanoDef() return UnitDefNames[ROLES.Get("nano")] end
local function NANO() local T = E.trans and E.trans(); return T and T.BP and T.BP.NANO end

function M.Init(env)
    E, K = env or {}, (env and env.cfg) or {}
    tids, items, slots, convoys = {}, {}, {}, {}
    ordered, orderF, nurseryShortF = 0, -1e9, -1e9
    stats = { lifted = 0, done = 0, failed = 0, back = 0, moved = 0, reclaimed = 0 }
    if E.WG then E.WG.SinkLiftTids = tids end
end

function M.Busy(uid) local it = items[uid]; return it ~= nil and (it.state == "wait" or it.state == "fly") end

function M.Cancel(uid)
    local it = items[uid]
    if not it then return end
    for _, tid in ipairs(tids) do local j = AT.Job(tid); if j and j.unit == uid then AT.Cancel(tid) end end
    items[uid] = nil
end

function M.Carry(uid, x, z, prio, onDone)
    if not Alive(uid) then return false end
    local td = TransportDef()
    if not (td and AT.CanCarry(td.id, Spring.GetUnitDefID(uid))) then return false end
    items[uid] = { uid = uid, kind = "unit", x = x, z = z, state = "wait", prio = prio or 100, since = Spring.GetGameFrame(), fails = 0, onDone = onDone }
    return true
end

-- ── where a site's nanos stand ──────────────────────────────────────────────────────────────────────
-- A ring around the lab on a 48-elmo grid: outside the lab's footprint, within SINK_NANO_R of the site, never inside another sink spot's
-- clearance circle (metal_sink's FindSpot would then refuse that spot), and, for a ground lab, not in front of its exit.
local EXIT = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }
local function SiteSlots(site)
    local S = slots[site.key]
    if S then return S end
    local half = site.lab and math.max(site.lab.xsize or 0, site.lab.zsize or 0) * 4 or 72
    local R = K.SINK_NANO_R or 264
    local clear = (K.SINK_NANO_CLEAR or 216)
    local others = (E.SpotCenters and E.SpotCenters(site.key)) or {}
    local ex = EXIT[site.facing or 0] or EXIT[0]
    local ground = site.lab and not site.lab.canFly and not (site.lab.customParams and site.lab.customParams.airfactory)
    local list = {}
    for dx = -R, R, 48 do
        for dz = -R, R, 48 do
            local d2 = dx * dx + dz * dz
            if math.max(math.abs(dx), math.abs(dz)) >= half + 32 and d2 <= R * R then
                local fwd, lat = dx * ex[1] + dz * ex[2], math.abs(dx * ex[2] - dz * ex[1])
                if not (ground and fwd > 0 and lat < half + 24) then
                    local x, z = site.x + dx, site.z + dz
                    local ok = true
                    for _, o in ipairs(others) do
                        if (o.x - x) ^ 2 + (o.z - z) ^ 2 < clear * clear then ok = false; break end
                    end
                    if ok then list[#list + 1] = { x = x, z = z, d = d2 } end
                end
            end
        end
    end
    table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end if a.x ~= b.x then return a.x < b.x end return a.z < b.z end)
    S = { list = list, used = {} }
    slots[site.key] = S
    return S
end

local function FreeSlot(site)
    local S = SiteSlots(site)
    local nd = NanoDef()
    for k, p in ipairs(S.list) do
        local u = S.used[k]
        if not (u and items[u] and items[u].site == site.key) then
            local y = Spring.GetGroundHeight(p.x, p.z) or 0
            local t = nd and Spring.TestBuildOrder(nd.id, p.x, y, p.z, 0)
            if t and t > 0 then return k, p end
        end
    end
    return nil
end

local function SetSite(it, site, frame)
    local k, p = FreeSlot(site)
    if not k then return false end
    if it.site and slots[it.site] and it.slot then slots[it.site].used[it.slot] = nil end
    slots[site.key].used[k] = it.uid
    it.site, it.slot, it.x, it.z = site.key, k, p.x, p.z
    it.prio = site.kind == "decoy" and 60 or 50
    it.state, it.since = "wait", frame
    return true
end

-- ── the balance: what each site wants, phase-out, new nanos from the block ─────────────────────────────

local function Want(site)
    if site.kind == "proxy" then return site.want or 4 end      -- proxy_base.lua (2026-11-08): a forward base wants a fixed few nanos
    local nanoBP = (NanoDef() and NanoDef().buildSpeed) or 200
    local decoyBP = (E.decoyBP and E.decoyBP()) or 300
    local cover = math.ceil((site.decoys or 0) * decoyBP / nanoBP)
    if site.kind == "decoy" then
        if site.labID and (site.decoys or 0) >= (K.SINK_DECOY_OWN or 11) then return 0 end
        return math.max(0, (K.SINK_DECOY_START_NANOS or 16) - (site.labID and cover or 0))
    end
    return math.max(0, (K.SINK_RAMP_NANOS or 32) - cover)
end

local function Balance(frame, sites, byKey)
    local NB = NANO()
    if not NB then return end
    local have, list, orphans = {}, {}, {}
    for uid, it in pairs(items) do
        if it.kind == "nano" and it.state ~= "reclaim" then
            if it.site and byKey[it.site] then
                have[it.site] = have[it.site] or {}
                local h = have[it.site]
                h[#h + 1] = uid
            elseif it.state ~= "fly" then
                orphans[#orphans + 1] = uid       -- its site went away (lab lost, job dropped); one in the air lands first
            end
        end
    end
    -- surplus: placed ones first (one in the air keeps going), newest site first
    for _, site in ipairs(sites) do
        local h = have[site.key] or {}
        local extra = #h - Want(site)
        if extra > 0 then
            table.sort(h, function(a, b)
                local pa, pb = items[a].state == "placed", items[b].state == "placed"
                if pa ~= pb then return pa end
                return a < b
            end)
            for k = 1, extra do
                local it = items[h[k]]
                if it.state ~= "fly" then list[#list + 1] = h[k] end
            end
        end
    end
    -- deficits: decoy sites first (they make the build power for the rest), then in site order
    local short = {}
    for _, site in ipairs(sites) do
        local n = Want(site) - #(have[site.key] or {})
        if n > 0 then short[#short + 1] = { site = site, n = n } end
    end
    table.sort(short, function(a, b)
        if (a.site.kind == "proxy") ~= (b.site.kind == "proxy") then return a.site.kind == "proxy" end     -- a proxy base first
        if (a.site.kind == "decoy") ~= (b.site.kind == "decoy") then return a.site.kind == "decoy" end
        return a.site.key < b.site.key
    end)
    -- freed nanos go to a site that has less than half the nanos it wants (a move is a flight with no build power: eco_sim 2026-11-04,
    -- moving every freed nano to any short site was 373 of 499 moves and only 132 nanos ever came from the block)
    -- (an orphan goes to any short site)
    for _, s in ipairs(short) do
        local w = Want(s.site)
        while not s.site.convoy and s.n > 0 and (#orphans > 0 or (#list > 0 and w - s.n < w / 2)) do     -- (a convoy site is filled by its convoy only)
            local uid = (#orphans > 0) and table.remove(orphans) or table.remove(list)
            local it = items[uid]
            if it.state == "placed" then NB.Release(uid); NB.Park(NB.PRIO.LIFT, uid) end
            if SetSite(it, s.site, frame) then
                stats.moved = stats.moved + 1
                s.n = s.n - 1
            else
                orphans[#orphans + 1] = uid
                break
            end
        end
    end
    -- the rest stay where they are (more build power for that lab) -- unless the unit cap is short: then a neighbouring lifted nano reclaims them
    -- (the slot and the metal back)
    local reserve = E.CapReserve and E.CapReserve() or 0
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(E.teamID)
    local cnt = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(E.teamID)
    local capShort = reserve > 0 and maxU and cnt and maxU - cnt < 2 * reserve
    if not capShort then list = {} end
    for _, uid in ipairs(orphans) do list[#list + 1] = uid end         -- orphans no site took are reclaimed in any case
    for _, uid in ipairs(list) do
        local it = items[uid]
        if it.state == "placed" or it.state == "wait" then
            local x, _, z = Spring.GetUnitPosition(uid)
            local best, bd
            if x then
                for rid, r in pairs(items) do
                    if rid ~= uid and r.kind == "nano" and r.state == "placed" and Alive(rid) then
                        local rx, _, rz = Spring.GetUnitPosition(rid)
                        local d = rx and (rx - x) ^ 2 + (rz - z) ^ 2
                        if d and d <= 400 * 400 and (not bd or d < bd) then best, bd = rid, d end
                    end
                end
            end
            if best then
                NB.Release(uid)
                if NB.Reclaim(NB.PRIO.WIND_RECLAIM, best, uid) then
                    it.state = "reclaim"
                    if it.site and slots[it.site] and it.slot then slots[it.site].used[it.slot] = nil end
                    stats.reclaimed = stats.reclaimed + 1
                end
            end
        end
    end
end

-- Nanos from the block, just in time: no more waiting for a flight than there are idle transports (+ SINK_LIFT_BUFFER) -- a nano picked
-- is parked, and 100+ parked nanos waiting for 10 transports cost the block more than the sink gained (eco_sim 2026-11-04).
local function Shortfall(sites)
    local have = {}
    for _, it in pairs(items) do if it.kind == "nano" and it.state ~= "reclaim" and it.site then have[it.site] = (have[it.site] or 0) + 1 end end
    local short = {}
    for _, site in ipairs(sites) do
        local n = Want(site) - (have[site.key] or 0)
        if n > 0 then short[#short + 1] = { site = site, n = n } end
    end
    table.sort(short, function(a, b)
        if (a.site.kind == "proxy") ~= (b.site.kind == "proxy") then return a.site.kind == "proxy" end     -- a proxy base first
        if (a.site.kind == "decoy") ~= (b.site.kind == "decoy") then return a.site.kind == "decoy" end
        return a.site.key < b.site.key
    end)
    return short
end

local function Fill(frame, sites)
    local NB = NANO()
    local T = E.trans and E.trans()
    local nc = T and T.nc
    lastShort = Shortfall(sites)
    if not (NB and nc and nc.LiftPick and nc.Forget) then return end
    local short = lastShort
    if #short == 0 then return end
    local idle, waiting = 0, 0
    for _, tid in ipairs(tids) do if Alive(tid) and not AT.Job(tid) then idle = idle + 1 end end
    for _, it in pairs(items) do if it.state == "wait" then waiting = waiting + 1 end end
    local slotsFree = idle + (K.SINK_LIFT_BUFFER or 2) - waiting
    local convoyShort = false
    for _, s in ipairs(short) do if s.site.convoy and not convoys[s.site.key] then convoyShort = true end end
    if slotsFree <= 0 and not convoyShort then return end
    -- the unit cap: a nano taken is rebuilt in the block (a new unit), so none while the sink's reserve of slots is not free
    local reserve = E.CapReserve and E.CapReserve() or 0
    if reserve > 0 then
        local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(E.teamID)
        local cnt = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(E.teamID)
        if maxU and cnt and maxU - cnt < reserve then return end
    end
    local td, nd = TransportDef(), NanoDef()
    if not (td and nd and AT.CanCarry(td.id, nd.id)) then
        if not noCarryLogged then noCarryLogged = true; Echo(frame, "the light transport cannot carry a nano: no lifts") end
        return
    end
    local lifted = 0
    for _, it in pairs(items) do if it.kind == "nano" and it.state ~= "reclaim" then lifted = lifted + 1 end end
    local room = math.min((K.SINK_LIFT_NANOS_MAX or 160) - lifted,
                          math.floor((K.SINK_LIFT_KEEP_FRAC or 0.5) * (nc.nanoN + lifted)) - lifted, slotsFree)
    local asked, got = 0, 0
    local busy = function(id) return items[id] ~= nil end
    for _, s in ipairs(short) do
        local cv = s.site.convoy
        local hold = cv and convoys[s.site.key]                       -- (a convoy: nothing more is picked while it is out)
        local cRoom = cv and math.min(s.n, (K.SINK_LIFT_NANOS_MAX or 160) - lifted) or room
        if not hold and cRoom > 0 and s.n > 0 then
            local ask = math.min(s.n, cRoom)
            asked = asked + ask
            -- nursery nanos first (built to be flown), then the block's idle ones
            local blocks = K.SINK_NURSERY and K.SINK_NURSERY ~= "rows"
            local picks = (blocks and nc.NurseryPick) and nc.NurseryPick(ask, s.site.x, s.site.z, busy) or {}
            if #picks < ask then
                for _, id in ipairs(nc.LiftPick(ask - #picks, s.site.x, s.site.z, busy, K.SINK_LIFT_TIERS)) do picks[#picks + 1] = id end
            end
            got = got + #picks
            for _, uid in ipairs(picks) do
                local it = { uid = uid, kind = "nano", fails = 0, convoy = cv and s.site.key or nil }
                if SetSite(it, s.site, frame) then
                    nc.Forget(uid)
                    NB.Release(uid)
                    NB.Park(NB.PRIO.LIFT, uid)
                    items[uid] = it
                    stats.lifted = stats.lifted + 1
                    if cv then lifted = lifted + 1 else room = room - 1 end
                    s.n = s.n - 1
                end
            end
            if cv and #picks > 0 then Echo(frame, "convoy for site %d: %d nano(s) picked, waiting for a transport each", s.site.key, #picks) end
        end
    end
    -- NURSERY (user 2026-11-04: "if there are not enough idle nanos you can add a new building type for the nano cols where it just builds nanos
    -- like it would build winds"): while the block cannot fill a free flight it is asked for nursery blocks of 24 nanos, enough for what the sites
    -- are short of (at most SINK_NURSERY_MAX); SINK_NURSERY_HOLD frames after the last shortage the ask drops to 0 and empty nurseries become mex blocks
    if K.SINK_NURSERY then
        if got < asked then nurseryShortF = frame end
        local total = 0
        for _, s in ipairs(lastShort) do total = total + math.max(0, s.n) end
        -- "rows" (user 2026-11-04: "instead of the nano nursery blocks ... just fill in and grab a row, instead of taking up a building spot"): the
        -- nano fronts fill the rows the pattern skipped (also in T1) and recovery rebuilds a fill row once its nanos are flown -- nc.nurseryRowsWant
        local key = (K.SINK_NURSERY == "rows") and "nurseryRowsWant" or "nurseryWant"
        local what = (K.SINK_NURSERY == "rows") and "nursery rows (fill rows rebuilt)" or "nursery block(s)"
        if frame - nurseryShortF <= (K.SINK_NURSERY_HOLD or 3600) then
            local per = (K.SINK_NURSERY == "rows") and 3 or 24
            local want = math.min(K.SINK_NURSERY == "rows" and 1e9 or (K.SINK_NURSERY_MAX or 4), math.max(nc[key] or 0, math.ceil(total / per)))
            if want ~= nc[key] then Echo(frame, "the block is asked for %d %s (sites short %d nanos, %d of %d flights filled)", want, what, total, got, asked) end
            nc[key] = want
        elseif (nc[key] or 0) > 0 then
            nc[key] = 0
            Echo(frame, "no %s wanted any more", what)
        end
    end
end

-- ── transports ───────────────────────────────────────────────────────────────────────────────────

local wantT = 0            -- transports wanted at the last tick

-- a finished light transport joins the pool while it is short (any lab's: the lab-order request does not say whose a unit is; air_lift.lua asks again
-- for its own)
function M.OnFinished(uid, defID)
    local td = TransportDef()
    if not (td and defID == td.id) then return end
    if #tids >= wantT and ordered <= 0 then return end
    local W = E.WG
    for _, f in ipairs((W and W.NcFerryTids) or {}) do if f == uid then return end end
    tids[#tids + 1] = uid
    ordered = math.max(0, ordered - 1)
    Spring.GiveOrderToUnit(uid, AT.CMD_STOP, {}, {})
end

-- More transports: through the lab-order API (WG.LabOrders, normal tier, not from a lab held for the macro's air cons -- eco_sim 2026-11-04: 20 transports
-- inserted ahead of the T1 air lab's queue held back the block's air cons and income at 20:00), else straight from the T1 air lab.
local function Transports(frame, nWork)
    for k = #tids, 1, -1 do if not Alive(tids[k]) then table.remove(tids, k) end end
    local convoyShort = false                  -- (a convoy waits for a transport per nano: its transports come at the high tier)
    for _, sh in ipairs(lastShort or {}) do if sh.site.convoy and not convoys[sh.site.key] then convoyShort = true end end
    for _, it in pairs(items) do if it.convoy and it.state == "wait" and not convoys[it.convoy] then convoyShort = true end end
    wantT = math.min(K.SINK_LIFT_TRANSPORTS or 10, nWork)
    local td = TransportDef()
    if not td then return end
    local LO = E.WG and E.WG.LabOrders
    if LO and LO.Request then
        if wantT > #tids then
            LO.Request("sink:transport", { picks = { td.name }, n = wantT - #tids, tier = convoyShort and "high" or "normal", held_ok = false, require = false })
        end
        return
    end
    local T = E.trans and E.trans()
    local lab = T and T.airLabID
    if ordered > 0 and frame - orderF > 2700 then ordered = 0 end          -- orders that never came out: forget them
    if #tids + ordered < wantT and lab and Alive(lab) and frame - orderF >= 150 and E.CB and E.CB.OrderCon then
        E.CB.OrderCon(E.WG, lab, td.id, frame, true)
        ordered, orderF = ordered + 1, frame
    end
end

-- ── the update ───────────────────────────────────────────────────────────────────────────────────

function M.Update(frame, sites)
    if frame % 30 ~= 0 then return end
    local NB = NANO()
    local byKey = {}
    for _, s in ipairs(sites or {}) do byKey[s.key] = s end
    -- moves that ended
    for _, job in ipairs(AT.Update(frame)) do
        local it = items[job.unit]
        if it then
            if job.state == "done" then
                stats.done = stats.done + 1
                if it.kind == "unit" then
                    items[it.uid] = nil
                    if it.onDone then it.onDone(it.uid, true) end
                else
                    it.state = "placed"
                    if NB then NB.Release(it.uid) end
                    local site = it.site and byKey[it.site]
                    stats.proxyLanded = (stats.proxyLanded or 0) + ((site and site.kind == "proxy") and 1 or 0)
                    -- the proxy's build power: every other landed nano HIGH (user 2026-11-08: first dibs on metal; then "don't put everything on high prio
                    -- it starved the bots whole eco ... only half the nanos")
                    if site and site.kind == "proxy" and stats.proxyLanded % 2 == 0 then
                        local gc = Game and Game.CustomCommands and Game.CustomCommands.GameCMD
                        Spring.GiveOrderToUnit(it.uid, (gc and gc.PRIORITY) or 34571, { 1 }, {})
                    end
                end
            else
                stats.failed = stats.failed + 1
                it.fails, it.state = (it.fails or 0) + 1, "wait"
                if it.fails >= 3 or not Alive(it.uid) then
                    items[it.uid] = nil
                    if it.kind == "unit" then
                        if it.onDone then it.onDone(it.uid, false) end
                    elseif NB and Alive(it.uid) then NB.Release(it.uid) end             -- a nano left where it is: the engine's auto-assist
                    Echo(frame, "gave up moving %d (%s)", it.uid, tostring(job.why))
                end
            end
        end
    end
    for uid, it in pairs(items) do if not Alive(uid) then items[uid] = nil end end
    -- the nanos at their sites: repair the frame, then guard the lab
    if NB then
        for uid, it in pairs(items) do
            if it.kind == "nano" and it.state == "placed" then
                local site = it.site and byKey[it.site]
                -- (not the proxy's: user 2026-11-08, "Don't control the nanos except for setting them high prio, the base behavior is good enough" -- in
                -- game 4 they stood guarding the lab while the cons built next to them)
                if site and site.kind ~= "proxy" then
                    if site.frameID and Alive(site.frameID) and Spring.GetUnitIsBeingBuilt(site.frameID) then NB.Assist(NB.PRIO.SINK, uid, site.frameID)
                    elseif site.labID and Alive(site.labID) then NB.Guard(NB.PRIO.SINK, uid, site.labID) end
                end
            end
        end
    end
    if frame % (K.SINK_LIFT_BALANCE or 300) == 0 then Balance(frame, sites or {}, byKey) end
    if frame % 60 == 0 then Fill(frame, sites or {}) end
    -- CONVOYS: load them all at once, gather at the rally point, set down together
    M.Convoys(frame, byKey)
    -- waiting lifts to idle transports: the highest prio first, then the oldest; the nearest transport
    local wait, nWork = {}, 0
    for _, it in pairs(items) do
        if it.state == "wait" and not it.convoy then wait[#wait + 1] = it; nWork = nWork + 1 elseif it.state == "fly" or it.state == "wait" then nWork = nWork + 1 end
    end
    table.sort(wait, function(a, b) if a.prio ~= b.prio then return a.prio > b.prio end if a.since ~= b.since then return a.since < b.since end return a.uid < b.uid end)
    for _, it in ipairs(wait) do
        local ux, _, uz = Spring.GetUnitPosition(it.uid)
        local best, bd
        if ux then
            for _, tid in ipairs(tids) do
                if not AT.Job(tid) and Alive(tid) then
                    local tx, _, tz = Spring.GetUnitPosition(tid)
                    local d = tx and (tx - ux) ^ 2 + (tz - uz) ^ 2
                    if d and (not bd or d < bd) then best, bd = tid, d end
                end
            end
        end
        if not best then break end
        local job, why = AT.Move(best, it.uid, it.x, it.z, frame, { arrive = 140, timeout = 90 * 30 })
        if job then
            it.state = "fly"
            if it.kind == "unit" then Spring.GiveOrderToUnit(it.uid, AT.CMD_STOP, {}, {}) end
        else
            Echo(frame, "transport %d cannot carry %d: %s", best, it.uid, tostring(why))
            items[it.uid] = nil
            if it.kind == "unit" and it.onDone then it.onDone(it.uid, false) end
        end
    end
    local need = 0
    for _, s in ipairs(lastShort or {}) do need = need + math.max(0, s.n) end
    Transports(frame, nWork + need)
    if frame - lastLog >= 1800 and next(items) then
        lastLog = frame
        local n = { wait = 0, fly = 0, placed = 0, reclaim = 0 }
        for _, it in pairs(items) do n[it.state] = (n[it.state] or 0) + 1 end
        Echo(frame, "transports %d (+%d ordered), nanos placed %d / waiting %d / in the air %d / being reclaimed %d; so far lifted %d, moves done %d, failed %d, moved between sites %d, reclaimed %d",
            #tids, ordered, n.placed, n.wait, n.fly, n.reclaim, stats.lifted, stats.done, stats.failed, stats.moved, stats.reclaimed)
    end
end

-- ── convoys ──────────────────────────────────────────────────────────────────────────────────────

local function Publish()
    local W = E.WG
    if not W then return end
    local best
    for key, c in pairs(convoys) do
        local sx, sz, n = 0, 0, 0
        for _, tid in ipairs(c.tids) do
            local x, _, z = Spring.GetUnitPosition(tid)
            if x then sx, sz, n = sx + x, sz + z, n + 1 end
        end
        if n > 0 then best = { state = c.state, x = sx / n, z = sz / n, tx = c.tx, tz = c.tz, n = n, key = key, frame = Spring.GetGameFrame(), tids = c.tids,
                               atRally = c.atRally or 0, rx = c.rx, rz = c.rz } end
    end
    W.ProxyConvoy = best
end

function M.Convoys(frame, byKey)
    -- a site's `carry` units (the proxy's ground con) ride in its convoy
    for key, site in pairs(byKey) do
        for _, uid in ipairs(site.convoy and site.carry or {}) do
            if Alive(uid) and not items[uid] and not convoys[key] then
                local it = { uid = uid, kind = "unit", fails = 0, convoy = key }
                if SetSite(it, site, frame) then
                    items[uid] = it
                    Spring.GiveOrderToUnit(uid, AT.CMD_STOP, {}, {})
                    Echo(frame, "convoy for site %d: carries unit %d (%s)", key, uid, (UnitDefs[Spring.GetUnitDefID(uid)] or {}).name or "?")
                end
            end
        end
    end
    -- new convoys: every waiting item of a `go` site, once there is an idle transport for each
    local bySite = {}
    for _, it in pairs(items) do
        if it.convoy and it.state == "wait" and not convoys[it.convoy] then
            bySite[it.convoy] = bySite[it.convoy] or {}
            table.insert(bySite[it.convoy], it)
        end
    end
    for key, list in pairs(bySite) do
        local site = byKey[key]
        local idle = {}
        for _, tid in ipairs(tids) do if Alive(tid) and not AT.Job(tid) then idle[#idle + 1] = tid end end
        local placed = 0
        for _, it in pairs(items) do if it.site == key and it.state == "placed" then placed = placed + 1 end end
        if site and site.convoy and site.convoy.go then convoyGoF[key] = convoyGoF[key] or frame end
        local carryN = 0
        for _, it in ipairs(list) do if it.kind == "unit" then carryN = carryN + 1 end end
        local full = site and #list - carryN >= Want(site) - placed and carryN >= #(site.carry or {}) or false
        local late = convoyGoF[key] and frame - convoyGoF[key] >= CONVOY.PICK_S * 30
        local n = (full and #idle >= #list) and #list or (late and math.min(#list, #idle)) or 0
        if site and site.convoy and n > 0 then
            table.sort(list, function(a, b) return a.uid < b.uid end)
            local c = { state = "loading", tids = {}, f = frame, tx = site.x, tz = site.z }
            for k = 1, n do
                local it = list[k]
                local ux, _, uz = Spring.GetUnitPosition(it.uid)
                local bi, bd
                for i, tid in ipairs(idle) do
                    local tx, _, tz = Spring.GetUnitPosition(tid)
                    local d = (tx and ux) and (tx - ux) ^ 2 + (tz - uz) ^ 2 or 1e18
                    if not bd or d < bd then bi, bd = i, d end
                end
                local tid = table.remove(idle, bi)
                local job = AT.Move(tid, it.uid, it.x, it.z, frame, { arrive = 140, timeout = CONVOY.TIMEOUT_S * 30, hold = true })
                if job then it.state = "fly"; c.tids[#c.tids + 1] = tid end
            end
            if #c.tids > 0 then
                convoys[key] = c
                Echo(frame, "CONVOY for site %d: %d transports loading", key, #c.tids)
            end
        elseif site and site.convoy and frame % 900 == 0 then
            Echo(frame, "convoy for site %d waits: %d nanos, %d idle transports", key, #list, #idle)
        end
    end
    -- the convoys in flight
    for key, c in pairs(convoys) do
        local live = {}
        for _, tid in ipairs(c.tids) do
            if AT.Job(tid) then live[#live + 1] = tid
            elseif c.home and Alive(tid) then
                -- set down: home again round the edge (game 5, 2026-11-08: the 9 transports stayed parked on the spot and blocked the jammer and the lab --
                -- the landed con stood there 150 s and the spot was given up)
                local x, _, z = Spring.GetUnitPosition(tid)
                if x then
                    local first = true
                    for _, p in ipairs(ER.Route(x, z, c.home[1], c.home[2], { avoid = byKey[key] and byKey[key].avoid })) do
                        Spring.GiveOrderToUnit(tid, CMD and CMD.MOVE or 10, { p.x, Spring.GetGroundHeight(p.x, p.z) or 0, p.z }, first and {} or { "shift" })
                        first = false
                    end
                end
            end
        end
        c.tids = live
        if #live == 0 then
            Echo(frame, "CONVOY for site %d: over after %ds", key, math.floor((frame - c.f) / 30))
            convoys[key] = nil
        elseif c.state == "loading" then
            local all = true
            for _, tid in ipairs(live) do if AT.Job(tid).state ~= "carrying" then all = false end end
            if all or frame - c.f > CONVOY.LOAD_S * 30 then
                -- the rally point: RALLY_D short of the site, toward where the transports are
                local sx, sz, n = 0, 0, 0
                for _, tid in ipairs(live) do
                    local x, _, z = Spring.GetUnitPosition(tid)
                    if x then sx, sz, n = sx + x, sz + z, n + 1 end
                end
                local cx, cz = (n > 0) and sx / n or c.tx, (n > 0) and sz / n or c.tz   -- (n: transports with a position)
                c.home = { cx, cz }                                         -- (where they go back to once they set down)
                -- (user 2026-11-08: "Have the convoy and air con hug the side of the map so there is less chance they get spotted or intercepted": the
                -- route runs round the map's border, the way that stays clear of the enemy's build power, and the rally point is on it)
                local site = byKey[key]
                local route = ER.Route(cx, cz, c.tx, c.tz, { avoid = site and site.avoid })
                local before, after
                c.rx, c.rz, before, after = ER.Back(route, cx, cz, CONVOY.RALLY_D)
                c.via = {}
                for k2 = 1, #after - 1 do c.via[#c.via + 1] = after[k2] end      -- (the waypoints from the rally point on; the site is the unload)
                local d = 0
                for k2 = 1, #route do local p = route[k2]; local q = route[k2 - 1] or { x = cx, z = cz }; d = d + math.sqrt((p.x - q.x) ^ 2 + (p.z - q.z) ^ 2) end
                for _, tid in ipairs(live) do if AT.Job(tid).state == "carrying" then AT.MoveTo(tid, c.rx, c.rz, before) end end
                c.state, c.rallyF = "rally", frame
                Echo(frame, "CONVOY for site %d: %d of %d loaded, gathering at %d,%d (the route round the map's edge: %d waypoints, %.0f long)", key, n, #live, c.rx, c.rz, #route, d)
            end
        elseif c.state == "rally" then
            local at = 0
            for _, tid in ipairs(live) do
                local x, _, z = Spring.GetUnitPosition(tid)
                if x and (x - c.rx) ^ 2 + (z - c.rz) ^ 2 <= CONVOY.RALLY_R ^ 2 then at = at + 1 end
                local j = AT.Job(tid)
                if j.state == "carrying" and x and (x - c.rx) ^ 2 + (z - c.rz) ^ 2 > CONVOY.RALLY_R ^ 2 and (Spring.GetUnitCommandCount and (Spring.GetUnitCommandCount(tid) or 0) == 0) then
                    AT.MoveTo(tid, c.rx, c.rz)                               -- (loaded late: on to the rally point)
                end
            end
            c.atRally = at
            -- GO: every loaded transport sets down at once -- no gathering, no waiting for the route (user 2026-11-08: "the trans seem to wait to land ...
            -- just need to land as fast as possible either it is clear or it is not waiting will not help ... The trans waited ~60 seconds to land and in
            -- that time the disparity between it and the enemy only grew"); the convoy waits on the edge only BEFORE go (synced with the ground units)
            local site = byKey[key]
            if site and site.convoy and site.convoy.go then
                local loaded = 0
                for _, tid in ipairs(live) do
                    local j = AT.Job(tid)
                    if j.state == "carrying" then AT.Go(tid, j.x, j.z, frame, { timeout = 120 * 30, via = c.via }); loaded = loaded + 1 end
                end
                c.state, c.flyF = "flying", frame
                Echo(frame, "CONVOY for site %d: GO -- %d transports land now (%d were at the rally point)", key, loaded, at)
            end
        elseif c.state == "flying" then
            for _, tid in ipairs(live) do                                  -- (one that loaded late: straight in too)
                local j = AT.Job(tid)
                if j.hold and j.state == "carrying" then AT.Go(tid, j.x, j.z, frame, { timeout = 120 * 30, via = c.via }) end
            end
        end
    end
    Publish()
end

M.Stats = function() return stats end

return M
