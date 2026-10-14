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

local EC   = "enderstorage:ender_chest"
local PICK = "minecraft:diamond_pickaxe"
local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- A turtle standing at 10,64,0 with the chest recorded at `entry`, already
-- placed in the world. Returns base, c, and the radio messages it sends.
local function standing(entry, opts)
    opts = opts or {}
    local world = opts.world or {}
    if not opts.noChest then world[key(entry.x, entry.y, entry.z)] = EC end
    local base, c = fresh({ pos = { x = 10, y = 64, z = 0, facing = opts.facing or 0 },
                            equipped = opts.equipped or { left = PICK },
                            world = world, inv = opts.inv })
    local sent = {}
    peripheral.find = function()
        return { transmit = function(ch, r, body) sent[#sent + 1] = tostring(body) end,
                 open = function() end, isOpen = function() return true end, close = function() end }
    end
    base.recoverModem()
    base.ledger.registerKind("fuel_chest", { blockName = EC, homeSlot = 16 })
    base.ledger.record("fuel_chest", entry)
    return base, c, sent
end
local function said(sent, text)
    for _, b in ipairs(sent) do if b:find(text, 1, true) then return true end end
    return false
end

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

    -- Recovery (task 2) ------------------------------------------------------

    ["a chest below is dug back into its home slot and the record cleared"] =
    function(assert_eq)
        local base, c = standing(E)
        local ok = base.ledger.recover("fuel_chest")
        assert_eq(ok, true)
        assert_eq(c.inv[16] and c.inv[16].name, EC, "home in slot 16")
        assert_eq(c.world[key(10, 63, 0)], nil, "gone from the world")
        assert_eq(base.ledger.get("fuel_chest"), nil, "and the record cleared")
    end,

    ["a chest in front is dug after turning to the recorded facing"] =
    function(assert_eq)
        local F = { x = 11, y = 64, z = 0, face = "forward", facing = 1, turtleAt = { x = 10, y = 64, z = 0 } }
        local base, c = standing(F, { facing = 3 })
        local ok = base.ledger.recover("fuel_chest")
        assert_eq(ok, true)
        assert_eq(c.pos.facing, 1, "turned to face where it was placed")
        assert_eq(c.world[key(11, 64, 0)], nil, "and dug that block")
        assert_eq(c.inv[16] and c.inv[16].name, EC)
    end,

    ["a different block where the chest was is never dug"] =
    function(assert_eq)
        local base, c, sent = standing(E, { noChest = true, world = { [key(10, 63, 0)] = "minecraft:stone" } })
        local ok = base.ledger.recover("fuel_chest")
        assert_eq(ok, false)
        assert_eq(c.world[key(10, 63, 0)], "minecraft:stone", "not ours, not dug")
        assert_eq(base.ledger.get("fuel_chest") ~= nil, true, "the record is the only evidence: kept")
        assert_eq(said(sent, "needs_hands: fuel_chest at 10,63,0"), true, "and someone is told where")
    end,

    ["a turtle not where it stood is not trusted"] =
    function(assert_eq)
        local away = { x = 10, y = 63, z = 0, face = "down", turtleAt = { x = 40, y = 64, z = 0 } }
        local base, c, sent = standing(away)
        local ok = base.ledger.recover("fuel_chest")
        assert_eq(ok, false)
        assert_eq(c.world[key(10, 63, 0)], EC, "nothing dug from the wrong place")
        assert_eq(base.ledger.get("fuel_chest") ~= nil, true)
        assert_eq(said(sent, "needs_hands: fuel_chest at 10,63,0"), true)
    end,

    ["a full pack is never emptied onto the ground"] =
    function(assert_eq)
        local inv = {}
        for s = 1, 16 do inv[s] = { name = "minecraft:cobblestone", count = 64 } end
        local base, c, sent = standing(E, { inv = inv })
        local ok = base.ledger.recover("fuel_chest")
        local total = 0
        for s = 1, 16 do total = total + (c.inv[s] and c.inv[s].count or 0) end
        assert_eq(ok, false)
        assert_eq(total, 16 * 64, "nothing dropped to make room")
        assert_eq(c.world[key(10, 63, 0)], EC, "and the chest left where it is")
        assert_eq(base.ledger.get("fuel_chest") ~= nil, true)
        assert_eq(said(sent, "needs_hands: fuel_chest"), true)
    end,

    ["a stowed pickaxe is borrowed"] =
    function(assert_eq)
        local base, c = standing(E, { equipped = { left = "computercraft:wireless_modem_advanced",
                                                   right = "advancedperipherals:chunk_controller" } })
        local borrowed = 0
        base.setDigToolWrapper(function(what, fn)
            borrowed = borrowed + 1
            local saved = c.equipped.left
            c.equipped.left = PICK
            local ok, err = pcall(fn)
            c.equipped.left = saved
            if not ok then error(err, 0) end
            return true
        end)
        local ok = base.ledger.recover("fuel_chest")
        base.setDigToolWrapper(nil)
        assert_eq(ok, true)
        assert_eq(borrowed, 1)
        assert_eq(c.world[key(10, 63, 0)], nil)
    end,

    ["forward recovery waits for a measured facing"] =
    function(assert_eq)
        local F = { x = 11, y = 64, z = 0, face = "forward", facing = 1, turtleAt = { x = 10, y = 64, z = 0 } }
        local base, c, sent = standing(F, { facing = 1, world = {
            [key(9, 64, 0)] = "minecraft:stone", [key(10, 64, 1)] = "minecraft:stone",
            [key(10, 64, -1)] = "minecraft:stone" } })
        base.setCanDig(false)
        local naps, chestAtFirstReport = 0, nil
        local savedSleep = sleep
        sleep = function()
            naps = naps + 1
            if naps == 1 then chestAtFirstReport = c.world[key(11, 64, 0)] end
            if naps == 2 then c.world[key(9, 64, 0)] = nil end      -- someone digs it a hole
        end
        local ok = base.ledger.recover("fuel_chest")
        sleep = savedSleep
        assert_eq(said(sent, "stuck_no_fix"), true, "it waited, and said so")
        assert_eq(chestAtFirstReport, EC, "nothing dug while the facing was unknown")
        assert_eq(ok, true, "and recovered once it could measure")
        assert_eq(c.world[key(11, 64, 0)], nil)
    end,

    -- The fuel chest is entry one (task 3) ----------------------------------

    ["a refuel records the fuel chest before placing it"] = function(assert_eq)
        local base, c = fresh({ pos = { x = 10, y = 64, z = 0, facing = 0 }, realFuel = true, fuel = 600,
                                equipped = { left = PICK }, inv = { [16] = { name = EC, count = 1 } },
                                containers = { [EC] = { { name = "minecraft:coal", count = 64 } } } })
        base.gpsSync()                                         -- as every turtle has before it refuels
        local atPlace
        local place = turtle.placeDown
        turtle.placeDown = function(...) atPlace = base.ledger.get("fuel_chest"); return place(...) end
        base.fuel.refuelFromChest()
        turtle.placeDown = place
        assert_eq(atPlace ~= nil, true, "on disk before the chest went down")
        assert_eq(atPlace and atPlace.face, "down")
        assert_eq(atPlace and (atPlace.x .. "," .. atPlace.y .. "," .. atPlace.z), "10,63,0", "the block, not the turtle")
        assert_eq(atPlace and atPlace.turtleAt.y, 64)
    end,

    ["a placement that fails leaves no record"] = function(assert_eq)
        local base = fresh({ pos = { x = 10, y = 64, z = 0, facing = 0 }, realFuel = true, fuel = 600,
                             equipped = { left = PICK }, inv = { [16] = { name = EC, count = 1 } } })
        local place = turtle.placeDown
        turtle.placeDown = function() return false end
        local ok = base.fuel.refuelFromChest()
        turtle.placeDown = place
        assert_eq(ok, false)
        assert_eq(base.ledger.get("fuel_chest"), nil, "nothing went down, so nothing is recorded")
    end,

    ["a finished refuel leaves no record"] = function(assert_eq)
        local base, c = fresh({ pos = { x = 10, y = 64, z = 0, facing = 0 }, realFuel = true, fuel = 600,
                                equipped = { left = PICK }, inv = { [16] = { name = EC, count = 1 } },
                                containers = { [EC] = { { name = "minecraft:coal", count = 64 } } } })
        base.fuel.refuelFromChest()
        assert_eq(c.inv[16] and c.inv[16].name, EC, "the chest is home")
        assert_eq(base.ledger.get("fuel_chest"), nil, "and the record cleared")
    end,

    ["a reboot mid-refuel leaves the record for boot"] = function(assert_eq)
        local base, c = fresh({ pos = { x = 10, y = 64, z = 0, facing = 0 }, realFuel = true, fuel = 600,
                                equipped = { left = PICK }, inv = { [16] = { name = EC, count = 1 } },
                                containers = { [EC] = { { name = "minecraft:coal", count = 64 } } } })
        local dig = turtle.digDown
        turtle.digDown = function() return false end          -- the reboot lands here
        base.fuel.refuelFromChest()
        turtle.digDown = dig
        assert_eq(c.world[key(10, 63, 0)], EC, "the chest is still out there")
        assert_eq(base.ledger.get("fuel_chest") ~= nil, true, "and the record says so")
    end,

    ["a fuel chest stranded at the dock is recovered and nothing else is dug"] =
    function(assert_eq)
        local base, c = fresh({ pos = { x = 10, y = 64, z = 0, facing = 0 },
                                equipped = { left = PICK },
                                world = { [key(10, 63, 0)] = "minecraft:chest", [key(10, 65, 0)] = EC } })
        base.ledger.record("fuel_chest", { x = 10, y = 65, z = 0, face = "up",
                                           turtleAt = { x = 10, y = 64, z = 0 } })
        local n = base.ledger.recoverAll()
        assert_eq(n, 1)
        assert_eq(c.inv[16] and c.inv[16].name, EC, "back in the fuel chest's slot")
        assert_eq(c.world[key(10, 63, 0)], "minecraft:chest", "the station chest is never touched")
        assert_eq(base.ledger.get("fuel_chest"), nil)
    end,

    -- Review #5 (release 2): a chest above or below needs a position, not a
    -- facing. At the dock the fuel chest always goes UP (the station chest is
    -- below), and a turtle boxed in there cannot measure its facing -- it sat
    -- before the main loop, unreachable, with the chest directly overhead.
    ["a chest above is recovered without waiting for a facing"] =
    function(assert_eq)
        local U = { x = 10, y = 65, z = 0, face = "up", turtleAt = { x = 10, y = 64, z = 0 } }
        local base, c = standing(U, { world = {
            [key(11, 64, 0)] = "minecraft:stone", [key(9, 64, 0)] = "minecraft:stone",
            [key(10, 64, 1)] = "minecraft:stone", [key(10, 64, -1)] = "minecraft:stone" } })
        base.setCanDig(false)
        local naps = 0
        local savedSleep = sleep
        sleep = function()
            naps = naps + 1
            if naps >= 3 then c.world[key(9, 64, 0)] = nil end   -- so a wrong wait still ends
        end
        local ok = base.ledger.recover("fuel_chest")
        sleep = savedSleep
        assert_eq(ok, true)
        assert_eq(naps, 0, "no wait: up needs no facing")
        assert_eq(c.world[key(10, 65, 0)], nil)
    end,

    -- Review #3 (release 2): records that outlive the truth. A reboot between
    -- the dig and the clear, or a person fetching the chest by hand, left a
    -- record that raised NEEDS HANDS on every boot, pointing at an empty block.
    ["a record for a chest already home is cleared without digging"] =
    function(assert_eq)
        local base, c, sent = standing(E, { noChest = true, inv = { [16] = { name = EC, count = 1 } } })
        local ok = base.ledger.recover("fuel_chest")
        assert_eq(ok, true)
        assert_eq(base.ledger.get("fuel_chest"), nil, "the record was stale: cleared")
        assert_eq(said(sent, "needs_hands"), false, "and nobody is sent to an empty block")
    end,

    ["a chest dug but not yet moved home is moved home and cleared"] =
    function(assert_eq)
        local base, c, sent = standing(E, { noChest = true, inv = { [1] = { name = EC, count = 1 } } })
        local ok = base.ledger.recover("fuel_chest")
        assert_eq(ok, true)
        assert_eq(c.inv[16] and c.inv[16].name, EC, "moved home")
        assert_eq(base.ledger.get("fuel_chest"), nil)
        assert_eq(said(sent, "needs_hands"), false)
    end,

    -- Review #2 (release 2): the home slot holding something else (refuel
    -- itself guards against coal landing in CHEST_SLOT). The chest came aboard
    -- but the turtle kept the record and raised NEEDS HANDS for ever.
    ["a home slot holding something else is cleared to make way"] =
    function(assert_eq)
        local base, c, sent = standing(E, { inv = { [16] = { name = "minecraft:coal", count = 5 } } })
        local ok = base.ledger.recover("fuel_chest")
        local coal = 0
        for s = 1, 16 do
            if c.inv[s] and c.inv[s].name == "minecraft:coal" then coal = coal + c.inv[s].count end
        end
        assert_eq(ok, true)
        assert_eq(c.inv[16] and c.inv[16].name, EC, "the chest is home")
        assert_eq(coal, 5, "and the coal was moved, not lost")
        assert_eq(base.ledger.get("fuel_chest"), nil)
    end,

    -- Review #9 (release 2): a write that throws escaped refuelFromChest, which
    -- delivery and support call with no wrapper -- killing base.run, and the
    -- refuel retried on the next boot: a crash loop on a full disk.
    ["a write that throws is reported, never raised"] = function(assert_eq)
        local base = fresh()
        local open = fs.open
        fs.open = function(p, m)
            if m == "w" then
                return { write = function() error("Out of space", 0) end, close = function() end }
            end
            return open(p, m)
        end
        local ok, r1, r2 = pcall(base.ledger.record, "fuel_chest", E)
        fs.open = open
        assert_eq(ok, true, "nothing escapes: " .. tostring(r1))
        assert_eq(r1, false)
        assert_eq(r2, "ledger_write_failed")
        assert_eq(base.ledger.get("fuel_chest"), nil)
    end,
}
