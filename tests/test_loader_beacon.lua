-- Task 5c: loader beacon.
--
-- Coverage note (see task-5c-report.md for the full explanation): this file
-- covers only protocol.lua, which is the one loader-beacon piece that is
-- actually unit-testable under this harness.
--
--   * central_server.lua's LOADER_BEACON handler and the "dispatcher can
--     never pick a LOADER" guarantee are verified by inspection, not by a
--     test here. central_server.lua is a self-running top-level script (its
--     last statement is `while true do pcall(server.run) end`, executed
--     unconditionally at load time) with no `return server` -- requiring it
--     under plain Lua immediately drives into that loop and crashes on the
--     first missing CC API (confirmed empirically: `No modem found` from
--     server.run(), then `attempt to call a nil value (global 'sleep')` from
--     the reboot path). Restructuring that would be more than the "add
--     handlers" scope this task is limited to for central_server.lua.
--   * loader_turtle.lua is a top-level script with an infinite loop and is
--     not unit-testable either, per the task brief.
--   * mine_flow.lua (beaconSeenWithin, placeLoader's beacon gate) and the
--     miner's beacon-lost path in ore_turtle.lua do not exist yet -- they are
--     built in a later task and wired to this beacon then.
--
-- What *is* tested here: the role/message-type constants exist with the
-- exact values other modules will match on, the payload builder shapes the
-- beacon payload correctly (including the no-GPS and no-deployer-yet cases),
-- and an encoded LOADER_BEACON message round-trips through proto.decode
-- instead of being rejected as an unknown type.

package.path = "./?.lua;" .. package.path

local function fresh()
    package.loaded["protocol"] = nil
    return require("protocol")
end

return {

    ["ROLE.LOADER exists with the exact value central_server matches on"] = function(assert_eq)
        local proto = fresh()
        assert_eq(proto.ROLE.LOADER, "LOADER")
    end,

    ["MSG.LOADER_BEACON exists with the exact value used on the wire"] = function(assert_eq)
        local proto = fresh()
        assert_eq(proto.MSG.LOADER_BEACON, "LOADER_BEACON")
    end,

    ["payloadLoaderBeacon carries position, deployedBy and a fresh timestamp"] = function(assert_eq)
        local proto = fresh()
        os.epoch = os.epoch or function() return os.time() * 1000 end
        local pos = { x = 96, y = 60, z = -208 }
        local p = proto.payloadLoaderBeacon(pos, "miner_7")
        assert_eq(p.position.x, 96)
        assert_eq(p.position.y, 60)
        assert_eq(p.position.z, -208)
        assert_eq(p.deployedBy, "miner_7")
        if type(p.ts) ~= "number" then
            error("payloadLoaderBeacon: ts must be a number, got " .. type(p.ts))
        end
    end,

    ["payloadLoaderBeacon tolerates no GPS fix (nil position)"] = function(assert_eq)
        -- The loader's position() helper returns nil when gps.locate() times
        -- out; the beacon must still go out rather than erroring, since a
        -- position-less beacon is still proof of life.
        local proto = fresh()
        os.epoch = os.epoch or function() return os.time() * 1000 end
        local p = proto.payloadLoaderBeacon(nil, "miner_7")
        assert_eq(p.position, nil)
        assert_eq(p.deployedBy, "miner_7")
    end,

    ["payloadLoaderBeacon tolerates no known deployer yet"] = function(assert_eq)
        -- Task 5c does not implement the server-side deployer join (that's a
        -- later task); loader_turtle.lua always passes deployedBy = nil today.
        local proto = fresh()
        os.epoch = os.epoch or function() return os.time() * 1000 end
        local p = proto.payloadLoaderBeacon({ x = 0, y = 60, z = 0 }, nil)
        assert_eq(p.deployedBy, nil)
    end,

    ["an encoded LOADER_BEACON message round-trips through decode"] = function(assert_eq)
        -- proto.decode() rejects any msg.type not present in proto.MSG as
        -- "unknown message type" -- this pins that LOADER_BEACON was actually
        -- added to that table, not just given a builder function.
        local proto = fresh()
        os.epoch = os.epoch or function() return os.time() * 1000 end
        local payload = proto.payloadLoaderBeacon({ x = 1, y = 2, z = 3 }, nil)
        local msg = proto.encode(proto.MSG.LOADER_BEACON, "loader_1", "server", payload)
        local ok, decoded = proto.decode(msg)
        assert_eq(ok, true)
        assert_eq(decoded.type, "LOADER_BEACON")
        assert_eq(decoded.payload.position.x, 1)
    end,

}
