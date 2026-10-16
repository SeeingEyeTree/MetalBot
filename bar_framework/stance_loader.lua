-- bar_framework/stance_loader.lua
-- Reads stances/<name>.lua (exported by stance_editor.html) and answers "which unit should this idle lab queue?".
--
-- A stance is a unit comp: {n, share, ...} where share is the fraction of ARMY SPEND (metal + energy/70) each unit gets.
-- The pick rule is the value-deficit rule from stances/README.md: of the stance's units that THIS lab can build, take
-- the one furthest below share x (total value built under the stance).  Ordering a unit adds its value to the ledger, so
-- two labs asked in the same tick do not both pick the same unit.
--
-- USAGE
--   local SL = VFS.Include("LuaUI/Widgets/bar_framework/stance_loader.lua")
--   local st = SL.Load("T1_bombing_run")                  -- nil if missing / malformed
--   local ledger = SL.NewLedger()
--   local defID = SL.Pick(st, ledger, function(defID) return labCanBuild[defID] end)
--   SL.Note(ledger, defID)                                -- after ordering it

local M = {}

local DIRS = { "LuaUI/Widgets/stances/", "stances/" }

-- The one value formula (metal + energy/70): the editor's val() and lab_controller's UnitValue use the same.
local function Value(defID)
    local d = defID and UnitDefs and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end
M.Value = Value

-- Tolerates a stance given as a table already (tests) and a missing VFS.
function M.Load(name)
    if type(name) == "table" then return M.Prepare(name) end
    local chunk
    for _, dir in ipairs(DIRS) do
        local ok, r = pcall(function() return VFS.Include(dir .. name .. ".lua") end)
        if ok and type(r) == "table" then chunk = r; break end
    end
    if not chunk then return nil end
    return M.Prepare(chunk)
end

-- Resolves unit names to defIDs, drops unknown units and renormalises the shares.
function M.Prepare(raw)
    if type(raw) ~= "table" or type(raw.units) ~= "table" then return nil end
    -- plan (optional): the game plan the stance stands for, read by the bot through Strategy:Plan(), e.g.
    -- { army = "raid" | "hold", bombers = 0..1 } (RAID_BOT: click_army mode and the air labs' bomber want)
    local st = { name = raw.name or "?", intent = raw.intent, control = raw.control,
                 suggestedShare = tonumber(tostring(raw.suggestedShare or ""):match("(%d+)%D*$")) or nil,
                 plan = type(raw.plan) == "table" and raw.plan or nil,
                 units = {}, byName = {}, byDef = {}, extras = {}, extraByDef = {} }
    local sum = 0
    for _, u in ipairs(raw.units) do
        local ud = UnitDefNames and UnitDefNames[u.n]
        if ud and (u.share or 0) > 0 then
            -- behaviors = {"kite", ...} and cfg = {kite = {step = 400}} plug the unit into behavior_host (strategy.lua)
            -- tag = "mass" | "quality" (optional): strategy_hooks.income_mix tilts the share by income
            st.units[#st.units + 1] = { n = u.n, defID = ud.id, share = u.share, note = u.note,
                                        behaviors = u.behaviors, cfg = u.cfg, tag = u.tag }
            sum = sum + u.share
        end
    end
    if #st.units == 0 or sum <= 0 then return nil end
    -- extras (optional): units the stance does not BUILD through the spine (the Dragons from their own lab) but still wants
    -- controlled -- { n, behaviors, cfg } as for a unit, no share.  strategy:BehaviorsFor reads them.
    for _, u in ipairs(type(raw.extras) == "table" and raw.extras or {}) do
        local ud = UnitDefNames and UnitDefNames[u.n]
        if ud then
            local e = { n = u.n, defID = ud.id, behaviors = u.behaviors, cfg = u.cfg, note = u.note }
            st.extras[#st.extras + 1] = e
            st.extraByDef[ud.id] = e
        end
    end
    for _, u in ipairs(st.units) do
        u.share = u.share / sum
        st.byName[u.n] = u
        st.byDef[u.defID] = u
    end
    return st
end

function M.NewLedger() return { total = 0, byDef = {} } end

-- Count what already exists (or is queued) towards the ledger, e.g. when a stance starts mid-game.
function M.Note(ledger, defID, n)
    if not (ledger and defID) then return end
    local v = Value(defID) * (n or 1)
    ledger.total = ledger.total + v
    ledger.byDef[defID] = (ledger.byDef[defID] or 0) + v
end

-- canBuild(defID) -> truthy when the idle lab can build it.  `skip` (optional set of defIDs) excludes units.
-- Returns defID, or nil when the lab can build nothing in the stance.
-- positiveOnly: take a unit only while it is BELOW its share (nil when everything the lab can build is at or over its
-- share) -- for labs that should stop rather than overbuild.
-- weights (optional): { [unit name] = multiplier } applied to the shares at run time, then renormalised (strategy.lua's
-- `weights` hook: more AA once enemy air shows up, more raiders when their eco is exposed...).
function M.Pick(st, ledger, canBuild, skip, positiveOnly, weights)
    if not (st and ledger) then return nil end
    local best, bestGap
    local total = math.max(ledger.total, 1)
    local wsum = 0
    if weights then
        for _, u in ipairs(st.units) do wsum = wsum + u.share * (weights[u.n] or 1) end
        if wsum <= 0 then weights = nil end
    end
    for _, u in ipairs(st.units) do
        if (not skip or not skip[u.defID]) and canBuild(u.defID) then
            -- gap = value the unit should have by now minus what it has; the first order of a
            -- stance (total 0) goes to the largest share.
            local share = weights and u.share * (weights[u.n] or 1) / wsum or u.share
            local gap = share * total - (ledger.byDef[u.defID] or 0)
            if ledger.total <= 0 then gap = share end
            if (not positiveOnly or gap > 0) and (not bestGap or gap > bestGap) then best, bestGap = u.defID, gap end
        end
    end
    return best
end

function M.Names(st)
    local t = {}
    for _, u in ipairs(st and st.units or {}) do t[#t + 1] = string.format("%s %.0f%%", u.n, u.share * 100) end
    return table.concat(t, ", ")
end

return M
