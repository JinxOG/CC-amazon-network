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
