-- bar_framework/endgame.lua
-- game_mechanics 9: bots do not resign, so a won game only ends when the enemy
-- commander dies.  A bot that has won but cannot find the commander is stuck forever.
-- Intended behaviour: detect "we've won", scout the map, send bombers at the commander.
--
-- DETECTING "WON" (the doc's open problem)
-- ----------------------------------------
-- A bot cannot see the other side's economy, only what it has seen.  So "won" here
-- means all of:
--   * late enough that a quiet map is not just the opening (WON_MIN_FRAME);
--   * no armed enemy unit has been in view for QUIET_FRAMES;
--   * no attack on us is in progress;
--   * we have an army worth the name, and what we remember of theirs is small next to
--     it (UNWIN_RATIO);
--   * we have actually been looking: our front is past the midline, or recon has seen
--     the enemy base recently.  An army sitting at home seeing nothing proves nothing.
-- It must hold on two checks in a row to switch on, and switches off again the moment
-- a real enemy army turns up, so a wrong call costs a few bombers, not the game.
--
-- STRIKE
-- ------
-- Bombers (lab controller builds them only while hunting) wait at home until the
-- commander has been seen recently, then all go at once: ATTACK on the unit if it is in
-- view, otherwise on its last known position.  Bombers are one-way (no repair pads).
-- Nuke silos, if any, fire at the same position unless an enemy anti-nuke covers it.
--
-- USAGE
--   local EG = VFS.Include("LuaUI/Widgets/bar_framework/endgame.lua")
--   EG.Init{ EI = EI, MM = MM, UQ = UQ, ARMY = ARMY, TM = TM, teamID = t }
--   EG.Update(frame, armyValue, frontFrac, enemyBaseSeenFrame)   -- every ~150 frames
--   EG.Strike(frame, bomberIDs)                                  -- every ~30 frames
--   if EG.Hunting() then ... end

local M = {}

-- ── Tunables ──────────────────────────────────────────────────────────────────

M.WON_MIN_FRAME   = 15 * 60 * 30
M.QUIET_FRAMES    = 3 * 60 * 30
M.MIN_ARMY_VALUE  = 8000
M.UNWIN_RATIO     = 0.30
M.FRONT_FRAC      = 0.50   -- our front must be at least this far along home->foe...
M.BASE_SEEN_AGE   = 3600   -- ...or recon must have seen their base within 2 min
M.CONFIRM_CHECKS  = 2
M.STRIKE_FRESH    = 1800   -- a commander sighting this recent is worth a strike
M.BOMBER_MIN      = 4      -- wait for this many, unless the commander is in view now
M.STAGE_BACK      = 600    -- bombers wait this far behind home
M.NUKE_FRESH      = 900
M.NUKE_INTERVAL   = 900    -- frames between missiles

local CMD_MOVE   = 10
local CMD_ATTACK = 20

-- ── State ─────────────────────────────────────────────────────────────────────

local EI, MM, UQ, ARMY, TM
local myTeamID
local hunting    = false
local huntSince  = nil
local confirms   = 0
local lastNuke   = -1e9
local reason     = ""

function M.Init(opts)
    EI, MM, UQ, ARMY, TM = opts.EI, opts.MM, opts.UQ, opts.ARMY, opts.TM
    myTeamID = opts.teamID
end

function M.Hunting() return hunting end
function M.Reason() return reason end

local function Clock(frame)
    return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60)
end

-- Pure check, exposed for testing.  Returns won, why-not.
function M.IsWon(frame, armyValue, frontFrac, enemyBaseSeenFrame, lastArmed, incidents,
                 enemyValue)
    if frame < M.WON_MIN_FRAME then return false, "early" end
    if frame - (lastArmed or -1e9) < M.QUIET_FRAMES then return false, "enemy army seen" end
    if (incidents or 0) > 0 then return false, "under attack" end
    if (armyValue or 0) < M.MIN_ARMY_VALUE then return false, "army too small" end
    if (enemyValue or 0) > (armyValue or 0) * M.UNWIN_RATIO then return false, "enemy army remembered" end
    local looked = (frontFrac or 0) >= M.FRONT_FRAC
        or (enemyBaseSeenFrame and frame - enemyBaseSeenFrame <= M.BASE_SEEN_AGE)
    if not looked then return false, "not looked" end
    return true, "won"
end

function M.Update(frame, armyValue, frontFrac, enemyBaseSeenFrame)
    if not EI then return hunting end
    local incidents = TM and #TM.Incidents() or 0
    local enemyValue = EI.AirValue(frame) + EI.GroundValue(frame)
    local won, why = M.IsWon(frame, armyValue, frontFrac, enemyBaseSeenFrame,
                             EI.LastArmedFrame(), incidents, enemyValue)
    reason = why
    if won then
        confirms = confirms + 1
        if not hunting and confirms >= M.CONFIRM_CHECKS then
            hunting, huntSince = true, frame
            Spring.Echo(string.format(
                "[END] %s WON-STATE: hunting the commander (army %.0f, enemy remembered %.0f, "
                .. "last armed enemy seen %ds ago)", Clock(frame), armyValue, enemyValue,
                math.floor((frame - EI.LastArmedFrame()) / 30)))
        end
    else
        confirms = 0
        -- Only a real army ends the hunt; the other conditions (e.g. a scout seeing
        -- nothing for a moment) are about ENTERING it.
        if hunting and (why == "enemy army seen" and enemyValue > armyValue * M.UNWIN_RATIO
                        or why == "under attack" or why == "army too small") then
            hunting = false
            Spring.Echo(string.format("[END] %s hunt off: %s", Clock(frame), why))
        end
    end
    return hunting
end

-- Is this a nuke launcher we own?  A stockpiling weapon with a targetable missile.
local siloCache = {}
local function IsSiloDef(defID)
    local s = siloCache[defID]
    if s ~= nil then return s end
    s = false
    local d = defID and UnitDefs[defID]
    if d and d.canStockpile then
        for i = 1, #(d.weapons or {}) do
            local w  = d.weapons[i]
            local wd = w and w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
            if wd and wd.targetable and wd.targetable ~= 0
               and not (wd.interceptor and wd.interceptor ~= 0) then
                s = true
            end
        end
    end
    siloCache[defID] = s
    return s
end

local function FireNukes(frame, cx, cz, cf)
    if not hunting or not cx or frame - cf > M.NUKE_FRESH then return end
    if frame - lastNuke < M.NUKE_INTERVAL then return end
    if EI.AntiNukeCovers(cx, cz) then return end
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        if IsSiloDef(Spring.GetUnitDefID(uid)) then
            local stock = Spring.GetUnitStockpile and Spring.GetUnitStockpile(uid)
            if stock and stock > 0 then
                local y = Spring.GetGroundHeight(cx, cz) or 0
                Spring.GiveOrderToUnit(uid, CMD_ATTACK, { cx, y, cz }, {})
                lastNuke = frame
                Spring.Echo(string.format("[END] %s nuke launched at commander %d,%d",
                    Clock(frame), cx, cz))
                return
            end
        end
    end
end

-- Orders for the bombers, and the nukes.
function M.Strike(frame, bomberIDs)
    if not (ARMY and MM and MM.Ready()) then return end
    local cx, cz, cf, cuid = EI.Commander()
    FireNukes(frame, cx, cz, cf)

    local inView = cuid and Spring.GetUnitPosition(cuid) ~= nil
    local fresh = cx and frame - cf <= M.STRIKE_FRESH
    local go = fresh and (#bomberIDs >= M.BOMBER_MIN or inView)

    if go then
        for _, uid in ipairs(bomberIDs) do
            ARMY.Claim(ARMY.PRIO.RAID, uid, {
                role = "STRIKE", cmd = CMD_ATTACK,
                targetID = inView and cuid or nil, x = cx, z = cz,
            }, frame)
        end
        return
    end
    local sx, sz = MM.PointAt(-M.STAGE_BACK, 0)
    sx, sz = MM.Clamp(sx, sz, 300)
    for _, uid in ipairs(bomberIDs) do
        -- A strike claim outranks the wait, so it has to be given up explicitly.
        if ARMY.RoleOf(uid) == "STRIKE" then ARMY.Release(uid) end
        ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, {
            role = "BOMBER_WAIT", cmd = CMD_MOVE, x = sx, z = sz,
        }, frame)
    end
end

return M
