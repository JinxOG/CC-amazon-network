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

    ["a step outside any booking only goes into a free section"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "a", { op = "enter", sec = "N2" }, t).ok, true, "one-section step into a free section")
        assert_eq(core.handle(st, "b", { op = "enter", sec = "N2" }, t).ok, false, "refused while a is in it")
        core.handle(st, "a", { op = "leave", sec = "N2" }, t)
        assert_eq(core.handle(st, "b", { op = "enter", sec = "N2" }, t).ok, true)
    end,

    ["a silent turtle's booking is dropped, except the section it stands in"] = function(assert_eq)
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
        assert_eq(core.handle(st, "third", { op = "enter", sec = "J3" }, later).ok, false,
            "J3 stays held: the silent turtle is physically in it")
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
