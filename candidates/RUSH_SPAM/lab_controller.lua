-- RUSH_SPAM labs: every factory spams its cheapest fast unit on repeat.  The bot lab makes a few
-- con bots first (they help build eco and plants), then Armada-"Pawn" equivalents (corak);
-- vehicle plants make corgator (the "Flash" equivalent).

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name = "Lab Controller", desc = "RUSH_SPAM factory spam (COR)",
        author = "", date = "2026", license = "GNU GPL, v3 or later", layer = 0, enabled = true,
    }
end

local CON_BOTS  = 6      -- con bots the first bot lab makes before switching to army
local BATCH     = 8      -- units added to a queue when it runs empty
local TICK      = 30

local CMD_REPEAT = CMD.REPEAT
local myTeam
local facs = {}          -- factory unitID -> true
local lastFill = {}    -- factory -> frame of its last refill (orders take ~30 frames to land)
local GRACE = 150

local function Def(n) local d = UnitDefNames[n]; return d and d.id end

function widget:Initialize() myTeam = Spring.GetMyTeamID() end

function widget:UnitFinished(uid, defID, team)
    if team ~= myTeam then return end
    if UnitDefs[defID].isFactory then
        facs[uid] = true
    end
end

function widget:UnitDestroyed(uid) facs[uid] = nil end

local function Fill(uid, name, n)
    local id = Def(name)
    if not id then return end
    for _ = 1, n do Spring.GiveOrderToUnit(uid, -id, {}, { "shift" }) end
end

function widget:GameFrame(f)
    if f % TICK ~= 0 then return end
    for uid in pairs(facs) do
        if f - (lastFill[uid] or -999) > GRACE and next(Spring.GetFullBuildQueue(uid) or {}) == nil then
            lastFill[uid] = f
            local nm = UnitDefs[Spring.GetUnitDefID(uid)].name
            local cons = #Spring.GetTeamUnitsByDefs(myTeam, { Def("corck") })
            if nm == "corlab" and cons < CON_BOTS then
                Fill(uid, "corck", CON_BOTS - cons)   -- no repeat: a repeated con queue never ends
                Spring.GiveOrderToUnit(uid, CMD_REPEAT, { 0 }, {})
            else
                Spring.GiveOrderToUnit(uid, CMD_REPEAT, { 1 }, {})
                Fill(uid, nm == "corlab" and "corak" or "corgator", BATCH)
            end
        end
    end
end
