-- ledger_logger.lua   (2026-10-25)
-- Three ledgers that say where a bot's improvements are, for ledger_report.py.  A general widget (like metalbot_stats_tracker.lua and
-- human_control_logger.lua): it only reads, issues no orders, and works for a bot, a person or both.  Rows go to the infolog AND to
-- <BAR data>/LuaUI/Config/metalbot_ledger_<date>.log (the infolog is overwritten on each launch).
--
--   [LED] init     team start_x start_z map
--   [LED] spend    every SPEND_EVERY frames (30 s): WHERE THE INCOME WENT and why the rest did not go.
--                    m_inc m_pull m_bank(fraction of storage) e_inc e_pull e_fill    the team's resources
--                    cap=<units>/<max>  labs_busy/labs_idle  cons_idle  nano_idle  bp_use (share of all build power in use)
--                    to_<kind>=<metal/s>   the metal rate the builders are putting into each kind of thing:
--                      army_ground army_air   combat units        bp    constructors, labs, nanos, decoy commanders, rez bots
--                      eco   mexes, energy, storage               defence   armed structures      other   the rest   commander
--                    explained = sum of the to_ rates; unexplained = m_pull - explained (what the builders' own numbers miss)
--                    why = spending (pull is >= 90% of income, or the bank is not filling) | unit_cap | idle_labs | energy |
--                          build_power (all builders busy: more BP would spend more) | idle_builders | nothing_to_build
--   [LED] fight    one row per fight (events closer than FIGHT_GAP frames): what each side LOST, in value_weights terms
--                    lost_<cat> killed_<cat> (cat = army eco bp defence commander other, metal-equivalent), ratio = killed / lost,
--                    top_lost / top_killed = name:count,...  x z = where   dur = seconds   n_lost n_killed
--   [LED] value    every minute: the cumulative lost_ / killed_ totals by category
--   [LED] scout    one row per arrival WAVE at the base (an enemy within ARRIVE_R of our start; waves are WAVE_GAP frames apart):
--                    lead_s = seconds between that unit first being seen (LOS or radar) and reaching ARRIVE_R of home (0 = a surprise),
--                    seen_d = how far away it was when first seen, seen_by = los | radar | both, unit = its type (? = radar blip),
--                    n = units in the wave, surprise = 1 when lead_s < SURPRISE_S
-- What a unit is worth: bar_framework/value_weights.lua (eco = cost + 60 s of income, build power the most, commander 25k).
-- Limits: a kill is only logged when the unit died in LOS (the callin does not fire for radar-only deaths); an enemy that is never seen
-- is never in the scout ledger.  Test: tests/test_ledger_logger.lua.

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name    = "Ledger Logger",
        desc    = "Spend, fight and scouting-lead ledgers (value-weighted)",
        author  = "MetalBot",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 100001,
        enabled = true
    }
end

local SPEND_EVERY = 900       -- frames between spend rows (30 s)
local VALUE_EVERY = 1800      -- frames between cumulative value rows (1 min)
local FIGHT_GAP   = 150       -- frames of quiet that end a fight
local SCAN_EVERY  = 30        -- frames between enemy scans (scout ledger)
local ARRIVE_R    = 1800      -- an enemy this close to our start has "arrived"
local WAVE_GAP    = 600       -- frames without an arrival that close a wave
local SURPRISE_S  = 5         -- a lead under this many seconds is a surprise

local floor, sqrt, fmt = math.floor, math.sqrt, string.format
local VW = VFS.Include("LuaUI/Widgets/bar_framework/value_weights.lua").New()

local myTeam, myAlly = 0, 0
local startX, startZ = 0, 0
local frame = 0
local logFile
local CATS = { "army", "eco", "bp", "defence", "commander", "other" }

-- ── output ────────────────────────────────────────────────────────────────────

local function Stamp(f) local s = floor(f / 30); return fmt("f=%d t=%d:%02d", f, floor(s / 60), s % 60) end

local function Out(line)
    Spring.Echo(line)
    if logFile then logFile:write(line, "\n"); logFile:flush() end
end

local function OpenLog()
    local ok, f = pcall(io.open, "LuaUI/Config/metalbot_ledger_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")
    if ok and f then logFile = f end
end

local nameCache = {}
local function DefName(defID)
    local n = nameCache[defID]
    if not n then
        local d = defID and UnitDefs[defID]
        n = d and d.name or "?"
        nameCache[defID] = n
    end
    return n
end

local function IsAlly(team)
    if team == nil then return false end
    if team == myTeam then return true end
    if Spring.AreTeamsAllied then
        local ok, r = pcall(Spring.AreTeamsAllied, team, myTeam)
        if ok then return r and true or false end
    end
    return false
end

local function Top(counts, n)
    local arr = {}
    for k, c in pairs(counts) do arr[#arr + 1] = { k, c } end
    table.sort(arr, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local out = {}
    for i = 1, math.min(n, #arr) do out[i] = arr[i][1] .. ":" .. arr[i][2] end
    return #out > 0 and table.concat(out, ",") or "-"
end

local function ZeroCats() local t = {}; for _, c in ipairs(CATS) do t[c] = 0 end return t end

-- ── fight ledger ──────────────────────────────────────────────────────────────

local totals = { lost = ZeroCats(), killed = ZeroCats() }
local fight       -- the fight in progress, or nil
local seen = {}   -- scout ledger: [enemy unitID] = { f = first frame seen, d = distance to home then, by = "los"|"radar"|"both", def = defID or nil, arrived = bool }

local function NewFight(f) return { f0 = f, f1 = f, lost = ZeroCats(), killed = ZeroCats(), lostN = {}, killedN = {}, nl = 0, nk = 0, sx = 0, sz = 0, n = 0 } end

local function FlushFight(f, force)
    if not fight then return end
    if not force and f - fight.f1 < FIGHT_GAP then return end
    local fi = fight
    fight = nil
    local lv, kv = 0, 0
    for _, c in ipairs(CATS) do lv = lv + fi.lost[c]; kv = kv + fi.killed[c] end
    local parts = {}
    for _, c in ipairs(CATS) do
        parts[#parts + 1] = fmt("lost_%s=%d killed_%s=%d", c, fi.lost[c], c, fi.killed[c])
    end
    Out(fmt("[LED] fight %s dur=%d x=%d z=%d n_lost=%d n_killed=%d lost=%d killed=%d ratio=%.2f %s top_lost=%s top_killed=%s",
        Stamp(fi.f0), floor((fi.f1 - fi.f0) / 30), fi.n > 0 and fi.sx / fi.n or 0, fi.n > 0 and fi.sz / fi.n or 0, fi.nl, fi.nk,
        lv, kv, lv > 0 and kv / lv or (kv > 0 and 99 or 0), table.concat(parts, " "), Top(fi.lostN, 5), Top(fi.killedN, 5)))
end

local function Progress(unitID)
    local ok, being, prog = pcall(Spring.GetUnitIsBeingBuilt, unitID)
    if ok and being then return prog or 0 end
    return 1
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
    seen[unitID] = nil
    if not unitDefID then return end
    local mine, theirs = IsAlly(unitTeam), not IsAlly(unitTeam)
    -- our own losses to an enemy; reclaims, decay and self-destruct (no attacker, or one of ours) are not losses
    local byEnemy = attackerTeam ~= nil and not IsAlly(attackerTeam)
    local byUs = attackerTeam ~= nil and IsAlly(attackerTeam)
    local lostSide = mine and byEnemy
    local killSide = theirs and byUs
    if not (lostSide or killSide) then return end
    local v, cat = VW.Value(unitDefID, Progress(unitID))
    if v <= 0 then return end
    if not fight then fight = NewFight(frame) end
    fight.f1 = frame
    local x, _, z = Spring.GetUnitPosition(unitID)
    if x then fight.sx, fight.sz, fight.n = fight.sx + x, fight.sz + z, fight.n + 1 end
    local name = DefName(unitDefID)
    if lostSide then
        fight.lost[cat] = fight.lost[cat] + v; totals.lost[cat] = totals.lost[cat] + v
        fight.nl = fight.nl + 1; fight.lostN[name] = (fight.lostN[name] or 0) + 1
    else
        fight.killed[cat] = fight.killed[cat] + v; totals.killed[cat] = totals.killed[cat] + v
        fight.nk = fight.nk + 1; fight.killedN[name] = (fight.killedN[name] or 0) + 1
    end
end

local function ValueRow(f)
    local parts = {}
    for _, c in ipairs(CATS) do
        parts[#parts + 1] = fmt("lost_%s=%d killed_%s=%d", c, totals.lost[c], c, totals.killed[c])
    end
    Out(fmt("[LED] value %s %s", Stamp(f), table.concat(parts, " ")))
end

-- ── spend ledger ──────────────────────────────────────────────────────────────

local function Res(kind)
    local cur, stor, pull, inc, exp = Spring.GetTeamResources(myTeam, kind)
    return cur or 0, stor or 1, pull or 0, inc or 0, exp or 0
end

-- number of orders in a unit's queue (GetUnitCommands(id, 0) returns the count; some versions return a table)
local function QueueLen(uid)
    local ok, q = pcall(Spring.GetUnitCommands, uid, 0)
    if not ok or q == nil then return 0 end
    if type(q) == "number" then return q end
    return #q
end

local function FactoryHasQueue(uid)
    if not Spring.GetRealBuildQueue then return QueueLen(uid) > 0 end
    local ok, q = pcall(Spring.GetRealBuildQueue, uid)
    if not ok or q == nil then return QueueLen(uid) > 0 end
    return #q > 0
end

local function SpendKind(d)
    local cat = VW.Category(d)
    if cat == "army" then return d.canFly and "army_air" or "army_ground" end
    return cat
end

local SPEND_KINDS = { "army_ground", "army_air", "bp", "eco", "defence", "commander", "other" }

local function SpendRow(f)
    local mCur, mStor, mPull, mInc = Res("metal")
    local eCur, eStor, ePull, eInc = Res("energy")
    local to = {}
    for _, k in ipairs(SPEND_KINDS) do to[k] = 0 end
    local labsBusy, labsIdle, consIdle, nanoIdle, nBuilders = 0, 0, 0, 0, 0
    local bpAll, bpUsed = 0, 0
    for _, uid in ipairs(Spring.GetTeamUnits(myTeam) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        local d = defID and UnitDefs[defID]
        if d and (d.isBuilder or d.isFactory) and (d.buildSpeed or 0) > 0 and not Spring.GetUnitIsBeingBuilt(uid) then
            nBuilders = nBuilders + 1
            local tgt = Spring.GetUnitIsBuilding(uid)
            local power = 0
            if tgt then
                power = Spring.GetUnitCurrentBuildPower and Spring.GetUnitCurrentBuildPower(uid) or 1
                local td = UnitDefs[Spring.GetUnitDefID(tgt) or -1]
                if td and (td.buildTime or 0) > 0 then
                    local k = SpendKind(td)
                    to[k] = to[k] + power * d.buildSpeed * (td.metalCost or 0) / td.buildTime
                end
            end
            bpAll = bpAll + d.buildSpeed
            bpUsed = bpUsed + power * d.buildSpeed
            if d.isFactory then
                if tgt then labsBusy = labsBusy + 1
                elseif not FactoryHasQueue(uid) then labsIdle = labsIdle + 1 end
            elseif not tgt and QueueLen(uid) == 0 then
                if (d.speed or 0) > 0 then consIdle = consIdle + 1 else nanoIdle = nanoIdle + 1 end
            end
        end
    end
    local explained = 0
    for _, k in ipairs(SPEND_KINDS) do explained = explained + to[k] end
    local units, cap = 0, 0
    if Spring.GetTeamUnitCount then units = Spring.GetTeamUnitCount(myTeam) or 0 end
    if Spring.GetTeamMaxUnits then cap = Spring.GetTeamMaxUnits(myTeam) or 0 end
    local bankFrac = mStor > 0 and mCur / mStor or 0
    local eFill = eStor > 0 and eCur / eStor or 0
    local bpUse = bpAll > 0 and bpUsed / bpAll or 0
    local why = "spending"
    if mPull < 0.9 * mInc and bankFrac >= 0.5 then
        if cap > 0 and units >= 0.97 * cap then why = "unit_cap"
        elseif labsIdle > 0 then why = "idle_labs"
        elseif eFill < 0.02 then why = "energy"
        elseif bpUse >= 0.85 then why = "build_power"
        elseif consIdle + nanoIdle > 0.3 * math.max(1, nBuilders) then why = "idle_builders"
        else why = "nothing_to_build" end
    end
    local parts = {}
    for _, k in ipairs(SPEND_KINDS) do parts[#parts + 1] = fmt("to_%s=%.0f", k, to[k]) end
    Out(fmt("[LED] spend %s m_inc=%.0f m_pull=%.0f m_bank=%.2f e_inc=%.0f e_pull=%.0f e_fill=%.2f cap=%d/%d labs_busy=%d labs_idle=%d cons_idle=%d nano_idle=%d bp_use=%.2f %s explained=%.0f unexplained=%.0f why=%s",
        Stamp(f), mInc, mPull, bankFrac, eInc, ePull, eFill, units, cap, labsBusy, labsIdle, consIdle, nanoIdle, bpUse,
        table.concat(parts, " "), explained, mPull - explained, why))
end

-- ── scouting lead ─────────────────────────────────────────────────────────────

local wave            -- the arrival wave in progress: { rec = the first unit's record, name, f0 (first arrival), f (latest), n }

local function LosBy(uid)
    local ok, st = pcall(Spring.GetUnitLosState, uid, myAlly, false)
    if not ok or type(st) ~= "table" then return "los" end
    local los, radar = st.los or st.inLos, st.radar or st.inRadar
    if los and radar then return "both" elseif los then return "los" elseif radar then return "radar" end
    return "los"
end

local function FlushWave(f, force)
    if not wave then return end
    if not force and f - wave.f < WAVE_GAP then return end
    local w = wave
    wave = nil
    local lead = math.max(0, (w.f0 - w.rec.f) / 30)
    Out(fmt("[LED] scout %s lead_s=%.0f seen_d=%d seen_by=%s unit=%s n=%d surprise=%d", Stamp(w.f0), lead, w.rec.d, w.rec.by,
        w.name, w.n, lead < SURPRISE_S and 1 or 0))
end

local function ScanEnemies(f)
    FlushWave(f)
    for _, uid in ipairs(Spring.GetAllUnits() or {}) do
        local team = Spring.GetUnitTeam(uid)
        if team ~= nil and not IsAlly(team) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local dx, dz = x - startX, z - startZ
                local dist = sqrt(dx * dx + dz * dz)
                local rec = seen[uid]
                if not rec then
                    rec = { f = f, d = dist, by = LosBy(uid), def = Spring.GetUnitDefID(uid) }
                    seen[uid] = rec
                end
                if not rec.arrived and dist <= ARRIVE_R then
                    local d = rec.def and UnitDefs[rec.def]
                    -- a radar blip (type unknown) counts; so does any armed or mobile enemy, but not a structure or a wreck
                    if (not d) or ((d.speed or 0) > 0) then
                        rec.arrived = true
                        if not wave then
                            wave = { rec = rec, f0 = f, f = f, n = 0, name = d and DefName(rec.def) or "?" }
                        end
                        wave.n, wave.f = wave.n + 1, f
                    end
                end
            end
        end
    end
end

-- ── callins ───────────────────────────────────────────────────────────────────

function widget:Initialize()
    myTeam = Spring.GetMyTeamID(); myAlly = Spring.GetMyAllyTeamID()
    OpenLog()
    if Spring.GetTeamStartPosition then
        local x, _, z = Spring.GetTeamStartPosition(myTeam)
        if x and x > 0 then startX, startZ = x, z end
    end
    Out(fmt("[LED] init team=%d start_x=%d start_z=%d map=%s", myTeam, startX, startZ, tostring(Game and Game.mapName or "?")))
end

function widget:GameFrame(f)
    frame = f
    if fight and f - fight.f1 >= FIGHT_GAP then FlushFight(f) end
    if f > 0 and f % SPEND_EVERY == 0 then
        local ok, err = pcall(SpendRow, f)
        if not ok then Out("[LED] error spend: " .. tostring(err)) end
    end
    if f > 0 and f % VALUE_EVERY == 0 then ValueRow(f) end
    if f % SCAN_EVERY == 0 then
        local ok, err = pcall(ScanEnemies, f)
        if not ok then Out("[LED] error scout: " .. tostring(err)) end
    end
end

function widget:Shutdown()
    FlushFight(frame, true)
    FlushWave(frame, true)
    ValueRow(frame)
    if logFile then logFile:close(); logFile = nil end
end
