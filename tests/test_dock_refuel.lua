-- fuel.dockRefuel()'s fallback to the turtle's own fuel ender chest.
--
-- Why this exists: on 1.9.7 two miners were dispatched on fuel they could not
-- complete a trip with, and one stranded mid-air at 0. dockRefuel only ever
-- sucked coal from the dock station chest, so a miner parked at its dock with a
-- FULL coal ender chest in slot 15 could not top itself up. It then cleared the
-- flat 500-fuel pre-departure gate and left anyway.
--
-- Until now the whole refuel path had no real coverage at all: stub_cc lacked
-- detectUp/digUp/placeUp/placeDown/suck/suckUp, so fuel.refuelFromChest could
-- not even run headlessly and every existing test replaced it with a stub. The
-- container/realFuel support these tests use was added to stub_cc for this.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

local COAL      = "minecraft:coal"
local EC        = "enderstorage:ender_chest"
local DOCK_CHEST = "minecraft:chest"

local MODULES = { "turtle_base", "mine_flow", "equipment", "geofence", "loader_state" }
local function clearModules()
    for _, m in ipairs(MODULES) do package.loaded[m] = nil end
end

-- Boots turtle_base for `role` against a server that never answers, parks the
-- turtle on a dock whose station chest is EMPTY, and gives it a stocked coal
-- ender chest in the fuel slot. Returns the base module and the fuel level
-- after dockRefuel().
--
-- dockChestCoal lets a test stock the station chest instead, to prove the
-- fallback does NOT fire when the normal path works.
local function refuelAtDock(role, opts)
    opts = opts or {}
    clearModules()
    local eq = require("equipment")

    local savedEpoch, savedTimer, savedPull = os.epoch, os.startTimer, os.pullEvent
    local savedSleep, savedLabel, savedId   = sleep, os.getComputerLabel, os.getComputerID
    local savedPeripheral, savedGps         = peripheral, gps

    local containers = {
        [EC]         = { { name = COAL, count = 64 } },
        [DOCK_CHEST] = {},
    }
    if opts.dockChestCoal then
        containers[DOCK_CHEST] = { { name = COAL, count = 64 } }
    end
    if opts.emptyEC then containers[EC] = {} end

    local c = stub.install({
        fuel      = opts.fuel or 600,
        realFuel  = true,
        containers = containers,
        equipped  = { left = eq.ITEMS.MODEM, right = eq.ITEMS.PICKAXE },
        inv       = { [15] = { name = EC, count = 1 } },
    })

    os.getComputerLabel = function() return role:lower() .. "_test" end
    os.getComputerID    = function() return 1 end
    local lastTimer = 0
    os.epoch      = function() return 1000000 end
    os.startTimer = function() lastTimer = lastTimer + 1; return lastTimer end
    os.pullEvent  = function() return "timer", lastTimer end
    -- base.init's boot registration is deliberately UNBOUNDED for every role
    -- except MINER, so a no-op sleep would spin forever here against a server
    -- that never answers. Bounding it and letting the error escape is fine:
    -- base.init assigns _self.role and the CHEST_SLOT/BURN_MAX overrides before
    -- it ever tries to register, so everything dockRefuel depends on is already
    -- in place by the time registration gives up.
    local sleeps = 0
    sleep = function()
        sleeps = sleeps + 1
        if sleeps > 20 then error("register gave up (expected in this harness)", 0) end
    end
    local modem = { open = function() end, isOpen = function() return true end,
                    transmit = function() end }
    peripheral = { find = function(k) return k == "modem" and modem or nil end,
                   getType = function() return nil end, wrap = function() return nil end }
    gps = { locate = function() return 0, 64, 0 end }

    local base = require("turtle_base")
    pcall(base.init, role)

    -- The world is built AFTER init, not before: initPosition() calls
    -- detectFacing(), which physically moves the turtle to work out which way
    -- it points. Blocks placed at hardcoded coordinates beforehand end up in
    -- the wrong place relative to where the turtle finally stands (and would
    -- obstruct the calibration move itself).
    --
    -- Dock station chest below, open air above and in front, so
    -- findFreeSpace() deploys the ender chest UP and never needs to dig.
    local p = c.pos
    local function keyOf(dx, dy, dz)
        return (p.x + dx) .. "," .. (p.y + dy) .. "," .. (p.z + dz)
    end
    c.world[keyOf(0, -1, 0)] = DOCK_CHEST
    if opts.boxedIn then
        local dx, dz = 0, 0
        if     p.facing == 0 then dz = -1
        elseif p.facing == 1 then dx =  1
        elseif p.facing == 2 then dz =  1
        else                      dx = -1 end
        c.world[keyOf(0, 1, 0)]   = "minecraft:stone"   -- above
        c.world[keyOf(dx, 0, dz)] = "minecraft:stone"   -- ahead
    end

    -- base.init runs fuel.refuel(), which burns nothing here (no loose coal),
    -- so the level going into dockRefuel is still the configured one.
    local before = turtle.getFuelLevel()
    local ok     = base.fuel.dockRefuel()
    local after  = turtle.getFuelLevel()

    os.epoch, os.startTimer, os.pullEvent = savedEpoch, savedTimer, savedPull
    sleep, os.getComputerLabel, os.getComputerID = savedSleep, savedLabel, savedId
    peripheral, gps = savedPeripheral, savedGps

    return ok, before, after, containers
end

return {
    -- The actual bug: an empty dock chest used to mean no refuel at all.
    ["a miner with an empty dock chest refuels from its own fuel ender chest"] =
    function(assert_eq)
        local ok, before, after = refuelAtDock(proto.ROLE.MINER)
        assert_eq(ok, true, "dockRefuel must report success via the EC fallback")
        assert_eq(after > before, true,
            string.format("fuel must rise via the EC fallback (was %d, now %d)", before, after))
    end,

    -- Pins the standing constraint that delivery behaviour is untouched. A
    -- DELIVERY turtle must take the old path and gain nothing, even though it
    -- also carries an ender chest in slot 15.
    ["a delivery turtle does NOT use the EC fallback"] = function(assert_eq)
        local ok, before, after = refuelAtDock(proto.ROLE.DELIVERY)
        assert_eq(ok, false, "delivery must still report failure on an empty dock chest")
        assert_eq(after, before, "delivery fuel must not change")
    end,

    -- The fallback is a fallback: when the station chest has coal the normal
    -- path must handle it and the ender chest must be left untouched.
    ["a stocked dock chest is used and the ender chest is left alone"] =
    function(assert_eq)
        local ok, before, after, containers = refuelAtDock(proto.ROLE.MINER,
            { dockChestCoal = true })
        assert_eq(ok, true, "the normal dock path must still work")
        assert_eq(after > before, true, "fuel must rise from the dock chest")
        assert_eq(#containers[EC], 1, "the ender chest must not have been drawn from")
    end,

    -- Guards the destructive case. With down, up and front all blocked,
    -- refuelFromChest would dig to make room -- and at a dock the blocked space
    -- below is the station chest, so digging destroys the player's chest.
    ["the fallback refuses to deploy when it would have to dig"] = function(assert_eq)
        local ok, before, after = refuelAtDock(proto.ROLE.MINER, { boxedIn = true })
        assert_eq(ok, false, "boxed in, the fallback must bail rather than dig")
        assert_eq(after, before, "no fuel gained when the fallback is skipped")
    end,

    -- An empty ender chest must be reported, not silently treated as success.
    ["an empty fuel ender chest reports failure"] = function(assert_eq)
        local ok, before, after = refuelAtDock(proto.ROLE.MINER, { emptyEC = true })
        assert_eq(ok, false, "an empty EC must report failure")
        assert_eq(after, before, "no fuel gained from an empty EC")
    end,
}
