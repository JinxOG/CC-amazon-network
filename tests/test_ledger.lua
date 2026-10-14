-- The placed-item ledger (recovery layer release 2, ruled 2026-10-08).
--
-- Whatever a turtle places in the world and means to take back -- the fuel
-- chest first, every role uses one -- is recorded BEFORE the place, cleared
-- only once it is back in its home slot, and recovered at boot. node_181 lost
-- its ore chest to a reboot mid-dump on 2026-10-08 because nothing on disk said
-- it was out there; the fuel chest has the same exposure in every role.
package.path = "./?.lua;" .. package.path
local stub = require("tests.stub_cc")
os.epoch = os.epoch or function() return os.time() * 1000 end

local MODS = { "turtle_base", "logship", "geofence" }
local function reload()
    for _, m in ipairs(MODS) do package.loaded[m] = nil end
    return require("turtle_base")
end
local function fresh(opts)
    local c = stub.install(opts or {})
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    return reload(), c
end
local E = { x = 10, y = 63, z = 0, face = "down", turtleAt = { x = 10, y = 64, z = 0 } }

return {
    ["nothing recorded on a clean start"] = function(assert_eq)
        local base = fresh()
        assert_eq(base.ledger.get("fuel_chest"), nil)
        assert_eq(next(base.ledger.all()), nil)
    end,

    ["a record survives a reboot"] = function(assert_eq)
        local base = fresh()
        assert_eq(base.ledger.record("fuel_chest", E), true)
        local base2 = reload()
        local r = base2.ledger.get("fuel_chest")
        assert_eq(r and r.x, 10)
        assert_eq(r and r.face, "down")
        assert_eq(r and r.turtleAt.y, 64)
        assert_eq(r and r.placedAt ~= nil, true, "stamped with when it went down")
        assert_eq(base2.ledger.all().fuel_chest ~= nil, true, "and listed after the reboot")
    end,

    ["two kinds out at once are kept separately"] = function(assert_eq)
        local base = fresh()
        base.ledger.record("fuel_chest", E)
        base.ledger.record("ore_chest", { x = 11, y = 64, z = 0, face = "forward", facing = 1,
                                          turtleAt = { x = 10, y = 64, z = 0 } })
        base.ledger.clear("fuel_chest")
        local ore = base.ledger.get("ore_chest")
        assert_eq(base.ledger.get("fuel_chest"), nil)
        assert_eq(ore and ore.x, 11, "clearing one never touches the other")
    end,

    ["a rollback leaves no record"] = function(assert_eq)
        local base = fresh()
        base.ledger.record("fuel_chest", E)
        base.ledger.rollback("fuel_chest")
        assert_eq(base.ledger.get("fuel_chest"), nil)
        assert_eq(reload().ledger.get("fuel_chest"), nil, "not on disk either")
    end,

    ["an unwritable disk is reported, never assumed"] = function(assert_eq)
        local base = fresh()
        local open = fs.open
        fs.open = function(p, m) if m == "w" then return nil end return open(p, m) end
        local ok, why = base.ledger.record("fuel_chest", E)
        fs.open = open
        assert_eq(ok, false)
        assert_eq(why, "ledger_write_failed")
        assert_eq(base.ledger.get("fuel_chest"), nil, "no claim in memory either")
    end,

    ["a truncated file reads as no record and boots"] = function(assert_eq)
        fresh()
        local f = fs.open("ledger_fuel_chest.dat", "w"); f.write("{ x = 10, y ="); f.close()
        local base2 = reload()
        assert_eq(base2.ledger.get("fuel_chest"), nil)
        assert_eq(next(base2.ledger.all()), nil, "and all() skips it too")
    end,
}
