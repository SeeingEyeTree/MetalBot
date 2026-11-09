-- bar_framework/cap_mode.lua  (macro side: what the bot does at the unit cap -- user 2026-11-08)
-- User: "watching the bot it looks like it hits the unit cap and gets stalled out.  Have it self d figs, wasps, t1 mexs, any t1 units and just be super
-- aggressive with units that exist.  At unit cap it is just about throwing as much metal as possible at the enemy as quickly as possible.  Want to keep
-- some open so dragons and the proxy can be built up.  The only air unit that should be built is dragons and air scouts.  Only ground unit should be demons
-- and Behemoth.  Eco and nanos in the nano cols should be reclaimed as they can."  User's choices: on at 90% of the cap, 200 slots kept free; T1 eco is
-- reclaimed by nanos (self-destructed where no nano reaches); the lab whitelist holds everywhere, the proxy included, but cons can still be built.
--
-- ON at ON_FRAC of the cap, OFF below OFF_FRAC (published as WG.CapMode = { on, free, want, frame }).  While on and fewer than FREE slots are free:
--   T1 ECO (mexes, winds) is reclaimed by a nano in its reach (metal back); one no nano reaches is self-destructed; RECLAIM_BATCH a tick, the ones in
--   flight counted as freed.  The nano-column block stops rebuilding what it loses (recovery.lua) and lets its nanos go once their blocks are past T1
--   (nanos.lua) -- both read WG.CapMode.
-- The unit side (unit_runtime CAP) self-destructs fighters, Wasps, Shurikens and T1 army and sends everything else at the enemy; the lab side (lab_rules)
-- builds only Dragons, air scouts, Demons, Behemoths and cons.
--
--   local CAP = VFS.Include("LuaUI/Widgets/bar_framework/cap_mode.lua")
--   CAP.Init{ cfg, teamID, trans = fn -> line_transition state, Clock, WG }      CAP.Update(frame)
-- Log rows [CAP].

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = {}

M.CFG = {
    ON_FRAC       = 0.90,
    OFF_FRAC      = 0.85,
    FREE          = 200,     -- slots kept free (Dragons, the proxy)
    RECLAIM_BATCH = 30,      -- T1 eco units sent to be reclaimed / self-destructed a tick
    PENDING_S     = 40,      -- one that is still there after this is tried again
    EVERY         = 60,
}

local CMD_SELFD = 65
local E, K = {}, {}
local S = { on = false, pending = {}, reclaimed = 0, selfd = 0 }

local function Clock(f) return E.Clock and E.Clock(f) or string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end

function M.Init(env)
    E = env or {}
    K = {}
    for k, v in pairs(M.CFG) do K[k] = v end
    for k, v in pairs(type(E.cfg) == "table" and E.cfg or {}) do
        if M.CFG[k] == nil then Spring.Echo("[CAP] option '" .. tostring(k) .. "' is not a cap_mode option (typo?)") end
        K[k] = v
    end
    S = { on = false, pending = {}, reclaimed = 0, selfd = 0 }
end

local function T1Eco()
    local set = {}
    for _, role in ipairs({ "mex", "wind" }) do
        local d = UnitDefNames[ROLES.Get(role) or ""]
        if d then set[d.id] = true end
    end
    return set
end

function M.Update(frame)
    if frame % K.EVERY ~= 0 then return end
    local team = E.teamID
    local n = Spring.GetTeamUnitCount(team) or 0
    local max = (Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(team)) or 3000
    local frac = n / math.max(1, max)
    if not S.on and frac >= K.ON_FRAC then
        S.on = true
        Spring.Echo(string.format("[CAP] %s ON: %d / %d units (%.0f%%): T1 eco reclaimed, only Dragons / air scouts / Demons / Behemoths / cons built, everything else attacks",
            Clock(frame), n, max, 100 * frac))
    elseif S.on and frac < K.OFF_FRAC then
        S.on = false
        Spring.Echo(string.format("[CAP] %s off: %d / %d units (%.0f%%)", Clock(frame), n, max, 100 * frac))
    end
    -- the ones in flight (a reclaim takes a while, a self-destruct 5 s)
    local inFlight = 0
    for uid, f in pairs(S.pending) do
        if not Spring.GetUnitDefID(uid) then S.pending[uid] = nil
        elseif frame - f > K.PENDING_S * 30 then S.pending[uid] = nil
        else inFlight = inFlight + 1 end
    end
    local free = max - n
    if E.WG then E.WG.CapMode = { on = S.on, free = free, want = K.FREE, frame = frame, units = n, max = max } end
    if not S.on or free + inFlight >= K.FREE then return end
    -- T1 eco: a nano in reach reclaims it, else it is self-destructed
    local T = E.trans and E.trans()
    local NANO = T and T.BP and T.BP.NANO
    local InRange = T and T.BP and T.BP.NanosInRange
    local eco = T1Eco()
    local sent, reclaim, selfd = 0, 0, 0
    local need = K.FREE - free - inFlight
    for _, uid in ipairs(Spring.GetTeamUnits(team) or {}) do
        if sent >= math.min(K.RECLAIM_BATCH, need) then break end
        local defID = Spring.GetUnitDefID(uid)
        if defID and eco[defID] and not S.pending[uid] and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            local done = false
            if x and NANO and InRange then
                for _, nid in ipairs(InRange(x, z) or {}) do
                    local a = NANO.Assignment and NANO.Assignment(nid)
                    if not (a and a.cmd == 90) and NANO.Reclaim(NANO.PRIO.DECOM, nid, uid) then done = true; reclaim = reclaim + 1; break end
                end
            end
            if not done then
                Spring.GiveOrderToUnit(uid, CMD_SELFD, {}, {})
                selfd = selfd + 1
            end
            S.pending[uid] = frame
            sent = sent + 1
        end
    end
    S.reclaimed, S.selfd = S.reclaimed + reclaim, S.selfd + selfd
    if sent > 0 and frame - (S.logF or -1e9) >= 600 then
        S.logF = frame
        Spring.Echo(string.format("[CAP] %s %d free of %d wanted: %d T1 eco to reclaim, %d self-destructed (so far %d / %d)", Clock(frame), free, K.FREE,
            reclaim, selfd, S.reclaimed, S.selfd))
    end
end

function M.State() return S end
return M
