-- Task 8a: mine_flow.lua -- the place / swap / mine / swap / retrieve cycle
-- for a solo miner that carries its own chunk-loader turtle.
--
-- Ordering is the entire safety argument (see mine_flow.lua's header), so
-- these tests exercise every refusal path, not just the happy path: a
-- refused placement must never give up chunky or drop the loader, a refused
-- retrieval must never dig up the loader, and the persisted loader_state
-- record must survive exactly as long as a real, physically-standing loader
-- would.
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

-- Registry names, matching equipment.ITEMS verbatim (see equipment.lua and
-- tests/test_equipment.lua). The stub's `equipped`/inventory tables are keyed
-- by registry name only -- short kinds like "modem"/"chunky" (as used in an
-- earlier draft of this task's brief) don't exist in the world.
local MODEM   = "computercraft:wireless_modem_advanced"
local CHUNKY  = "advancedperipherals:chunk_controller"
local PICKAXE = "minecraft:diamond_pickaxe"

-- Functions, not shared table literals: stub_cc stores whatever table is
-- passed as opts.equipped and mutates it in place on every equip/unequip, so
-- a single shared constant reused across tests would get permanently
-- corrupted by the first test that swaps anything.
local function E_TRAVEL() return { left = MODEM, right = CHUNKY } end
local function E_MINE()   return { left = MODEM, right = PICKAXE } end

-- mine_flow.noteBeacon/beaconSeenWithin/the beacon-wait deadline all stamp
-- os.epoch("utc"). stub_cc does not model the real-time clock (only turtle/
-- peripheral/os.pullEvent/textutils), so provide the same fallback
-- tests/test_loader_state.lua and tests/test_bypass_geofence.lua use for the
-- same gap.
os.epoch = os.epoch or function() return os.time() * 1000 end

local function freshModules()
    package.loaded["equipment"]    = nil
    package.loaded["geofence"]     = nil
    package.loaded["loader_state"] = nil
    package.loaded["mine_flow"]    = nil
end

-- A controllable fake clock for os.epoch, so tests that exercise the beacon
-- wait's real wall-clock deadline (mine_flow.lua's BEACON_WAIT_SECONDS)
-- don't have to actually block the test runner for 15 real seconds per test.
-- restore() MUST be called before the test returns, success or failure --
-- callers use it in a straight-line sequence, not pcall/finally, so a test
-- that errors before restoring will leak the fake clock into later tests;
-- every use below is written to reach restore() on every path.
local function fakeClock(startSeconds)
    local now = startSeconds
    local orig = os.epoch
    os.epoch = function() return now * 1000 end
    return {
        advance = function(by) now = now + (by or 0) end,
        restore = function() os.epoch = orig end,
    }
end

-- A pump hook that delivers exactly one fresh LOADER_BEACON, reporting
-- `position`, on its first call and does nothing after. Models a loader that
-- beacons immediately once alive. `position` is nil to model a beacon sent
-- with no GPS fix at all.
local function beaconOnFirstPump(position)
    return function(flow)
        local delivered = false
        return function()
            if not delivered then
                flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = position } })
                delivered = true
            end
        end
    end
end

-- A pump hook that never delivers a beacon but advances a fakeClock by
-- `pollSeconds` (mine_flow.lua's own BEACON_POLL_SECONDS) per call --
-- modelling a real proto.receive-backed pump that blocks for roughly one
-- real second when nothing arrives. Using this instead of a truly no-op
-- pump means the "no beacon ever arrives, wait out the deadline" tests below
-- exercise the full 15-second wall-clock wait via a fake clock advancing at
-- a REALISTIC rate, without the test runner actually blocking for 15 real
-- seconds.
local function neverBeaconPump(clock)
    return function(flow)
        return function(pollSeconds)
            clock.advance(pollSeconds or 1)
        end
    end
end

-- Finds the index of an upvalue named `name` closed over by function `fn`.
-- Used ONCE below to test beaconSeenWithin's own _expectedLoaderPos guard in
-- true isolation: noteBeacon has its OWN, separate _expectedLoaderPos check
-- that refuses to ever set _lastBeaconAt while no placement is active, and
-- every place retrieveLoader clears _expectedLoaderPos it clears
-- _lastBeaconAt in the same breath -- so the exact precondition the guard
-- defends against (a stale _lastBeaconAt surviving past _expectedLoaderPos
-- going nil) cannot currently be constructed through any sequence of public
-- calls. That makes the guard real defense-in-depth against a future code
-- path that might not pair the two, but untestable by normal means -- so
-- this pokes the private state directly, the standard way to test an
-- otherwise-unreachable invariant guard.
local function findUpvalue(fn, name)
    local i = 1
    while true do
        local uname = debug.getupvalue(fn, i)
        if not uname then return nil end
        if uname == name then return i end
        i = i + 1
    end
end

-- Every test below places from pos = {x=0,y=80,z=0,facing=0} at an anchor
-- chunk of {cx=0,cz=-1}: aheadBlock(facing=0 => north) puts the loader at
-- (0,80,-1). A pumpFactory built from beaconOnFirstPump(LOADER_LANDING)
-- reports exactly that position -- the common "our loader answers correctly"
-- case every test that isn't specifically about the position check needs out
-- of the way.
local LOADER_LANDING = { x = 0, y = 80, z = -1 }

-- c.pos already carries facing (stub_cc defaults it to 0 and tracks it on
-- every turn), so handing hooks.pos the same table satisfies mine_flow's
-- "pos() must return facing too" requirement for free.
local function loadFlow(equipped, inv, world, pumpFactory)
    freshModules()
    local c  = stub.install({ equipped = equipped, inv = inv, world = world or {},
                               pos = { x = 0, y = 80, z = 0, facing = 0 } })
    local eq = require("equipment")
    local gf = require("geofence")
    local ls = require("loader_state")
    ls.clear()
    local flow = require("mine_flow")
    flow.setHooks({
        pos  = function() return c.pos end,
        pump = pumpFactory and pumpFactory(flow) or function() end,
    })
    return flow, eq, gf, ls, c
end

local function travelInv()
    local eq = require("equipment")
    return {
        [1]  = { name = "advancedperipherals:geo_scanner", count = 1 },
        [2]  = { name = eq.ITEMS.LOADER_TURTLE, count = 1 },
        [3]  = { name = eq.ITEMS.PICKAXE,       count = 1 },
        [14] = { name = "minecraft:coal",       count = 32 },
        [15] = { name = "enderstorage:ender_chest", count = 1 },
        [16] = { name = "enderstorage:ender_chest", count = 1 },
    }
end

return {

    -- ─── placeLoader: happy path ────────────────────────────────────────

    ["placeLoader places, confirms standing, waits for the beacon, swaps to pickaxe, then arms the fence"] = function(assert_eq)
        local flow, eq, gf = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        -- Miner at 0,0 facing north => loader lands at 0,-1, which is chunk 0,-1.
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky"), nil, "chunky must be stowed after the swap")
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem stays on")
        assert_eq(gf.isActive(), true, "fence must be armed once the pickaxe is on")
        local a = gf.anchor()
        assert_eq(a.cx, 0)
        assert_eq(a.cz, -1, "fence anchors on the LOADER's chunk, not the miner's position")
    end,

    -- ─── placeLoader: refusal paths must never surrender chunky or the loader ──

    ["placeLoader refuses a target outside the sector's anchor chunk"] = function(assert_eq)
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        -- Demand a chunk the placement cannot reach from here.
        local ok, reason = flow.placeLoader(1, { cx = 5, cz = 5 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_target_wrong_chunk")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must NOT be removed when placement is refused")
        assert_eq(gf.isActive(), false)
        assert_eq(eq.findSlot(eq.ITEMS.LOADER_TURTLE) ~= nil, true,
            "loader must still be carried, not dropped in the wrong chunk")
        assert_eq(ls.hasPlaced(), false, "nothing was ever placed, nothing should be recorded")
    end,

    ["placeLoader refuses when the loader turtle is not carried"] = function(assert_eq)
        local inv = travelInv(); inv[2] = nil
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), inv, nil, beaconOnFirstPump(LOADER_LANDING))
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_turtle_missing")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must NOT be removed when placement fails")
        assert_eq(gf.isActive(), false)
        assert_eq(ls.hasPlaced(), false)
    end,

    ["placeLoader refuses when the target square ahead is already occupied"] = function(assert_eq)
        local world = { ["0,80,-1"] = "minecraft:stone" }
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), world, beaconOnFirstPump(LOADER_LANDING))
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "placement_blocked")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must stay equipped")
        assert_eq(eq.findSlot(eq.ITEMS.LOADER_TURTLE) ~= nil, true,
            "loader must still be carried, never dropped in inventory")
        assert_eq(ls.hasPlaced(), false, "placement never even attempted -- nothing to record")
        assert_eq(gf.isActive(), false)
    end,

    -- ─── loader_state ordering across a place() that cleanly fails ─────────

    ["a clean turtle.place() failure rolls back the loader_state record it just wrote"] = function(assert_eq)
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        assert_eq(ls.hasPlaced(), false)
        -- Force a definite, clean "not placed" answer from turtle.place()
        -- itself (distinct from the placement_blocked pre-check above),
        -- exercising the crash-safety rollback: we KNOW nothing is out
        -- there, so the record loader_state.record() just wrote must not
        -- survive as a false positive.
        turtle.place = function() return false, "forced failure" end
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_place_failed")
        assert_eq(ls.hasPlaced(), false, "a clean place() failure must not leave a stale record")
        assert_eq(eq.sideOf("chunky") ~= nil, true)
        assert_eq(eq.findSlot(eq.ITEMS.LOADER_TURTLE) ~= nil, true,
            "place() never actually consumed the item")
    end,

    -- Finding 7 (review fix pass 2): pins that loader_state.record() runs
    -- BEFORE turtle.place() ever executes, not merely that hasPlaced() is
    -- true somewhere in the aftermath -- the two end-state tests above and
    -- below are satisfied just as well by a place()-then-record() ordering,
    -- which is exactly the ordering loader_state.lua's whole design exists
    -- to avoid (a crash between them would lose the loader with no record at
    -- all). Verified red against that mutation, then green again below.
    ["loader_state.record() runs strictly BEFORE turtle.place(), never after"] = function(assert_eq)
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        local recordedBeforePlace = nil
        local origPlace = turtle.place
        turtle.place = function(...)
            recordedBeforePlace = ls.hasPlaced()
            return origPlace(...)
        end
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, true, reason)
        assert_eq(recordedBeforePlace, true,
            "loader_state.record() must have already run by the time turtle.place() is called")
    end,

    ["placeLoader keeps the loader_state record when place() succeeds but standing can't be confirmed"] = function(assert_eq)
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        -- turtle.detect() always reports false, whatever the world holds:
        -- the pre-place check ("is it blocked ahead?") now passes vacuously,
        -- but so does the post-place confirmation, which is the failure this
        -- test targets. place() itself still runs normally and DOES commit
        -- the loader to the world -- we just can't see it -- so unlike the
        -- test above, the record must NOT be rolled back.
        turtle.detect = function() return false end
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_not_detected_after_place")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must stay equipped -- we don't know what actually happened")
        assert_eq(ls.hasPlaced(), true,
            "place() reported success -- the record must survive for a recovery pass")
        assert_eq(gf.isActive(), false)
    end,

    -- Finding 5 (review fix pass 2): equipment.toMineMode() swaps chunky for
    -- pickaxe FIRST, then runs a trailing equipment.validate("mine") as its
    -- own success check (equipment.lua:156). If ONLY that trailing check
    -- fails (e.g. missing cargo, unrelated to chunk safety), the swap has
    -- already landed -- chunky is off -- and the old comment "we still hold
    -- chunky, so we are safe" was not actually true. The loader is already
    -- beacon-confirmed alive by this point, so the fence must go up anyway.
    ["placeLoader arms the fence even when toMineMode reports failure after its swap already landed, so chunky-off never means fence-off"] = function(assert_eq)
        -- equipment.toMineMode() swaps chunky for pickaxe FIRST, then runs a
        -- trailing equipment.validate("mine") as its own success check
        -- (equipment.lua:156). Not reachable through today's equipment.lua
        -- -- validate("mine")'s validateCargo() checks exactly the same
        -- scanner/fuel_ec/ore_ec that validate("travel") already confirmed
        -- at the very top of placeLoader, and nothing in between touches
        -- them, so it cannot fail there without something ELSE changing
        -- cargo out from under it first (confirmed empirically: dropping the
        -- ore ender chest from inventory makes validate("travel") fail
        -- first, before the loader is even placed, not this trailing
        -- check). But the invariant this branch asserts must hold
        -- regardless of how toMineMode's own internals evolve, so this
        -- simulates the exact shape directly: the swap already landed
        -- (chunky off, pickaxe on), and toMineMode still reports failure.
        local flow, eq, gf = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        eq.toMineMode = function()
            local pSlot = eq.findSlot(eq.ITEMS.PICKAXE)
            local chunkySide = eq.sideOf("chunky")
            turtle.select(pSlot)
            if chunkySide == "left" then turtle.equipLeft() else turtle.equipRight() end
            return false, "simulated_post_swap_validation_failure"
        end
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "simulated_post_swap_validation_failure")
        assert_eq(eq.sideOf("chunky"), nil, "the swap itself did land")
        assert_eq(gf.isActive(), true,
            "chunky is off -- the fence MUST be on, or the miner is unloaded and unfenced")
        local a = gf.anchor()
        assert_eq(a.cx, 0); assert_eq(a.cz, -1)
    end,

    -- Mutation target (fix pass 3, mutation 4 of 5): replacing the
    -- `equipment.sideOf("chunky") == nil` guard above with `true` (arming
    -- the fence unconditionally on ANY toMineMode failure). This is the
    -- other half of that branch: toMineMode can also fail BEFORE the swap
    -- ever lands (e.g. no pickaxe carried at all) -- chunky stays equipped,
    -- self-loading is intact, and arming the fence here would be wrong: the
    -- miner isn't relying on the loader for anything yet.
    ["placeLoader does NOT arm the fence when toMineMode fails before its swap ever lands"] = function(assert_eq)
        local inv = travelInv()
        inv[3] = nil -- no pickaxe carried at all -> toMineMode fails at pickaxe_missing, before any swap
        local flow, eq, gf = loadFlow(
            E_TRAVEL(), inv, nil, beaconOnFirstPump(LOADER_LANDING))
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "pickaxe_missing")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "the swap never happened -- chunky stays on")
        assert_eq(gf.isActive(), false,
            "the fence must NOT arm when chunky is still equipped -- we are already safe, self-loaded")
    end,

    -- ─── Beacon gate ────────────────────────────────────────────────────

    ["placeLoader refuses to give up chunky if no beacon arrives before the deadline"] = function(assert_eq)
        local clock = fakeClock(1000)
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), nil, neverBeaconPump(clock))
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        clock.restore()
        assert_eq(ok, false)
        assert_eq(reason, "loader_no_beacon")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must stay on -- the loader never proved it's alive")
        assert_eq(gf.isActive(), false, "fence must never arm around an unconfirmed loader")
        assert_eq(ls.hasPlaced(), true,
            "the loader really is standing there -- still recorded for recovery")
    end,

    -- Finding 4 (review fix pass 2): the wait must be governed by real
    -- wall-clock time elapsing, not by how many times pump() happens to get
    -- called. A pump that returns near-instantly (draining non-beacon
    -- traffic -- server heartbeats, job messages -- without blocking) must
    -- not be able to exhaust the wait in well under a second just by being
    -- called many times fast. Modelled with a fake clock that advances only
    -- 0.01s per call (far less than the documented ~1s/call a real pump is
    -- expected to take).
    --
    -- Asserts on ELAPSED SIMULATED TIME, not on how many times pump() was
    -- called: an earlier draft of this test asserted pumpCalls > 20, which a
    -- reintroduced attempt-count loop with a larger constant (e.g.
    -- BEACON_WAIT_ATTEMPTS = 2000) would also satisfy without actually being
    -- time-bounded. Checking that the deadline (BEACON_WAIT_SECONDS = 15) of
    -- SIMULATED time actually elapsed is what the fix specifically changed.
    ["the beacon wait is governed by elapsed wall-clock time, not by how many times pump() is called"] = function(assert_eq)
        local clock = fakeClock(1000)
        local totalAdvanced = 0
        local flow = loadFlow(E_TRAVEL(), travelInv(), nil, function()
            return function(pollSeconds)
                totalAdvanced = totalAdvanced + 0.01
                clock.advance(0.01)
                if totalAdvanced > 10000 then
                    error("advanced far more simulated time than any deadline should ever allow -- looks like a real hang")
                end
            end
        end)
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        clock.restore()
        assert_eq(ok, false)
        assert_eq(reason, "loader_no_beacon")
        if totalAdvanced < 14 then
            error(string.format(
                "only %.2fs of simulated wall-clock time elapsed before giving up -- " ..
                "expected close to the full 15s deadline (mine_flow.lua's BEACON_WAIT_SECONDS)",
                totalAdvanced))
        end
    end,

    ["placeLoader accepts a beacon whose position matches exactly where the loader landed"] = function(assert_eq)
        local flow, eq, gf = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky"), nil)
        assert_eq(gf.isActive(), true)
    end,

    ["placeLoader refuses with loader_beacon_mismatch when a beacon arrives from a different position"] = function(assert_eq)
        -- Models a SECOND, unrelated loader in radio range -- a neighbouring
        -- miner's sector, or an orphan left standing from an earlier failure
        -- (Task 5b's loader_state exists precisely because that happens).
        -- Proof that SOME loader is alive must never be mistaken for proof
        -- that OURS is.
        local foreign = { x = 999, y = 80, z = 999 }
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(foreign))
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_beacon_mismatch")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must stay on -- a foreign beacon proves nothing about OUR loader")
        assert_eq(gf.isActive(), false)
        assert_eq(ls.hasPlaced(), true,
            "our loader really is standing there -- still recorded for recovery")
    end,

    ["placeLoader refuses with loader_beacon_no_position when the loader beacons with no GPS fix"] = function(assert_eq)
        -- A beacon with position = nil (gps.locate timed out for the
        -- loader) is not verification, even though it might genuinely be
        -- our loader -- there's nothing to check it against. This makes GPS
        -- coverage at the sector a hard requirement: a loader placed outside
        -- GPS range can never be adopted, which is the safe direction to
        -- fail in.
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(nil))
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_beacon_no_position")
        assert_eq(eq.sideOf("chunky") ~= nil, true)
        assert_eq(gf.isActive(), false)
        assert_eq(ls.hasPlaced(), true)
    end,

    ["a beacon seen before this placement started does not satisfy the gate"] = function(assert_eq)
        -- Models a stale beacon left over from a PREVIOUS sector's (already
        -- retrieved) loader: it must not let a brand new placement skip
        -- verifying that THIS loader is actually alive. Calling noteBeacon
        -- before placeLoader has ever run is a no-op regardless of position,
        -- since there is no _expectedLoaderPos yet to match against -- which
        -- is a stronger guarantee than "stale", but exercises the same risk.
        local clock = fakeClock(1000)
        local flow, eq = loadFlow(E_TRAVEL(), travelInv(), nil, neverBeaconPump(clock))
        flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_LANDING } })
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        clock.restore()
        assert_eq(ok, false)
        assert_eq(reason, "loader_no_beacon")
        assert_eq(eq.sideOf("chunky") ~= nil, true)
    end,

    ["noteBeacon ignores non-beacon messages and beacons with no placement to verify against"] = function(assert_eq)
        local flow = loadFlow(E_TRAVEL(), travelInv())
        flow.noteBeacon({ type = "HEARTBEAT" })
        assert_eq(flow.beaconSeenWithin(9999), false)
        -- Well-formed, correctly-positioned LOADER_BEACON, but no
        -- placeLoader has ever run in this flow -- nothing to match against.
        flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_LANDING } })
        assert_eq(flow.beaconSeenWithin(9999), false)
    end,

    ["beaconSeenWithin reports true inside the window and false once it elapses, scoped to the placed loader"] = function(assert_eq)
        local fakeNow = 1000
        local origEpoch = os.epoch
        os.epoch = function() return fakeNow * 1000 end
        local flow = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        local ok = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, true)
        assert_eq(flow.beaconSeenWithin(10), true)
        fakeNow = 1005
        assert_eq(flow.beaconSeenWithin(10), true)
        fakeNow = 1020
        assert_eq(flow.beaconSeenWithin(10), false)
        os.epoch = origEpoch
    end,

    -- Finding 3 (review fix pass 2): _lastBeaconAt used to survive a
    -- successful retrieval untouched, so beaconSeenWithin could report a
    -- stale "yes" (the placement gate itself was never at risk -- its flags
    -- reset per-wait -- but a mid-mining liveness monitor built on
    -- beaconSeenWithin, per Task 8b, would trust a beacon from a loader
    -- that is now sitting in our inventory).
    ["beaconSeenWithin returns false immediately after a successful retrieval, not stale-true into the next sector"] = function(assert_eq)
        local eqm = require("equipment")
        local flow, eq, gf, ls, c = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        local ok = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, true)
        assert_eq(flow.beaconSeenWithin(9999), true)

        local ok2, reason2 = flow.retrieveLoader()
        assert_eq(ok2, true, reason2)
        assert_eq(flow.beaconSeenWithin(9999), false,
            "a stale true here means the miner could trust a loader that is now sitting in its own inventory")
    end,

    -- Fix pass 3 review: the test above pins only the DISJUNCTION of two
    -- redundant mechanisms (retrieveLoader's own _lastBeaconAt clear, and
    -- beaconSeenWithin's _expectedLoaderPos guard) -- either one alone makes
    -- it pass, so either could silently rot without the test ever noticing.
    -- These two pin them SEPARATELY.

    -- Isolates retrieveLoader's `_lastBeaconAt = nil` specifically. Checking
    -- beaconSeenWithin() right after retrieveLoader returns (as above) can't
    -- isolate this: beaconSeenWithin's OWN guard (_expectedLoaderPos, also
    -- cleared by retrieveLoader in the same breath) would mask it every
    -- time. Instead this hooks the log() call placeLoader makes AFTER
    -- setting _expectedLoaderPos for a SECOND sector but BEFORE calling
    -- waitForFreshBeacon (which has its own, independent reset) -- at that
    -- exact point, _expectedLoaderPos is legitimately non-nil (so the OTHER
    -- guard can't be what saves the check) and waitForFreshBeacon's own
    -- reset hasn't run yet, isolating retrieveLoader's clear as the only
    -- thing that can be under test.
    ["retrieveLoader clears _lastBeaconAt on success -- a later placement doesn't inherit a stale beacon before its own wait even starts"] = function(assert_eq)
        local eqm = require("equipment")
        local flow, eq, gf, ls, c = loadFlow(
            E_TRAVEL(), travelInv(), nil, beaconOnFirstPump(LOADER_LANDING))
        assert_eq(flow.placeLoader(1, { cx = 0, cz = -1 }), true)
        assert_eq(flow.retrieveLoader(), true)

        -- Second sector, same spot: re-carry a loader turtle and place again.
        c.inv[2] = { name = eqm.ITEMS.LOADER_TURTLE, count = 1 }
        local sawStaleTrue = nil
        local delivered = false
        flow.setHooks({
            pos = function() return c.pos end,
            pump = function()
                if not delivered then
                    flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_LANDING } })
                    delivered = true
                end
            end,
            log = function(msg)
                if sawStaleTrue == nil and
                   msg == "Waiting for loader beacon before giving up chunk loading..." then
                    sawStaleTrue = flow.beaconSeenWithin(9999)
                end
            end,
        })
        local ok2, reason2 = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok2, true, reason2)
        assert_eq(sawStaleTrue, false,
            "a beacon from the FIRST loader must not read as 'alive' for the SECOND, before its own wait has even started")
    end,

    -- Isolates beaconSeenWithin's own _expectedLoaderPos guard. See the
    -- findUpvalue comment above for why this cannot be constructed through
    -- any sequence of public calls given the code's other correct
    -- invariants, and why poking the private state directly is the right
    -- tool here.
    ["beaconSeenWithin's own _expectedLoaderPos guard refuses a stale beacon timestamp even with no active placement"] = function(assert_eq)
        local flow = loadFlow(E_TRAVEL(), travelInv())
        local idx = findUpvalue(flow.beaconSeenWithin, "_lastBeaconAt")
        assert_eq(idx ~= nil, true, "test setup: expected an upvalue named _lastBeaconAt")
        debug.setupvalue(flow.beaconSeenWithin, idx, os.epoch("utc") / 1000)
        assert_eq(flow.beaconSeenWithin(9999), false,
            "no placement is in flight (_expectedLoaderPos is nil) -- a beacon timestamp alone must never read as 'alive'")
    end,

    -- ─── retrieveLoader ─────────────────────────────────────────────────

    ["retrieveLoader keeps chunky on across the dig, restores modem, and clears the record"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil                                  -- loader is placed, not carried
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        gf.setAnchorChunk(0, 0, 1)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky on at the end")
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem restored at the end")
        assert_eq(gf.isActive(), false, "fence released once self-loading again")
        assert_eq(ls.hasPlaced(), false, "record cleared only once retrieval actually succeeded")
    end,

    ["retrieveLoader equips chunky BEFORE digging, never after"] = function(assert_eq)
        -- The end-state tests above ("keeps chunky on across the dig") pass
        -- even under a broken implementation that digs FIRST and swaps
        -- chunky on afterward, because the stub's turtle.dig() only checks
        -- for a pickaxe, not chunky -- so a same-end-state assertion can't
        -- tell the two orderings apart. This test pins the ordering
        -- directly by capturing what's equipped at the instant dig() runs.
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local origDig = turtle.dig
        local chunkyOnAtDigTime = nil
        turtle.dig = function(...)
            chunkyOnAtDigTime = eq.sideOf("chunky") ~= nil
            return origDig(...)
        end

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        assert_eq(chunkyOnAtDigTime, true,
            "chunky must already be equipped at the instant dig() runs -- never dig, then swap")
    end,

    -- Finding 2 (review fix pass 2): findSlot(CHUNKY) is inventory-only, so
    -- it can't see a chunky that's already equipped -- which is exactly
    -- what equipment.reconcile() (the documented boot self-heal) can leave
    -- behind, or what a reboot landing right after retrievalSwapIn (before
    -- dig()) leaves in place. Already-equipped must be treated as success,
    -- matching equipment.toTravelMode's identical pattern (equipment.lua:164).
    ["retrieveLoader succeeds when chunky is already equipped, not chunky_missing"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil                                   -- loader is placed, not carried
        inv[3] = { name = eqm.ITEMS.MODEM, count = 1 }  -- already displaced into inventory
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        -- chunky+pickaxe both already equipped: exactly the state a reboot
        -- right after retrievalSwapIn (but before dig()) would leave behind.
        local flow, eq, gf, ls = loadFlow(
            { left = eqm.ITEMS.CHUNKY, right = eqm.ITEMS.PICKAXE }, inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky") ~= nil, true)
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem restored at the end")
        assert_eq(ls.hasPlaced(), false)
    end,

    -- Finding 1 (fix pass 3 review): the chunky-already-equipped path added
    -- for fix pass 2's finding 2 was itself a dead end when reconcile()'s
    -- specific displacement (pickaxe, not modem) is the reason chunky is
    -- already on: retrieveLoader took the chunkyEquipped branch, skipped
    -- retrievalSwapIn, and hit the equipment invariant permanently, with no
    -- route forward (the loader stays standing, safely, but unrecoverable
    -- without an undocumented dependency on the caller restoring mine mode
    -- first). equipment.toRetrieveMode() (added to equipment.lua this pass)
    -- is the missing modem->pickaxe transition that actually finishes the
    -- job.
    ["retrieveLoader recovers via toRetrieveMode when reconcile left chunky+modem equipped (pickaxe displaced)"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil -- loader placed, not carried; slot3 keeps its PICKAXE from travelInv()
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        -- chunky+modem equipped: exactly the dead end reconcile() leaves
        -- behind after a reboot mid-retrieval with both sides full (it
        -- displaces the pickaxe, not the modem, there).
        local flow, eq, gf, ls = loadFlow(
            { left = eqm.ITEMS.CHUNKY, right = eqm.ITEMS.MODEM }, inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky") ~= nil, true)
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem restored at the end")
        assert_eq(ls.hasPlaced(), false)
    end,

    -- Mutation target (fix pass 3, mutation 1 of 5): deleting the
    -- `retrieval_equipment_invalid` invariant just before turtle.dig().
    -- Simulates a hypothetical equipment.lua bug -- retrievalSwapIn
    -- reporting success without actually leaving chunky equipped -- to
    -- prove this invariant, not any upstream equipment call's own claim, is
    -- what actually gates the dig.
    ["retrieveLoader refuses to dig if the chunky+pickaxe invariant isn't actually satisfied, whatever an upstream equipment call claims"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv(); inv[2] = nil
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        eq.retrievalSwapIn = function() return true end -- lies: chunky never actually equipped

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "retrieval_equipment_invalid")
        assert_eq(world["0,80,-1"], eqm.ITEMS.LOADER_TURTLE,
            "must never dig without the invariant actually holding")
    end,

    -- Finding 2 (fix pass 3 review) / mutation target (mutation 2 of 5):
    -- a dig that returns true (the block IS gone) but nothing matching the
    -- loader turtle's name turns up in inventory afterward -- in real
    -- CC:Tweaked this is a completely full inventory silently destroying
    -- the drop. The chunk is definitively no longer held and chunky is
    -- already equipped, so the fence must release -- but the record must
    -- survive: a physical loader turtle really is lost, which is exactly
    -- what an operator needs to be told, not have silently cleared. This is
    -- also the third of the three checks fix pass 2's Critical fix was
    -- required to have -- nothing before this pass constrained it.
    ["retrieveLoader releases the fence but keeps the record when the loader can't be found in inventory after a successful dig"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        gf.setAnchorChunk(0, 0, 1)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        -- Force "the block is gone, but nothing came back" directly: real
        -- dig() would need a completely full inventory to reproduce this,
        -- which this module makes no assumption about the exact cause of --
        -- only that it is handled correctly when it happens.
        local origDig = turtle.dig
        turtle.dig = function()
            local ok = origDig()
            eq.findSlot = function() return nil end -- nothing "found" from here on
            return ok
        end

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_lost_after_dig")
        assert_eq(gf.isActive(), false, "nothing holds that chunk anymore -- release it")
        assert_eq(ls.hasPlaced(), true,
            "a real loader turtle is genuinely lost -- an operator needs to see this, not have it silently cleared")
    end,

    ["retrieveLoader aborts before digging if chunky is not carried, leaving the loader standing"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv(); inv[2] = nil; inv[3] = nil
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "chunky_missing")
        assert_eq(world["0,80,-1"], eqm.ITEMS.LOADER_TURTLE,
            "loader must still be standing -- never dig it up without chunky in hand")
        assert_eq(ls.hasPlaced(), true, "nothing was retrieved -- the record must survive")
    end,

    -- Finding 1 (review fix pass 2, reproduction A): turtle.detect() alone
    -- only proves SOMETHING is in front of the miner. Here the real loader
    -- is genuinely standing at its recorded position (0,80,-1), but the
    -- miner is turned to face a completely different, plain block. The old
    -- code would have dug that block, called it a successful retrieval, and
    -- abandoned the real loader forever.
    ["retrieveLoader refuses when the recorded loader position doesn't match what's ahead of the miner"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv(); inv[2] = nil
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        -- Miner faces south (facing=2): ahead is (0,80,1), a plain stone
        -- block. The real loader is recorded at (0,80,-1) -- behind the
        -- miner, not ahead of it.
        local world = { ["0,80,1"] = "minecraft:stone", ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls, c = loadFlow(E_MINE(), inv, world)
        c.pos.facing = 2
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_position_mismatch")
        assert_eq(world["0,80,1"], "minecraft:stone", "the stone must never be dug")
        assert_eq(world["0,80,-1"], eqm.ITEMS.LOADER_TURTLE, "the real loader must be left alone")
        assert_eq(ls.hasPlaced(), true, "the real loader is still out there -- the record must survive")
    end,

    -- Finding 1 (review fix pass 2, reproduction B): the position matches
    -- the record exactly, but the block actually there is not a loader
    -- turtle -- turtle.detect() can't tell that apart from the real thing;
    -- turtle.inspect()'s reported name can.
    ["retrieveLoader refuses when the block ahead matches the recorded position but is not a loader turtle"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv(); inv[2] = nil
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = "minecraft:stone" } -- right position, wrong block
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_not_in_front")
        assert_eq(world["0,80,-1"], "minecraft:stone", "must never dig a block that isn't the loader")
        assert_eq(ls.hasPlaced(), true)
    end,

    ["retrieveLoader leaves the loader_state record intact when the dig itself fails"] = function(assert_eq)
        -- Force turtle.dig() to fail its own "no space for the item" path
        -- (distinct from the chunky_missing pre-check above) by filling
        -- every slot but one with an unrelated, maxed-out stack, leaving no
        -- home for the dug loader-turtle item and no empty slot either.
        local eqm = require("equipment")
        local inv = {}
        for s = 1, 15 do inv[s] = { name = "minecraft:cobblestone", count = 64 } end
        inv[16] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_dig_failed")
        assert_eq(world["0,80,-1"], eqm.ITEMS.LOADER_TURTLE,
            "a failed dig must not remove the block")
        assert_eq(ls.hasPlaced(), true,
            "a mid-retrieval failure must leave the persisted record intact")
    end,

    ["retrieveLoader refuses if the loader is not actually in front"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv(); inv[2] = nil
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, {})
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_not_in_front")
        assert_eq(ls.hasPlaced(), true)
    end,

    -- Finding 6 (review fix pass 2): a dig that succeeds but is followed by
    -- a comms swap-out failure used to be indistinguishable from a failed
    -- dig (same generic path), and left the fence armed around a chunk with
    -- no loader in it -- the record and the fence both need to reflect
    -- reality (loader recovered) as soon as that's known, independent of
    -- whether the equipment swap back to comms succeeds.
    ["retrieveLoader returns a distinct reason when the loader is recovered but the comms swap-out fails, and releases the fence anyway"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        gf.setAnchorChunk(0, 0, 1)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        -- Force a deeper equipment fault on the comms swap-out specifically,
        -- AFTER a normal, successful dig.
        eq.retrievalSwapOut = function() return false, "forced failure" end

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_recovered_comms_down")
        assert_eq(eq.findSlot(eqm.ITEMS.LOADER_TURTLE) ~= nil, true,
            "the loader really is back in inventory")
        assert_eq(ls.hasPlaced(), false,
            "the loader is no longer standing anywhere -- the record must not survive")
        assert_eq(gf.isActive(), false,
            "nothing holds that chunk anymore -- the fence must not still claim it does")
    end,

    -- ─── adoptRecordedLoader (minor point 4, fix pass 3) ────────────────

    ["adoptRecordedLoader re-establishes beacon tracking from the persisted record after a simulated reboot"] = function(assert_eq)
        -- _expectedLoaderPos is in-memory only, so a fresh mine_flow require
        -- (simulating a reboot) starts with it nil even though the loader
        -- is still genuinely placed and beaconing. Without adopting the
        -- persisted record first, noteBeacon is a permanent no-op.
        local eqm = require("equipment")
        local flow, eq, gf, ls = loadFlow(E_MINE(), travelInv(), {})
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        -- Before adopting: a correctly-positioned beacon is still ignored.
        flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_LANDING } })
        assert_eq(flow.beaconSeenWithin(9999), false)

        local ok = flow.adoptRecordedLoader()
        assert_eq(ok, true)
        flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_LANDING } })
        assert_eq(flow.beaconSeenWithin(9999), true,
            "after adopting the persisted record, a matching beacon must register")
    end,

    ["adoptRecordedLoader refuses when there is nothing persisted to adopt"] = function(assert_eq)
        local flow = loadFlow(E_MINE(), travelInv(), {})
        local ok, reason = flow.adoptRecordedLoader()
        assert_eq(ok, false)
        assert_eq(reason, "no_loader_recorded")
    end,

    -- ─── retrieveLoader: normalising the loader back into slot 2 ──────────
    -- Field defect: turtle.dig() deposits the retrieved loader into whatever
    -- slot real CC:Tweaked's inventory-add algorithm picks (typically the
    -- currently-selected tool slot, or the first free slot it can find) --
    -- never necessarily equipment.SLOTS.LOADER (slot 2). Left uncorrected,
    -- the loader permanently occupies a mining slot (reducing ore capacity)
    -- while slot 2 sits empty, and the next boot's initProtectedSlots can no
    -- longer populate protectedSlotNames[S_LOADER], degrading rescue.

    ["retrieveLoader normalises the loader into slot 2 when the dig lands it in a mining slot"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil -- loader placed, not carried
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        -- Force the dug loader to land in a mining slot (6) rather than its
        -- home slot (2), reproducing the field-observed outcome directly
        -- rather than depending on exactly which slot the stub's own
        -- dig()-collection scan happens to pick.
        local origDig = turtle.dig
        turtle.dig = function()
            local ok = origDig()
            if ok then
                for s = 1, 16 do
                    local it = turtle.getItemDetail(s)
                    if it and it.name == eqm.ITEMS.LOADER_TURTLE and s ~= 6 then
                        turtle.select(s)
                        turtle.transferTo(6)
                        break
                    end
                end
            end
            return ok
        end

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        local home = turtle.getItemDetail(eq.SLOTS.LOADER)
        assert_eq(home ~= nil and home.name, eqm.ITEMS.LOADER_TURTLE,
            "loader must be normalised back into equipment.SLOTS.LOADER")
        assert_eq(turtle.getItemDetail(6), nil,
            "the mining slot it landed in must be empty once normalised")
    end,

    ["retrieveLoader leaves the loader alone when it already dug straight into slot 2"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil -- loader placed, not carried
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        -- The stub's own dig()-collection scan already lands the loader in
        -- slot 2 here (it is the lowest empty slot at dig time), so this
        -- exercises the true no-op path. Proven by making any transferTo
        -- call an error: normalisation must not even attempt to move
        -- anything once the loader is already home.
        turtle.transferTo = function()
            error("transferTo must not be called -- the loader is already in slot 2")
        end

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        local home = turtle.getItemDetail(eq.SLOTS.LOADER)
        assert_eq(home ~= nil and home.name, eqm.ITEMS.LOADER_TURTLE)
    end,

    ["retrieveLoader relocates an occupant already sitting in slot 2 rather than destroying it, then moves the loader home"] = function(assert_eq)
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = { name = "minecraft:cobblestone", count = 5 } -- occupies the loader's home slot
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf, ls = loadFlow(E_MINE(), inv, world)
        ls.record(0, 80, -1, { cx = 0, cz = -1 }, 1)

        -- Force the dug loader to land somewhere other than slot 2 (which
        -- is unavailable anyway, since it's occupied), landing in slot 6.
        local origDig = turtle.dig
        turtle.dig = function()
            local ok = origDig()
            if ok then
                for s = 1, 16 do
                    local it = turtle.getItemDetail(s)
                    if it and it.name == eqm.ITEMS.LOADER_TURTLE and s ~= 6 then
                        turtle.select(s)
                        turtle.transferTo(6)
                        break
                    end
                end
            end
            return ok
        end

        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)

        local home = turtle.getItemDetail(eq.SLOTS.LOADER)
        assert_eq(home ~= nil and home.name, eqm.ITEMS.LOADER_TURTLE,
            "loader must end up in its home slot even though something else was sitting there")

        -- The displaced cobblestone must survive somewhere, never be
        -- dropped or overwritten.
        local foundCobble, cobbleCount = false, 0
        for s = 1, 16 do
            local it = turtle.getItemDetail(s)
            if it and it.name == "minecraft:cobblestone" then
                foundCobble = true
                cobbleCount = cobbleCount + it.count
            end
        end
        assert_eq(foundCobble, true, "the slot-2 occupant must be relocated, not destroyed")
        assert_eq(cobbleCount, 5, "not a single item of the occupant may be lost")
    end,
}
