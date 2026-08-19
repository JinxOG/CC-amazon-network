-- The IN-FIELD ender chest refuel: does a miner that runs low mid-job actually
-- recover, thousands of blocks from base with no dock chest in reach?
--
-- This was never covered. test_control_loop asserts that ensureFuel routes
-- through the installed dig-tool wrapper and that a pickaxe is equipped at the
-- moment the chest would be deployed -- but it replaces refuelFromChest with a
-- stub, so the actual deploy/suck/burn/recover cycle never ran headlessly. It
-- could not: stub_cc had no placeDown, digUp, suck or container contents until
-- the 1.9.8 fuel work added them.
--
-- What makes the field case different from the dock case:
--   * mid-air, so nothing is below/above/front and no digging is needed to
--     make room -- but recovering the chest still needs a pickaxe
--   * the miner is in TRAVEL mode: modem + chunky equipped, pickaxe stowed in
--     slot 3, so the wrapper has to swap modem -> pickaxe and back
--   * CHEST_SLOT is 15 for a MINER (base.init sets it), and slot 16 holds the
--     ORE chest, which has no coal in it

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

local COAL = "minecraft:coal"
local EC   = "enderstorage:ender_chest"

local MODULES = { "turtle_base", "mine_flow", "equipment", "geofence", "loader_state" }
local function clearModules()
    for _, m in ipairs(MODULES) do package.loaded[m] = nil end
end

-- A booted MINER hanging in the air in travel mode, low on fuel, carrying a
-- stocked coal ender chest. Returns everything a test needs to assert on.
local function fieldMiner(opts)
    opts = opts or {}
    clearModules()
    local eq = require("equipment")

    local savedEpoch, savedTimer, savedPull = os.epoch, os.startTimer, os.pullEvent
    local savedSleep, savedLabel, savedId   = sleep, os.getComputerLabel, os.getComputerID
    local savedPeripheral, savedGps         = peripheral, gps

    local containers = { [EC] = { { name = COAL, count = 64 } } }
    if opts.emptyEC then containers[EC] = {} end

    local c = stub.install({
        fuel     = opts.fuel or 150,          -- below CFG.FUEL_CRITICAL (200)
        realFuel = true,
        containers = containers,
        -- Travel mode: modem and chunky equipped, pickaxe stowed.
        equipped = { left = eq.ITEMS.MODEM, right = eq.ITEMS.CHUNKY },
        inv = {
            [3]  = { name = eq.ITEMS.PICKAXE, count = 1 },
            [15] = { name = EC, count = 1 },   -- fuel EC  (CHEST_SLOT for a miner)
            [16] = { name = EC, count = 1 },   -- ore EC
        },
    })

    os.getComputerLabel = function() return "miner_test" end
    os.getComputerID    = function() return 1 end
    local lastTimer = 0
    os.epoch      = function() return 1000000 end
    os.startTimer = function() lastTimer = lastTimer + 1; return lastTimer end
    os.pullEvent  = function() return "timer", lastTimer end
    -- MINER boot registration is bounded, so this returns on its own.
    sleep = function() end
    local modem = { open = function() end, isOpen = function() return true end,
                    transmit = function() end }
    peripheral = { find = function(k) return k == "modem" and modem or nil end,
                   getType = function() return nil end, wrap = function() return nil end }
    gps = { locate = function() return 0, 175, 0 end }

    local base = require("turtle_base")
    pcall(base.init, proto.ROLE.MINER)

    -- Mid-air: leave c.world empty so findFreeSpace() places DOWN without
    -- digging. Set after init because detectFacing() moves the turtle.
    c.world = {}
    c.fuel  = opts.fuel or 150

    -- The real wrapper ore_turtle installs, reproduced: ore_turtle.lua cannot be
    -- required under this harness (it self-executes base.init and pcall(base.run)
    -- at load), so its withDigTool is mirrored here. Same swap sequence.
    local calls = { n = 0, sawPickaxe = nil }
    base.setDigToolWrapper(function(what, fn)
        calls.n = calls.n + 1
        if eq.sideOf("pickaxe") then calls.sawPickaxe = true; return fn() end
        if not eq.toRetrieveMode() then return nil end       -- modem -> pickaxe
        calls.sawPickaxe = eq.sideOf("pickaxe") ~= nil
        local ok, err = pcall(fn)
        eq.retrievalSwapOut()                                -- pickaxe -> modem
        if not ok then error(err, 0) end
        return true
    end)

    local restore = function()
        os.epoch, os.startTimer, os.pullEvent = savedEpoch, savedTimer, savedPull
        sleep, os.getComputerLabel, os.getComputerID = savedSleep, savedLabel, savedId
        peripheral, gps = savedPeripheral, savedGps
    end
    return c, base, eq, calls, containers, restore
end

return {
    -- The headline question: does a miner low on fuel in the field recover?
    ["a miner in travel mode refuels from its ender chest mid-air"] =
    function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        local before = c.fuel
        local ok     = base.fuel.protectedRefuelFromChest()
        local after  = c.fuel
        restore()

        assert_eq(ok, true, "the field refuel must report success")
        assert_eq(after > before, true,
            string.format("fuel must rise in the field (was %d, now %d)", before, after))
        assert_eq(calls.n, 1, "it must route through the dig-tool wrapper")
        assert_eq(calls.sawPickaxe, true,
            "a pickaxe must be equipped while the chest is deployed and recovered")
        assert_eq(#containers[EC] < 1 or containers[EC][1].count < 64, true,
            "coal must actually have been drawn out of the ender chest")
    end,

    -- The chest is the miner's only fuel source for the rest of the job. Losing
    -- it in the field means it can never refuel again, which is how a turtle
    -- ends up stranded at 0.
    -- Asserting only "slot 15 holds an ender chest" is NOT discriminating: both
    -- chests share one item name, and refuelFromChest's recovery loop moves the
    -- first chest it finds in any slot into CHEST_SLOT. Deleting the digFn()
    -- that recovers the deployed chest still leaves that assertion true --
    -- because the loop then drags the ORE chest out of slot 16 into slot 15.
    -- So this checks the whole picture: one chest in each slot, and none left
    -- behind in the world.
    ["the ender chest is recovered to its own slot, without cannibalising the ore chest"] =
    function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.fuel.protectedRefuelFromChest()
        local slot15, slot16 = turtle.getItemDetail(15), turtle.getItemDetail(16)
        local chestsLeftInWorld = 0
        for _, block in pairs(c.world) do
            if block == EC then chestsLeftInWorld = chestsLeftInWorld + 1 end
        end
        restore()

        assert_eq(slot15 ~= nil and slot15.name == EC, true,
            "the fuel ender chest must be back in slot 15")
        assert_eq(slot15 and slot15.count, 1, "slot 15 must hold exactly one chest")
        assert_eq(slot16 ~= nil and slot16.name == EC, true,
            "the ore ender chest must still be in slot 16")
        assert_eq(slot16 and slot16.count, 1, "slot 16 must hold exactly one chest")
        assert_eq(chestsLeftInWorld, 0, "no chest may be left deployed in the world")
    end,

    -- The compounding-failure case. Called WITHOUT the dig-tool wrapper while in
    -- travel mode, refuelFromChest places the chest and then cannot dig it back
    -- up (no pickaxe) -- the exact situation turtle_base's setDigToolWrapper
    -- comment describes. Recovery must then leave the ore chest alone: losing
    -- the fuel chest is bad, and silently eating the ore chest as well would
    -- leave the miner unable to dump for the rest of the job too.
    ["a failed chest recovery must not steal the ore chest"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        -- No wrapper: the pickaxe stays in slot 3 and digDown fails.
        base.setDigToolWrapper(nil)
        base.fuel.refuelFromChest()
        local slot15, slot16 = turtle.getItemDetail(15), turtle.getItemDetail(16)
        local chestsInWorld = 0
        for _, block in pairs(c.world) do
            if block == EC then chestsInWorld = chestsInWorld + 1 end
        end
        local pickaxeStowed = turtle.getItemDetail(3)
        restore()

        assert_eq(pickaxeStowed ~= nil, true, "precondition: the pickaxe must still be stowed")
        assert_eq(chestsInWorld, 1, "precondition: the chest must be stuck in the world")
        assert_eq(slot16 ~= nil and slot16.name == EC, true,
            "the ore chest must survive a failed fuel-chest recovery")
        assert_eq(slot16 and slot16.count, 1, "the ore chest must not be drawn from")
        assert_eq(slot15, nil,
            "slot 15 must be left empty rather than filled with the ore chest")
    end,

    -- Chunk loading must survive the swap. The wrapper trades the MODEM side for
    -- the pickaxe and leaves chunky alone; if it ever swapped out chunky instead,
    -- the miner would unload its own chunk mid-refuel.
    ["chunky stays equipped throughout, and the modem comes back"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.fuel.protectedRefuelFromChest()
        local chunky = eq.sideOf("chunky")
        local modem  = eq.sideOf("modem")
        restore()
        assert_eq(chunky ~= nil, true, "chunk loading must never be given up to refuel")
        assert_eq(modem ~= nil, true, "the modem must be restored after the refuel")
    end,

    -- The debris sweep at the top of refuelFromChest exists for support turtles,
    -- which pick up road rubbish in slots 1..BURN_MAX and keep nothing else
    -- there. A miner keeps its whole kit in that range, so the sweep was
    -- throwing the turtle's own hardware on the ground -- observed in-world as
    -- missing loader turtles and a missing geo scanner.
    --
    -- The modem is the one that turns item loss into a brick: equipment.reconcile
    -- looks for it in the inventory it was just dropped from, so Invariant B
    -- cannot hold and base.init errors out at ore_turtle.lua's module load,
    -- skipping recoverPlacedLoader() and abandoning the placed chunk loader too.
    --
    -- No wrapper here on purpose: called directly, refuelFromChest does no
    -- equipment swapping, so slots 1-4 hold still and the sweep is the only
    -- thing that can empty them.
    ["the debris sweep must not drop the miner's own hardware"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.setDigToolWrapper(nil)

        -- The full kit in its declared slots, and every mining slot loaded, so
        -- freeCount() is 1 (slot 14 only) -- well under the sweep's threshold of 4.
        c.inv[1] = { name = eq.ITEMS.SCANNER,       count = 1 }
        c.inv[2] = { name = eq.ITEMS.LOADER_TURTLE, count = 1 }
        c.inv[3] = { name = eq.ITEMS.PICKAXE,       count = 1 }
        c.inv[4] = { name = eq.ITEMS.MODEM,         count = 1 }
        for s = 5, 13 do c.inv[s] = { name = "minecraft:cobblestone", count = 64 } end
        c.inv[14] = nil

        base.fuel.refuelFromChest()

        local scanner = turtle.getItemDetail(1)
        local loader  = turtle.getItemDetail(2)
        local tool    = turtle.getItemDetail(3)
        local modem   = turtle.getItemDetail(4)
        restore()

        assert_eq(scanner ~= nil and scanner.name == eq.ITEMS.SCANNER, true,
            "the geo scanner must survive the debris sweep")
        assert_eq(loader ~= nil and loader.name == eq.ITEMS.LOADER_TURTLE, true,
            "the carried chunk loader must survive the debris sweep")
        assert_eq(tool ~= nil and tool.name == eq.ITEMS.PICKAXE, true,
            "the stowed pickaxe must survive the debris sweep")
        assert_eq(modem ~= nil and modem.name == eq.ITEMS.MODEM, true,
            "the modem must survive the debris sweep — losing it bricks the miner")
    end,

    -- Slot protection alone is not enough. Hardware gets physically displaced
    -- into a mining slot -- dug up during movement, or a retrieved loader turtle
    -- landing in the first free slot -- which is the whole reason ore_turtle
    -- carries rescueProtectedItems. A sweep that trusted slot position would
    -- drop a displaced loader while congratulating itself on protecting slot 2.
    ["hardware displaced into a mining slot is still not dropped"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.setDigToolWrapper(nil)

        -- Slot 2 empty, the loader turtle sitting in a mining slot instead.
        -- It goes in slot 5 specifically: the sweep stops the moment it has
        -- freed 4 slots, so a displaced item parked deeper in the range is never
        -- reached and the test would pass without proving anything.
        c.inv[1] = { name = eq.ITEMS.SCANNER, count = 1 }
        c.inv[2] = nil
        for s = 5, 13 do c.inv[s] = { name = "minecraft:cobblestone", count = 64 } end
        c.inv[5]  = { name = eq.ITEMS.LOADER_TURTLE, count = 1 }
        c.inv[14] = nil

        base.fuel.refuelFromChest()

        local found = false
        for s = 1, 14 do
            local i = turtle.getItemDetail(s)
            if i and i.name == eq.ITEMS.LOADER_TURTLE then found = true end
        end
        restore()

        assert_eq(found, true,
            "a loader turtle displaced into a mining slot must survive the sweep")
    end,

    -- The other half of the pair: a declared home slot is protected by position,
    -- whatever is sitting in it. Name protection cannot cover this, because it
    -- depends on equipment.ITEMS matching the pack -- and those registry names
    -- are the thing most likely to drift (the spec dates its verification for
    -- exactly that reason). If the modem's registry name changes under us, the
    -- name table silently stops matching and slot position is all that is left
    -- standing between the sweep and the miner's hardware.
    ["a declared home slot is protected whatever is sitting in it"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.setDigToolWrapper(nil)

        -- Slot 2 is the loader's home, holding an item whose name we do not know.
        c.inv[1] = { name = eq.ITEMS.SCANNER, count = 1 }
        c.inv[2] = { name = "somemod:renamed_chunk_loader", count = 1 }
        for s = 5, 13 do c.inv[s] = { name = "minecraft:cobblestone", count = 64 } end
        c.inv[14] = nil

        base.fuel.refuelFromChest()

        local slot2 = turtle.getItemDetail(2)
        restore()

        assert_eq(slot2 ~= nil and slot2.name == "somemod:renamed_chunk_loader", true,
            "an unrecognised item in a protected home slot must not be dropped")
    end,

    -- The sweep's purpose is still served: genuine debris goes, hardware stays.
    -- Without this, "protect everything" would pass the test above and quietly
    -- break refuelling for the support turtles the sweep was written for.
    ["the debris sweep still clears genuine debris"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.setDigToolWrapper(nil)

        c.inv[1] = { name = eq.ITEMS.SCANNER, count = 1 }
        for s = 5, 13 do c.inv[s] = { name = "minecraft:cobblestone", count = 64 } end
        c.inv[14] = nil

        base.fuel.refuelFromChest()

        local cobbleLeft = 0
        for s = 1, 14 do
            local i = turtle.getItemDetail(s)
            if i and i.name == "minecraft:cobblestone" then cobbleLeft = cobbleLeft + 1 end
        end
        restore()

        assert_eq(cobbleLeft < 9, true,
            string.format("the sweep must still clear debris (9 stacks in, %d left)", cobbleLeft))
    end,

    -- Debris on the ground despawns, and on a miner it is mined ore. A role that
    -- can bank its cargo installs a make-room hook; when that hook frees enough
    -- slots the sweep must not run at all, so nothing is dropped.
    ["a make-room hook that frees slots stops the sweep dropping anything"] =
    function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.setDigToolWrapper(nil)

        -- Two free slots to start (4 and 14), so the hook fires.
        c.inv[1] = { name = eq.ITEMS.SCANNER,       count = 1 }
        c.inv[2] = { name = eq.ITEMS.LOADER_TURTLE, count = 1 }
        for s = 5, 13 do c.inv[s] = { name = "minecraft:iron_ore", count = 64 } end
        c.inv[14] = nil

        -- Stands in for ore_turtle's dumpToEC: banks the cargo somewhere real.
        -- It clears the DEEP slots (11-13) on purpose. The sweep works upward
        -- from slot 1 and stops at four free, so it would have taken 5 and 6 --
        -- slots the hook never touches. Those two are therefore the discriminator:
        -- they survive only if the hook's work meant the sweep never ran.
        local banked = 0
        base.setMakeRoomFn(function()
            for s = 11, 13 do
                if c.inv[s] then banked = banked + 1; c.inv[s] = nil end
            end
        end)

        base.fuel.refuelFromChest()
        local slot5, slot6 = turtle.getItemDetail(5), turtle.getItemDetail(6)
        restore()
        base.setMakeRoomFn(nil)

        assert_eq(banked, 3, "the hook must be given the chance to bank the cargo")
        assert_eq(slot5 ~= nil and slot5.name == "minecraft:iron_ore", true,
            "ore in slot 5 must survive — the hook already made room")
        assert_eq(slot6 ~= nil and slot6.name == "minecraft:iron_ore", true,
            "ore in slot 6 must survive — the hook already made room")
    end,

    -- The hook is an optimisation, not a dependency. A miner that cannot bank --
    -- boxed in, chest missing, dump raising -- must still refuel, because a
    -- turtle stuck at zero fuel is worse than a stack of cobblestone on the floor.
    ["a failing make-room hook still lets the refuel proceed"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner()
        base.setDigToolWrapper(nil)

        -- Slots 1 and 2 loaded so only 4 and 14 are free: the hook fires only
        -- below four, and a fixture that starts AT four never reaches it.
        c.inv[1] = { name = eq.ITEMS.SCANNER,       count = 1 }
        c.inv[2] = { name = eq.ITEMS.LOADER_TURTLE, count = 1 }
        for s = 5, 13 do c.inv[s] = { name = "minecraft:cobblestone", count = 64 } end
        c.inv[14] = nil

        local fired = false
        base.setMakeRoomFn(function()
            fired = true
            error("cannot deploy the ore chest")
        end)

        local before = c.fuel
        base.fuel.refuelFromChest()
        local after = c.fuel
        restore()
        base.setMakeRoomFn(nil)

        assert_eq(fired, true, "precondition: the hook must actually have been reached")
        assert_eq(after > before, true,
            string.format("the refuel must survive a failing hook (was %d, now %d)",
                before, after))
    end,

    -- An empty chest in the field is the genuinely unrecoverable case, and it
    -- must be reported as failure so ensureFuel escalates to ERROR rather than
    -- looping as though it had succeeded.
    ["an empty ender chest in the field reports failure"] = function(assert_eq)
        local c, base, eq, calls, containers, restore = fieldMiner({ emptyEC = true })
        local before = c.fuel
        local ok     = base.fuel.protectedRefuelFromChest()
        local after  = c.fuel
        restore()
        assert_eq(ok, false, "an empty EC must report failure in the field")
        assert_eq(after, before, "no fuel can be gained from an empty chest")
    end,
}
