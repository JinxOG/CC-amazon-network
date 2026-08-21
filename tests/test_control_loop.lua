-- Final-review fixes F1, F3, F4 (and the F2 ordering guard).
--
-- These drive turtle_base's control loop, boot registration and fuel path
-- directly. turtle_base IS requirable; base.run's controlLoop is reachable by
-- supplying a `parallel` that only runs the first coroutine and letting the
-- event queue run dry to end it.
--
-- F2 lives in ore_turtle.lua's mineJob, which is NOT requirable under this
-- harness (it self-executes base.init at load and pcall(base.run)/os.reboot at
-- the bottom -- same limitation test_miner_hooks documents). The one honest
-- thing available there is a source-ordering assertion, which is what the last
-- test in this file is; it is explicitly weaker than the others and is labelled
-- as such rather than pretending to exercise the flow.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

local MODULES = { "turtle_base", "mine_flow", "equipment", "geofence", "loader_state" }

-- ─── Deterministic clock / event pump ────────────────────────────────────────
-- Only os.pullEvent advances the clock (by one heartbeat interval), so the
-- number of control-loop iterations is exactly the number of queued events and
-- every heartbeat boundary is hit precisely once per iteration.

local HEARTBEAT_MS = 5000

local function withFakeRuntime(body)
    local savedEpoch      = os.epoch
    local savedStartTimer = os.startTimer
    local savedPullEvent  = os.pullEvent
    local savedSleep      = sleep
    local savedParallel   = parallel
    local savedLabel      = os.getComputerLabel
    local savedCompId     = os.getComputerID

    local ok, err = pcall(body)

    os.epoch            = savedEpoch
    os.startTimer       = savedStartTimer
    os.pullEvent        = savedPullEvent
    sleep               = savedSleep
    parallel            = savedParallel
    os.getComputerLabel = savedLabel
    os.getComputerID    = savedCompId
    if not ok then error(err, 0) end
end

local function clearModules()
    for _, m in ipairs(MODULES) do package.loaded[m] = nil end
end

-- ─── F1: only the server's own traffic proves the server is alive ────────────

-- Runs base.run's control loop over `events`, returns the loaded base module.
-- The loop ends when the queue runs dry (os.pullEvent raises), which the
-- `parallel` stand-in below swallows exactly the way parallel.waitForAny ending
-- a coroutine would.
local function runControlLoop(events)
    clearModules()
    stub.install({ fuel = 100000 })

    local clock   = 1000000
    local timerId = 0
    local queue   = events

    os.epoch      = function() return clock end
    os.startTimer = function() timerId = timerId + 1; return timerId end
    os.pullEvent  = function()
        clock = clock + HEARTBEAT_MS
        local ev = table.remove(queue, 1)
        if not ev then error("test: event queue exhausted", 0) end
        return table.unpack(ev)
    end
    sleep    = function() end   -- deliberately does NOT advance the clock
    parallel = { waitForAny = function(controlLoop) pcall(controlLoop) end }

    gps = { locate = function() return 0, 64, 0 end }

    local base = require("turtle_base")
    base.recoverModem()          -- bind the stub's equipped modem so sends work
    base.run(function() end)
    return base
end

-- Both helpers below produce a message addressed to "broadcast" on CH_LOCAL.
-- The ONLY difference between them is `from`, which is the whole point: a
-- test where the two messages differed in any other way would not isolate the
-- gate being fixed.
local function beaconEvent()
    -- Byte-for-byte the shape loader_turtle.lua:91-92 puts on CH_LOCAL.
    local msg = proto.encode(proto.MSG.LOADER_BEACON, "loader_1", "broadcast",
        proto.payloadLoaderBeacon({ x = 0, y = 64, z = 0 }, nil))
    return { "modem_message", "left", proto.CH_LOCAL, proto.CH_SERVER, msg }
end

local function serverBroadcastEvent()
    -- central_server.lua:80 sendBroadcast's shape: from = "server".
    local msg = proto.encode(proto.MSG.HEARTBEAT_ACK, "server", "broadcast",
        { ts = 1 })
    return { "modem_message", "left", proto.CH_BROADCAST, proto.CH_SERVER, msg }
end

local function repeated(fn, n)
    local out = {}
    for _ = 1, n do out[#out + 1] = fn() end
    return out
end

local suite = {}

suite["a broadcast from a non-server sender does NOT reset the missed-heartbeat counter"] =
function(assert_eq)
    withFakeRuntime(function()
        -- Six loader beacons, one per control-loop iteration, i.e. one every
        -- 5s -- exactly loader_turtle.lua's BEACON_INTERVAL. MAX_MISSED = 3 at a
        -- 5s heartbeat needs 15s of silence to trip, so before the fix this
        -- beacon stream held the counter at 0 forever and serverDown was
        -- unreachable for EVERY turtle in ender-modem range (i.e. all of them),
        -- delivery included.
        local base = runControlLoop(repeated(beaconEvent, 6))
        assert_eq(base.isServerDown(), true,
            "loader beacons must not suppress server-down detection")
    end)
end

suite["a broadcast from the server DOES reset the missed-heartbeat counter"] =
function(assert_eq)
    withFakeRuntime(function()
        -- Same cadence, same addressing, only `from` differs. Guards against
        -- over-fixing F1 by deleting the reset outright: that would make the
        -- turtle declare the server down while the server is plainly talking.
        local base = runControlLoop(repeated(serverBroadcastEvent, 6))
        assert_eq(base.isServerDown(), false,
            "server traffic must still prove the server is alive")
    end)
end

-- ─── F3: bounded boot registration for the miner, unbounded for everyone else ─

-- Drives base.init with a server that never answers. proto.receive is made to
-- time out immediately (os.pullEvent always returns the timer it just started),
-- so one REGISTER attempt costs exactly one sleep(5) and one transmit.
local function initWithDeadServer(role, sleepBudget)
    clearModules()
    local eq = require("equipment")
    stub.install({
        fuel     = 100000,
        equipped = { left = eq.ITEMS.MODEM, right = eq.ITEMS.CHUNKY },
    })

    -- proto.selfId() needs these; stub_cc models turtle/peripheral/fs but not
    -- the computer identity, and base.init calls it first thing.
    os.getComputerLabel = function() return role:lower() .. "_test" end
    os.getComputerID    = function() return 1 end

    local sent, sleeps, lastTimer = 0, 0, 0

    local modem = {
        open     = function() end,
        isOpen   = function() return true end,
        transmit = function() sent = sent + 1 end,
    }
    peripheral = { find = function(k) return k == "modem" and modem or nil end,
                   getType = function() return nil end,
                   wrap = function() return nil end }

    os.epoch      = function() return 1000000 end
    os.startTimer = function() lastTimer = lastTimer + 1; return lastTimer end
    os.pullEvent  = function() return "timer", lastTimer end
    sleep = function()
        sleeps = sleeps + 1
        if sleeps > sleepBudget then
            error("UNBOUNDED: register() never gave up", 0)
        end
    end

    gps = { locate = function() return 0, 64, 0 end }

    local base = require("turtle_base")
    local ok, err = pcall(base.init, role)
    return ok, err, sent, sleeps
end

suite["a miner's boot registration gives up so loader recovery can run"] =
function(assert_eq)
    withFakeRuntime(function()
        -- Invariant E: a miner that reboots in the field with a loader placed
        -- must retrieve it and come home with no server contact at all.
        -- ore_turtle's recoverPlacedLoader runs AFTER base.init returns, so an
        -- unbounded register() here means it never runs. A budget of 100 sleeps
        -- is ~16x the bound, so tripping it means "loops forever", not "slow".
        local ok, err, sent = initWithDeadServer(proto.ROLE.MINER, 100)
        assert_eq(ok, true, "base.init must return for a miner with no server: " .. tostring(err))
        -- 1 REGISTER per attempt; the HEARTBEAT/log traffic base.init does not
        -- send means every transmit here is a registration attempt.
        assert_eq(sent, 6, "expected exactly BOOT_REGISTER_ATTEMPTS attempts")
    end)
end

for _, role in ipairs({ proto.ROLE.DELIVERY, proto.ROLE.SUPPORT }) do
    suite[string.format(
        "%s boot registration still blocks forever (unchanged)", role)] =
    function(assert_eq)
        withFakeRuntime(function()
            -- The delivery/support/warehouse no-op guard for F3: these roles
            -- must keep the original behaviour of never proceeding past
            -- registration, so tripping the sleep budget is the PASS condition.
            local ok, err, sent = initWithDeadServer(role, 100)
            assert_eq(ok, false, role .. " must not gain a registration bound")
            assert_eq(tostring(err):find("UNBOUNDED") ~= nil, true,
                "expected the unbounded-loop guard, got: " .. tostring(err))
            assert_eq(sent > 6, true,
                "the loop must keep retrying past the miner's bound")
        end)
    end
end

-- ─── F4: the control-loop refuel path is pickaxe-protected ───────────────────

-- Sets up a miner in TRAVEL mode: modem + chunky equipped, pickaxe stowed in
-- slot 3. This is the state in which refuelFromChest places the fuel ender
-- chest and cannot dig it back up.
local function travelModeMiner(fuelLevel)
    clearModules()
    local eq = require("equipment")
    local c = stub.install({
        fuel     = fuelLevel,
        equipped = { left = eq.ITEMS.MODEM, right = eq.ITEMS.CHUNKY },
        inv      = {
            [3]  = { name = eq.ITEMS.PICKAXE, count = 1 },
            [15] = { name = "enderstorage:ender_chest", count = 1 },
            [16] = { name = "enderstorage:ender_chest", count = 1 },
        },
    })
    gps = { locate = function() return 0, 64, 0 end }
    return c, require("turtle_base"), eq
end

-- Sets up a miner in MINE mode: modem + pickaxe equipped, chunky stowed in
-- slot 3. This is the dominant state whenever ensureFuel fires mid-sector --
-- withDigTool short-circuits here (`if equipment.sideOf("pickaxe") then
-- return fn() end`) instead of taking the swap path.
local function mineModeMiner(fuelLevel)
    clearModules()
    local eq = require("equipment")
    local c = stub.install({
        fuel     = fuelLevel,
        equipped = { left = eq.ITEMS.MODEM, right = eq.ITEMS.PICKAXE },
        inv      = {
            [3]  = { name = eq.ITEMS.CHUNKY, count = 1 },
            [15] = { name = "enderstorage:ender_chest", count = 1 },
            [16] = { name = "enderstorage:ender_chest", count = 1 },
        },
    })
    gps = { locate = function() return 0, 64, 0 end }
    return c, require("turtle_base"), eq
end

-- ore_turtle.lua's withDigTool, reproduced here over the same equipment
-- primitives it uses. Reproduced rather than imported because ore_turtle.lua
-- cannot be required; the assertion below is about turtle_base ROUTING through
-- whatever wrapper is installed, which is the half that was missing.
local function makeWrapper(eq)
    local calls = { n = 0 }
    return calls, function(what, fn)
        calls.n = calls.n + 1
        if eq.sideOf("pickaxe") then return fn() end
        local swapped = eq.toRetrieveMode()          -- modem -> pickaxe
        if not swapped then return nil end
        local ok, err = pcall(fn)
        eq.retrievalSwapOut()                        -- pickaxe -> modem
        if not ok then error(err, 0) end
        return true
    end
end

suite["ensureFuel's chest refuel runs with a pickaxe when a wrapper is installed"] =
function(assert_eq)
    withFakeRuntime(function()
        sleep = function() end
        local c, base, eq = travelModeMiner(100)   -- below FUEL_CRITICAL (200)
        local calls, wrapper = makeWrapper(eq)
        base.setDigToolWrapper(wrapper)

        -- Stand in for the real chest deploy so the assertion is about the
        -- equipped state at the moment the chest would be placed and dug up.
        local sawPickaxe, ran = nil, 0
        base.fuel.refuelFromChest = function()
            ran = ran + 1
            sawPickaxe = eq.sideOf("pickaxe") ~= nil
            c.fuel = 100000
            return true
        end

        assert_eq(base.fuel.ensureFuel(), true)
        assert_eq(ran, 1, "refuelFromChest must still actually be called")
        assert_eq(calls.n, 1, "ensureFuel must route through the installed wrapper")
        assert_eq(sawPickaxe, true,
            "the fuel ender chest would be placed and abandoned without a pickaxe")
        -- And the miner is back in travel mode: chunk loading was never traded.
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem must be restored")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must never come off")
    end)
end

suite["ensureFuel with no wrapper installed calls refuelFromChest directly (delivery no-op)"] =
function(assert_eq)
    withFakeRuntime(function()
        sleep = function() end
        local c, base, eq = travelModeMiner(100)
        -- No setDigToolWrapper: this is delivery/support/warehouse.
        local ran, leftSide, rightSide = 0, eq.sideOf("modem"), eq.sideOf("chunky")
        base.fuel.refuelFromChest = function()
            ran = ran + 1
            c.fuel = 100000
            return true
        end

        assert_eq(base.fuel.ensureFuel(), true)
        assert_eq(ran, 1, "refuelFromChest must be called exactly as before")
        assert_eq(eq.sideOf("modem"), leftSide, "no equipment swap may happen")
        assert_eq(eq.sideOf("chunky"), rightSide, "no equipment swap may happen")
    end)
end

suite["protectedRefuelFromChest reports true when a pickaxe is already equipped (mine mode)"] =
function(assert_eq)
    withFakeRuntime(function()
        sleep = function() end
        -- Mine mode: withDigTool's `if equipment.sideOf("pickaxe") then return
        -- fn() end` short-circuit fires, so the wrapper itself returns fn()'s
        -- return value -- which is nil, because the injected body
        -- (`function() result = fuel.refuelFromChest() end`) returns nothing.
        -- The bug: protectedRefuelFromChest mistook that nil for "could not
        -- equip a pickaxe at all" and reported false even though the refuel
        -- underneath had already succeeded.
        local c, base, eq = mineModeMiner(100)
        local calls, wrapper = makeWrapper(eq)
        base.setDigToolWrapper(wrapper)

        local ran = 0
        base.fuel.refuelFromChest = function()
            ran = ran + 1
            c.fuel = 100000
            return true
        end

        assert_eq(base.fuel.protectedRefuelFromChest(), true,
            "a refuel that actually succeeded while a pickaxe was already equipped must report true")
        assert_eq(ran, 1, "refuelFromChest must have actually run")
        assert_eq(calls.n, 1, "must route through the installed wrapper")
        -- The short-circuit path never swaps: still in mine mode afterward.
        assert_eq(eq.sideOf("pickaxe") ~= nil, true, "pickaxe must remain equipped")
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem must remain equipped")
    end)
end

-- ─── F2: pre-departure preflight ordering (source assertion only) ────────────

suite["mineJob checks for an outstanding loader and travel equipment BEFORE departing"] =
function(assert_eq)
    -- WEAKER THAN THE TESTS ABOVE, and deliberately so: ore_turtle.lua cannot
    -- be required under this harness, so the dispatch/fail spin itself is not
    -- reachable here. What this does pin is the ordering that caused it -- both
    -- guards must precede base.depart, or a miner with a failed retrieval
    -- departs, fails validation, is auto-respawned a replacement job, and spins
    -- roughly once a minute forever. Anchored on exact code lines, not on the
    -- bare identifiers, so a mention in a comment cannot satisfy it.
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local departAt = src:find("local ok, err = base%.depart%(true%)")
    assert_eq(departAt ~= nil, true, "mineJob's base.depart call moved or vanished")

    local validateAt = src:find("local eqOk, eqReason = equipment%.validate%(\"travel\"%)")
    assert_eq(validateAt ~= nil, true, "the travel-equipment check vanished")
    assert_eq(validateAt < departAt, true,
        "equipment.validate('travel') must run BEFORE base.depart")

    local loaderGuardAt = src:find("loader_outstanding")
    assert_eq(loaderGuardAt ~= nil, true, "the outstanding-loader guard is missing")
    assert_eq(loaderGuardAt < departAt, true,
        "the outstanding-loader guard must run BEFORE base.depart")

    -- The failure must be non-retryable, or the server re-queues it anyway.
    local guardBlock = src:sub(loaderGuardAt, departAt)
    assert_eq(guardBlock:find("base%.sendFailed%(detail, false%)") ~= nil, true,
        "the outstanding-loader failure must be reported as non-recoverable")
end

-- Same technique, same limitation, for the 1.9.8 fuel/slot preflight. On 1.9.7
-- two miners were dispatched on fuel they could not finish a trip with; one
-- stranded mid-air at 0. The preflight is only worth anything if it runs while
-- the turtle is still on its dock, so ordering is the property to pin.
suite["the fuel and slot preflight runs before departure (SOURCE-ORDERING, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local departAt = src:find("local ok, err = base%.depart%(true%)")
    assert_eq(departAt ~= nil, true, "mineJob's base.depart call moved or vanished")

    local slotAt = src:find("local slotOk, slotReason = preflightSlots%(%)")
    assert_eq(slotAt ~= nil, true, "the slot preflight vanished")
    assert_eq(slotAt < departAt, true, "preflightSlots() must run BEFORE base.depart")

    local fuelAt = src:find("local needFuel = fuelForZone%(job%.params, SKY_Y%)")
    assert_eq(fuelAt ~= nil, true, "the zone fuel preflight vanished")
    assert_eq(fuelAt < departAt, true, "fuelForZone() must run BEFORE base.depart")

    -- A wrong inventory layout is not fixable by retrying, so it must be
    -- non-recoverable; being short of fuel IS fixable once the coal chest is
    -- stocked, so that one must be recoverable or the zone is abandoned.
    local slotBlock = src:sub(slotAt, fuelAt)
    assert_eq(slotBlock:find("base%.sendFailed%(slotReason, false%)") ~= nil, true,
        "a bad slot layout must be reported as non-recoverable")
    local fuelBlock = src:sub(fuelAt, departAt)
    assert_eq(fuelBlock:find("base%.sendFailed%(detail, true%)") ~= nil, true,
        "insufficient fuel must be reported as recoverable")

    -- It must attempt a top-up before refusing, otherwise a miner on a dry dock
    -- chest can never recover on its own.
    assert_eq(fuelBlock:find("base%.fuel%.dockRefuel%(%)") ~= nil, true,
        "the fuel preflight must try dockRefuel before refusing the job")
end

-- The `stand` square must be FACTUAL, not aspirational (SOURCE-ONLY, weaker).
--
-- placeLoader records the loader from the turtle's actual position, so if
-- `stand` is built from the coordinates the turtle was merely told to fly to,
-- the two describe different squares whenever the approach falls short --
-- another miner in the way being the common cause. The loader then goes down
-- where the turtle really is, retrieval flies to where it meant to be, and the
-- record check fails with loader_position_mismatch. That is non-recoverable, so
-- the miner goes home and leaves its loader standing, which in turn blocks it
-- from every future job through the loader_outstanding guard. Two miners were
-- lost that way in a single four-miner run.
suite["the placement stand square comes from the real position (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    -- The exact buggy form: intended coordinates captured as if they were fact.
    assert_eq(src:find("stand%s*=%s*{%s*x%s*=%s*standX,%s*y%s*=%s*travelY,%s*z%s*=%s*standZ") == nil, true,
        "stand must not be built from the intended coordinates")

    -- It must be read back from the turtle instead.
    local standAt = src:find("stand%s*=%s*{%s*x%s*=%s*standPos%.x")
    assert_eq(standAt ~= nil, true, "stand must be built from a position read back via base.getPos()")
    local posAt = src:find("local standPos%s*=%s*base%.getPos%(%)")
    assert_eq(posAt ~= nil, true, "standPos must come from base.getPos()")
    assert_eq(posAt < standAt, true, "the position must be read before stand is built from it")

    -- And the approach itself must be checked, or the turtle places a loader
    -- from wherever it happened to stop.
    local moveAt = src:find("local mOk, mErr = base%.move%.to%(standX, travelY, standZ%)")
    assert_eq(moveAt ~= nil, true, "the approach to the placement square must capture its result")
    local guard = src:sub(moveAt, standAt)
    assert_eq(guard:find("if not mOk then") ~= nil, true,
        "a failed approach must be handled before anything is placed")
    assert_eq(guard:find("base%.sendFailed") ~= nil, true,
        "a failed approach must fail the job rather than placing anyway")
end

-- Boot must survive a missing modem (SOURCE-ONLY, weaker).
--
-- comms.init() calls error() when it cannot equip a modem, and reconcile cannot
-- recover one that is not in the inventory -- reachable in the field because
-- turtle_base's refuelFromChest drops slots 1-14 on the ground, and slot 4 is
-- the modem. Unprotected, that error escaped module load and everything below
-- it never ran, including recoverPlacedLoader(), so a turtle that lost its modem
-- also permanently abandoned its chunk loader. Loader recovery needs no comms
-- (Invariant E), so it must still happen.
suite["a missing modem must not abort boot before loader recovery (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local guarded = src:find("pcall%(base%.init, proto%.ROLE%.MINER%)")
    assert_eq(guarded ~= nil, true, "base.init must be pcall-protected at boot")

    -- The bare call must be gone, not merely accompanied by a guarded one.
    assert_eq(src:find("\nbase%.init%(") == nil, true,
        "an unprotected base.init call must not remain")

    -- Loader recovery must still be reached after a failed init.
    local recoverAt = src:find("pcall%(recoverPlacedLoader%)")
    assert_eq(recoverAt ~= nil, true, "recoverPlacedLoader must still run at boot")
    assert_eq(guarded < recoverAt, true,
        "boot must reach loader recovery after the guarded init, not before it")
end

-- The miner must empty its ore before any refuel (SOURCE-ONLY, weaker).
--
-- refuelFromChest clears "debris" by dropping slots 1-14 on the ground when
-- fewer than 4 are free. On a miner that is the scanner, the carried loader, the
-- stowed tool and the modem. Dumping first means the count is never low enough
-- to trigger it.
suite["ore is dumped before every refuel path (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    -- Path 1: the in-field fuel check.
    local checkAt = src:find("local function checkFuel%(jobId%)")
    assert_eq(checkAt ~= nil, true, "checkFuel moved or vanished")
    local dumpAt  = src:find("dumpIfInventoryTight%(\"refuel\"%)", checkAt)
    local burnAt  = src:find("tryRefuelSlot14%(%)", checkAt)
    assert_eq(dumpAt ~= nil, true, "checkFuel must dump before refuelling")
    assert_eq(dumpAt < burnAt, true, "the dump must precede the first refuel step")

    -- Path 2: FORCE_REFUEL, which lands straight in refuelFromChest.
    local forceAt = src:find("base%.setRefuelFn%(function%(%)")
    assert_eq(forceAt ~= nil, true, "the FORCE_REFUEL handler moved or vanished")
    local fDumpAt = src:find("dumpIfInventoryTight%(\"force refuel\"%)", forceAt)
    local fChestAt = src:find("base%.fuel%.refuelFromChest%(%)", forceAt)
    assert_eq(fDumpAt ~= nil, true, "FORCE_REFUEL must dump before refuelling")
    assert_eq(fDumpAt < fChestAt, true,
        "the dump must precede refuelFromChest on the FORCE_REFUEL path")

    -- The dump must never dig to make room: docked, the block below is the
    -- station chest, and destroying it to dump ore is worse than not dumping.
    local defAt = src:find("dumpIfInventoryTight = function%(why%)")
    assert_eq(defAt ~= nil, true, "dumpIfInventoryTight definition moved or vanished")
    local body = src:sub(defAt, defAt + 1400)
    assert_eq(body:find("turtle%.detectDown%(%)") ~= nil, true,
        "the guard must still check what is below before digging")
    -- Scoped to the depot, NOT to any obstruction. Skipping on anything below
    -- meant a miner refuelling in a tunnel skipped the dump and then let
    -- turtle_base's debris sweep throw that ore on the ground, where it is lost
    -- instead of banked to RS through the slot-16 chest.
    assert_eq(body:find("base%.isInsideBuilding") ~= nil, true,
        "the no-dig guard must apply only at the dock, where the station chest is below")
end

-- The geo scanner gets Invariant D's treatment (SOURCE-ONLY, weaker).
--
-- The scanner is placed as a world block by the same pattern as the chunk
-- loader, and had no record at all -- so any interruption between placeDown()
-- and digDown() abandoned it. One went missing in the field on 2026-08-18.
-- Losing it is not cosmetic: scanSector refuses to run without a scanner in
-- slot 1 and returns an empty ore list, so the miner works whole sectors and
-- silently finds nothing.
suite["the placed geo scanner is recorded before it is placed (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local scanAt = src:find("local function scanSector%(%)")
    assert_eq(scanAt ~= nil, true, "scanSector moved or vanished")

    -- Record BEFORE place, the whole point of Invariant D's ordering: a crash
    -- the other way round loses the scanner with nothing on disk to find it.
    local recordAt = src:find("scannerRecord%(p0%.x, p0%.y %- 1, p0%.z%)", scanAt)
    local placeAt  = src:find("turtle%.placeDown%(%)", scanAt)
    assert_eq(recordAt ~= nil, true, "scanSector must persist the placement")
    assert_eq(placeAt ~= nil, true, "scanSector must still place the scanner")
    assert_eq(recordAt < placeAt, true,
        "the placement must be recorded BEFORE the scanner is placed")

    -- A refused write must abort the placement rather than placing unrecorded.
    local guard = src:sub(recordAt, placeAt)
    assert_eq(guard:find("refusing to place") ~= nil, true,
        "a failed record write must stop the placement")

    -- The scan must not be able to skip the recovery by throwing.
    local pcallAt = src:find("pcall%(sc%.scan, SCAN_RADIUS%)", scanAt)
    assert_eq(pcallAt ~= nil, true, "sc.scan must be pcall'd so the dig still runs")
    local digAt = src:find("turtle%.digDown%(%)", pcallAt)
    assert_eq(digAt ~= nil and digAt > pcallAt, true,
        "the recovery dig must follow the guarded scan")
end

suite["scanner recovery runs at boot and verifies identity (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    -- Must actually be wired into boot, not merely defined.
    local callAt = src:find("pcall%(recoverPlacedScanner%)")
    assert_eq(callAt ~= nil, true, "recoverPlacedScanner must run at boot")
    local runAt = src:find("pcall%(base%.run, mineJob%)")
    assert_eq(runAt ~= nil and callAt < runAt, true,
        "scanner recovery must run before any job is accepted")

    -- Identity before digging. detectDown() alone is how the loader retrieval
    -- used to destroy the wrong block.
    local defAt = src:find("local function recoverPlacedScanner%(%)")
    assert_eq(defAt ~= nil, true, "recoverPlacedScanner definition moved or vanished")

    -- Bound the window to the function itself. A fixed +N char slice overran
    -- into scanSector, which also mentions SCANNER_NAME, so the identity
    -- assertion below passed even with the check deleted -- a green test
    -- proving nothing, caught only because the mutation run is mandatory.
    local endAt = src:find("local function scanSector%(%)", defAt)
    assert_eq(endAt ~= nil and endAt > defAt, true,
        "could not bound recoverPlacedScanner's body")
    local body = src:sub(defAt, endAt - 1)

    local inspectAt = body:find("turtle%.inspectDown%(%)")
    local bodyDigAt = body:find("turtle%.digDown%(%)")
    assert_eq(inspectAt ~= nil, true, "recovery must inspect before digging")
    assert_eq(bodyDigAt ~= nil and inspectAt < bodyDigAt, true,
        "the identity check must precede the dig")
    -- Assert the comparison, not the bare identifier: the identifier alone is
    -- satisfied by any incidental mention.
    assert_eq(body:find("block%.name == SCANNER_NAME") ~= nil, true,
        "recovery must confirm the block below is actually the geo scanner")
end

suite["a miner without a geo scanner refuses to depart (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local preAt = src:find("local function preflightSlots%(%)")
    assert_eq(preAt ~= nil, true, "preflightSlots moved or vanished")
    local body = src:sub(preAt, preAt + 1600)
    assert_eq(body:find("SCANNER_NAME") ~= nil, true,
        "the preflight must check for the geo scanner")
    assert_eq(body:find("must_hold_the_geo_scanner") ~= nil, true,
        "the refusal reason must name the scanner so an operator can act on it")
end

-- A carried loader clears a stale placement record (SOURCE-ONLY, weaker).
--
-- Invariant D clears the record "only after confirmed retrieval", and C4
-- correctly refused to infer absence from beacon silence -- a loader placed by
-- turtle.place() is powered off and beacons nothing, so silence proves nothing.
-- Possession is a different kind of evidence: the same physical loader cannot be
-- carried and standing in the world at once. Two miners sat benched on stale
-- records on 2026-08-18, each needing a hand-deleted file to work again.
suite["a carried loader clears a stale placement record (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local defAt = src:find("local function clearStaleLoaderRecord%(%)")
    assert_eq(defAt ~= nil, true, "clearStaleLoaderRecord moved or vanished")
    local endAt = src:find("local function recoverPlacedLoader%(%)", defAt)
    assert_eq(endAt ~= nil and endAt > defAt, true, "could not bound the helper")
    local body = src:sub(defAt, endAt - 1)

    -- The test must be possession, not silence: assert the actual lookup.
    assert_eq(body:find("equipment%.findSlot%(equipment%.ITEMS%.LOADER_TURTLE%)") ~= nil, true,
        "staleness must be decided by carrying a loader, not by beacon silence")
    assert_eq(body:find("loader_state%.clear%(%)") ~= nil, true,
        "a proven-stale record must actually be cleared")
    -- It must stay visible: the one case this gets wrong is a replacement
    -- supplied while the original is still standing, and the coordinates are
    -- what let the orphan check catch that.
    assert_eq(body:find("stale_loader_record_cleared") ~= nil, true,
        "clearing must be reported to the server, not done silently")

    -- Both entry points must use it, or a docked miner handed a replacement
    -- still needs a reboot to notice.
    local bootAt = src:find("if clearStaleLoaderRecord%(%) then return end")
    assert_eq(bootAt ~= nil, true, "boot recovery must consult the staleness check")
    local guardAt = src:find("clearStaleLoaderRecord%(%)\n    if loader_state%.hasPlaced%(%) then")
    assert_eq(guardAt ~= nil, true,
        "the pre-departure guard must consult it before refusing the job")
end

-- Room is made before the loader is dug up (SOURCE-ONLY, weaker).
--
-- turtle.dig() with no room for the drop returns TRUE and destroys the item.
-- mine_flow detects that afterwards as loader_lost_after_dig, but by then a
-- physical loader turtle is gone. Observed live: four miners resumed boot
-- recovery carrying a full load of ore, dug up their loaders, and two of the
-- four destroyed them; a third had partial room and it landed in a mining slot.
suite["room is made before the loader is dug up (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local fnAt = src:find("local function retrievePlacedLoader%(stand%)")
    assert_eq(fnAt ~= nil, true, "retrievePlacedLoader moved or vanished")
    local endAt = src:find("\nlocal function ", fnAt + 10) or #src
    local body  = src:sub(fnAt, endAt)

    local dumpAt = body:find('dumpIfInventoryTight%("loader retrieval"%)')
    assert_eq(dumpAt ~= nil, true,
        "retrievePlacedLoader must make room before digging the loader up")

    -- A true position before the approach is computed. The stand square and the
    -- recorded loader position were captured when the loader went down;
    -- everything since is dead reckoning across a sector of mining, and it
    -- drifts. move.to cannot catch that -- it loops until its OWN tracked
    -- position matches, so a drifted turtle arrives "successfully" at the wrong
    -- block. Two miners lost their jobs and stranded their loaders that way.
    -- Anchored on newline + indentation, NOT the bare identifier. The bare form
    -- also matches the explanatory comment a few lines above the call, so
    -- deleting the call left this assertion green -- caught only because the
    -- mutation run is mandatory. Prose cannot satisfy "\n    base.gpsSync()".
    local syncAt = body:find("\n    base%.gpsSync%(%)")
    assert_eq(syncAt ~= nil, true,
        "retrievePlacedLoader must resync GPS before working out the approach")
    local approachAt = body:find("approachFor%(rec, base%.getPos%(%)%)")
    assert_eq(approachAt ~= nil, true, "the approach derivation moved or vanished")
    assert_eq(syncAt < approachAt, true,
        "the resync must precede the approach, or it is derived from a drifted position")

    -- It must come before the approach, so every path gets it -- not tucked
    -- after a move that can return early.
    local moveAt = body:find("local ok, err = base%.move%.to%(sx, sy, sz%)")
    assert_eq(moveAt ~= nil, true, "the approach move moved or vanished")
    assert_eq(dumpAt < moveAt, true, "the dump must precede the approach")
end

-- Boot recovery must hand the turtle back as dispatchable (SOURCE-ONLY, weaker).
--
-- returnToDockFromSky sets STATUS.RETURNING, and only sendComplete/sendFailed
-- reset it to IDLE -- both of which report the outcome of a JOB. Boot recovery
-- is not a job, so it called neither. Observed live: four miners recovered their
-- loaders, flew home correctly, and then sat at the dock in RETURNING while
-- their jobs stayed PENDING behind "idle=0". Recovery worked and the fleet was
-- still deadlocked.
suite["boot recovery leaves the turtle dispatchable (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local fnAt = src:find("local function recoverPlacedLoader%(%)")
    assert_eq(fnAt ~= nil, true, "recoverPlacedLoader moved or vanished")
    local endAt = src:find("\nlocal function ", fnAt + 10) or #src
    local body  = src:sub(fnAt, endAt)

    local returnAt = body:find("base%.returnToDockFromSky%(%)")
    assert_eq(returnAt ~= nil, true, "boot recovery must still fly home")

    -- Position reaches the dashboard on heartbeats, and the control loop that
    -- sends them does not start until base.run -- after this whole recovery. So
    -- the flight legs must report position explicitly, or a turtle flying home
    -- is indistinguishable from one that died in the field.
    local legAt = body:find("local function legReport%(what%)")
    assert_eq(legAt ~= nil, true, "the flight home must report its legs")
    local ascAt = body:find('legReport%("ascending to the sky lane"%)')
    local flyAt = body:find('legReport%("flying to arrivals"%)')
    local descAt = body:find('legReport%("descending to dock"%)')
    assert_eq(ascAt ~= nil and flyAt ~= nil and descAt ~= nil, true,
        "each leg of the flight home must report")
    assert_eq(ascAt < flyAt and flyAt < descAt, true,
        "leg reports must be in flight order")
    local idleAt = body:find("base%.setStatus%(proto%.STATUS%.IDLE%)")
    assert_eq(idleAt ~= nil, true,
        "boot recovery must reset status to IDLE or the turtle is never dispatched again")
    assert_eq(returnAt < idleAt, true,
        "the IDLE reset must come after the return that set RETURNING")

    -- ...but ONLY when the dock was actually reached. returnToDockFromSky sets
    -- STATUS.ERROR and returns false when the return route fails -- routine for
    -- the last miner home, with the others still queued at the single-block
    -- arrivals hole. Forcing IDLE unconditionally overwrote that ERROR and
    -- reported DOCKED, so a turtle stranded above the hole announced itself
    -- parked at its bay and got dispatched again from the wrong place.
    assert_eq(body:find("local docked, dockErr = base%.returnToDockFromSky%(%)") ~= nil, true,
        "the dock result must be captured, not discarded")
    local guardAt = body:find("if docked == false then")
    assert_eq(guardAt ~= nil, true, "a failed dock must be handled")
    assert_eq(guardAt < idleAt, true,
        "the failed-dock guard must come BEFORE the IDLE reset, or it masks the ERROR")
    local guard = body:sub(guardAt, idleAt)
    assert_eq(guard:find("dock_not_reached") ~= nil, true,
        "a failed dock must be reported to the server, not swallowed")
    assert_eq(guard:find("\n        return") ~= nil, true,
        "a failed dock must return before claiming IDLE and DOCKED")
end

-- Ore squatting in a reserved slot is dumped (SOURCE-ONLY, weaker).
--
-- While the loader stands in the world its home slot is EMPTY, and turtle.dig()
-- puts drops in the first free slot -- so ore lands in slot 2. dumpToEC used to
-- skip every reserved slot, so that ore was never dumped: it sat there
-- permanently and on retrieval the loader could not be returned home, landing in
-- a mining slot instead. Seen in-world.
suite["ore that lands in a reserved slot is still dumped (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local fnAt = src:find("local function dumpToEC%(%)")
    assert_eq(fnAt ~= nil, true, "dumpToEC moved or vanished")
    local endAt = src:find("\nlocal function ", fnAt + 10) or #src
    local body  = src:sub(fnAt, endAt)

    assert_eq(body:find("foreignInReserved") ~= nil, true,
        "dumpToEC must dump foreign items out of reserved slots")
    -- Hardware must still be exempt wherever it sits.
    assert_eq(body:find("protectedItemNames%[item%.name%]") ~= nil, true,
        "hardware must stay exempt from dumping")
    -- The coal buffer must NOT be emptied: coal in slot 14 is working as
    -- intended, and dumping it would throw away the fuel just drawn from the EC.
    assert_eq(body:find("s ~= S_COAL") ~= nil, true,
        "the coal buffer slot must be exempt from the foreign-item dump")
end

-- The refuel make-room hook is installed (SOURCE-ONLY, weaker).
--
-- W3's base.setMakeRoomFn fires just before the debris sweep, and is inert until
-- a role installs one. It is the ONLY thing covering fuel.ensureFuel() from the
-- control loop, which reaches refuelFromChest with no W1 code in front of it --
-- guarding the entrances could never have caught that path.
suite["the refuel make-room hook is installed (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local installAt = src:find(
        'base%.setMakeRoomFn%(function%(%) dumpIfInventoryTight%("refuel sweep"%) end%)')
    assert_eq(installAt ~= nil, true,
        "the make-room hook must be installed, or the sweep still drops ore on the ground")

    -- The closure is built here but dumpIfInventoryTight is assigned much later,
    -- so the forward declaration is load-bearing: without it the name compiles
    -- to a GLOBAL lookup and is nil when the hook fires. This file already
    -- carries that exact bug's scar for rescueProtectedItems.
    local declAt = src:find("\nlocal dumpIfInventoryTight\n")
    assert_eq(declAt ~= nil, true,
        "dumpIfInventoryTight must be forward-declared as a local")
    assert_eq(declAt < installAt, true,
        "the forward declaration must precede the hook closure or it captures a nil global")

    local assignAt = src:find("\ndumpIfInventoryTight = function%(why%)")
    assert_eq(assignAt ~= nil, true,
        "dumpIfInventoryTight must be assigned to the forward-declared local, not redeclared")
    assert_eq(installAt < assignAt, true,
        "precondition: the hook really is built before the function is assigned")
end

-- Retrieval retries and believes the loader over the record (SOURCE-ONLY, weaker).
--
-- A single attempt cannot be made reliable: the record is written from the
-- miner's dead-reckoned belief at placement, that belief drifts over a sector,
-- and move.to loops until its OWN tracked position matches -- so a drifted
-- turtle arrives "successfully" at the wrong block. Resyncing before the
-- approach did not fix it (1.9.28), because the approach is itself a long
-- flight and turtle_base resyncs every 50 moves. The loader broadcasts its own
-- gps.locate() fix, which is the one position in play that is not a guess.
suite["retrieval retries and believes the loader's own position (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local fnAt = src:find("local function retrievePlacedLoader%(stand%)")
    assert_eq(fnAt ~= nil, true, "retrievePlacedLoader moved or vanished")
    local endAt = src:find("\nlocal function ", fnAt + 10) or #src
    local body  = src:sub(fnAt, endAt)

    -- Anchored on newline + indentation throughout: the bare identifiers all
    -- appear in the explanatory comments in this same function, and matching
    -- those made an earlier version of this suite pass against deleted code.
    assert_eq(body:find("for attempt = 1, RETRIEVE_ATTEMPTS do") ~= nil, true,
        "the approach must retry rather than failing on the first mismatch")
    assert_eq(body:find("\n            base%.gpsSync%(%)") ~= nil, true,
        "each retry must take a fresh GPS fix")
    -- Anchored on the ASSIGNMENT, not the bare call: nearbyBeaconPos() also
    -- appears in the wait loop just above, and matching that left this green
    -- when the assignment was stubbed to nil.
    assert_eq(body:find("\n            local beaconPos = mine_flow%.nearbyBeaconPos%(%)") ~= nil, true,
        "a retry must ask the loader where it thinks it is")
    assert_eq(body:find("\n                loader_state%.record%(beaconPos%.x") ~= nil, true,
        "a corrected position must be written back to the record")
    assert_eq(body:find("\n                stand = nil") ~= nil, true,
        "the stand square derived from the stale record must be discarded")

    -- Only a position mismatch is retryable. Retrying a missing loader or a
    -- failed dig just burns fuel before failing identically.
    assert_eq(body:find('tostring%(reason%):match%("%^loader_position_mismatch"%)') ~= nil, true,
        "only a position mismatch may be retried")
end

-- mine_flow must keep the near-miss beacon rather than discarding it.
suite["a near-miss loader beacon is kept, not discarded (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("mine_flow.lua", "r"))
    local src = f:read("*a")
    f:close()

    assert_eq(src:find("\nlocal NEAR_MISS_RADIUS = %d") ~= nil, true,
        "a near-miss radius must be defined")
    assert_eq(src:find("\n            _nearMissBeaconPos = { x = pos%.x") ~= nil, true,
        "a beacon close to the record must be captured, not thrown away")
    assert_eq(src:find("\nfunction mine_flow%.nearbyBeaconPos%(%)") ~= nil, true,
        "the captured position must be readable by the caller")

    -- It must be cleared when a NEW loader is placed, or a stale correction
    -- from the previous sector's loader could be applied to this one.
    local placeAt = src:find("\n    _expectedLoaderPos = { x = tx, y = p%.y, z = tz }")
    assert_eq(placeAt ~= nil, true, "placement no longer records the expected position")
    local clearAt = src:find("\n    _nearMissBeaconPos = nil", placeAt)
    assert_eq(clearAt ~= nil and clearAt - placeAt < 200, true,
        "placing a new loader must clear any near-miss position from the previous one")
end

-- Displaced hardware is put back on every dump (SOURCE-ONLY, weaker).
--
-- node_138 finished a job at the dock carrying its chunk loader in a mining slot
-- instead of slot 2. turtle.dig() puts drops in the first free slot, so a
-- retrieved loader lands wherever there is room, and mine_flow's
-- normalizeLoaderSlot is tidy-up-only -- it gives up if the home slot is
-- occupied at that instant. rescueProtectedItems existed to fix exactly this but
-- ran only inside dumpToEC's dig-first branch, so on the ordinary path it never
-- ran at all.
suite["displaced hardware is rescued on every dump (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local fnAt = src:find("local function dumpToEC%(%)")
    assert_eq(fnAt ~= nil, true, "dumpToEC moved or vanished")
    local endAt = src:find("\nlocal function ", fnAt + 10) or #src
    local body  = src:sub(fnAt, endAt)

    -- Must run unconditionally at the end, not only in the dig-first branch.
    -- Anchored on newline + 4 spaces: the conditional call inside the branch is
    -- indented deeper, and the identifier also appears in the prose above it.
    local tailCall = body:find("\n    rescueProtectedItems%(%)")
    assert_eq(tailCall ~= nil, true,
        "dumpToEC must rescue displaced hardware on every dump, not only when it digs first")

    -- It has to come after the drop loop frees the reserved slots, or the home
    -- slot is still occupied and the rescue silently does nothing.
    local dropAt = body:find("turtle%.dropDown%(%)")
    assert_eq(dropAt ~= nil and dropAt < tailCall, true,
        "the rescue must run after the drop loop has cleared the reserved slots")
end

suite["the rescue scans the swap slots, not just mining slots (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a")
    f:close()

    local fnAt = src:find("rescueProtectedItems = function%(%)")
    assert_eq(fnAt ~= nil, true, "rescueProtectedItems moved or vanished")
    local endAt = src:find("\nlocal function ", fnAt + 10) or #src
    local body  = src:sub(fnAt, endAt)

    -- Slots 2, 3 and 4 are empty during their swap windows, so a drop can land
    -- there. Scanning only MINE_FIRST..MINE_LAST missed a loader in slot 4.
    assert_eq(body:find("for s = 1, S_COAL do") ~= nil, true,
        "the rescue must scan the swap slots as well as the mining slots")
    -- 15 and 16 must stay out of range: both hold same-named ender chests, and
    -- scanning them could pull the ore chest out of 16 into an empty 15.
    assert_eq(body:find("for s = 1, 16 do") == nil, true,
        "the rescue must NOT scan the ender chest slots")
end

return suite
