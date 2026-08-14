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

-- mine_flow.noteBeacon/beaconSeenWithin stamp os.epoch("utc"). stub_cc does
-- not model the real-time clock (only turtle/peripheral/os.pullEvent/
-- textutils), so provide the same fallback tests/test_loader_state.lua and
-- tests/test_bypass_geofence.lua use for the same gap.
os.epoch = os.epoch or function() return os.time() * 1000 end

local function freshModules()
    package.loaded["equipment"]    = nil
    package.loaded["geofence"]     = nil
    package.loaded["loader_state"] = nil
    package.loaded["mine_flow"]    = nil
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

    -- ─── Beacon gate ────────────────────────────────────────────────────

    ["placeLoader refuses to give up chunky if no beacon arrives before the deadline"] = function(assert_eq)
        -- No pumpFactory: default pump is a no-op, so no beacon ever arrives.
        local flow, eq, gf, ls = loadFlow(
            E_TRAVEL(), travelInv())
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_no_beacon")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must stay on -- the loader never proved it's alive")
        assert_eq(gf.isActive(), false, "fence must never arm around an unconfirmed loader")
        assert_eq(ls.hasPlaced(), true,
            "the loader really is standing there -- still recorded for recovery")
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
        local flow, eq = loadFlow(E_TRAVEL(), travelInv())
        flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_LANDING } })
        -- default pump is a no-op: no FRESH beacon ever arrives
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
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
}
