-- Bay types (shakeout stress test, Task 1): each bay's dock type is a setting.
-- docs/superpowers/specs/2026-11-09-shakeout-stress-test-design.md section 4.
-- Run: lua tests/run.lua tests.test_bay_types
package.path = "./?.lua;" .. package.path

local function load()
    package.loaded["waypoints"] = nil
    return require("waypoints")
end

local TYPES = { "DELIVERY", "SUPPORT", "MINER" }

return {
    ["totals"] = function(assert_eq)
        local W = load()
        assert_eq(W.totalDocks("DELIVERY"), 16, "delivery docks")
        assert_eq(W.totalDocks("SUPPORT"), 16, "support docks")
        assert_eq(W.totalDocks("MINER"), 128, "miner docks")
    end,

    ["miner_docks_span_both_sides"] = function(assert_eq)
        local W = load()
        local south, north = 0, 0
        for _, d in ipairs(W.docks.MINER) do
            if d.z < W.WHITE_Z then south = south + 1 elseif d.z > W.RED_Z then north = north + 1 end
        end
        assert_eq(south, 64, "miner docks in the worker rows")
        assert_eq(north, 64, "miner docks in the support rows")
    end,

    ["dock_type_for"] = function(assert_eq)
        local W = load()
        assert_eq(W.dockTypeFor("DELIVERY"), "DELIVERY", "delivery")
        assert_eq(W.dockTypeFor("SUPPORT"), "SUPPORT", "support")
        assert_eq(W.dockTypeFor("MINER"), "MINER", "miner")
        assert_eq(W.dockTypeFor("LOADER"), nil, "a loader has no dock")
    end,

    ["typed_assignment"] = function(assert_eq)
        -- assignment saves to disk; give it a stub fs for the test, then put back what was there
        local oldfs = _G.fs
        _G.fs = { open = function() return nil end, exists = function() return false end }
        local W = load()
        local d = W.assignDock("MINER", "m1")
        assert_eq(d ~= nil and d.role, "MINER", "dock is a miner dock")
        assert_eq(W.getDockFor("MINER", "m1"), d, "found again by type")
        assert_eq(W.getDockFor("DELIVERY", "m1"), nil, "not a delivery dock")
        assert_eq(W.freeDocks("MINER"), 127, "one miner dock used")
        assert_eq(W.freeDocks("DELIVERY"), 16, "delivery untouched")
        W.releaseDock("MINER", "m1")
        assert_eq(W.freeDocks("MINER"), 128, "released")
        _G.fs = oldfs
    end,

    ["routes_are_single_axis"] = function(assert_eq)
        local W = load()
        local bad, n = "", 0
        for _, t in ipairs(TYPES) do
            for _, d in ipairs(W.docks[t]) do
                local fns = { { "dep", W.departureRoute(d), d }, { "sup", W.supportDepartureRoute(d), d },
                              { "ret", W.returnRoute(d), d } }
                for _, f in ipairs(fns) do
                    local px, pz = d.x, d.z
                    for i, wp in ipairs(f[2]) do
                        -- the first leg of a departure starts at the dock; returns end at it
                        if not (f[1] == "ret" and i == 1) then
                            local dxm, dzm = wp.x ~= px, wp.z ~= pz
                            n = n + 1
                            if dxm and dzm then bad = bad .. f[1] .. " " .. d.x .. "," .. d.z .. " leg " .. i .. "; " end
                        end
                        px, pz = wp.x, wp.z
                    end
                end
            end
        end
        assert_eq(n > 1000, true, "legs checked (" .. n .. ")")
        assert_eq(bad, "", "legs that change both x and z")
    end,

    ["routes_avoid_dock_cells"] = function(assert_eq)
        local W = load()
        local isDock = {}
        for _, t in ipairs(TYPES) do
            for _, d in ipairs(W.docks[t]) do isDock[d.x .. "," .. d.z] = true end
        end
        local bad, n = "", 0
        for _, t in ipairs(TYPES) do
            for _, d in ipairs(W.docks[t]) do
                for _, name in ipairs({ "departureRoute", "supportDepartureRoute", "returnRoute" }) do
                    local route = W[name](d)
                    local x, z = d.x, d.z
                    -- a return begins out on the taxiway: start at its first waypoint
                    if name == "returnRoute" then x, z = route[1].x, route[1].z end
                    for _, wp in ipairs(route) do
                        while x ~= wp.x or z ~= wp.z do
                            if x ~= wp.x then x = x + (wp.x > x and 1 or -1) else z = z + (wp.z > z and 1 or -1) end
                            n = n + 1
                            if isDock[x .. "," .. z] and not (x == d.x and z == d.z) then
                                bad = bad .. name .. " " .. d.x .. "," .. d.z .. " via " .. x .. "," .. z .. "; "
                            end
                        end
                    end
                end
            end
        end
        assert_eq(n > 10000, true, "cells walked (" .. n .. ")")
        assert_eq(bad, "", "routes through another dock's cell")
    end,
}
