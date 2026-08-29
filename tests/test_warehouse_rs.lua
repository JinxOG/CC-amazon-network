-- warehouse.lua's Refined Storage call path.
--
-- Every rsBridge call was unprotected until 2026-08-28. AdvancedPeripherals
-- 0.7.44r threw NoClassDefFoundError from ItemFilter.parse on every importItem
-- between 26 June and 28 August; that error left clearEnderChest, left main, and
-- ended the program, so the warehouse stayed dead until a human noticed
-- deliveries had stopped. The mod bug is fixed upstream. These cover the
-- exposure it revealed, which is not specific to importItem -- an unloaded RS
-- network or the next mod regression arrives exactly the same way.
--
-- The property under test throughout: a throwing peripheral must degrade the
-- call, never the program.

package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

-- rsBridge stand-in. `throwOn` names a method that raises, reproducing the mod
-- bug; everything else answers normally.
local function fakeRS(throwOn)
    local calls = {}
    local function guard(name, ret)
        return function(...)
            calls[#calls + 1] = name
            if throwOn == name then error("java.lang.NoClassDefFoundError: TableHelper", 0) end
            return ret
        end
    end
    return {
        _calls     = calls,
        importItem = guard("importItem", 3),
        exportItem = guard("exportItem", 5),
        getItem    = guard("getItem", { amount = 64 }),
    }
end

-- A chest that keeps whatever it holds. When an import fails the items really do
-- stay put, so a chest that empties itself anyway would hide the failure this
-- test exists to reproduce -- clearEnderChest would return early instead of
-- exhausting its retries and warning.
local function fakeChest(contents)
    return { list = function() return contents end }
end

local function fresh(rs, chest)
    stub.install({})
    -- The harness has no global sleep; only test_control_loop installs one.
    -- clearEnderChest's retry pacing needs it, and a no-op is right here: the
    -- point is the retry behaviour, not the delay.
    sleep = function() end
    peripheral = peripheral or {}
    peripheral.find    = function(n)
        if n == "rsBridge" then return rs end
        if n == "modem" then return { open = function() end, transmit = function() end } end
        return nil
    end
    peripheral.wrap    = function() return chest end
    peripheral.getType = function() return "minecraft:chest" end
    peripheral.getName = function() return "rsBridge_0" end
    _G.__CC_WAREHOUSE_TEST = true
    package.loaded["warehouse"] = nil
    package.loaded["protocol"]  = nil
    local W = require("warehouse")
    _G.__CC_WAREHOUSE_TEST = nil
    package.loaded["warehouse"] = nil
    return W
end

return {
    ["a throwing rsBridge call returns nil and an error, and does not raise"] = function(assert_eq)
        local W = fresh(fakeRS("importItem"), fakeChest({}))
        local ok, res, err = pcall(W.rsCall, "importItem", { name = "x", count = 1 }, "top")
        assert_eq(ok, true,
            "rsCall must absorb the throw -- unprotected, this ended the whole program")
        assert_eq(res, nil)
        assert_eq(type(err), "string")
    end,

    ["a healthy call passes its result through"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        assert_eq(W.rsCall("exportItem", { name = "x", count = 5 }, "top"), 5)
        assert_eq(W.rsCall("getItem", { name = "x" }).amount, 64)
    end,

    -- pcall would catch a nil method on its own, so the guard's only value is the
    -- message: "rsBridge has no method 'x'" instead of "attempt to call a nil
    -- value". That distinction is the whole point, so it is what gets asserted --
    -- checking only for "some string" passes with the guard deleted.
    ["an unknown method names itself rather than reporting a nil call"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        local res, err = W.rsCall("noSuchMethod", {})
        assert_eq(res, nil)
        assert_eq(type(err) == "string" and err:find("noSuchMethod", 1, true) ~= nil, true,
            "the error must name the method that was missing")
    end,

    -- The exact shape of the live bug: a chest with items, an import that throws.
    ["clearEnderChest survives an import that throws every time"] = function(assert_eq)
        local rs = fakeRS("importItem")
        local W  = fresh(rs, fakeChest({ [1] = { name = "minecraft:stone", count = 8 } }))
        local ok, total = pcall(W.clearEnderChest)
        assert_eq(ok, true,
            "a failing import must not take the warehouse down with it")
        assert_eq(total, 0, "and nothing may be counted as moved when nothing moved")
    end,

    ["checkStock reports empty rather than crashing when getItem throws"] = function(assert_eq)
        local W = fresh(fakeRS("getItem"), fakeChest({}))
        local ok, inStock, have = pcall(W.checkStock, "minecraft:iron_ingot", 10)
        assert_eq(ok, true)
        assert_eq(inStock, false, "an unreadable stock level is a shortfall, not a pass")
        assert_eq(have, 0)
    end,

    ["loadChests reports zero when the export throws"] = function(assert_eq)
        local W = fresh(fakeRS("exportItem"), fakeChest({}))
        local ok, moved = pcall(W.loadChests, 4)
        assert_eq(ok, true)
        assert_eq(moved, 0,
            "zero loaded is what makes the caller abort the job -- a raise would "
            .. "have skipped that decision entirely")
    end,
}
