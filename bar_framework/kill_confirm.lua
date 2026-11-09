-- bar_framework/kill_confirm.lua  (unit side: did a target we shot at out of sight die?  user 2026-11-08: "I know in game there is a way to see through
-- fog of war if you killed things, you can see an explosion animation in game.  Check if there is a API call for target kill confirmation.")
-- There is no engine call that says "your fogged target died": an enemy's UnitDestroyed reaches a widget only in line of sight (BAR's api_widget_events
-- gadget), ghosts of buildings are invisible to widgets, and widget:Explosion is synced-only.  What does work (knowledge/bots/proxy_base_2026-11-08.md):
--   WRECK      features are always visible in BAR (modrules featureVisibility = 3) and enemy FeatureCreated is forwarded to widgets: a wreck at the
--              target's spot whose GetFeatureResurrect is the target's unit = dead.  (Most likely the "explosion through the fog" the user sees: our
--              own shell's impact, plus the wreck popping in.)  A nanoframe leaves no wreck; heavy overkill may leave a heap (matched by spot only).
--   DOT GONE   a target on our radar whose dot disappears without a UnitLeftRadar (that callin fires only on a LOS-status change, never on death) = dead.
--   SEEN       its UnitDestroyed in our sight.
--   HITS       our own shells' impacts reach a widget in fog through BAR's VisibleExplosion (gfx_explosion_lights; it may not run headless): counted per
--              target, for the "probably dead" rule of the caller.
--   CROSS-CHECK our team's live unitsKilled (Spring.GetTeamStatsHistory: the last entry is live), logged.
-- Unit ids are reused by the engine: a target is forgotten once it is dead.
--
--   local KC = VFS.Include("LuaUI/Widgets/bar_framework/kill_confirm.lua").New{ teamID, Clock }
--   KC.Watch(uid, defID, x, z, frame)   KC.Unwatch(uid)   KC.Dead(uid) -> why | nil   KC.Hits(uid) -> n
--   KC.Tick(frame)   KC.OnFeatureCreated(fid)   KC.OnLeftRadar(uid, frame)   KC.OnDestroyed(uid)   KC.OnExplosion(x, z, ownerID, isOurs)
--   KC.TeamKills() -> live unitsKilled of our team (nil when the stats are not readable)

local M = {}

M.CFG = {
    WRECK_R    = 140,     -- a wreck this close to the target's spot with the target's resurrect name = dead
    HEAP_R     = 60,      -- ... or this close with any name (a heap)
    HIT_R      = 220,     -- an impact this close to a target is a hit on it
}

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do C[k] = v end
    local KC = { cfg = C }
    local watch = {}       -- [uid] = { defID, name, x, z, since, seenDot, hits }
    local dead = {}        -- [uid] = why
    local left = {}        -- [uid] = frame of its last UnitLeftRadar

    function KC.Watch(uid, defID, x, z, frame)
        if watch[uid] then watch[uid].x, watch[uid].z = x or watch[uid].x, z or watch[uid].z; return end
        local d = UnitDefs[defID]
        watch[uid] = { defID = defID, name = d and d.name, x = x, z = z, since = frame or 0, hits = 0 }
        dead[uid] = nil
    end
    function KC.Unwatch(uid) watch[uid], left[uid] = nil, nil end
    function KC.Dead(uid) return dead[uid] end
    function KC.Hits(uid) local w = watch[uid]; return w and w.hits or 0 end
    local function Kill(uid, why)
        if not watch[uid] then return end
        dead[uid] = why
        watch[uid] = nil
    end

    function KC.OnDestroyed(uid) Kill(uid, "seen") end
    function KC.OnLeftRadar(uid, frame) left[uid] = frame end

    function KC.OnFeatureCreated(fid)
        local fx, _, fz = Spring.GetFeaturePosition(fid)
        if not fx then return end
        local rname = Spring.GetFeatureResurrect and Spring.GetFeatureResurrect(fid)
        for uid, w in pairs(watch) do
            local d2 = (w.x - fx) ^ 2 + (w.z - fz) ^ 2
            if (d2 <= C.WRECK_R ^ 2 and rname and rname ~= "" and rname == w.name) or d2 <= C.HEAP_R ^ 2 then Kill(uid, "wreck") end
        end
    end

    function KC.OnExplosion(x, z, ownerID, isOurs)
        if not (x and isOurs) then return end
        for _, w in pairs(watch) do
            if (w.x - x) ^ 2 + (w.z - z) ^ 2 <= C.HIT_R ^ 2 then w.hits = w.hits + 1 end
        end
    end

    -- the radar dot of a watched target: there last tick, gone now, and no UnitLeftRadar since = dead
    function KC.Tick(frame)
        for uid, w in pairs(watch) do
            local x = Spring.GetUnitPosition(uid)
            if x then
                w.seenDot, w.dotF = true, frame
            elseif w.seenDot then
                if not (left[uid] and left[uid] >= (w.dotF or 0)) then Kill(uid, "dot gone")
                else w.seenDot = false end
            end
        end
    end

    function KC.TeamKills()
        if not Spring.GetTeamStatsHistory then return nil end
        local ok, n = pcall(Spring.GetTeamStatsHistory, o.teamID)
        if not (ok and n and n > 0) then return nil end
        local ok2, h = pcall(Spring.GetTeamStatsHistory, o.teamID, n, n)
        local e = ok2 and h and h[1]
        return e and e.unitsKilled or nil
    end

    return KC
end

return M
