-- threat_map_viz glue.  Runs the REAL bar_framework/threat_map.lua (TM_SRC) and
-- unit_query.lua (UQ_SRC) against a scenario handed over by the page.  Only the map
-- model and the Spring API are stubbed; every number the page shows comes out of
-- threat_map.lua itself.
--
-- Globals set by the page before this file runs: UnitDefs, WeaponDefs, TM_SRC, UQ_SRC.

local POS, TEAM, DEFOF, ALLY, ONLY = {}, {}, {}, {}, nil
local TM, MM
local S_HOME = { 0, 0 }

Spring = {
    Echo            = function() end,
    GetUnitPosition = function(uid)
        local p = POS[uid]
        if p then return p[1], 0, p[2] end
    end,
    GetUnitAllyTeam     = function(uid) return TEAM[uid] or 0 end,
    GetUnitDefID        = function(uid) return DEFOF[uid] end,
    GetUnitLastAttacker = function() return nil end,
    GetTeamUnits        = function()
        if ONLY then return { ONLY } end
        local t = {}
        for i = 1, #ALLY do t[i] = ALLY[i].id end
        return t
    end,
}

local UQ = load(UQ_SRC, "=unit_query")()

TM = load(TM_SRC, "=threat_map")()
MM = { Ready = function() return false end, Dist = function() return 1 end,
       Home = function() return 0, 0 end, DistBetween = function() return 0 end }
TM.Init{ MM = MM, UQ = UQ, teamID = 0, allyID = 0 }

-- ── JSON out ──────────────────────────────────────────────────────────────────

local function esc(c) return string.format("\\u%04x", c:byte()) end
local function enc(v)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return string.format("%.10g", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "string" then
        return '"' .. (v:gsub('[%c"\\]', esc)) .. '"'
    elseif t == "table" then
        if next(v) == nil then return "[]" end
        local out = {}
        if #v > 0 then
            for i = 1, #v do out[i] = enc(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for k, x in pairs(v) do out[#out + 1] = enc(tostring(k)) .. ":" .. enc(x) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end

-- ── Tunables ──────────────────────────────────────────────────────────────────

local TUNABLES = {
    "CONTACT_TTL", "INCIDENT_MERGE", "INCIDENT_TTL",
    "SPEED_BANDS", "POS_GROUND", "POS_AIR",
    "BAND_IGNORE", "BAND_RESPOND", "BAND_ALARM",
    "DEFICIT_RUSH", "DEFICIT_BUILD",
    "NONSPECIALIST_AA_WEIGHT", "RESPONSE_HORIZON",
}

function defaults()
    local m = load(TM_SRC, "=threat_map")()
    local d = {}
    for _, k in ipairs(TUNABLES) do d[k] = m[k] end
    return enc(d)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function withOnly(id, fn)
    ONLY = id
    local a, b = fn()
    ONLY = nil
    return a, b
end

local function allyBreakdown(x, z)
    local rows = {}
    for i = 1, #ALLY do
        local id = ALLY[i].id
        rows[i] = {
            id = id,
            ownG   = withOnly(id, function() return TM.OwnStrength("ground") end),
            ownA   = withOnly(id, function() return TM.OwnStrength("air") end),
            availG = withOnly(id, function() return TM.AvailableStrength("ground", x, z) end),
            availA = withOnly(id, function() return TM.AvailableStrength("air", x, z) end),
        }
    end
    return rows
end

local function bandAll()
    local incs = TM.Incidents()
    for i = 1, #incs do TM.IncidentBand(incs[i]) end
end

-- ── Run a scenario ────────────────────────────────────────────────────────────

function run(S)
    TM = load(TM_SRC, "=threat_map")()
    for k, v in pairs(S.tun or {}) do TM[k] = v end

    local hx, hz = S.home[1], S.home[2]
    local dist = math.sqrt((S.foe[1] - hx) ^ 2 + (S.foe[2] - hz) ^ 2)
    S_HOME = { hx, hz }
    MM = {
        Ready       = function() return dist > 0 end,
        Home        = function() return hx, hz end,
        Dist        = function() return dist end,
        DistBetween = function(a, b, c, d) return math.sqrt((c - a) ^ 2 + (d - b) ^ 2) end,
    }
    TM.Init{ MM = MM, UQ = UQ, teamID = 0, allyID = 0 }

    POS, TEAM, DEFOF, ALLY = {}, {}, {}, {}
    for _, u in ipairs(S.allies or {}) do
        POS[u.id] = { u.x, u.z }
        DEFOF[u.id] = u.def
        ALLY[#ALLY + 1] = u
    end

    -- Replay in frame order.  Contacts go in before hits at the same frame, and
    -- TM.Update runs at each step the way the widget calls it every tick, so contacts
    -- and incidents expire mid-scenario exactly as they would live.
    local items = {}
    for _, e in ipairs(S.enemies or {}) do items[#items + 1] = { f = e.frame, k = "enemy", e = e, s = #items } end
    for _, e in ipairs(S.events or {}) do items[#items + 1] = { f = e.frame, k = "event", e = e, s = #items } end
    table.sort(items, function(a, b)
        if a.f ~= b.f then return a.f < b.f end
        if a.k ~= b.k then return a.k == "enemy" end
        return a.s < b.s
    end)

    for _, it in ipairs(items) do
        TM.Update(it.f)
        local e = it.e
        if it.k == "enemy" then
            POS[e.id], TEAM[e.id], DEFOF[e.id] = { e.x, e.z }, 1, e.def
            TM.Note(e.id, e.x, e.z, e.def, e.frame)
        else
            local vid = e.id
            POS[vid], TEAM[vid] = { e.x, e.z }, 0
            if e.kind == "hit_unseen" then
                TM.OnDamaged(vid, nil, e.dmg, nil, nil, nil, nil, e.frame)
            elseif e.kind == "hit_seen" then
                local aid = e.id + 200000
                POS[aid], TEAM[aid], DEFOF[aid] = { e.x, e.z }, 1, e.def
                TM.OnDamaged(vid, nil, e.dmg, nil, nil, aid, e.def, e.frame)
            elseif e.kind == "hit_known" then
                -- Replay of a logged hit: the attacker's type was known (so the channel is),
                -- but its position is not re-noted; the logged contact list already has it.
                local aid = e.id + 200000
                TEAM[aid], DEFOF[aid] = 1, e.def
                TM.OnDamaged(vid, nil, e.dmg, nil, nil, aid, e.def, e.frame)
            elseif e.kind == "loss_killed" then
                TEAM[e.id + 300000] = 1
                TM.OnUnitDestroyed(vid, e.def, true, e.frame, e.id + 300000)
            else -- loss_quiet: reclaim / unattributed death
                TM.OnUnitDestroyed(vid, e.def, true, e.frame, nil)
            end
        end
        bandAll()
    end
    -- Replay only: contacts that were alive earlier but are absent from the final list died
    -- (or aged out) before now; the logged list is the truth for the end state.
    for _, id in ipairs(S.stale or {}) do TM.OnUnitDestroyed(id, nil, false, S.frame) end
    TM.Update(S.frame)
    bandAll()

    local out = { channels = {}, contacts = {}, incidents = {}, allies = {} }

    for _, ch in ipairs({ "ground", "air" }) do
        local score, cx, cz = TM.ChannelScore(ch)
        local approach = TM.ApproachScore(ch)
        local avail = TM.AvailableStrength(ch, hx, hz)
        out.channels[ch] = {
            score = score, cx = cx, cz = cz, approach = approach,
            avail = avail, own = TM.OwnStrength(ch),
            deficit = approach / math.max(1, avail),
        }
    end

    local state, worst, wch = TM.ProductionUrgency()
    out.urgency = { state = state, worst = worst, channel = wch }

    local top = TM.TopIncident()
    for i, inc in ipairs(TM.Incidents()) do
        local score = TM.IncidentScore(inc)
        out.incidents[i] = {
            x = inc.x, z = inc.z, vx = inc.vx, vz = inc.vz,
            n = inc.n, dmg = inc.dmg, valueLost = inc.valueLost,
            channel = inc.channel, first = inc.firstFrame, last = inc.lastFrame,
            score = score, band = inc.band, bandNow = TM.Band(score),
            deficit = TM.Deficit(score, inc.channel, inc.x, inc.z),
            leaving = TM.IsLeaving(inc), top = (inc == top),
        }
    end

    for id, c in pairs(TM.Contacts()) do
        local ch = c.air and "air" or "ground"
        local w = TM.PosWeight(ch, c.x, c.z)
        out.contacts[#out.contacts + 1] = {
            id = id, x = c.x, z = c.z, def = c.defID, frame = c.frame,
            v = c.v, air = c.air, w = w, threat = c.v * w,
            counted = (c.defID and UQ.is_mobile(c.defID) and UQ.has_weapons(c.defID)) and true or false,
        }
    end

    out.allies = allyBreakdown(hx, hz)
    return enc(out)
end

-- What the palette card shows for one unit type.
function info(def)
    local ch = UQ.is_air(def) and "air" or "ground"
    local combatant = UQ.is_mobile(def) and UQ.has_weapons(def) and not UQ.is_builder(def)
        and not UQ.is_factory(def) and not UQ.is_commander(def)
    return enc({
        intrinsic = TM.Intrinsic(def), speedFactor = TM.SpeedFactor(UQ.max_speed(def)),
        channel = ch, dedicatedAA = UQ.is_dedicated_aa(def),
        hitsAir = UQ.can_hit_air(def), hitsGround = UQ.can_hit_ground(def),
        combatant = combatant and true or false,
    })
end

-- Everything that depends on a point on the map: position weights, what could reach
-- it in time (total and per ally), and the what-if threat of one more enemy there.
function probe(x, z, def)
    local out = {
        wG = TM.PosWeight("ground", x, z), wA = TM.PosWeight("air", x, z),
        availG = TM.AvailableStrength("ground", x, z),
        availA = TM.AvailableStrength("air", x, z),
        allies = allyBreakdown(x, z),
    }
    if def and UnitDefs[def] then
        local t, ch = TM.ThreatOf(def, x, z)
        out.what = { threat = t, channel = ch, deficit = TM.Deficit(t, ch, x, z) }
    end
    return enc(out)
end
