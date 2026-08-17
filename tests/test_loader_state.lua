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
}
