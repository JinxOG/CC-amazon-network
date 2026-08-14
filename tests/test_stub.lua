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
}
