-- loader_state persists the "we have a physical loader out there" fact across
-- a simulated reboot, and tolerates a corrupt state file without erroring.
local stub = require("tests.stub_cc")

-- loader_state.record() stamps placedAt with os.epoch("utc"). stub_cc does not
-- model the real-time clock (only turtle/peripheral/os.pullEvent/textutils),
-- so provide the same fallback tests/test_bypass_geofence.lua uses for the
-- same gap.
os.epoch = os.epoch or function() return os.time() * 1000 end

local function fresh()
    stub.install({})
    package.loaded["loader_state"] = nil
    local ls = require("loader_state")
    ls.clear()
    return ls
end

return {
    ["no loader recorded on a clean start"] = function(assert_eq)
        local ls = fresh()
        assert_eq(ls.hasPlaced(), false)
        assert_eq(ls.get(), nil)
    end,

    ["record survives a simulated reboot"] = function(assert_eq)
        local ls = fresh()
        ls.record(100, 64, -200, { sx = 96, sz = -208 }, 24)
        package.loaded["loader_state"] = nil          -- simulate reboot
        local ls2 = require("loader_state")
        assert_eq(ls2.hasPlaced(), true)
        local s = ls2.get()
        assert_eq(s.x, 100); assert_eq(s.y, 64); assert_eq(s.z, -200)
        assert_eq(s.sector.sx, 96); assert_eq(s.radius, 24)
    end,

    ["clear removes the record"] = function(assert_eq)
        local ls = fresh()
        ls.record(1, 2, 3, { sx = 0, sz = 0 }, 24)
        ls.clear()
        assert_eq(ls.hasPlaced(), false)
    end,

    ["clear persists across a simulated reboot, not just in memory"] = function(assert_eq)
        -- Pins the on-disk half of clear(): if clear() only reset the
        -- in-memory cache and forgot fs.delete, hasPlaced() would still
        -- report true after a reboot re-reads the (never-deleted) file.
        local ls = fresh()
        ls.record(5, 6, 7, { sx = 0, sz = 0 }, 24)
        ls.clear()
        package.loaded["loader_state"] = nil           -- simulate reboot
        local ls2 = require("loader_state")
        assert_eq(ls2.hasPlaced(), false)
        assert_eq(ls2.get(), nil)
    end,

    ["record survives a reboot with a falsy-but-valid coordinate"] = function(assert_eq)
        -- Guards the data.x ~= nil check in loader_state.load(): x = 0 is a
        -- legitimate world coordinate. An implementation that tested
        -- `data.x` for truthiness alone would happen to pass here too (0 is
        -- truthy in Lua), but a stricter `~= nil` check is what's intended
        -- and this pins that the field survives the round trip at all.
        local ls = fresh()
        ls.record(0, 64, 0, { sx = 0, sz = 0 }, 24)
        package.loaded["loader_state"] = nil
        local ls2 = require("loader_state")
        assert_eq(ls2.hasPlaced(), true)
        assert_eq(ls2.get().x, 0)
    end,

    ["a record that cannot be written fails closed instead of raising"] = function(assert_eq)
        -- A full disk makes fs.open return nil. record() ran f.write on that
        -- nil, which raised from inside mine_flow.placeLoader. Now it reports
        -- the failure so placeLoader can refuse to place -- with the loader
        -- still in inventory, which is the recoverable direction. It must also
        -- not claim in memory to have a placement it never persisted.
        local ls = fresh()
        local realOpen = fs.open
        fs.open = function(path, mode)
            if mode == "w" then return nil end
            return realOpen(path, mode)
        end
        local ok, wrote, reason = pcall(ls.record, 10, 64, 20, { sx = 0, sz = 0 }, 24)
        fs.open = realOpen
        assert_eq(ok, true, "record must not raise on a full disk: " .. tostring(wrote))
        assert_eq(wrote, false, "record must report the write failure")
        assert_eq(reason, "loader_state_write_failed")
        assert_eq(ls.hasPlaced(), false,
            "an unpersisted record must not be reported as a placement")
    end,

    ["placeLoader refuses to place a loader it could not record"] = function(assert_eq)
        -- The half that matters: record()'s return value must actually gate
        -- the placement, or the fix is a no-op at the only call site.
        local eq = require("equipment")
        local c = stub.install({
            equipped = { left = eq.ITEMS.MODEM, right = eq.ITEMS.CHUNKY },
            inv      = { [1]  = { name = eq.ITEMS.SCANNER,       count = 1 },
                         [2]  = { name = eq.ITEMS.LOADER_TURTLE, count = 1 },
                         [3]  = { name = eq.ITEMS.PICKAXE,       count = 1 },
                         [15] = { name = "enderstorage:ender_chest", count = 1 },
                         [16] = { name = "enderstorage:ender_chest", count = 1 } },
            pos      = { x = 0, y = 80, z = 0, facing = 2 },
            world    = {},
        })
        for _, m in ipairs({ "loader_state", "mine_flow", "geofence" }) do
            package.loaded[m] = nil
        end
        local flow = require("mine_flow")
        local gf   = require("geofence")
        flow.setHooks({
            reportPhase = function() end,
            log         = function() end,
            pos         = function() return { x = 0, y = 80, z = 0, facing = 2 } end,
            pump        = function() end,
        })

        local realOpen = fs.open
        fs.open = function(path, mode)
            if mode == "w" then return nil end
            return realOpen(path, mode)
        end
        local ok, reason = flow.placeLoader(2, { cx = 0, cz = 0 })
        fs.open = realOpen

        assert_eq(ok, false, "placement must be refused when the record failed")
        assert_eq(reason, "loader_state_write_failed")
        assert_eq(c.inv[2] ~= nil, true, "the loader must still be in inventory")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must not be surrendered")
        assert_eq(gf.isActive(), false, "no fence may be armed")
    end,

    ["corrupt state file is treated as no loader, not a crash"] = function(assert_eq)
        local ls = fresh()
        local f = fs.open("loader_state.dat", "w")
        f.write("{ this is not valid lua")
        f.close()
        package.loaded["loader_state"] = nil
        local ls2 = require("loader_state")
        assert_eq(ls2.hasPlaced(), false,
            "a corrupt file must not brick the miner on boot")
    end,
    -- The label is what later proves a CARRIED turtle is the one we placed.
    -- Every advanced turtle shares one item id, so without it a dug-up miner in
    -- the pack looks exactly like our own returned loader (see
    -- clearStaleLoaderRecord). An in-world probe on 2026-08-22 established that
    -- a label replaces the upgrade-derived displayName, survives place->break on
    -- the item, and is readable from Lua.
    ["the record carries the loader's label, and survives a reload"] = function(assert_eq)
        local ls = require("loader_state")
        assert_eq(ls.record(10, 70, -20, { sx = 0, sz = 0 }, 1, "loader_196"), true)
        assert_eq(ls.get().label, "loader_196")
        package.loaded["loader_state"] = nil
        local ls2 = require("loader_state")
        assert_eq(ls2.get().label, "loader_196", "the label must survive a reboot")
    end,

    ["a record written without a label simply has none"] = function(assert_eq)
        local ls = require("loader_state")
        assert_eq(ls.record(1, 2, 3, { sx = 0, sz = 0 }, 1), true)
        assert_eq(ls.get().label, nil,
            "older records predate the label and must stay readable")
    end,

    -- CORRECTING A POSITION MUST NOT FORGET WHAT THE LOADER IS.
    --
    -- Boot recovery believes the loader's own beacon over the record when they
    -- disagree (1-block mismatches are real: node_182, 10-06,
    -- "ahead=1767 recorded=1768"). That path used to re-record with record(),
    -- which takes the label as its last argument, and passed none -- so the
    -- label was dropped by the one path that only runs during reboot recovery,
    -- which is the exact case the label exists for. Found by W3, 10-08.
    --
    -- A dedicated correction keeps that from being possible: there is no
    -- argument to forget.
    ["correcting the position keeps the label, sector and radius"] = function(assert_eq)
        local ls = require("loader_state")
        assert_eq(ls.record(100, 70, -200, { cx = 6, cz = -13 }, 1, "loader_196"), true)
        assert_eq(ls.correctPosition(101, 70, -200), true)
        local r = ls.get()
        assert_eq(r.x, 101, "the position is corrected")
        assert_eq(r.y, 70); assert_eq(r.z, -200)
        assert_eq(r.label, "loader_196", "the label MUST survive the correction")
        assert_eq(r.radius, 1, "and so must the radius")
        assert_eq(r.sector and r.sector.cx, 6, "and the sector")
    end,

    ["correcting the position survives a reload"] = function(assert_eq)
        local ls = require("loader_state")
        assert_eq(ls.record(1, 2, 3, { cx = 0, cz = 0 }, 1, "loader_203"), true)
        assert_eq(ls.correctPosition(4, 5, 6), true)
        package.loaded["loader_state"] = nil
        local ls2 = require("loader_state")
        local r = ls2.get()
        assert_eq(r.x, 4); assert_eq(r.label, "loader_203")
    end,

    ["correcting with nothing recorded is refused, not invented"] = function(assert_eq)
        local ls = require("loader_state")
        ls.clear()
        local ok, why = ls.correctPosition(1, 2, 3)
        assert_eq(ok, false, "there is no loader to correct")
        assert_eq(why, "no_loader_recorded")
        assert_eq(ls.hasPlaced(), false, "and nothing may be created by trying")
    end,

}
