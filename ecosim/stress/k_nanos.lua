local kills = {{21600, 'block_nanos'}}
local S = WG.Strategy
if not S then error("stress: no WG.Strategy") end
local origTick = S.Tick
local ki = 1
local function InBlock(x) return x and x < 1820 end   -- moved default spawns: the block lies at x 112..1824, the line beyond
local SETS = {
  block_nanos = function(d, x) return d.name == "cornanotc" and InBlock(x) end,
  block_all   = function(d, x) return (d.speed or 0) == 0 and InBlock(x) end,
  block_half  = function(d, x, uid) return (d.speed or 0) == 0 and InBlock(x) and uid % 2 == 0 end,
  aircons     = function(d) return d.name == "corca" or d.name == "coraca" end,
  airlab      = function(d) return d.name == "corap" end,
  t2labs      = function(d) return d.name == "coraap" end,
}
S.Tick = function(self, frame, state)
    while kills[ki] and frame >= kills[ki][1] do
        local f, n = SETS[kills[ki][2]], 0
        for _, uid in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID()) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            local x = select(1, Spring.GetUnitPosition(uid))
            if d and f(d, x, uid) then Spring.DestroyUnit(uid); n = n + 1 end
        end
        Spring.Echo(string.format("[STRESS] frame %d killed %d %s", frame, n, kills[ki][2]))
        ki = ki + 1
    end
    return origTick(self, frame, state)
end
