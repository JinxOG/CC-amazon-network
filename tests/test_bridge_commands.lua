-- The duplicate key of a bridge command (W3, 2026-11-13; SPEC-OWNER's ruling of 2026-11-12, fix 3). The real path,
-- two HOLD_TURTLE in one millisecond through the stand-in bridge, is sandbox/scenarios/w3_dup_commands.lua; these pin
-- the key itself.
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

local function freshServer()
    stub.install({})
    local savedEpoch, savedPeripheral = os.epoch, peripheral
    os.epoch = function() return 1000000 end
    peripheral = { find = function() return nil end }
    package.loaded["cloudstore"] = nil
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"] = nil
    local server = require("central_server")
    return server, function()
        os.epoch, peripheral = savedEpoch, savedPeripheral
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
        package.loaded["cloudstore"] = nil
    end
end

return {
    ["two commands of one type in one millisecond for different turtles have different keys"] = function(assert_eq)
        local server, restore = freshServer()
        local a = server.cmdKey({ type = "HOLD_TURTLE", ts = 1794540000123, params = { turtleId = "node_11", reason = "r" } })
        local b = server.cmdKey({ type = "HOLD_TURTLE", ts = 1794540000123, params = { turtleId = "node_31", reason = "r" } })
        restore()
        assert_eq(a ~= b, true, "different turtles, different commands: " .. a .. " vs " .. b)
    end,

    ["a true copy has the same key, whatever order its parameters come back in"] = function(assert_eq)
        local server, restore = freshServer()
        local p1 = { turtleId = "node_32", reason = "twice", nested = { x = 1, z = -2 } }
        local p2 = {}
        local keys = { "nested", "reason", "turtleId" }
        for i = #keys, 1, -1 do p2[keys[i]] = p1[keys[i]] end
        local a = server.cmdKey({ type = "HOLD_TURTLE", ts = 5, params = p1 })
        local b = server.cmdKey({ type = "HOLD_TURTLE", ts = 5, params = p2 })
        local later = server.cmdKey({ type = "HOLD_TURTLE", ts = 6, params = p1 })
        restore()
        assert_eq(a, b, "the same command, decoded twice")
        assert_eq(a ~= later, true, "the same command a millisecond later is a new command")
        assert_eq(a:match("^(%d+)"), "5", "the key starts with the time, which the 60 s prune reads")
    end,
}
