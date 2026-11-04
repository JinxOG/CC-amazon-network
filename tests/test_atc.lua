-- The base air-traffic control rules (atc.lua), with no radio.
-- docs/superpowers/specs/2026-11-03-base-atc-design.md
package.path = "./?.lua;" .. package.path

local function loadCore()
    package.loaded["atc"] = nil
    _G.__ATC_TEST = true
    local core = require("atc")
    _G.__ATC_TEST = nil
    return core
end

-- A state past its settle window, so grants are live.
local function live()
    local core = loadCore()
    local st = core.new(0)
    return core, st, core.CFG.SETTLE_MS + 1
end

local DEPART3 = { "S3", "J3", "W3", "J2", "W2", "J1", "W1", "DH" }
local RETURN3 = { "ARR", "R5", "J5", "R4", "J4", "R3", "J3", "S3" }

return {
    -- node_4070 homed from support dock 211,-2793 straight into the parked turtle at 211,-2797 and stayed there
    -- (w3_atc_base150, 2026-11-03). A homing route from one dock to another must cross no third dock.
    ["no homing route from one dock to another drives through a third dock"] = function(assert_eq)
        package.loaded["waypoints"] = nil
        local W = require("waypoints")
        local isDock = {}
        for _, role in ipairs({ "DELIVERY", "SUPPORT" }) do
            for _, d in ipairs(W.docks[role]) do isDock[d.x .. "," .. d.z] = true end
        end
        local routes, worst, where = 0, 0, ""
        for _, role in ipairs({ "DELIVERY", "SUPPORT" }) do
            for _, from in ipairs(W.docks[role]) do
                for _, to in ipairs(W.docks[role]) do
                    if from ~= to then
                        routes = routes + 1
                        local x, z, crossed = from.x, from.z, 0
                        local function step()
                            if isDock[x .. "," .. z] and not (x == to.x and z == to.z) then crossed = crossed + 1 end
                        end
                        for _, wp in ipairs(W.internalReturnRouteFrom(to, from.x, from.z)) do
                            while x ~= wp.x do x = x + (wp.x > x and 1 or -1); step() end
                            while z ~= wp.z do z = z + (wp.z > z and 1 or -1); step() end
                        end
                        if crossed > worst then worst, where = crossed, from.x .. "," .. from.z .. " -> " .. to.x .. "," .. to.z end
                    end
                end
            end
        end
        assert_eq(routes > 10000, true, "every pair of docks was tried (" .. routes .. ")")
        assert_eq(worst, 0, "a homing route crossed another dock: " .. where)
    end,

    ["one turtle per section: a second departure waits in its dock until the way is clear"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "a", { op = "request", route = DEPART3 }, t).ok, true, "a is admitted")
        assert_eq(core.handle(st, "a", { op = "enter", sec = "S3" }, t).ok, true, "and enters its column")
        assert_eq(core.handle(st, "b", { op = "request", route = DEPART3 }, t).ok, false,
            "b is not admitted while a holds any of its route: it waits in its dock")
        for i, s in ipairs(DEPART3) do
            if i > 1 then assert_eq(core.handle(st, "a", { op = "enter", sec = s }, t).ok, true, "a enters " .. s) end
            core.handle(st, "a", { op = "leave", sec = s }, t)
            if i < #DEPART3 then
                assert_eq(core.handle(st, "b", { op = "request", route = DEPART3 }, t).ok, false, "still out while a is in " .. DEPART3[i + 1])
            end
        end
        assert_eq(core.handle(st, "b", { op = "request", route = DEPART3 }, t).ok, true, "admitted once a is out of the base")
        for _, s in ipairs(DEPART3) do
            assert_eq(core.handle(st, "b", { op = "enter", sec = s }, t).ok, true, "and never stops: " .. s)
            core.handle(st, "b", { op = "leave", sec = s }, t)
        end
    end,

    -- The jam that cannot happen: today a leaver and a returner meet head-on in
    -- bay 3's one-block column. Here the returner is not let out of the holding
    -- line while the leaver holds the crossing or the column.
    ["a returner and a leaver of the same bay never meet head-on"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "out", { op = "request", route = DEPART3 }, t).ok, true)
        assert_eq(core.handle(st, "out", { op = "enter", sec = "S3" }, t).ok, true)
        assert_eq(core.handle(st, "home", { op = "request", route = RETURN3 }, t).ok, false,
            "the returner stays in the holding line: S3 and J3 are out's")
        assert_eq(core.handle(st, "out", { op = "enter", sec = "J3" }, t).ok, true)
        core.handle(st, "out", { op = "leave", sec = "S3" }, t)
        assert_eq(core.handle(st, "home", { op = "request", route = RETURN3 }, t).ok, false, "J3 still out's")
        assert_eq(core.handle(st, "out", { op = "enter", sec = "W3" }, t).ok, true)
        core.handle(st, "out", { op = "leave", sec = "J3" }, t)
        assert_eq(core.handle(st, "home", { op = "request", route = RETURN3 }, t).ok, true, "out is west of bay 3: home comes up")
        for _, s in ipairs(RETURN3) do
            assert_eq(core.handle(st, "home", { op = "enter", sec = s }, t).ok, true, "home never waits at " .. s)
            core.handle(st, "home", { op = "leave", sec = s }, t)
        end
    end,

    ["partners share a section: a delivery holding the dispatch hole lets its support in"] = function(assert_eq)
        local core, st, t = live()
        local SUP = { "N1", "J1", "W1", "DH" }
        assert_eq(core.handle(st, "del", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "del" }, t).ok, true)
        for _, s in ipairs({ "S1", "J1", "W1", "DH" }) do core.handle(st, "del", { op = "enter", sec = s }, t) end
        for _, s in ipairs({ "S1", "J1", "W1" }) do core.handle(st, "del", { op = "leave", sec = s }, t) end
        assert_eq(core.handle(st, "sup", { op = "request", route = SUP, group = "del" }, t).ok, true,
            "the support is admitted although its partner holds DH")
        assert_eq(core.handle(st, "other", { op = "request", route = SUP }, t).ok, false, "nobody else is")
        for _, s in ipairs(SUP) do
            assert_eq(core.handle(st, "sup", { op = "enter", sec = s }, t).ok, true, "sup enters " .. s)
        end
    end,

    ["a request kept waiting holds off later ones that overlap it"] = function(assert_eq)
        local core, st, t = live()
        -- b sits in W2 (part of long's route) for longer than FAIR_MS
        core.handle(st, "b", { op = "request", route = { "W2" } }, t)
        core.handle(st, "b", { op = "enter", sec = "W2" }, t)
        assert_eq(core.handle(st, "long", { op = "request", route = DEPART3 }, t).ok, false, "W2 is b's")
        local later = t + core.CFG.FAIR_MS + 1
        assert_eq(core.handle(st, "long", { op = "request", route = DEPART3 }, later - 1).ok, false, "still waiting")
        assert_eq(core.handle(st, "short", { op = "request", route = { "S3", "J3" } }, later).ok, false,
            "S3 and J3 are free, but long has waited past FAIR_MS for them: short waits its turn")
        assert_eq(core.handle(st, "elsewhere", { op = "request", route = { "N5", "J5" } }, later).ok, true,
            "a route long does not need is not held up")
        core.handle(st, "b", { op = "leave", sec = "W2" }, later)
        assert_eq(core.handle(st, "long", { op = "request", route = DEPART3 }, later).ok, true, "long goes first")
    end,

    ["while it settles after boot nothing is granted"] = function(assert_eq)
        local core = loadCore()
        local st = core.new(1000)
        local r = core.handle(st, "a", { op = "request", route = DEPART3 }, 2000)
        assert_eq(r.ok, false)
        assert_eq(r.why, "settling")
        assert_eq(core.handle(st, "a", { op = "enter", sec = "S3", cur = nil }, 3000).ok, false)
    end,

    -- Unjam from the open end: after a restart the turtles standing in the base
    -- are put back first, the one nearest the end of its route ahead.
    ["the rebuild puts turtles in the base first, the one nearest the open end ahead"] = function(assert_eq)
        local core = loadCore()
        local st = core.new(0)
        -- back, in W3 heading west; front, in W2 just ahead of it; both need J2? front is past it
        core.handle(st, "back", { op = "enter", sec = "J2", cur = "W3", route = { "W3", "J2", "W2", "J1", "W1", "DH" } }, 100)
        core.handle(st, "front", { op = "enter", sec = "J1", cur = "W2", route = { "W2", "J1", "W1", "DH" } }, 200)
        core.handle(st, "docked", { op = "request", route = DEPART3 }, 300)          -- no cur: waits
        local n = core.settle(st, core.CFG.SETTLE_MS + 1)
        local t = core.CFG.SETTLE_MS + 2
        assert_eq(n, 2, "two turtles were standing in a section")
        assert_eq(core.handle(st, "front", { op = "enter", sec = "J1" }, t).ok, true, "the front one goes first")
        assert_eq(core.handle(st, "back", { op = "enter", sec = "J2" }, t).ok, true, "J2 is free for the back one")
        assert_eq(core.handle(st, "back", { op = "enter", sec = "W2" }, t).ok, false, "but W2 is front's until it leaves")
        assert_eq(core.handle(st, "docked", { op = "request", route = DEPART3 }, t).ok, false,
            "a departure through the lanes they stand in waits in its dock")
        assert_eq(core.handle(st, "home5", { op = "request", route = { "ARR", "R5", "J5", "S5" } }, t).ok, true,
            "a return that does not cross them comes straight in")
    end,

    ["a turtle the ATC never heard of, standing in a section, is given it"] = function(assert_eq)
        local core, st, t = live()
        local r = core.handle(st, "x", { op = "enter", sec = "J2", cur = "W3", route = { "W3", "J2", "W2" } }, t)
        assert_eq(r.ok, true, "nothing is ahead of it in J2")
        assert_eq(core.handle(st, "y", { op = "enter", sec = "W3" }, t).ok, false, "and W3 is held: it is in there")
    end,

    -- The boot rush (2026-11-03): turtles the ATC did not know were each given their whole route on trust, and
    -- a miner going east on the red lane met a support going west. Only where it stands is taken on trust.
    ["a turtle the ATC does not know is trusted with where it stands, not with where it wants to go"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "west", { op = "request", route = { "R1", "J1", "S1" } }, t).ok, true)
        assert_eq(core.handle(st, "west", { op = "enter", sec = "R1" }, t).ok, true)
        local r = core.handle(st, "east", { op = "enter", sec = "R1", cur = "J1", route = { "J1", "R1", "J2", "R2" } }, t)
        assert_eq(r.ok, false, "R1 is west's: east is refused, not booked through it")
        assert_eq(core.handle(st, "west", { op = "enter", sec = "J1" }, t).ok, false, "J1 is east's: it stands there")
        assert_eq(core.handle(st, "third", { op = "request", route = { "R2", "J3", "S3" } }, t).ok, true,
            "and the rest of east's route (J2, R2) was not booked for it: a third turtle may use R2")
    end,

    ["a step outside any booking only goes into a free section"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "a", { op = "enter", sec = "N2" }, t).ok, true, "one-section step into a free section")
        assert_eq(core.handle(st, "b", { op = "enter", sec = "N2" }, t).ok, false, "refused while a is in it")
        core.handle(st, "a", { op = "leave", sec = "N2" }, t)
        assert_eq(core.handle(st, "b", { op = "enter", sec = "N2" }, t).ok, true)
    end,

    -- It used to keep the sections the silent turtle had entered ("it stands there"). That leaked: a lost leave
    -- or a never-refreshed one-step entry held a bay column for good, and 35 departures waited in their docks
    -- (w3_atc_base150, 2026-11-03). A dead turtle left in a lane is still physically in the way, and the next
    -- turtle's stuck rule hands its job back.
    ["a silent turtle gives back everything, the sections it entered too"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "dead", { op = "request", route = DEPART3 }, t)
        core.handle(st, "dead", { op = "enter", sec = "S3" }, t)
        core.handle(st, "dead", { op = "enter", sec = "J3" }, t)
        core.handle(st, "dead", { op = "leave", sec = "S3" }, t)
        core.handle(st, "other", { op = "request", route = { "R3", "J2", "W2" } }, t)
        assert_eq(core.handle(st, "other", { op = "enter", sec = "R3" }, t).ok, true)
        assert_eq(core.handle(st, "other", { op = "enter", sec = "J2" }, t).ok, false, "dead's booking is ahead in J2")
        local later = t + core.CFG.STALE_MS + 1
        core.handle(st, "other", { op = "report" }, later)        -- other is alive
        assert_eq(core.sweep(st, later) >= 1, true, "the silent booking is dropped")
        assert_eq(core.handle(st, "other", { op = "enter", sec = "J2" }, later).ok, true, "J2 is free now")
        assert_eq(core.handle(st, "third", { op = "enter", sec = "J3" }, later).ok, true,
            "and J3, which it had entered, is free too")
    end,

    ["a turtle that keeps asking keeps what it holds, its one-step entries included"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "w", { op = "enter", sec = "N4" }, t).ok, true, "a one-step entry outside any booking")
        local half = t + math.floor(core.CFG.STALE_MS / 2)
        core.handle(st, "w", { op = "enter", sec = "J4", cur = "N4" }, half)       -- still asking, from N4
        local later = t + core.CFG.STALE_MS + 1
        core.handle(st, "w", { op = "enter", sec = "J4", cur = "N4" }, later)
        core.sweep(st, later)
        assert_eq(core.handle(st, "x", { op = "enter", sec = "N4" }, later).ok, false, "N4 is still w's")
    end,

    ["a cancelled booking frees every section but the one it stands in"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "a", { op = "request", route = DEPART3 }, t)
        core.handle(st, "a", { op = "enter", sec = "S3" }, t)
        core.handle(st, "a", { op = "cancel", cur = "S3" }, t)
        assert_eq(core.handle(st, "b", { op = "enter", sec = "W2" }, t).ok, true, "W2 is free")
        assert_eq(core.handle(st, "b", { op = "enter", sec = "S3" }, t).ok, false, "S3 is not: a is in it")
    end,
}
