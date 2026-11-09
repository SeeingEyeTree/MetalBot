-- bar_framework/roles.lua   (C4, 2026-10-16)
-- ROLES instead of unit names.  The framework says "the decoy", "the radar plane", "the T2 bot con"; this file says which unit that is per
-- faction.  Cortex is filled in; Armada is a table to fill in (a missing Armada entry falls back to the Cortex name with a one-time log row,
-- so a half-filled table never crashes a game).  The faction is read once from the team's side (Spring.GetTeamInfo), or set with SetFaction.
--
--   Roles.Get("decoy")          -> "cordecom"
--   Roles.Def("decoy")          -> the UnitDefs entry (or nil)
--   Roles.Id("decoy")           -> its defID
--   Roles.Is(defID, "decoy")    -> true when that unit has that role
--   Roles.Set("decoy", "name")  -> override one role (a bot's config, a test)
--   Roles.SetFaction("arm")     -> force a faction ("cor" / "arm")
-- A module's option defaults take the role name, so a bot can still override one option:  O("DECOY_UNIT", Roles.Get("decoy")).
-- NOT roles (stay literals): blueprint / build-order items (mexes, winds, nanos in a layout file): blueprints are per-faction files.
-- tests/check_role_names.py fails on a new quoted unit name in bar_framework/ outside the whitelist.

local M = {}

M.TABLE = {
    cor = {
        decoy        = "cordecom",     -- the decoy commander the sink labs and line labs are assisted by
        sink_unit    = "corcrwh",      -- the unit the metal sink makes (a Dragon)
        radar_plane  = "corawac",
        scout_air    = "corfink",      -- T1 air scout (bomb_run's wave scouts)
        fighter_t1   = "corveng",   fighter_t2 = "corvamp",
        bomber_t1    = "corshad",   bomber_t2  = "corhurc",
        stunner      = "corbw",        -- cheap air raider that stuns (Shuriken)
        raider       = "corape",       -- main air raider (Wasp)
        savior       = "cormabm",      -- mobile anti-nuke
        silo         = "corsilo",
        aa_light     = "corrl",     aa_heavy   = "corflak",
        -- mobile AA, by lab (the air-defence floor / rush, lab_rules): flak truck (T2 vehicle plant), T2 bot, T1 vehicle, T1 bot, hover
        aa_flak_truck = "corsent",  aa_t2_bot  = "coraak",  aa_t1_veh  = "cormist", aa_t1_bot = "corcrash", aa_hover = "corah",
        nano         = "cornanotc",
        raider_veh   = "corgator",     -- the vehicle plant's cheap fast fighter (Incisor): early defence from the line's vp
        pounder      = "corlevlr",     -- the T1 vehicle plant's screen (Pounder): the spine garrison (unit_runtime SPINE_GARRISON)
        grunt        = "corak",        -- the T1 bot lab's basic fighter (early defence from the starter lab; army_groups' spam element)
        jammer_veh   = "coreter",      -- radar jammer, T2 vehicle plant (army_groups' jammer element)
        jammer_bot   = "corspec",      -- radar jammer, T2 bot lab
        radar        = "corrad",       -- T1 radar tower (the commander's early radar)
        con_t1_bot   = "corck",     con_t1_veh = "corcv",   con_t1_air = "corca",
        con_t2_bot   = "corack",    con_t2_veh = "coracv",  con_t2_air = "coraca",
        lab_t1_bot   = "corlab",    lab_t1_veh = "corvp",   lab_t1_air = "corap",
        lab_t2_bot   = "coralab",   lab_t2_veh = "coravp",  lab_t2_air = "coraap",
        lab_t3       = "corgant",
        mex          = "cormex",    wind       = "corwin",  storage    = "corestor",
        moho         = "cormoho",   fusion     = "corfus",  afus       = "corafus",   antinuke = "corfmd",   -- the nano-column block (line_transition/nano_cols)
        transport_air = "corvalk",     -- T1 air transport (lifts a nano turret: bar_framework/air_transport.lua; air_lift.lua's slow units)
        arty_t2_veh  = "cormart",      -- T2 vehicle artillery (Quaker): army_groups' arty element (5 x 420 alpha one-shots a Brute)
        heavy_t2_veh = "corgol",       -- T2 heavy tank (Tzar): army_groups' stop element ("stopping power", 292 aoe); only heavy transports lift it
        transport_heavy = "corseah",   -- T2 heavy air transport (T2 air lab): lifts a Tzar (air_lift.lua)
        transport_heavy_t1 = "corhvytrans",   -- T1 heavy air transport: lifts a Tzar too (air_lift.lua)
        -- static defence the proxy base builds (bar_framework/proxy/): T1 laser tower (Twin Guard), T2 pop-up laser (Scorpion),
        -- T2 pop-up artillery (Persecutor), long-range plasma cannon (Basilisk, range 4950)
        hllt         = "corhllt",   def_t2_popup = "corvipe",   def_t2_arty = "cortoast",   lrpc = "corint",
        jammer_t1    = "corjamt",   jammer_t2 = "corshroud",    radar_t2 = "corarad",       -- static jammers (Castro, Shroud), the T2 radar tower
        rez_bot      = "cornecro",                                                          -- the T1 bot lab's rez bot (Graverobber)
        def_t2_bulwark = "cordoom", aa_long = "corscreamer",  lrpc_t3 = "corbuzz",  heavy_t3 = "corjugg",   -- Bulwark, Screamer, Calamity, Behemoth (proxy ramp)
        heavy_t3_bot = "cordemon",                                                          -- Demon (T3): with the Behemoth the only ground army at the cap (cap_mode)
    },
    arm = {},      -- Armada: fill in (armdecom, armawac, armfig ...); a missing entry falls back to the Cortex name
}

local faction, over, warned = nil, {}, {}

local function Detect()
    if faction then return faction end
    faction = "cor"
    local ok, a, b, c, d, side = pcall(function() return Spring.GetTeamInfo(Spring.GetMyTeamID()) end)
    if ok and type(side) == "string" and side:lower():find("arm") then faction = "arm" end
    return faction
end

function M.SetFaction(f) faction = (f == "arm" or f == "cor") and f or "cor" end
function M.Faction() return Detect() end
function M.Set(role, name) over[role] = name end

function M.Get(role)
    if over[role] then return over[role] end
    local f = Detect()
    local n = M.TABLE[f] and M.TABLE[f][role]
    if n then return n end
    n = M.TABLE.cor[role]
    if n and f ~= "cor" and not warned[role] then
        warned[role] = true
        Spring.Echo("[ROLES] no " .. f .. " unit for role '" .. role .. "': using " .. n)
    end
    return n
end

function M.Def(role)
    local n = M.Get(role)
    return n and UnitDefNames and UnitDefNames[n] or nil
end
function M.Id(role)
    local d = M.Def(role)
    return d and d.id or nil
end
function M.Is(defID, role)
    local d = M.Def(role)
    return d ~= nil and defID ~= nil and d.id == defID
end

-- Several roles as a name set { [name] = true } (for the old "is this one of ..." tables).
function M.Names(...)
    local out = {}
    for _, r in ipairs({ ... }) do local n = M.Get(r); if n then out[n] = true end end
    return out
end

return M
