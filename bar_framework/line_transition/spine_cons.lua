-- bar_framework/line_transition/spine_cons.lua
-- The spine's constructors: what the spine (spine.lua / slot_spine.lua) borrows from the air-con pool and gives back.
-- The spine is a section of the con broker like the grids: the cons it holds are owned by "spine", registered here as a job that
-- wants none (it asks with Take, per cell, when it needs a builder) so they show up under their section in CB.Status / CB.Sections.
-- Part of line_transition (bar_framework/line_transition.lua installs it).

local M = {}

function M.Install(X)
    local CB = X.CB
    local AssignCons = X.AssignCons     -- con_orders

    -- a T1 (t1Only) or any air con that can build defID, taken from the free pool for the spine
    local function SpineTakeCon(T, defID, t1Only)
        return CB.Take(T.CB, "spine", { tier = t1Only and 1 or nil,
            canTake = function(cid) return not defID or T.BP.CanBuild(Spring.GetUnitDefID(cid), defID) end })
    end

    -- the spine is done with a con: back to the pool, and hand it to whichever job wants it
    local function SpineReturnCon(T, uid)
        if not Spring.GetUnitDefID(uid) then return end
        CB.Add(T.CB, uid)                          -- (already known: no-op)
        CB.Release(T.CB, uid, true)
        AssignCons(T, T.frame)
    end

    X.SpineTakeCon, X.SpineReturnCon = SpineTakeCon, SpineReturnCon

    X.jobs = X.jobs or {}
    X.jobs.spine = function(T, cb)
        CB.AddJob(cb, { name = "spine", section = "spine", prio = 100, tier = "any",
            -- the spine takes its ground cons itself (SpineTakeCon); an AIR lab (the T2 air plant, slot_spine AIR_LABS) waits for an air con, which the
            -- broker offers here as it comes out of the air lab (OfferCon places it on that lab's session)
            want = function() return (T.spineOn and T.spineMod.AirConWant) and T.spineMod.AirConWant() or 0 end,
            start = function(id) return T.spineOn and T.spineMod.OfferCon and T.spineMod.OfferCon(id) or false end })
    end
end

return M
