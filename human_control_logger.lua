-- human_control_logger.lua
-- Records how a HUMAN controls units, so a unit controller can be modelled on it.
-- Use with candidates/LINE_HUMAN (macro + cons only; no unit controller), play a normal game,
-- then run:  python human_control_report.py   (finds the newest log; --help for options)
--
-- Output: one line per record, key=value, no spaces inside values. Written to BOTH the infolog
-- and  <BAR data>/LuaUI/Config/metalbot_human_<date>.log  (the infolog is overwritten each launch).
--   [HCL] init   team start_x start_z map
--   [HCL] cmd    an order a PLAYER gave (src=ui), one line per order batch (all units that got the
--                same order in the same frame):
--                  cmd=move|fight|attack|patrol|guard|reclaim|... shift=0|1 n=<units>
--                  comp=name:count,...  cx,cz=<centroid>  tx,tz=<target>  tdef=<unit under cursor>
--                  dist=<centroid->target>  from_base/to_base=<centroid/target distance to our start>
--                  out=<to_base - from_base: >0 sends units away from home, <0 pulls back>
--                  enemy_d=<target to nearest visible enemy, -1 none>  enemy_near=<enemies within
--                  ENEMY_R of the units>  hp=<mean hp fraction>  sel=<1 if exactly the selection>
--   [HCL] queue  the player queued a unit in a factory: lab=<name> unit=<name> n=<count> front=0|1
--   [HCL] sel    selection changed: n=<units> comp=...   (throttled; shows what is picked up together)
--   [HCL] group  control group changed: g=<0-9> n=<units> comp=...
--   [HCL] cam    camera focus every CAM_EVERY frames: x z h  (where attention is; h = zoom height)
--   [HCL] ctx    situation every CTX_EVERY frames: army n/mv/centroid/spread/hp, idle fraction, how
--                far it is from base, enemies in LOS (n, nearest dist to army, comp), metal/energy
--   [HCL] loc    LOCALITY, one row after every move/fight/attack/patrol/stop order (src=cmd) and every LOC_EVERY
--                frames for the selected units (src=snap), only when an enemy is within LOC_R of one of them:
--                  n=<ordered army units> cx,cz=<their centroid> lead_d/rear_d=<nearest/farthest ordered unit to its
--                  nearest enemy> rng_min/rng_max=<weapon range of the ordered units> foe_n=<enemies within LOC_R of
--                  any of them> we_hit=<of those, how many some ordered unit can hit> they_hit=<ordered units some
--                  enemy can hit>
--                  own=name:x:z:dist_to_nearest_foe:hp,...   (nearest the enemy first; sampled above 24)
--                  foe=name:x:z:dist_to_nearest_own:range:hp:los,...   (nearest first, <=24; hp=-1 unknown, los=0 radar)
--   [HCL] fight  a combat burst (damage within a 5 s window): dmg_taken, losses, kills, where
--   [HCL] lua    orders issued by Lua (other widgets) per interval: count only (the macro's own)
-- Time stamps: f=<frame> t=<m:ss>. Distances are elmos (8 elmos = 1 map square).

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name    = "Human Control Logger",
        desc    = "Logs how a human player commands units (orders, selections, groups, camera, context)",
        author  = "MetalBot",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 100000,
        enabled = true
    }
end

local CAM_EVERY   = 60        -- frames between camera samples (2 s)
local CTX_EVERY   = 150       -- frames between situation rows (5 s)
local SEL_MIN_GAP = 15        -- frames; selection changes closer than this are merged
local ENEMY_R     = 900       -- an enemy this close to the ordered units counts as "near"
local FIGHT_GAP   = 150       -- frames of quiet that end a combat burst
local ARMY_MIN_MV = 30        -- metal cost under which a mobile unit is not "army" (cons, scouts)
local LOC_R       = 1800      -- [HCL] loc: enemies within this of the nearest ordered unit are listed
local LOC_EVERY   = 60        -- frames between loc rows for the SELECTED units (2 s), only when enemies are in LOC_R
local LOC_MAX_FOES = 24       -- enemies listed per loc row (nearest first)
local LOC_MAX_OWN  = 24       -- ordered units listed per loc row (nearest the enemy first; sampled above this)

local spGetMyTeamID      = Spring.GetMyTeamID
local spGetUnitPosition  = Spring.GetUnitPosition
local spGetUnitDefID     = Spring.GetUnitDefID
local spGetUnitHealth    = Spring.GetUnitHealth
local spGetTeamUnits     = Spring.GetTeamUnits
local spGetAllUnits      = Spring.GetAllUnits
local spGetUnitTeam      = Spring.GetUnitTeam
local spGetUnitAllyTeam  = Spring.GetUnitAllyTeam
local spGetMyAllyTeamID  = Spring.GetMyAllyTeamID
local spGetSelectedUnits = Spring.GetSelectedUnits
local spGetGroupList     = Spring.GetGroupList
local spGetGroupUnits    = Spring.GetGroupUnits
local spGetTeamResources = Spring.GetTeamResources
local spGetUnitCommands  = Spring.GetUnitCommands
local spGetCameraState   = Spring.GetCameraState
local spGetGroundHeight  = Spring.GetGroundHeight
local spGetUnitIsDead    = Spring.GetUnitIsDead
local spGetUnitLosState  = Spring.GetUnitLosState
local sqrt, floor, min, max = math.sqrt, math.floor, math.min, math.max
local fmt = string.format

local myTeam, myAlly
local startX, startZ = 0, 0
local logFile = nil
local game = { frame = 0 }

-- ── output ────────────────────────────────────────────────────────────────────

local function Stamp(f) local s = floor(f / 30); return fmt("f=%d t=%d:%02d", f, floor(s / 60), s % 60) end

local function Out(line)
    Spring.Echo(line)
    if logFile then logFile:write(line, "\n"); logFile:flush() end
end

local function OpenLog()
    local ok, f = pcall(io.open, "LuaUI/Config/metalbot_human_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")
    if ok and f then logFile = f end
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local cmdNames = {}
local function BuildCmdNames()
    local wanted = { "STOP", "WAIT", "MOVE", "PATROL", "FIGHT", "ATTACK", "AREA_ATTACK", "GUARD", "REPAIR",
        "RECLAIM", "RESURRECT", "CAPTURE", "LOAD_UNITS", "UNLOAD_UNITS", "DGUN", "SELFD", "RESTORE",
        "SET_WANTED_MAX_SPEED", "REPEAT", "FIRE_STATE", "MOVE_STATE", "CLOAK", "ONOFF", "STOCKPILE" }
    for _, n in ipairs(wanted) do
        local id = CMD and CMD[n]
        if id then cmdNames[id] = string.lower(n) end
    end
end
local function CmdName(id)
    if id < 0 then return "build" end
    return cmdNames[id] or ("cmd" .. id)
end

local nameCache = {}
local function DefName(defID)
    local n = nameCache[defID]
    if not n then
        local d = UnitDefs[defID]
        n = d and d.name or ("def" .. tostring(defID))
        nameCache[defID] = n
    end
    return n
end

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return sqrt(dx * dx + dz * dz) end

-- "name:count,..." most common first, at most `top` entries.
local function Comp(counts, top)
    local arr = {}
    for n, c in pairs(counts) do arr[#arr + 1] = { n, c } end
    table.sort(arr, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local parts = {}
    for i = 1, min(top or 8, #arr) do parts[i] = arr[i][1] .. ":" .. arr[i][2] end
    return #parts > 0 and table.concat(parts, ",") or "-"
end

-- Armed, mobile, non-builder: the units a unit controller would command.
local armyCache = {}
local function IsArmy(defID)
    local v = armyCache[defID]
    if v == nil then
        local d = UnitDefs[defID]
        v = d ~= nil and not d.isBuilding and (d.speed or 0) > 0 and not d.isBuilder
            and #(d.weapons or {}) > 0 and (d.metalCost or 0) >= ARMY_MIN_MV or false
        armyCache[defID] = v
    end
    return v
end

-- Enemies we can currently see (units in LOS or radar-visible and identified). Cheap enough at 5 s.
local function VisibleEnemies()
    local list = {}
    local all = spGetAllUnits and spGetAllUnits() or {}
    for i = 1, #all do
        local uid = all[i]
        if spGetUnitAllyTeam(uid) ~= myAlly then
            local los = spGetUnitLosState and spGetUnitLosState(uid, myAlly, false)
            if los and (los.los or los.typed) then
                local x, _, z = spGetUnitPosition(uid)
                if x then list[#list + 1] = { uid = uid, x = x, z = z, def = spGetUnitDefID(uid) } end
            end
        end
    end
    return list
end

-- ── player orders ─────────────────────────────────────────────────────────────

local pending = {}      -- key -> batch; flushed once its frame has passed
local luaOrders = 0     -- orders by other widgets since the last ctx row
local lastEnemies, lastEnemiesFrame = {}, -999

local function Enemies()
    if game.frame - lastEnemiesFrame >= 30 then
        lastEnemies = VisibleEnemies(); lastEnemiesFrame = game.frame
    end
    return lastEnemies
end

-- ── locality: the units we ordered and the enemies around THEM ────────────────
-- A centroid of every visible enemy says little; what matters is who is near THESE units and who can reach whom.
-- One [HCL] loc row = the ordered units and the enemies within LOC_R of any of them, each with its own position.
local rangeCache = {}
local function RangeOf(defID)
    local r = rangeCache[defID]
    if r == nil then
        local d = UnitDefs[defID]
        r = d and floor(d.maxWeaponRange or 0) or 0
        rangeCache[defID] = r
    end
    return r
end

local function FreshEnemies()
    if game.frame - lastEnemiesFrame >= 8 then
        lastEnemies = VisibleEnemies(); lastEnemiesFrame = game.frame
    end
    return lastEnemies
end

local function LocRow(frame, src, uids)
    local own, sx, sz = {}, 0, 0
    for _, uid in ipairs(uids) do
        local defID = spGetUnitDefID(uid)
        local x, _, z = spGetUnitPosition(uid)
        if defID and x and IsArmy(defID) then
            local hp, mhp = spGetUnitHealth(uid)
            own[#own + 1] = { x = x, z = z, def = defID, r = RangeOf(defID),
                              hp = (hp and mhp and mhp > 0) and hp / mhp or 1 }
            sx, sz = sx + x, sz + z
        end
    end
    if #own == 0 then return end
    local cx, cz = sx / #own, sz / #own
    -- enemies within LOC_R of the NEAREST ordered unit, with that distance
    local foes = {}
    for _, e in ipairs(FreshEnemies()) do
        local dmin
        for _, o in ipairs(own) do
            local d = Dist(o.x, o.z, e.x, e.z)
            if not dmin or d < dmin then dmin = d end
        end
        if dmin <= LOC_R then
            local hp, mhp, los = nil, nil, 0
            local ls = spGetUnitLosState and spGetUnitLosState(e.uid, myAlly, false)
            if ls and ls.los then
                los = 1
                hp, mhp = spGetUnitHealth(e.uid)
            end
            foes[#foes + 1] = { x = e.x, z = e.z, def = e.def, d = dmin, r = e.def and RangeOf(e.def) or 0,
                                hp = (hp and mhp and mhp > 0) and hp / mhp or -1, los = los }
        end
    end
    if #foes == 0 then return end
    table.sort(foes, function(a, b) return a.d < b.d end)

    -- who can reach whom (any ordered unit / any enemy)
    local rmin, rmax = 1e9, 0
    for _, o in ipairs(own) do rmin = min(rmin, o.r); rmax = max(rmax, o.r) end
    local weHit, theyHit = 0, 0           -- enemies that some ordered unit can hit / ordered units some enemy can hit
    for _, f in ipairs(foes) do
        for _, o in ipairs(own) do
            if Dist(o.x, o.z, f.x, f.z) <= o.r then weHit = weHit + 1; break end
        end
    end
    for _, o in ipairs(own) do
        for _, f in ipairs(foes) do
            if Dist(o.x, o.z, f.x, f.z) <= f.r then theyHit = theyHit + 1; break end
        end
    end
    -- the ordered unit nearest the enemy (the lead) and the farthest from it (the rear)
    for _, o in ipairs(own) do
        o.d = 1e9
        for _, f in ipairs(foes) do
            local d = Dist(o.x, o.z, f.x, f.z)
            if d < o.d then o.d = d end
        end
    end
    table.sort(own, function(a, b) return a.d < b.d end)
    local ownS, foeS = {}, {}
    local step = max(1, math.ceil(#own / LOC_MAX_OWN))
    for i = 1, #own, step do      -- lead first; evenly sampled when the group is big
        local o = own[i]
        ownS[#ownS + 1] = fmt("%s:%d:%d:%d:%.2f", DefName(o.def), o.x, o.z, o.d, o.hp)
    end
    for i = 1, min(#foes, LOC_MAX_FOES) do
        local f = foes[i]
        foeS[#foeS + 1] = fmt("%s:%d:%d:%d:%d:%.2f:%d", f.def and DefName(f.def) or "?", f.x, f.z, f.d, f.r, f.hp, f.los)
    end
    Out(fmt("[HCL] loc %s src=%s n=%d cx=%d cz=%d lead_d=%d rear_d=%d rng_min=%d rng_max=%d foe_n=%d we_hit=%d they_hit=%d own=%s foe=%s",
        Stamp(frame), src, #own, cx, cz, own[1].d, own[#own].d, rmin, rmax, #foes, weHit, theyHit,
        table.concat(ownS, ","), table.concat(foeS, ",")))
end

local function OptsShift(o)
    if type(o) == "table" then return (o.shift or o[3]) and 1 or 0 end
    return (o and floor(o / 32) % 2 == 1) and 1 or 0
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag, playerID, fromSynced, fromLua)
    if unitTeam ~= myTeam then return end
    if fromLua then luaOrders = luaOrders + 1; return end
    local d = UnitDefs[unitDefID]
    if cmdID < 0 and d and d.isFactory then
        -- a lab queue entry, not a unit order
        local key = "q" .. unitID .. "_" .. (-cmdID) .. "_" .. game.frame
        local b = pending[key] or { kind = "queue", frame = game.frame, lab = DefName(unitDefID),
                                    unit = DefName(-cmdID), n = 0 }
        b.n = b.n + 1
        b.front = (type(cmdOpts) == "table" and cmdOpts.meta) and 1 or 0   -- "insert at front"
        pending[key] = b
        return
    end
    local p = cmdParams or {}
    local ps = (p[1] and fmt("%d", p[1]) or "") .. "_" .. (p[2] and fmt("%d", p[2]) or "") .. "_" .. (p[3] and fmt("%d", p[3]) or "")
    local key = cmdID .. "|" .. ps .. "|" .. OptsShift(cmdOpts) .. "|" .. game.frame
    local b = pending[key]
    if not b then
        b = { kind = "cmd", frame = game.frame, cmd = cmdID, params = p, shift = OptsShift(cmdOpts), units = {} }
        pending[key] = b
    end
    b.units[#b.units + 1] = unitID
end

local function FlushPending(frame)
    for key, b in pairs(pending) do
        if b.frame < frame then
            pending[key] = nil
            if b.kind == "queue" then
                Out(fmt("[HCL] queue %s lab=%s unit=%s n=%d front=%d", Stamp(b.frame), b.lab, b.unit, b.n, b.front or 0))
            else
                local counts, sx, sz, n, hpSum, hpN = {}, 0, 0, 0, 0, 0
                for _, uid in ipairs(b.units) do
                    local x, _, z = spGetUnitPosition(uid)
                    local defID = spGetUnitDefID(uid)
                    if x and defID then
                        sx, sz, n = sx + x, sz + z, n + 1
                        local nm = DefName(defID); counts[nm] = (counts[nm] or 0) + 1
                        local hp, mhp = spGetUnitHealth(uid)
                        if hp and mhp and mhp > 0 then hpSum = hpSum + hp / mhp; hpN = hpN + 1 end
                    end
                end
                if n > 0 then
                    local cx, cz = sx / n, sz / n
                    local p, tx, tz, tdef = b.params, nil, nil, "-"
                    if #p >= 3 then tx, tz = p[1], p[3]
                    elseif #p == 1 and b.cmd ~= 0 then
                        -- a unit id (attack/guard/reclaim ...) or a feature id
                        local ux, _, uz = spGetUnitPosition(p[1])
                        if ux then
                            tx, tz = ux, uz
                            local td = spGetUnitDefID(p[1]); if td then tdef = DefName(td) end
                        end
                    end
                    local en, near, nd = Enemies(), 0, -1
                    for _, e in ipairs(en) do
                        if Dist(cx, cz, e.x, e.z) <= ENEMY_R then near = near + 1 end
                        if tx then
                            local d = Dist(tx, tz, e.x, e.z)
                            if nd < 0 or d < nd then nd = d end
                        end
                    end
                    local fromBase = Dist(cx, cz, startX, startZ)
                    local toBase = tx and Dist(tx, tz, startX, startZ) or -1
                    local sel = spGetSelectedUnits() or {}
                    Out(fmt("[HCL] cmd %s cmd=%s shift=%d n=%d comp=%s cx=%d cz=%d tx=%s tz=%s tdef=%s dist=%d from_base=%d to_base=%d out=%d enemy_d=%d enemy_near=%d hp=%.2f sel=%d",
                        Stamp(b.frame), CmdName(b.cmd), b.shift, n, Comp(counts, 6), cx, cz,
                        tx and fmt("%d", tx) or "-", tz and fmt("%d", tz) or "-", tdef,
                        tx and Dist(cx, cz, tx, tz) or -1, fromBase, toBase,
                        tx and (toBase - fromBase) or 0, nd, near, hpN > 0 and hpSum / hpN or -1,
                        (#sel == #b.units) and 1 or 0))
                    -- movement-type orders also get a locality row: who stood where when this was given
                    if b.cmd == CMD.MOVE or b.cmd == CMD.FIGHT or b.cmd == CMD.ATTACK or b.cmd == CMD.PATROL
                       or b.cmd == CMD.STOP then
                        local ok, err = pcall(LocRow, b.frame, "cmd", b.units)
                        if not ok then Out("[HCL] error loc: " .. tostring(err)) end
                    end
                end
            end
        end
    end
end

-- ── selection, groups, camera ─────────────────────────────────────────────────

local lastSelFrame, lastSelKey = -999, ""
local function CompOf(uids)
    local counts, n = {}, 0
    for _, uid in ipairs(uids) do
        local defID = spGetUnitDefID(uid)
        if defID then local nm = DefName(defID); counts[nm] = (counts[nm] or 0) + 1; n = n + 1 end
    end
    return n, Comp(counts, 6)
end

local function LogSelection(frame)
    local sel = spGetSelectedUnits() or {}
    if #sel == 0 then return end
    local n, comp = CompOf(sel)
    local key = n .. comp
    if key == lastSelKey then return end
    lastSelKey = key
    Out(fmt("[HCL] sel %s n=%d comp=%s", Stamp(frame), n, comp))
end

local groupSig = {}
local function PollGroups(frame)
    if not (spGetGroupList and spGetGroupUnits) then return end
    local list = spGetGroupList() or {}
    local seen = {}
    for g, cnt in pairs(list) do
        seen[g] = true
        local uids = spGetGroupUnits(g) or {}
        local n, comp = CompOf(uids)
        local sig = n .. comp
        if groupSig[g] ~= sig then
            groupSig[g] = sig
            Out(fmt("[HCL] group %s g=%d n=%d comp=%s", Stamp(frame), g, n, comp))
        end
    end
    for g in pairs(groupSig) do
        if not seen[g] then
            groupSig[g] = nil
            Out(fmt("[HCL] group %s g=%d n=0 comp=-", Stamp(frame), g))
        end
    end
end

local function LogCamera(frame)
    local cs = spGetCameraState and spGetCameraState()
    if not cs then return end
    local x, z, h = cs.px or cs.x, cs.pz or cs.z, cs.py or cs.height or cs.dist or cs.y
    if x and z then Out(fmt("[HCL] cam %s x=%d z=%d h=%d", Stamp(frame), x, z, h or 0)) end
end

-- ── situation ─────────────────────────────────────────────────────────────────

local function LogContext(frame)
    local n, mv, sx, sz, hpSum, idle = 0, 0, 0, 0, 0, 0
    local counts, pos = {}, {}
    for _, uid in ipairs(spGetTeamUnits(myTeam) or {}) do
        local defID = spGetUnitDefID(uid)
        if defID and IsArmy(defID) then
            local x, _, z = spGetUnitPosition(uid)
            if x then
                n = n + 1; mv = mv + (UnitDefs[defID].metalCost or 0)
                sx, sz = sx + x, sz + z
                pos[#pos + 1] = { x, z }
                local nm = DefName(defID); counts[nm] = (counts[nm] or 0) + 1
                local hp, mhp = spGetUnitHealth(uid)
                if hp and mhp and mhp > 0 then hpSum = hpSum + hp / mhp end
                local c = spGetUnitCommands and spGetUnitCommands(uid, 0)
                if (type(c) == "number" and c == 0) or (type(c) == "table" and #c == 0) then idle = idle + 1 end
            end
        end
    end
    local cx, cz = n > 0 and sx / n or startX, n > 0 and sz / n or startZ
    local spread = 0
    for _, p in ipairs(pos) do spread = spread + Dist(p[1], p[2], cx, cz) end
    spread = n > 0 and spread / n or 0
    local en, enN, enNear, ecx, ecz, ecounts = Enemies(), 0, -1, 0, 0, {}
    for _, e in ipairs(en) do
        enN = enN + 1; ecx, ecz = ecx + e.x, ecz + e.z
        if e.def then local nm = DefName(e.def); ecounts[nm] = (ecounts[nm] or 0) + 1 end
        local d = Dist(cx, cz, e.x, e.z)
        if enNear < 0 or d < enNear then enNear = d end
    end
    local mCur, mSto, mPull, mInc = spGetTeamResources(myTeam, "metal")
    local eCur, eSto, ePull, eInc = spGetTeamResources(myTeam, "energy")
    Out(fmt("[HCL] ctx %s army_n=%d army_mv=%d army_cx=%d army_cz=%d spread=%d hp=%.2f idle=%d from_base=%d comp=%s enemies=%d enemy_nearest=%d enemy_cx=%s enemy_cz=%s enemy_comp=%s metal=%d m_inc=%.1f energy=%d e_inc=%.1f lua_orders=%d",
        Stamp(frame), n, mv, cx, cz, spread, n > 0 and hpSum / n or -1, idle,
        Dist(cx, cz, startX, startZ), Comp(counts, 8), enN, enNear,
        enN > 0 and fmt("%d", ecx / enN) or "-", enN > 0 and fmt("%d", ecz / enN) or "-",
        Comp(ecounts, 8), mCur or 0, mInc or 0, eCur or 0, eInc or 0, luaOrders))
    luaOrders = 0
end

-- ── combat bursts ─────────────────────────────────────────────────────────────

local fight = nil   -- { start, last, dmg, losses, kills, sx, sz, n, lostCounts }
local function FightTouch(frame, x, z)
    if not fight then fight = { start = frame, dmg = 0, losses = 0, kills = 0, sx = 0, sz = 0, n = 0, lostCounts = {}, killCounts = {} } end
    fight.last = frame
    if x then fight.sx, fight.sz, fight.n = fight.sx + x, fight.sz + z, fight.n + 1 end
end

local function FlushFight(frame, force)
    if fight and (force or frame - fight.last > FIGHT_GAP) then
        local f = fight; fight = nil
        local cx, cz = f.n > 0 and f.sx / f.n or 0, f.n > 0 and f.sz / f.n or 0
        Out(fmt("[HCL] fight %s dur=%d dmg_taken=%d losses=%d kills=%d x=%d z=%d from_base=%d lost=%s killed=%s",
            Stamp(f.start), f.last - f.start, f.dmg, f.losses, f.kills, cx, cz, Dist(cx, cz, startX, startZ),
            Comp(f.lostCounts, 6), Comp(f.killCounts, 6)))
    end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer)
    if unitTeam ~= myTeam or not IsArmy(unitDefID) then return end
    local x, _, z = spGetUnitPosition(unitID)
    FightTouch(game.frame, x, z)
    fight.dmg = fight.dmg + (damage or 0)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
    local mine = unitTeam == myTeam
    if mine and IsArmy(unitDefID) then
        local x, _, z = spGetUnitPosition(unitID)
        FightTouch(game.frame, x, z)
        fight.losses = fight.losses + 1
        local nm = DefName(unitDefID); fight.lostCounts[nm] = (fight.lostCounts[nm] or 0) + 1
    elseif not mine and not (Spring.AreTeamsAllied and Spring.AreTeamsAllied(unitTeam, myTeam)) and UnitDefs[unitDefID] and (UnitDefs[unitDefID].speed or 0) > 0
           and (attackerTeam == myTeam or attackerTeam == nil or fight) then
        -- attackerTeam is often nil for an enemy the client only sees at range, so any enemy mobile death
        -- seen while our army is in a burst counts as a kill (slight over-count if an ally made it)
        local x, _, z = spGetUnitPosition(unitID)
        FightTouch(game.frame, x, z)
        fight.kills = fight.kills + 1
        local nm = DefName(unitDefID); fight.killCounts[nm] = (fight.killCounts[nm] or 0) + 1
    end
end

-- ── callbacks ─────────────────────────────────────────────────────────────────

function widget:Initialize()
    myTeam = spGetMyTeamID(); myAlly = spGetMyAllyTeamID()
    BuildCmdNames()
    OpenLog()
    local cmdr
    for _, uid in ipairs(spGetTeamUnits(myTeam) or {}) do
        local d = UnitDefs[spGetUnitDefID(uid)]
        if d and d.customParams and d.customParams.iscommander then cmdr = uid; break end
    end
    if cmdr then local x, _, z = spGetUnitPosition(cmdr); if x then startX, startZ = x, z end end
    Out(fmt("[HCL] init team=%d start_x=%d start_z=%d map=%s", myTeam, startX, startZ,
        tostring(Game and Game.mapName or "?")))
end

function widget:GameStart()
    -- the commander may not exist yet in Initialize
    for _, uid in ipairs(spGetTeamUnits(myTeam) or {}) do
        local d = UnitDefs[spGetUnitDefID(uid)]
        if d and d.customParams and d.customParams.iscommander then
            local x, _, z = spGetUnitPosition(uid)
            if x then startX, startZ = x, z; Out(fmt("[HCL] init team=%d start_x=%d start_z=%d (at game start)", myTeam, x, z)) end
            break
        end
    end
end

local selDirty = false
function widget:SelectionChanged()
    -- logged by GameFrame once the selection has been still for SEL_MIN_GAP frames
    selDirty = true; lastSelFrame = game.frame
end

function widget:GameFrame(frame)
    game.frame = frame
    FlushPending(frame)
    FlushFight(frame, false)
    if selDirty and frame - lastSelFrame >= SEL_MIN_GAP then selDirty = false; LogSelection(frame) end
    if frame % CAM_EVERY == 0 then LogCamera(frame) end
    if frame % 30 == 0 then PollGroups(frame) end
    if frame % CTX_EVERY == 0 then LogContext(frame) end
    if frame % LOC_EVERY == 30 then
        local sel = spGetSelectedUnits() or {}
        if #sel > 0 then
            local ok, err = pcall(LocRow, frame, "snap", sel)
            if not ok then Out("[HCL] error loc: " .. tostring(err)) end
        end
    end
end

function widget:Shutdown()
    FlushPending(game.frame + 1)
    FlushFight(game.frame, true)
    if logFile then logFile:close(); logFile = nil end
end
