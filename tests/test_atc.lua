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
    -- node_3069 rebooted in an aisle behind its dock (215,-2808) and drove Z first into the parked front row
    -- (world restart, sim, 2026-11-03). From ANY free cell of a bay side, homing must cross no dock.
    ["no homing route from anywhere in a bay drives through a dock"] = function(assert_eq)
        package.loaded["waypoints"] = nil
        local W = require("waypoints")
        local isDock = {}
        for _, role in ipairs({ "DELIVERY", "SUPPORT", "MINER" }) do
            for _, d in ipairs(W.docks[role]) do isDock[d.x .. "," .. d.z] = true end
        end
        local routes, worst, where = 0, 0, ""
        for x = 153, 217 do
            for _, zr in ipairs({ { -2813, -2804 }, { -2800, -2790 } }) do
                for z = zr[1], zr[2] do
                    local sec = W.atcSection(x, 67, z)
                    if sec and not isDock[x .. "," .. z] then
                        for _, role in ipairs({ "DELIVERY", "SUPPORT", "MINER" }) do
                            for _, to in ipairs(W.docks[role]) do
                                routes = routes + 1
                                local cx, cz, crossed = x, z, 0
                                local function step()
                                    if isDock[cx .. "," .. cz] and not (cx == to.x and cz == to.z) then crossed = crossed + 1 end
                                end
                                for _, wp in ipairs(W.internalReturnRouteFrom(to, x, z)) do
                                    while cx ~= wp.x do cx = cx + (wp.x > cx and 1 or -1); step() end
                                    while cz ~= wp.z do cz = cz + (wp.z > cz and 1 or -1); step() end
                                end
                                if crossed > worst then worst, where = crossed, x .. "," .. z .. " -> " .. to.x .. "," .. to.z end
                            end
                        end
                    end
                end
            end
        end
        assert_eq(routes > 10000, true, "every free bay cell to every dock was tried (" .. routes .. ")")
        assert_eq(worst, 0, "a homing route crossed a dock: " .. where)
    end,

    ["no homing route from one dock to another drives through a third dock"] = function(assert_eq)
        package.loaded["waypoints"] = nil
        local W = require("waypoints")
        local isDock = {}
        for _, role in ipairs({ "DELIVERY", "SUPPORT", "MINER" }) do
            for _, d in ipairs(W.docks[role]) do isDock[d.x .. "," .. d.z] = true end
        end
        local routes, worst, where = 0, 0, ""
        for _, role in ipairs({ "DELIVERY", "SUPPORT", "MINER" }) do
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

    -- The shakeout's per-bay 150 sim (w3_bay_types150, runs 053838/193503/194547, 2026-11-11): a delivery held DH at
    -- the hole waiting for its support; an older request wanted DH too and had waited past FAIR_MS, so the fairness
    -- rule kept the support out behind it; the older one could never get in while the pair held DH. A circle: the
    -- delivery left alone after 600 s, its support went down after it and held DH for good (waits of 19,353 s).
    ["a support whose delivery is already let in is not kept out by an older waiter"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "del", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "del" }, t).ok, true)
        for _, s in ipairs({ "S1", "J1", "W1", "DH" }) do core.handle(st, "del", { op = "enter", sec = s }, t) end
        for _, s in ipairs({ "S1", "J1", "W1" }) do core.handle(st, "del", { op = "leave", sec = s }, t) end
        local OLD = { "S2", "J2", "W2", "J1", "W1", "DH" }
        assert_eq(core.handle(st, "old", { op = "request", route = OLD }, t).ok, false, "DH is the pair's")
        local later = t + core.CFG.FAIR_MS + 1
        assert_eq(core.handle(st, "old", { op = "request", route = OLD }, later).ok, false, "still waiting, past FAIR_MS")
        local r = core.handle(st, "sup", { op = "request", route = { "N1", "J1", "W1", "DH" }, group = "del" }, later)
        assert_eq(r.ok, true, "its partner is in: the older waiter cannot move until this pair has gone ("
            .. tostring(r.why) .. ")")
        assert_eq(core.handle(st, "other", { op = "request", route = { "N2", "J2" } }, later).ok, false,
            "a stranger is still held behind the older waiter")
    end,

    -- The same circle, any turtle (2026-11-14): a support that cannot dig came back up the dispatch shaft by the way it
    -- went (home.retrace) and stood in DH asking for its way home; the departures queued for DH were older, so it was
    -- held "after an older request" -- in DH, which they were waiting for (sim w3_side_atc, DH held to the end).
    ["a turtle standing in a section an older waiter needs is not kept behind that waiter"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "back", { op = "request", route = { "DH" } }, t).ok, true)
        core.handle(st, "back", { op = "enter", sec = "DH" }, t)
        local OLD = { "S1", "J1", "W1", "DH" }
        assert_eq(core.handle(st, "old", { op = "request", route = OLD }, t).ok, false, "DH is back's")
        local later = t + core.CFG.FAIR_MS + 1
        assert_eq(core.handle(st, "old", { op = "request", route = OLD }, later).ok, false, "still waiting, past FAIR_MS")
        local r = core.handle(st, "back", { op = "request", cur = "DH", route = { "DH", "W1", "J1", "N1" } }, later)
        assert_eq(r.ok, true, "the older waiter cannot move until this one leaves DH (" .. tostring(r.why) .. ")")
        assert_eq(core.handle(st, "other", { op = "request", route = { "S1", "J1" } }, later).ok, false,
            "a turtle that holds nothing the older waiter needs is still held behind it")
    end,

    -- The circle through a chain (sim w3_side_atc, 2026-11-14): node_56 stood in DH asking for its way home; the
    -- returns on the holding line were older and overlapped it, and they were held behind node_52's older request,
    -- which waited for DH. Fairness kept the one turtle that could move from moving. A turtle standing in a section
    -- is in the way of others whatever it waits for, so fairness never holds it back; occupancy still does.
    ["a turtle standing in a section is not held back by fairness, only by what is occupied"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "here", { op = "request", route = { "DH" } }, t).ok, true)
        core.handle(st, "here", { op = "enter", sec = "DH" }, t)
        assert_eq(core.handle(st, "blocker", { op = "request", route = { "R1" } }, t).ok, true)
        core.handle(st, "blocker", { op = "enter", sec = "R1" }, t)
        local OLD = { "R1", "J1", "S1" }                     -- waits for R1, needs nothing "here" holds
        assert_eq(core.handle(st, "old", { op = "request", route = OLD }, t).ok, false, "R1 is blocker's")
        local later = t + core.CFG.FAIR_MS + 1
        assert_eq(core.handle(st, "old", { op = "request", route = OLD }, later).ok, false, "still waiting, past FAIR_MS")
        local r = core.handle(st, "here", { op = "request", cur = "DH", route = { "DH", "W1", "J1", "N1" } }, later)
        assert_eq(r.ok, true, "standing in DH, it is let go (" .. tostring(r.why) .. ")")
        assert_eq(core.handle(st, "dock", { op = "request", route = { "N2", "J1" } }, later).ok, false,
            "a turtle not in any section still waits its turn behind the older request")
    end,

    -- T2 w3-depart-off-dock-c (2026-11-14): a delivery home from 196,67,-2761, south of the base, went X then Z to its
    -- slot and crossed the taxi row (ARR) on the way; its support, one block behind, stopped in the taxi row holding ARR,
    -- and the delivery waited for ARR to go up -- for its own support, to the end of the run.
    ["the way to a holding slot never enters the arrivals section, from either side"] = function(assert_eq)
        package.loaded["waypoints"] = nil
        local W = require("waypoints")
        local function cells(from, route)
            local out, x, y, z = {}, from.x, from.y, from.z
            for _, wp in ipairs(route) do
                while y ~= wp.y do y = y + (wp.y > y and 1 or -1); out[#out + 1] = { x, y, z } end
                while x ~= wp.x do x = x + (wp.x > x and 1 or -1); out[#out + 1] = { x, y, z } end
                while z ~= wp.z do z = z + (wp.z > z and 1 or -1); out[#out + 1] = { x, y, z } end
            end
            return out
        end
        for _, from in ipairs({ { x = 196, y = 60, z = -2761 }, { x = 240, y = 60, z = -2760 }, { x = 196, y = 60, z = -2798 },
                                { x = 300, y = 60, z = -2770 } }) do
            for _, k in ipairs({ 1, 7, 14 }) do
                local route = W.holdingApproach(from, k, 60)
                local c = cells(from, route)
                local inArr, last, prev = 0, c[#c], c[#c - 1]
                for _, p in ipairs(c) do if W.atcSection(p[1], p[2], p[3]) == "ARR" then inArr = inArr + 1 end end
                local slot = W.holdingSlot(k, 60)
                local where = string.format("from %d,%d to slot %d", from.x, from.z, k)
                assert_eq(inArr, 0, where .. ": no cell of the way is in ARR")
                assert_eq(last[1] == slot.x and last[3] == slot.z, true, where .. ": it ends in the slot")
                assert_eq(prev and prev[3] < slot.z and prev[1] == slot.x, true,
                    where .. ": and comes into it from the north, so the support one behind is not on the taxi row")
                -- A support that fell behind catches up with move.to(prev) from where it is: X first, then Z. Up to 4
                -- behind, cutting a corner that way must not take it into ARR either (sim w3_side_atc: node_57, two
                -- behind, cut the corner of the first version of this detour into the arrivals shaft's foot and held
                -- ARR for 18 minutes).
                local cut = 0
                local all = { { from.x, from.y, from.z } }
                for _, p in ipairs(c) do all[#all + 1] = p end
                for lag = 2, 4 do
                    for i = 1, #all - lag do
                        local a, b = all[i], all[i + lag]
                        for _, q in ipairs(cells({ x = a[1], y = a[2], z = a[3] }, { { x = b[1], y = b[2], z = b[3] } })) do
                            if W.atcSection(q[1], q[2], q[3]) == "ARR" then cut = cut + 1 end
                        end
                    end
                end
                assert_eq(cut, 0, where .. ": a support up to 4 behind, catching up X first, never steps into ARR")
            end
        end
    end,

    -- T2 shakeout-side-c (2026-11-15): node_208's ATC_LEAVE / ATC_CANCEL were lost in a radio loss on its way home, so
    -- R2-R5 stayed booked to it on its dock; it asked for a departure every two seconds, every ask kept that booking
    -- alive, and the returns waiting for R2-R5 held its departure back as the older requests: 12 of 20 jammed.
    ["a new route is the end of the old one: what it booked and is not standing in is let go"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "home", { op = "request", route = RETURN3 }, t).ok, true)
        core.handle(st, "home", { op = "enter", sec = "ARR" }, t)
        core.handle(st, "home", { op = "enter", sec = "R5", cur = "ARR" }, t)
        core.handle(st, "home", { op = "leave", sec = "ARR" }, t)
        -- ... and home on its dock, its leaves and cancel lost. Another return now waits for the red lane.
        local back = RETURN3     -- overlaps the departure below at J3 and S3, as node_208's did at J1 and S1
        assert_eq(core.handle(st, "next", { op = "request", route = back }, t).ok, false, "R5 is still home's")
        local later = t + core.CFG.FAIR_MS + 1
        core.handle(st, "next", { op = "request", route = back }, later)
        -- home, docked (no section), asks for a departure
        local r = core.handle(st, "home", { op = "request", route = { "S3", "J3", "W3", "J2", "W2", "J1", "W1", "DH" } }, later)
        -- What it booked for the trip home and is not standing in is let go: nothing in R5..R2 is home's now.
        local stale = 0
        for _, sec in ipairs({ "R5", "R4", "R3", "R2" }) do
            for _, rid in ipairs(st.q[sec] or {}) do if st.res[rid] and st.res[rid].id == "home" then stale = stale + 1 end end
        end
        assert_eq(stale, 0, "the departure's ask let go of R5 and the rest it was not standing in")
        -- And the return goes: at once, or -- a return was let in last, so by turns (R3) the departure first -- once
        -- the departure is through J3 and S3.
        local n = core.handle(st, "next", { op = "request", route = back }, later)
        if not n.ok then
            assert_eq(r.ok, true, "the return waits only because the departure had its turn (" .. tostring(n.why) .. ")")
            for _, sec in ipairs({ "S3", "J3", "W3", "J2", "W2", "J1", "W1", "DH" }) do
                core.handle(st, "home", { op = "enter", sec = sec }, later); core.handle(st, "home", { op = "leave", sec = sec }, later)
            end
            n = core.handle(st, "next", { op = "request", route = back }, later + 1000)
        end
        assert_eq(n.ok, true, "the return goes (" .. tostring(n.why) .. ")")
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

    -- node_81 (a support: it cannot dig) was given the first free slot instead of its partner's, the only one
    -- dug all the way, and stayed in the tunnel (sim, 2026-11-03).
    ["a support gets its partner's holding slot, kept back from strangers for a minute"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "del", { op = "hold", line = "tunnel" }, t).slot, 1)
        assert_eq(core.handle(st, "other", { op = "hold", line = "tunnel" }, t).slot, 2)
        core.handle(st, "del", { op = "enter", sec = "ARR" }, t)                   -- del leaves slot 1 for the shaft
        assert_eq(core.handle(st, "stranger", { op = "hold", line = "tunnel" }, t + 1000).slot, 3,
            "slot 1 is kept back: a stranger gets the next one")
        assert_eq(core.handle(st, "sup", { op = "hold", line = "tunnel", prefer = 1 }, t + 9000).slot, 1,
            "the support asking for the slot it stands in gets it")
        assert_eq(core.handle(st, "late", { op = "hold", line = "tunnel", prefer = 2 }, t + 9000).slot ~= 2, true,
            "a slot somebody holds is not given away, asked for or not")
        core.handle(st, "sup", { op = "enter", sec = "ARR" }, t + 20000)
        assert_eq(core.handle(st, "next", { op = "hold", line = "tunnel", prefer = 1 }, t + 20000 + core.CFG.SLOT_KEEP_MS + 1).slot, 1,
            "after the minute it is anybody's")
    end,

    -- node_81 (cannot dig) asked for slot 3, the one it stood under, was given slot 1 while 3 was still held, and
    -- stayed in the tunnel (sim, 2026-11-03).
    ["a turtle that cannot dig gets the slot it stands under or none, never another"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "a", { op = "hold", line = "tunnel" }, t).slot, 1)
        assert_eq(core.handle(st, "b", { op = "hold", line = "tunnel" }, t).slot, 2)
        local r = core.handle(st, "sup", { op = "hold", line = "tunnel", prefer = 2, strict = true }, t)
        assert_eq(r.ok, false, "slot 2 is b's: refused")
        assert_eq(r.slot, nil, "and no other slot is handed out instead")
        core.handle(st, "b", { op = "enter", sec = "ARR" }, t + 1000)
        assert_eq(core.handle(st, "sup", { op = "hold", line = "tunnel", prefer = 2, strict = true }, t + 2000).slot, 2,
            "once b leaves it, slot 2 is the support's")
    end,

    -- node_81 held slot 1 from a trip seven minutes before; asking for slot 3, the one it stood under, it was told
    -- "slot 1, yours already" and sent through rock (sim, 2026-11-03).
    ["an old slot gives way to the one a turtle stands under, and finishing gives any slot back"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "sup", { op = "hold", line = "tunnel" }, t).slot, 1, "an earlier trip's slot")
        assert_eq(core.handle(st, "sup", { op = "hold", line = "tunnel", prefer = 3, strict = true }, t + 1000).slot, 3,
            "asking for the slot it stands under, it gets that one")
        assert_eq(core.handle(st, "x", { op = "hold", line = "tunnel", prefer = 1 }, t + 2000).slot, 1,
            "and slot 1 went back")
        core.handle(st, "sup", { op = "cancel" }, t + 3000)
        assert_eq(core.handle(st, "y", { op = "hold", line = "tunnel", prefer = 3 }, t + 4000).slot, 3,
            "finished (home), it holds no slot any more")
    end,

    -- Slot 1 again and again sent every arrival up the same column, into the support of the pair before, still
    -- waiting there: 8 turtles piled up under slot 1 (sim, 2026-11-03).
    ["holding slots are handed out in turn around the line, not the first free one"] = function(assert_eq)
        local core, st, t = live()
        local got = {}
        for i = 1, 3 do got[i] = core.handle(st, "r" .. i, { op = "hold", line = "tunnel" }, t).slot end
        assert_eq(table.concat(got, ","), "1,2,3")
        core.handle(st, "r1", { op = "enter", sec = "ARR" }, t)
        local later = t + core.CFG.SLOT_KEEP_MS + 1
        assert_eq(core.handle(st, "r4", { op = "hold", line = "tunnel" }, later).slot, 4,
            "slot 1 is free again, but the next arrival gets the next column")
    end,

    -- A homing route goes up a bay's centre column to the red lane and back down it: S5, J5, S5 again. Leaving S5
    -- took it out of S5's queue, and coming back it was told "ahead" by nobody, for good (node_3069, world restart,
    -- sim, 2026-11-03).
    ["a turtle may come back into a section of its own route it has left, if the section is free"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "h", { op = "request", route = { "S5", "J5" } }, t).ok, true)
        assert_eq(core.handle(st, "h", { op = "enter", sec = "S5" }, t).ok, true)
        assert_eq(core.handle(st, "h", { op = "enter", sec = "J5" }, t).ok, true)
        core.handle(st, "h", { op = "leave", sec = "S5" }, t)
        assert_eq(core.handle(st, "h", { op = "enter", sec = "S5", cur = "J5" }, t).ok, true, "back into S5: it is free")
        assert_eq(core.handle(st, "o", { op = "enter", sec = "S5" }, t).ok, false, "and it is h's again")
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
        -- other is alive and talking all the while, as a waiting turtle does (it asks every second or two): silence
        -- counts only while others are heard (2026-11-14, the blackout rule below)
        for at = t + 5000, later, 5000 do core.handle(st, "other", { op = "report" }, at) end
        core.handle(st, "other", { op = "report" }, later)
        assert_eq(core.sweep(st, later) >= 1, true, "the silent booking is dropped")
        assert_eq(core.handle(st, "other", { op = "enter", sec = "J2" }, later).ok, true, "J2 is free now")
        assert_eq(core.handle(st, "third", { op = "enter", sec = "J3" }, later).ok, true,
            "and J3, which it had entered, is free too")
    end,

    -- A total radio blackout (sim w3_side_atc, 5 minutes): the ATC hears nobody, so nobody is silent. Swept after 3
    -- minutes, node_35 lost R5 while standing in it, node_36 was granted R5 and J5, and each held what the other needed.
    ["a total blackout is no one's silence: nothing is swept, and a dead turtle still is once others talk"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "a", { op = "request", route = { "R5", "J5" } }, t)
        core.handle(st, "a", { op = "enter", sec = "R5" }, t)
        local after = t + 5 * 60000                                  -- five minutes in which the ATC hears no one
        local swept = core.sweep(st, after)
        assert_eq(swept, 0, "nothing swept: the ATC heard no one, so a was not silent")
        assert_eq(core.handle(st, "b", { op = "request", route = { "R5", "J5" } }, after).ok, false,
            "R5 is still a's, whom the blackout kept quiet")
        -- b now waits, asking every few seconds: a's silence counts again from here.
        local at = after
        while at < after + core.CFG.STALE_MS + 5000 do
            at = at + 5000
            core.handle(st, "b", { op = "request", route = { "R5", "J5" } }, at)
            core.sweep(st, at)
        end
        assert_eq(core.handle(st, "b", { op = "request", route = { "R5", "J5" } }, at).ok, true,
            "a turtle that stays silent while others are heard is swept as before: b gets R5")
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

    -- 2026-11-16 (T2 w3-atc-staged-lost-c): a delivery rebooted in the dispatch hole cell, its support standing behind
    -- it at staging. Measured again, the delivery booked its way home -- with no party now (a reboot forgets it) -- and
    -- waited for its support to move out of its way; the support, given up, asked for its own way home in its
    -- delivery's party and was held "busy at W1" by its own delivery's booking: each waited for the other.
    ["a support shares its delivery's bookings even when the delivery's carry no party"] = function(assert_eq)
        local core, st, t = live()
        local home = { "DH", "W1", "R0", "J1", "S1" }
        assert_eq(core.handle(st, "del", { op = "request", route = home, cur = "DH" }, t).ok, true, "the delivery's way home")
        local r = core.handle(st, "sup", { op = "request", route = { "DH", "W1", "R0", "J1", "N1" }, cur = "DH", group = "del" }, t + 1000)
        assert_eq(r.ok, true, "its support is let home through what its own delivery holds (" .. tostring(r.why) .. ")")
        local other = core.handle(st, "x9", { op = "request", route = { "W1" }, group = "zz" }, t + 2000)
        assert_eq(other.ok, false, "a turtle of another party still is not")
    end,

    -- R2 of docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md (W3, 2026-11-17): THE PAIR'S DEPARTURE
    -- IS ADMITTED AS ONE UNIT. The delivery used to be let out alone and its support asked only once the delivery was
    -- at the hole; traffic admitted in between held the support back while the delivery held the hole -- every
    -- STAGE_WAIT_S expiry (600 s) sat in that gap. Now each half asks from its dock naming its partner (pair), and
    -- neither is let in until both have asked and both routes are free.
    ["a pair's departure is let in only once both halves have asked, and then both at once"] = function(assert_eq)
        local core, st, t = live()
        local DEL, SUP = { "S1", "J1", "W1", "DH" }, { "N1", "J1", "W1", "DH" }
        local r1 = core.handle(st, "del", { op = "request", route = DEL, group = "del", pair = "sup" }, t)
        assert_eq(r1.ok, false, "the delivery alone is not let in")
        assert_eq(r1.why, "waiting for partner", "and is told why (" .. tostring(r1.why) .. ")")
        local r2 = core.handle(st, "sup", { op = "request", route = SUP, group = "del", pair = "del" }, t + 1000)
        assert_eq(r2.ok, true, "its support asks: both are let in (" .. tostring(r2.why) .. ")")
        local r3 = core.handle(st, "del", { op = "request", route = DEL, group = "del", pair = "sup" }, t + 2000)
        assert_eq(r3.ok, true, "the delivery's next ask finds itself let in")
        assert_eq(core.handle(st, "other", { op = "request", route = { "S2", "J2", "W2", "J1", "W1", "DH" } }, t + 3000).ok, false,
            "and nobody else into DH while the pair has it")
    end,

    ["a pair is not let in while either half's way is taken"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "x", { op = "request", route = { "N1" } }, t).ok, true, "a stranger holds N1, the support's way")
        assert_eq(core.handle(st, "x", { op = "enter", sec = "N1" }, t).ok, true)
        core.handle(st, "del", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "del", pair = "sup" }, t)
        local r = core.handle(st, "sup", { op = "request", route = { "N1", "J1", "W1", "DH" }, group = "del", pair = "del" }, t + 1000)
        local d = core.handle(st, "del", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "del", pair = "sup" }, t + 2000)
        assert_eq(r.ok, false, "the support is not let in")
        assert_eq(d.ok, false, "nor is the delivery, alone, although its own way is free")
        core.handle(st, "x", { op = "leave", sec = "N1" }, t + 3000)
        local r2 = core.handle(st, "sup", { op = "request", route = { "N1", "J1", "W1", "DH" }, group = "del", pair = "del" }, t + 4000)
        assert_eq(r2.ok, true, "N1 free: the pair goes")
    end,

    ["a message from either half keeps the pair's bookings alive"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "del", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "del", pair = "sup" }, t)
        core.handle(st, "sup", { op = "request", route = { "N1", "J1", "W1", "DH" }, group = "del", pair = "del" }, t)
        -- the support waits silently on its dock for HOLE_READY; its delivery keeps talking
        local later = t
        for _ = 1, 48 do              -- every 5 s, as a turtle at a gate talks: the ATC is not deaf
            later = later + 5000
            core.handle(st, "del", { op = "enter", sec = "S1" }, later)
            core.sweep(st, later)
        end
        local kept = st.byTurtle["sup"] ~= nil and st.res[st.byTurtle["sup"]] ~= nil
        assert_eq(kept, true, "the support's booking survived its own 240 s of silence")
    end,

    -- 2026-11-17 (sim w3_side_atc on ab88c93): the ATC restarted while a pair was going out; the delivery, in DH, was
    -- rebuilt from its report with no party, and its support -- whose booking from its dock was not rebuilt -- asked
    -- again and was held "after an older request" whose route needed DH: the DH its own delivery held for it.
    ["after an ATC restart a support is not held behind an older waiter for the DH its delivery holds"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "del", { op = "report", cur = "DH", route = { "DH" } }, t)          -- rebuilt: no group
        local OLD = { "S2", "J2", "W2", "J1", "W1", "DH" }
        assert_eq(core.handle(st, "old", { op = "request", route = OLD }, t).ok, false, "an older waiter for DH")
        local later = t + core.CFG.FAIR_MS + 1
        core.handle(st, "old", { op = "request", route = OLD }, later)
        local r = core.handle(st, "sup", { op = "request", route = { "N1", "J1", "W1", "DH" }, group = "del", pair = "del" }, later + 1000)
        assert_eq(r.ok, true, "the support is let in to its delivery (" .. tostring(r.why) .. ")")
    end,

    ["a turtle's report carries its party, so a restarted ATC rebuilds the pair"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "del", { op = "report", cur = "DH", route = { "DH" }, group = "del" }, t)
        local rid = st.byTurtle["del"]
        assert_eq(rid ~= nil and st.res[rid].group, "del", "the rebuilt booking is the pair's")
    end,

    -- 2026-11-17 (sim w3_side_atc on bfd5341): a support at the holding line asked for the slot it stood under -- its
    -- own delivery's -- and was refused, "slot 14 is node_33's", until its delivery had left. A pair shares its slot.
    ["a support shares the holding slot its own delivery holds; a stranger does not"] = function(assert_eq)
        local core, st, t = live()
        local d = core.handle(st, "del", { op = "hold", line = "tunnel" }, t)
        assert_eq(d.ok, true, "the delivery has a slot")
        local s = core.handle(st, "sup", { op = "hold", line = "tunnel", prefer = d.slot, strict = true, pair = "del" }, t + 1000)
        assert_eq(s.ok and s.slot, d.slot, "its support is given the same slot (" .. tostring(s.why) .. ")")
        local x = core.handle(st, "x", { op = "hold", line = "tunnel", prefer = d.slot, strict = true, pair = "zz" }, t + 2000)
        assert_eq(x.ok, false, "a turtle of another pair is not")
    end,

    -- R3 (the user, 2026-11-17): "every turtle should be aware of the order it's going in... I'm number 5, I go after
    -- 4". A request waiting to be let in is told its place in its line (departures: through DH; returns: through ARR)
    -- and who is just ahead; a pair counts once; a turtle that stopped asking is not in the line.
    ["a waiting turtle is told its place in its line and who is ahead of it"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "x", { op = "request", route = { "W1", "DH" } }, t).ok, true, "DH taken")
        local DEP = { "S2", "J2", "W2", "J1", "W1", "DH" }
        local a = core.handle(st, "a", { op = "request", route = DEP }, t + 1000)
        core.handle(st, "p1", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "p1", pair = "p2" }, t + 2000)
        core.handle(st, "p2", { op = "request", route = { "N1", "J1", "W1", "DH" }, group = "p1", pair = "p1" }, t + 2500)
        local b = core.handle(st, "b", { op = "request", route = DEP }, t + 3000)
        assert_eq(a.place, 1, "the first to ask is first (" .. tostring(a.place) .. ")")
        assert_eq(b.place, 3, "the third: a, then the pair p1+p2 counted once (" .. tostring(b.place) .. ")")
        assert_eq(b.after, "p1", "and it goes after the pair (" .. tostring(b.after) .. ")")
        assert_eq(b.line, "departure", "in the departure line")
        local later = core.handle(st, "b", { op = "request", route = DEP }, t + 30000)    -- a, p1, p2 stopped asking
        assert_eq(later.place, 1, "those that stopped asking are no longer ahead (" .. tostring(later.place) .. ")")
    end,

    -- R3 (SPEC-OWNER's ruling 2026-11-17: "alternate; if only one line is waiting it goes straight away, and the order
    -- never depends on a clock"). FAIR_MS let a newer request overtake an older one for 60 s; now an older waiter of
    -- the same line always goes first, and the departure and return lines take turns where they share sections.
    ["in one line the older waiter goes first, with no clock"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "x", { op = "request", route = { "J2" } }, t).ok, true, "J2 taken")
        core.handle(st, "old", { op = "request", route = { "S2", "J2", "W2", "J1", "W1", "DH" } }, t + 1000)    -- held at J2
        local new = core.handle(st, "new", { op = "request", route = { "S1", "J1", "W1", "DH" } }, t + 2000)
        assert_eq(new.ok, false, "the newer departure does not overtake the older one (" .. tostring(new.why) .. ")")
    end,

    ["the departure and return lines take turns where they share a section"] = function(assert_eq)
        local core, st, t = live()
        local DEP, RET = { "S1", "J1", "W1", "DH" }, { "ARR", "R1", "J1", "S1" }
        assert_eq(core.handle(st, "d0", { op = "request", route = DEP }, t).ok, true, "a departure goes: the last one let in")
        core.handle(st, "d0", { op = "enter", sec = "S1" }, t); core.handle(st, "d0", { op = "enter", sec = "J1" }, t)
        core.handle(st, "d1", { op = "request", route = DEP }, t + 1000)     -- older, the departure line
        core.handle(st, "r1", { op = "request", route = RET }, t + 2000)     -- newer, the return line
        for _, sec in ipairs({ "S1", "J1", "W1", "DH" }) do core.handle(st, "d0", { op = "leave", sec = sec }, t + 3000) end
        local r = core.handle(st, "r1", { op = "request", route = RET }, t + 4000)
        assert_eq(r.ok, true, "a departure went last: the return's turn, though the departure waiting is older (" .. tostring(r.why) .. ")")
        local d = core.handle(st, "d1", { op = "request", route = DEP }, t + 5000)
        assert_eq(d.ok, false, "the departure waits for the return it shares J1 and S1 with")
    end,

    ["with one line waiting it goes straight away"] = function(assert_eq)
        local core, st, t = live()
        local RET = { "ARR", "R1", "J1", "S1" }
        assert_eq(core.handle(st, "r0", { op = "request", route = RET }, t).ok, true, "a return goes")
        for _, sec in ipairs(RET) do core.handle(st, "r0", { op = "enter", sec = sec }, t); core.handle(st, "r0", { op = "leave", sec = sec }, t) end
        assert_eq(core.handle(st, "r1", { op = "request", route = RET }, t + 1000).ok, true,
            "another return, nobody in the other line: it goes, though a return went last")
    end,

    -- 2026-11-17 (sim w3_side_atc): node_36's support had left the pair; node_36 asked from its dock "waiting for
    -- partner" for 4 h, and as the oldest waiter held back every return whose way crossed its own -- the return line
    -- stopped with no section held. Half a pair cannot go, so it is ahead of nobody until both halves are asking.
    ["half a pair waiting for its partner holds back nobody"] = function(assert_eq)
        local core, st, t = live()
        local RET = { "ARR", "R5", "J5", "R4", "J4", "R3", "J3", "R2", "J2", "R1", "J1", "S1" }
        st.lastLine = "return"                       -- the departures' turn: an older departure would go first
        local d = core.handle(st, "del", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "del", pair = "sup" }, t)
        assert_eq(d.why, "waiting for partner", "the delivery asks alone")
        core.handle(st, "del", { op = "request", route = { "S1", "J1", "W1", "DH" }, group = "del", pair = "sup" }, t + 2000)
        local r = core.handle(st, "r1", { op = "request", route = RET }, t + 3000)
        assert_eq(r.ok, true, "a return whose way crosses the delivery's is let in (" .. tostring(r.why) .. ")")
    end,

    -- 2026-11-17 (T2 w3-pair-dropout-b): node_96, in DH with its support gone home, asked its way home naming its
    -- partner, and the ATC waited for the partner's ask for good. A pair asks from its docks, which are in no section;
    -- a request from inside a section is the turtle's alone, whatever it names.
    ["a request from inside a section is never half of a pair"] = function(assert_eq)
        local core, st, t = live()
        local r = core.handle(st, "del", { op = "request", cur = "DH", route = { "W1", "J1", "S1" }, group = "del", pair = "sup" }, t)
        assert_eq(r.ok, true, "standing in DH, its way home is let in alone (" .. tostring(r.why) .. ")")
    end,

    -- 2026-11-17 (T2 shakeout-side-h, s002): node_215 and node_219 left DH for the tunnel and their ATC_LEAVEs were lost;
    -- DH stayed booked, empty, until the 180 s sweep -- one message sent once, cleared by a timer. A report says where
    -- the turtle stands and what it still needs: a section it entered and is no longer in is left, and a report from
    -- outside the base (out) ends its booking. One with no known position changes nothing.
    ["a report from where a turtle stands lets go of the sections it has left"] = function(assert_eq)
        local core, st, t = live()
        local DEP = { "W1", "DH" }
        assert_eq(core.handle(st, "a", { op = "request", route = DEP }, t).ok, true)
        core.handle(st, "a", { op = "enter", sec = "W1" }, t)
        core.handle(st, "a", { op = "enter", sec = "DH" }, t)
        -- its ATC_LEAVE for W1 is lost; it reports from DH with nothing more ahead
        core.handle(st, "a", { op = "report", cur = "DH", route = { "DH" } }, t + 1000)
        local w1 = core.handle(st, "b", { op = "request", route = { "W1" } }, t + 2000)
        assert_eq(w1.ok, true, "W1, which it left, is free (" .. tostring(w1.why) .. ")")
        local dh = core.handle(st, "c", { op = "request", route = { "DH" } }, t + 3000)
        assert_eq(dh.ok, false, "DH, where it stands, is still its own")
    end,

    ["a report from outside the base ends the booking; one with no known position changes nothing"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "a", { op = "request", route = { "DH" } }, t).ok, true)
        core.handle(st, "a", { op = "enter", sec = "DH" }, t)
        core.handle(st, "a", { op = "report", route = {} }, t + 1000)            -- position unknown
        local still = core.handle(st, "b", { op = "request", route = { "DH" } }, t + 2000)
        core.handle(st, "a", { op = "report", out = true, route = {} }, t + 3000) -- out in the tunnel, its LEAVE lost
        local freed = core.handle(st, "b", { op = "request", route = { "DH" } }, t + 4000)
        assert_eq(still.ok, false, "a report that does not say where it stands lets nothing go")
        assert_eq(freed.ok, true, "out of the base: DH is free (" .. tostring(freed.why) .. ")")
    end,

    -- 2026-11-18 (T2 shakeout-payload-c): docked miner node_453 measured its facing, claiming the section beside its
    -- dock (N4) for the turn; the ATC_LEAVE that let it go was lost, and the one-off claim -- no booking behind it --
    -- was never healed by its reports nor swept (every message it sent kept it alive). 8 bay-4 miners could never
    -- claim N4 to measure theirs, and were decommissioned. A report heals ALL of a turtle's holds, one-off ones too.
    ["a report from outside the base ends a one-off claim too, not only a booking"] = function(assert_eq)
        local core, st, t = live()
        assert_eq(core.handle(st, "a", { op = "enter", sec = "N4" }, t).ok, true, "a turtle on its dock claims N4 for a turn")
        local blocked = core.handle(st, "b", { op = "enter", sec = "N4" }, t + 500).ok
        core.handle(st, "a", { op = "report", out = true, route = {} }, t + 1000)   -- its ATC_LEAVE lost; it says it is out
        local after = core.handle(st, "b", { op = "enter", sec = "N4" }, t + 2000)
        assert_eq(blocked, false, "while claimed, nobody else gets N4")
        assert_eq(after.ok, true, "out: N4 is free (" .. tostring(after.why) .. ")")
    end,

    -- DT, the dispatch tunnel near the base (Head Engineer ruling, 2026-11-24): one party in it at a time. A
    -- departing pair holds it from the dispatch hole until each of them is out of the zone; a turtle walking back
    -- the departures' tunnel waits for it. Its heals are the one-off claims': a report that does not say DT --
    -- a rebooted turtle has forgotten it is in there -- lets it go.
    ["a departure holds the dispatch tunnel; a turtle walking back waits for it"] = function(assert_eq)
        local core, st, t = live()
        local d = core.handle(st, "d", { op = "request", route = { "DH", "DT" } }, t)
        core.handle(st, "d", { op = "enter", sec = "DH" }, t + 100)
        core.handle(st, "d", { op = "enter", sec = "DT" }, t + 200)
        core.handle(st, "d", { op = "leave", sec = "DH" }, t + 300)
        local back = core.handle(st, "r", { op = "request", route = { "DT", "DH" } }, t + 400)
        core.handle(st, "d", { op = "leave", sec = "DT" }, t + 500)                 -- out of the zone
        local after = core.handle(st, "r", { op = "request", route = { "DT", "DH" } }, t + 600)
        assert_eq(d.ok, true, "the departure is let out")
        assert_eq(back.ok, false, "while it is in the tunnel, the turtle walking back is not let in")
        assert_eq(after.ok, true, "out of the zone, the tunnel is free (" .. tostring(after.why) .. ")")
    end,

    -- Sim w3_retrace_head_on: at the foot of the dispatch shaft a departure gives its way out back (atc.finish) one
    -- step before the tunnel; that took DT with it, and the pair walked the tunnel without it. It keeps DT.
    ["a departure done with its way out keeps the dispatch tunnel it has not reached yet"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "d", { op = "request", route = { "W1", "DH", "DT" } }, t)
        core.handle(st, "d", { op = "enter", sec = "W1" }, t + 100)
        core.handle(st, "d", { op = "enter", sec = "DH" }, t + 200)
        core.handle(st, "d", { op = "leave", sec = "W1" }, t + 300)
        core.handle(st, "d", { op = "cancel", cur = "DH", keep = "DT" }, t + 400)   -- at the shaft's foot
        local back = core.handle(st, "r", { op = "request", route = { "DT" } }, t + 500)   -- DT alone: DH is held anyway
        local w1 = core.handle(st, "x", { op = "enter", sec = "W1" }, t + 600)
        local into = core.handle(st, "d", { op = "enter", sec = "DT", cur = "DH" }, t + 700)
        assert_eq(back.ok, false, "the turtle walking back is not let in (" .. tostring(back.why) .. ")")
        assert_eq(w1.ok, true, "what it left behind is free")
        assert_eq(into.ok, true, "and it steps into the tunnel it kept (" .. tostring(into.why) .. ")")
    end,

    ["a report that does not say DT lets go of the dispatch tunnel"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "d", { op = "request", route = { "DH", "DT" } }, t)
        core.handle(st, "d", { op = "enter", sec = "DH" }, t + 100)
        core.handle(st, "d", { op = "enter", sec = "DT" }, t + 200)
        core.handle(st, "d", { op = "leave", sec = "DH" }, t + 300)
        local before = core.handle(st, "r", { op = "request", route = { "DT", "DH" } }, t + 400).ok
        core.handle(st, "d", { op = "report", route = {} }, t + 1000)               -- rebooted out there: it says nothing of DT
        local after = core.handle(st, "r", { op = "request", route = { "DT", "DH" } }, t + 1100)
        assert_eq(before, false, "held while it was in there")
        assert_eq(after.ok, true, "let go on its report (" .. tostring(after.why) .. ")")
    end,

    ["a report from inside the dispatch tunnel keeps it"] = function(assert_eq)
        local core, st, t = live()
        core.handle(st, "d", { op = "request", route = { "DH", "DT" } }, t)
        core.handle(st, "d", { op = "enter", sec = "DH" }, t + 100)
        core.handle(st, "d", { op = "enter", sec = "DT" }, t + 200)
        core.handle(st, "d", { op = "leave", sec = "DH" }, t + 300)
        core.handle(st, "d", { op = "report", cur = "DT", route = { "DT" } }, t + 1000)
        local r = core.handle(st, "r", { op = "request", route = { "DT", "DH" } }, t + 1100)
        assert_eq(r.ok, false, "still held (" .. tostring(r.why) .. ")")
    end,
}
