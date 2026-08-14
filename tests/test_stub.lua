local stub = require("tests.stub_cc")

return {
    ["stub tracks selected slot and inventory"] = function(assert_eq)
        local c = stub.install({ inv = { [1] = { name = "minecraft:coal", count = 5 } } })
        turtle.select(1)
        assert_eq(turtle.getItemCount(1), 5)
        assert_eq(turtle.getItemDetail(1).name, "minecraft:coal")
        assert_eq(c.selected, 1)
    end,

    ["stub models equipped sides"] = function(assert_eq)
        local c = stub.install({
            equipped = { left = "computercraft:wireless_modem_advanced", right = "minecraft:diamond_pickaxe" },
        })
        assert_eq(peripheral.getType("left"), "modem")
        assert_eq(peripheral.getType("right"), nil)
        assert_eq(c.equipped.right, "minecraft:diamond_pickaxe")
        assert_eq(turtle.getEquippedLeft().name, "computercraft:wireless_modem_advanced")
        assert_eq(turtle.getEquippedRight().name, "minecraft:diamond_pickaxe")
    end,

    ["peripheral.find resolves registry names to peripheral type"] = function(assert_eq)
        local c = stub.install({
            equipped = { left = "computercraft:wireless_modem_advanced" },
        })
        assert_eq(peripheral.find("modem") ~= nil, true)
        assert_eq(peripheral.find("chunkController"), nil)
    end,

    ["os.pullEvent drains the queued events in order"] = function(assert_eq)
        stub.install({ events = { { "custom_event", 42 }, { "terminate" } } })
        local name, arg = os.pullEvent()
        assert_eq(name, "custom_event")
        assert_eq(arg, 42)
        local name2 = os.pullEvent()
        assert_eq(name2, "terminate")
    end,

    ["textutils.serialise/unserialise round-trips a plain table"] = function(assert_eq)
        stub.install({})
        local t = { a = 1, b = "hi", c = { 2, 3 }, d = true }
        local round = textutils.unserialise(textutils.serialise(t))
        assert_eq(round.a, 1)
        assert_eq(round.b, "hi")
        assert_eq(round.c[1], 2)
        assert_eq(round.c[2], 3)
        assert_eq(round.d, true)
    end,

    ["dig caps stacks at 64 and overflows into the next slot"] = function(assert_eq)
        local c = stub.install({
            equipped = { right = "minecraft:diamond_pickaxe" },
            world = { ["0,64,-1"] = "minecraft:stone" },
            inv = { [1] = { name = "minecraft:stone", count = 64 } },
        })
        turtle.select(1)
        local ok = turtle.dig()
        assert_eq(ok, true)
        assert_eq(c.inv[1].count, 64)
        assert_eq(c.inv[2].name, "minecraft:stone")
        assert_eq(c.inv[2].count, 1)
    end,

    ["dig merges into any slot with room, not only the selected slot"] = function(assert_eq)
        local c = stub.install({
            equipped = { right = "minecraft:diamond_pickaxe" },
            world = { ["0,64,-1"] = "minecraft:stone" },
            inv = {
                [1] = { name = "minecraft:dirt", count = 1 },
                [3] = { name = "minecraft:stone", count = 2 },
            },
        })
        turtle.select(1)
        turtle.dig()
        assert_eq(c.inv[3].count, 3)
        assert_eq(c.inv[1].count, 1)
        assert_eq(c.inv[2], nil)
    end,

    ["dig fails without destroying the block when inventory is full"] = function(assert_eq)
        local inv = {}
        for s = 1, 16 do
            inv[s] = { name = "minecraft:item" .. s, count = 64 }
        end
        local c = stub.install({
            equipped = { right = "minecraft:diamond_pickaxe" },
            world = { ["0,64,-1"] = "minecraft:stone" },
            inv = inv,
        })
        local ok = turtle.dig()
        assert_eq(ok, false)
        assert_eq(c.world["0,64,-1"], "minecraft:stone")
    end,

    ["transferTo is a no-op when dest equals the selected slot"] = function(assert_eq)
        local c = stub.install({
            inv = { [1] = { name = "minecraft:stone", count = 64 } },
        })
        turtle.select(1)
        local ok = turtle.transferTo(1)
        assert_eq(ok, true)
        assert_eq(c.inv[1].count, 64)
        assert_eq(c.inv[1].name, "minecraft:stone")
    end,

    ["transferTo with n = 0 does not create a phantom slot entry"] = function(assert_eq)
        local c = stub.install({
            inv = { [1] = { name = "minecraft:stone", count = 64 } },
        })
        turtle.select(1)
        local ok = turtle.transferTo(2, 0)
        assert_eq(ok, true)
        assert_eq(c.inv[2], nil)
        assert_eq(c.inv[1].count, 64)
    end,

    ["transferTo clamps n to the source stack's actual count"] = function(assert_eq)
        local c = stub.install({
            inv = { [1] = { name = "minecraft:coal", count = 5 } },
        })
        turtle.select(1)
        local ok = turtle.transferTo(2, 100)
        assert_eq(ok, true)
        assert_eq(c.inv[2].count, 5)
        assert_eq(c.inv[1], nil)
    end,

    ["transferTo clamps a merge at 64 rather than overflowing the stack"] = function(assert_eq)
        local c = stub.install({
            inv = {
                [1] = { name = "minecraft:coal", count = 40 },
                [2] = { name = "minecraft:coal", count = 40 },
            },
        })
        turtle.select(1)
        local ok = turtle.transferTo(2)
        assert_eq(ok, true)
        assert_eq(c.inv[2].count, 64)
        assert_eq(c.inv[1].count, 16)
    end,

    ["transferTo fails when the destination has no room at all"] = function(assert_eq)
        local c = stub.install({
            inv = {
                [1] = { name = "minecraft:coal", count = 5 },
                [2] = { name = "minecraft:coal", count = 64 },
            },
        })
        turtle.select(1)
        local ok = turtle.transferTo(2)
        assert_eq(ok, false)
        assert_eq(c.inv[1].count, 5)
        assert_eq(c.inv[2].count, 64)
    end,

    ["digDown collects the block into inventory, not just clears it"] = function(assert_eq)
        local c = stub.install({
            equipped = { right = "minecraft:diamond_pickaxe" },
            world = { ["0,63,0"] = "minecraft:diamond_ore" },
        })
        local ok = turtle.digDown()
        assert_eq(ok, true)
        assert_eq(c.world["0,63,0"], nil)
        assert_eq(c.inv[1].name, "minecraft:diamond_ore")
        assert_eq(c.inv[1].count, 1)
    end,

    ["digDown fails without destroying the block when inventory is full"] = function(assert_eq)
        local inv = {}
        for s = 1, 16 do
            inv[s] = { name = "minecraft:item" .. s, count = 64 }
        end
        local c = stub.install({
            equipped = { right = "minecraft:diamond_pickaxe" },
            world = { ["0,63,0"] = "minecraft:diamond_ore" },
            inv = inv,
        })
        local ok = turtle.digDown()
        assert_eq(ok, false)
        assert_eq(c.world["0,63,0"], "minecraft:diamond_ore")
    end,

    ["textutils.unserialise returns nil on corrupt input instead of raising"] = function(assert_eq)
        stub.install({})
        local result = textutils.unserialise("{ this is not valid lua")
        assert_eq(result, nil)
    end,

    ["textutils.unserialise matches real CC:Tweaked's load-and-call fidelity"] = function(assert_eq)
        stub.install({})
        -- Not a defect: real CC:Tweaked's unserialise runs load("return "..s)
        -- and calls it, so non-literal-but-valid expressions evaluate too.
        assert_eq(textutils.unserialise("1+1"), 2)
    end,
}
