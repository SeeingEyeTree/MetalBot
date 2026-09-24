-- bar_framework/threat_log.lua
-- Records what threat_map saw, so a game can be replayed in threat_map_viz.html.
--
-- Everything goes out through Spring.Echo as `[TML] <kind> f=<frame> team=<t> ...` lines,
-- one per record, so it rides the infolog like the [TRK] rows.  Three record kinds:
--
--   snap  every SNAP_PERIOD frames: the bot's own state at that moment
--           urg=<state>,<worst deficit>,<channel>
--           e=<contacts>   id/def/x/z/lastSeenFrame;...   (TM.Contacts(): what the bot believed)
--           a=<combatants> def/x/z;...                    (own mobile armed units, capped)
--           i=<incidents>  x/z/vx/vz/n/dmg/lost/chan/first/last/band/score;...
--   ev    each input the widget fed to threat_map
--           k=hit   x z dmg att=<attacker def|->  ax az (attacker position if known)
--           k=loss  x z def att=<attacker def|-> attally=<0|1|->
--   geom  whenever the home/foe estimate changes: home / foe / map size
-- Positions are integers (elmos).  Unit defs are logged by NAME, not id.
--
--   local TL = VFS.Include("LuaUI/Widgets/bar_framework/threat_log.lua")
--   TL.Init{ TM = TM, UQ = UQ, MM = MM, teamID = t, allyID = a }
--   TL.Frame(frame)                      -- every game frame (cheap; acts on the period)
--   TL.OnDamaged(...same args as TM...)  -- before TM.OnDamaged
--   TL.OnUnitDestroyed(...)              -- before TM.OnUnitDestroyed

local M = {}

M.SNAP_PERIOD = 150   -- 5 game-seconds
M.MAX_ALLIES  = 400

local TM, UQ, MM, teamID, allyID
local lastGeom
local lastHit = {}   -- throttle: one hit row per 200-elmo cell + attacker per HIT_GAP frames
M.HIT_GAP = 0      -- >0 throttles rows; 0 logs every hit (needed for exact replay of incident smoothing)

function M.Init(o)
    TM, UQ, MM, teamID, allyID = o.TM, o.UQ, o.MM, o.teamID, o.allyID
end

local function defName(defID)
    local d = defID and UnitDefs[defID]
    return d and d.name or "-"
end

local function r(n) return math.floor((n or 0) + 0.5) end

local function Echo(kind, frame, body)
    Spring.Echo(string.format("[TML] %s f=%d team=%d %s", kind, frame, teamID or -1, body))
end

local function IsCombatant(defID)
    return defID and UQ.is_mobile(defID) and UQ.has_weapons(defID)
       and not UQ.is_builder(defID) and not UQ.is_factory(defID)
       and not UQ.is_commander(defID)
end

function M.Frame(frame)
    if not TM or frame % M.SNAP_PERIOD ~= 0 then return end

    -- Logged again whenever the foe estimate moves (a sighting replaces the mirror guess).
    if MM and MM.Ready() then
        local hx, hz = MM.Home()
        local fx, fz = MM.Foe()
        local mx, mz = MM.MapSize()
        local g = string.format("home=%d,%d foe=%d,%d map=%d,%d",
            r(hx), r(hz), r(fx), r(fz), r(mx), r(mz))
        if g ~= lastGeom then lastGeom = g; Echo("geom", frame, g) end
    end

    local urg, worst, ch = TM.ProductionUrgency()

    local e = {}
    for id, c in pairs(TM.Contacts()) do
        e[#e + 1] = string.format("%d/%s/%d/%d/%d", id, defName(c.defID), r(c.x), r(c.z), c.frame)
    end

    local a = {}
    for _, uid in ipairs(Spring.GetTeamUnits(teamID) or {}) do
        local defID = Spring.GetUnitDefID(uid)
        if IsCombatant(defID) and #a < M.MAX_ALLIES then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then a[#a + 1] = string.format("%s/%d/%d", defName(defID), r(x), r(z)) end
        end
    end

    local inc = {}
    for _, i in ipairs(TM.Incidents()) do
        inc[#inc + 1] = string.format("%d/%d/%.3f/%.3f/%d/%d/%d/%s/%d/%d/%s/%d",
            r(i.x), r(i.z), i.vx, i.vz, i.n, r(i.dmg), r(i.valueLost), i.channel,
            i.firstFrame, i.lastFrame, TM.IncidentBand(i), r(TM.IncidentScore(i)))
    end

    Echo("snap", frame, string.format("urg=%s,%.3f,%s e=%s a=%s i=%s",
        urg, worst or 0, tostring(ch), table.concat(e, ";"), table.concat(a, ";"), table.concat(inc, ";")))
end

function M.OnDamaged(victimID, victimDefID, damage, weaponDefID, projectileID,
                     attackerID, attackerDefID, frame)
    local vx, _, vz = Spring.GetUnitPosition(victimID)
    if not vx then return end
    local ax, az = "-", "-"
    if attackerID then
        local x, _, z = Spring.GetUnitPosition(attackerID)
        if x then ax, az = r(x), r(z) end
    end
    local key = math.floor(vx / 200) .. ":" .. math.floor(vz / 200) .. ":" .. defName(attackerDefID)
    if M.HIT_GAP > 0 and lastHit[key] and frame - lastHit[key] < M.HIT_GAP then return end
    lastHit[key] = frame
    Echo("ev", frame, string.format("k=hit x=%d z=%d dmg=%d att=%s ax=%s az=%s",
        r(vx), r(vz), r(damage), defName(attackerDefID), tostring(ax), tostring(az)))
end

function M.OnUnitDestroyed(unitID, defID, isMine, frame, attackerID)
    if not isMine then return end
    local x, _, z = Spring.GetUnitPosition(unitID)
    if not x then return end
    local ally = "-"
    if attackerID then
        local t = Spring.GetUnitAllyTeam(attackerID)
        if t ~= nil then ally = (t == allyID) and "0" or "1" end
    end
    local att = attackerID and defName(Spring.GetUnitDefID(attackerID)) or "-"
    Echo("ev", frame, string.format("k=loss x=%d z=%d def=%s att=%s attally=%s",
        r(x), r(z), defName(defID), att, ally))
end

return M
