-- Task 11: end-to-end harness run -- Invariant A, mechanised.
--
--   At every instant, either the miner's own chunky upgrade is equipped, OR a
--   placed loader is standing inside the ARMED geofence (with the miner itself
--   inside that fence).
--
-- Anything else means the miner can freeze in the field: losing comms is
-- self-correcting, losing chunk loading outside the base-loaded area needs a
-- player to fly out to the turtle.
--
-- ore_turtle.lua cannot be require()d here -- it self-executes and ends in
-- os.reboot() -- so this drives the modules it composes (mine_flow, equipment,
-- geofence, loader_state) through the same sequence ore_turtle's mineJob does,
-- with its geometry constants (SKY_Y, SURVEY_TRAVEL_Y, STAND_OFFSET,
-- PLACE_FACING, FENCE_CHUNK_RADIUS) copied verbatim, and with its soloReturn /
-- prepareToFly / approachFor orchestration mirrored below.
--
-- TWO DEVIATIONS FROM THE BRIEF'S assertLoaded SKETCH, both strengthening it:
--
--   1. The sketch tests `gf.contains(x, z)` for the loader without first
--      testing `gf.isActive()`. geofence.contains() returns TRUE for every
--      coordinate when no anchor is set (geofence.lua:47), so an unarmed fence
--      would make ANY standing loader anywhere in the world satisfy the
--      invariant -- including a fence that was wrongly cleared while chunky was
--      still stowed, which is precisely mutation M3 below. As written the
--      sketch cannot catch that. loaderInFence() gates on isActive() first.
--
--   2. A loader standing inside the fence only protects a miner that is ALSO
--      inside it, so whenever chunky is off the miner's own position is checked
--      against the fence too.
--
-- AND ONE ADDITION: end-state assertions do not constrain ordering (this
-- project has already shipped five tests that passed against broken code for
-- exactly that reason). So beyond calling sim.at() after every transition, the
-- harness wraps every turtle primitive that touches the world -- dig, digDown,
-- place, forward, back, up, down -- and re-checks the invariant immediately
-- BEFORE and AFTER each one. Correct code never performs a physical action
-- while unloaded; the only windows where chunky is off and the fence is not yet
-- armed (inside placeLoader, between toMineMode and setAnchorBlock) contain no
-- physical action at all, so the probes hold for the real implementation while
-- rejecting any reordering that digs, places or moves in such a window.
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

-- Registry names, matching equipment.ITEMS verbatim. The stub's equipped/
-- inventory tables are keyed by registry name only; short kinds like "chunky"
-- do not exist in the world.
local MODEM   = "computercraft:wireless_modem_advanced"
local CHUNKY  = "advancedperipherals:chunk_controller"
local PICKAXE = "minecraft:diamond_pickaxe"
local LOADER  = "computercraft:turtle_advanced"
local SCANNER = "advancedperipherals:geo_scanner"

-- stub_cc models turtle/peripheral/fs/os.pullEvent but not the wall clock;
-- same fallback tests/test_mine_flow.lua uses for the same gap.
os.epoch = os.epoch or function() return os.time() * 1000 end

-- ── Geometry, copied from ore_turtle.lua ────────────────────────────────────
local FENCE_CHUNK_RADIUS = 1     -- ore_turtle.lua:75
local SKY_Y              = 200   -- ore_turtle.lua:59
local TRAVEL_Y           = 175   -- ore_turtle.lua:60 (SURVEY_TRAVEL_Y)
local STAND_OFFSET       = 8     -- ore_turtle.lua:83
local PLACE_FACING       = 2     -- ore_turtle.lua:88 (south => loader lands at z+1)
local SCAN_Y             = 16    -- ore_turtle.lua:108 (SCAN_LEVELS[1])

local DOCK   = { x = 60, y = 64, z = 60 }
local SECTOR = { x = 0, z = 0 }
local STAND  = { x = SECTOR.x + STAND_OFFSET, z = SECTOR.z + STAND_OFFSET }
-- Facing south from (8,175,8) puts the loader on (8,175,9) -- chunk 0,0, which
-- is chunkOf(sectorX, sectorZ), the anchor chunk the sector requires.
local LOADER_POS   = { x = STAND.x, y = TRAVEL_Y, z = STAND.z + 1 }
local ANCHOR_CHUNK = { cx = 0, cz = 0 }

local function freshModules()
    package.loaded["equipment"]    = nil
    package.loaded["geofence"]     = nil
    package.loaded["loader_state"] = nil
    package.loaded["mine_flow"]    = nil
end

-- Controllable fake clock, so the tests that wait out mine_flow's real 15s
-- BEACON_WAIT_SECONDS deadline don't block the runner for 15 real seconds.
-- restore() must be reached on every path (callers use straight-line code, not
-- pcall/finally), or the fake clock leaks into later tests.
local function fakeClock(startSeconds)
    local now  = startSeconds
    local orig = os.epoch
    os.epoch = function() return now * 1000 end
    return {
        advance = function(by) now = now + (by or 0) end,
        restore = function() os.epoch = orig end,
    }
end

local function travelInv()
    return {
        [1]  = { name = SCANNER, count = 1 },
        [2]  = { name = LOADER,  count = 1 },
        [3]  = { name = PICKAXE, count = 1 },
        [14] = { name = "minecraft:coal", count = 32 },
        [15] = { name = "enderstorage:ender_chest", count = 1 },
        [16] = { name = "enderstorage:ender_chest", count = 1 },
    }
end

-- A loader that beacons its position on every poll, like a real one does once
-- it has booted. `clock` (optional) advances simulated wall time per poll, which
-- only matters for a beacon that will never satisfy the gate -- mine_flow keeps
-- polling to its deadline in that case.
local function beaconingLoader(position, clock)
    return function(flow)
        return function(pollSeconds)
            if clock then clock.advance(pollSeconds or 1) end
            flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = position } })
        end
    end
end

-- A pump that never beacons but burns ~1s of simulated wall clock per call,
-- like a real proto.receive-backed pump blocking on os.pullEvent.
local function neverBeaconPump(clock)
    return function()
        return function(pollSeconds) clock.advance(pollSeconds or 1) end
    end
end

-- ── The invariant ───────────────────────────────────────────────────────────

-- Is a loader turtle physically standing inside the ARMED fence? isActive()
-- first: geofence.contains() answers true for everything when nothing is
-- anchored, so without this gate an unarmed fence would satisfy the invariant
-- for free (see the header).
local function loaderInFence(eq, gf, world)
    if not gf.isActive() then return false end
    for k, v in pairs(world) do
        if v == eq.ITEMS.LOADER_TURTLE then
            local x, _, z = k:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
            if x and gf.contains(tonumber(x), tonumber(z)) then return true end
        end
    end
    return false
end

-- ── Simulated miner ─────────────────────────────────────────────────────────

-- ore_turtle.lua's approachFor: the square to stand on to dig the loader back
-- up, and the facing to do it from. Approaches from the side we are already
-- on, so the leg in never passes through the loader itself.
local function approachFor(rec, from)
    if from.z > rec.z then return rec.x, rec.y, rec.z + 1, 0 end
    if from.z < rec.z then return rec.x, rec.y, rec.z - 1, 2 end
    if from.x > rec.x then return rec.x + 1, rec.y, rec.z, 3 end
    return rec.x - 1, rec.y, rec.z, 1
end

local function newSim(assert_eq, o)
    o = o or {}
    freshModules()
    local c = stub.install({
        equipped  = o.equipped or { left = MODEM, right = CHUNKY },
        inv       = o.inv or travelInv(),
        world     = o.world or {},
        pos       = o.pos or { x = DOCK.x, y = DOCK.y, z = DOCK.z, facing = 0 },
        equipFail = o.equipFail,
    })
    -- Carry a previous install's on-disk files across a simulated reboot: the
    -- fs table is per-install, but loader_state.dat is exactly the thing that
    -- is supposed to survive one.
    if o.files then for k, v in pairs(o.files) do c.files[k] = v end end

    local eq   = require("equipment")
    local gf   = require("geofence")
    local ls   = require("loader_state")
    if not o.files then ls.clear() end
    local flow = require("mine_flow")

    local sim = { c = c, eq = eq, gf = gf, ls = ls, flow = flow, phases = {} }

    function sim.phase(name) sim.phases[#sim.phases + 1] = name end
    function sim.phaseSeq() return table.concat(sim.phases, ">") end

    flow.setHooks({
        pos         = function() return c.pos end,
        pump        = o.pump and o.pump(flow) or beaconingLoader(LOADER_POS)(flow),
        log         = function() end,
        reportPhase = function(p) sim.phase(p) end,
    })

    -- Invariant A. Called after every transition below, and before/after every
    -- physical turtle action by the probes.
    function sim.at(label)
        local selfLoaded = eq.sideOf("chunky") ~= nil
        local loaderDown = loaderInFence(eq, gf, c.world)
        assert_eq(selfLoaded or loaderDown, true, "Invariant A breached at: " .. label)
        if not selfLoaded then
            assert_eq(gf.contains(c.pos.x, c.pos.z), true,
                "miner is outside the fence it is relying on at: " .. label)
        end
    end

    -- Every turtle call that touches the world, checked on both sides. See the
    -- file header for why this is the assertion that constrains ordering.
    for _, name in ipairs({ "dig", "digDown", "place", "forward", "back", "up", "down" }) do
        local orig = turtle[name]
        turtle[name] = function(...)
            sim.at("before turtle." .. name .. "()")
            local a, b = orig(...)
            sim.at("after turtle." .. name .. "()")
            return a, b
        end
    end

    function sim.face(f)
        while c.pos.facing ~= f do turtle.turnRight() end
    end

    -- Ascend first, descend last, so the long lateral leg happens at the
    -- altitude we arrived at (ore_turtle.lua:1098-1105).
    local function stepped(ok, what)
        if not ok then error("simulated movement blocked going " .. what, 0) end
    end
    function sim.moveTo(x, y, z)
        while c.pos.y < y do stepped(turtle.up(), "up") end
        while c.pos.x < x do sim.face(1); stepped(turtle.forward(), "+x") end
        while c.pos.x > x do sim.face(3); stepped(turtle.forward(), "-x") end
        while c.pos.z < z do sim.face(2); stepped(turtle.forward(), "+z") end
        while c.pos.z > z do sim.face(0); stepped(turtle.forward(), "-z") end
        while c.pos.y > y do stepped(turtle.down(), "down") end
    end

    -- ore_turtle.lua's dumpOres, reduced to the part that matters here: it runs
    -- with the pickaxe on and chunky stowed. (The real one places and digs back
    -- an ender chest via withDigTool; the ender-chest mechanics are covered by
    -- tests/test_delivery_support.lua and add nothing to Invariant A.)
    -- Only mined ore leaves the inventory. ore_turtle protects its own slots
    -- via initProtectedSlots(); dumping the carried loader turtle (which lands
    -- in a "free" slot after retrieval) would be a different bug entirely.
    local KEEP = { [SCANNER] = true, [LOADER] = true, [PICKAXE] = true,
                   [CHUNKY] = true, [MODEM] = true }
    function sim.dumpOres()
        sim.phase("DUMPING")
        for s = 1, 16 do
            local it = c.inv[s]
            if it and not KEEP[it.name] and it.name:find("ore") then
                turtle.select(s); turtle.drop()
            end
        end
    end

    return sim
end

-- ore_turtle.lua's prepareToFly: never fly anywhere without our own chunk
-- loading. Give up the MODEM's side for it (comms are recoverable), falling
-- back to the pickaxe's side -- loaded and unable to dig still beats unloaded.
local function prepareToFly(sim)
    if sim.eq.sideOf("chunky") then return true end
    if sim.eq.retrievalSwapIn() then return true end
    return sim.eq.toTravelMode()
end

-- ore_turtle.lua's soloReturn: dump, take the loader back if one is still out,
-- restore our own chunk loading, and only THEN release the fence and fly.
--
-- MUTATION TARGET M3: releasing the fence before chunky is back (or flying
-- anyway when it could not be restored) is exactly the "unloaded and outside
-- the loaded area" state Invariant A forbids.
local function soloReturn(sim, assert_eq)
    sim.phase("RETURNING")
    sim.dumpOres()
    sim.at("ores dumped")

    if sim.ls.hasPlaced() then
        local rec = sim.ls.get()
        local sx, sy, sz, facing = approachFor(rec, sim.c.pos)
        sim.moveTo(sx, sy, sz)
        sim.face(facing)
        sim.at("standing at the loader's retrieval square")
        local ok, reason = sim.flow.retrieveLoader()
        sim.at("after retrieval attempt: " .. tostring(ok) .. "/" .. tostring(reason))
    end

    local flyable = prepareToFly(sim)
    sim.at("after prepareToFly")
    if not flyable then
        -- Chunky could not be restored. If a loader is still standing, that
        -- fence is now the ONLY thing keeping us inside loaded chunks; clearing
        -- it and flying is the unrecoverable freeze. Stay parked instead.
        return false
    end
    sim.gf.clear()
    sim.at("fence released for the flight home")
    sim.moveTo(sim.c.pos.x, SKY_Y, sim.c.pos.z)
    sim.moveTo(DOCK.x, SKY_Y, DOCK.z)
    sim.moveTo(DOCK.x, DOCK.y, DOCK.z)
    sim.at("docked")
    sim.phase("DOCKED")
    return true
end

-- Depart the base and fly to the sector's standing square, facing the block the
-- loader will be placed on.
local function departAndTravel(sim)
    sim.phase("DEPARTING")
    sim.at("docked, travel mode, nothing placed")
    sim.moveTo(DOCK.x, SKY_Y, DOCK.z)
    sim.at("ascended to sky altitude")
    sim.phase("TRAVELLING")
    sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
    sim.face(PLACE_FACING)
    sim.at("arrived at the sector standing square")
end

-- Descend, mine the two ore blocks below, dump. Runs entirely with chunky
-- stowed and the pickaxe on -- the whole window the placed loader is covering.
local function scanAndMine(sim, assert_eq)
    sim.phase("SCANNING")
    sim.moveTo(SECTOR.x, SCAN_Y, SECTOR.z)
    sim.at("descended to the scan level")
    assert_eq(sim.flow.beaconSeenWithin(240), true,
        "the loader must still be proving it is alive while we are relying on it")

    sim.phase("MINING")
    assert_eq(turtle.digDown(), true, "first ore")
    sim.at("first ore dug")
    assert_eq(turtle.down(), true, "descend into the first ore's slot")
    sim.at("descended into the shaft")
    assert_eq(turtle.digDown(), true, "second ore")
    sim.at("second ore dug")
    assert_eq(turtle.down(), true, "descend again")
    sim.at("bottom of the shaft")

    sim.dumpOres()
    sim.at("ores dumped mid-sector")
end

local function oreWorld()
    return {
        ["0,15,0"] = "minecraft:iron_ore",
        ["0,14,0"] = "minecraft:diamond_ore",
    }
end

return {

    -- ─── The full cycle ─────────────────────────────────────────────────────

    ["invariant A holds at every step of a full sector cycle"] = function(assert_eq)
        local sim = newSim(assert_eq, { world = oreWorld() })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow

        departAndTravel(sim)
        assert_eq(eq.sideOf("chunky") ~= nil, true, "travel mode is self-loaded")
        assert_eq(gf.isActive(), false, "no fence needed while we carry our own chunky")

        -- place + swap: the one hand-over where chunk duty changes owner.
        local placed, placeErr = flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK)
        assert_eq(placed, true, placeErr)
        sim.at("loader placed, fence armed, chunky handed over")
        assert_eq(eq.sideOf("chunky"), nil, "chunky is stowed for the mining window")
        assert_eq(eq.sideOf("pickaxe") ~= nil, true)
        assert_eq(gf.isActive(), true)
        assert_eq(gf.anchor().cx, ANCHOR_CHUNK.cx)
        assert_eq(gf.anchor().cz, ANCHOR_CHUNK.cz)
        assert_eq(sim.c.world[LOADER_POS.x .. "," .. LOADER_POS.y .. "," .. LOADER_POS.z], LOADER,
            "the loader is physically standing where placeLoader said it landed")
        assert_eq(ls.hasPlaced(), true)

        scanAndMine(sim, assert_eq)

        -- Retrieve from the exact square we placed from (ore_turtle keeps it in
        -- `stand`), which is what mine_flow's position check demands.
        sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
        sim.face(PLACE_FACING)
        sim.at("back at the standing square, still fenced")
        local got, retErr = flow.retrieveLoader()
        assert_eq(got, true, retErr)
        sim.at("loader retrieved, self-loading restored")
        assert_eq(eq.sideOf("chunky") ~= nil, true)
        assert_eq(eq.sideOf("modem") ~= nil, true, "comms back after the retrieval window")
        assert_eq(gf.isActive(), false, "fence released only once we are self-loaded again")
        assert_eq(ls.hasPlaced(), false)
        assert_eq(sim.c.world[LOADER_POS.x .. "," .. LOADER_POS.y .. "," .. LOADER_POS.z], nil,
            "nothing left standing in the sector")

        assert_eq(soloReturn(sim, assert_eq), true)
        assert_eq(eq.validate("travel"), true, "docked back in travel mode with the loader aboard")

        -- Ordering, not just end state: the phases must have happened in this
        -- sequence. PLACING_LOADER/SWAP_TO_PICKAXE/RETRIEVING come from
        -- mine_flow itself via the reportPhase hook.
        assert_eq(sim.phaseSeq(),
            "DEPARTING>TRAVELLING>PLACING_LOADER>SWAP_TO_PICKAXE>SCANNING>MINING>" ..
            "DUMPING>RETRIEVING>RETURNING>DUMPING>DOCKED")
    end,

    ["invariant A holds across two consecutive sectors without returning to base"] = function(assert_eq)
        -- The between-sectors seam: chunk duty goes back to our own upgrade and
        -- out again to a fresh placement, with no dock visit to reset anything.
        local sim = newSim(assert_eq, { world = oreWorld() })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow

        departAndTravel(sim)
        assert_eq(flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK), true)
        sim.at("sector 1: loader placed")
        scanAndMine(sim, assert_eq)
        sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
        sim.face(PLACE_FACING)
        assert_eq(flow.retrieveLoader(), true)
        sim.at("sector 1 complete, self-loaded again")

        -- Sector 2, same square (the geometry is what is being reused; a real
        -- second sector is 32 blocks over and identical in every other way).
        assert_eq(eq.validate("travel"), true, "next sector must start in travel mode")
        local placed2, err2 = flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK)
        assert_eq(placed2, true, err2)
        sim.at("sector 2: loader placed")
        assert_eq(gf.isActive(), true)
        assert_eq(ls.hasPlaced(), true)

        sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
        sim.face(PLACE_FACING)
        assert_eq(flow.retrieveLoader(), true)
        sim.at("sector 2 complete")
        assert_eq(soloReturn(sim, assert_eq), true)
        assert_eq(eq.validate("travel"), true)
    end,

    -- ─── Placement refused: chunk duty must never change hands ──────────────

    ["a placement refused for the wrong anchor chunk leaves the miner self-loading and unfenced, and it flies home"] = function(assert_eq)
        local sim = newSim(assert_eq, {})
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow
        departAndTravel(sim)

        -- The sector demands a chunk this standing square cannot reach.
        local ok, reason = flow.placeLoader(FENCE_CHUNK_RADIUS, { cx = 5, cz = 5 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_target_wrong_chunk")
        sim.at("placement refused: wrong anchor chunk")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must not be surrendered")
        assert_eq(gf.isActive(), false, "no loader out there, so nothing to fence")
        assert_eq(eq.findSlot(LOADER) ~= nil, true, "loader still carried, not dropped")
        assert_eq(ls.hasPlaced(), false)

        assert_eq(soloReturn(sim, assert_eq), true)
        assert_eq(eq.validate("travel"), true)
    end,

    ["a placement whose loader never beacons leaves chunky on and the fence unarmed, and the loader is collected on the way home"] = function(assert_eq)
        local clock = fakeClock(1000)
        local sim = newSim(assert_eq, { pump = neverBeaconPump(clock) })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow
        departAndTravel(sim)

        local ok, reason = flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK)
        clock.restore()
        assert_eq(ok, false)
        assert_eq(reason, "loader_no_beacon")
        sim.at("placement refused: the loader never proved it was alive")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "an unproven loader must never buy our own chunk loading")
        assert_eq(gf.isActive(), false, "never fence around an unconfirmed loader")
        -- It IS physically standing there, so the record must survive for the
        -- recovery pass soloReturn is about to run.
        assert_eq(ls.hasPlaced(), true)

        assert_eq(soloReturn(sim, assert_eq), true)
        assert_eq(ls.hasPlaced(), false, "soloReturn collected it on the way out")
        assert_eq(eq.findSlot(LOADER) ~= nil, true, "and it came home with us")
        assert_eq(eq.validate("travel"), true)
    end,

    ["a beacon from somebody else's loader does not buy our chunk loading"] = function(assert_eq)
        -- A second loader in radio range: a neighbouring miner's sector, or an
        -- orphan left standing from an earlier failure. Proof that SOME loader
        -- is alive is never proof that OURS is.
        local clock = fakeClock(1000)
        local sim = newSim(assert_eq,
            { pump = beaconingLoader({ x = 999, y = 80, z = 999 }, clock) })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow
        departAndTravel(sim)

        local ok, reason = flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK)
        clock.restore()
        assert_eq(ok, false)
        assert_eq(reason, "loader_beacon_mismatch")
        sim.at("placement refused: beacon position mismatch")
        assert_eq(eq.sideOf("chunky") ~= nil, true)
        assert_eq(gf.isActive(), false)
        assert_eq(ls.hasPlaced(), true)

        assert_eq(soloReturn(sim, assert_eq), true)
        assert_eq(ls.hasPlaced(), false)
        assert_eq(eq.validate("travel"), true)
    end,

    -- ─── Retrieval refused: the loader stays standing, the fence stays up ───

    ["retrieval is refused before digging when chunky cannot be restored, and the miner stays fenced rather than flying home unloaded"] = function(assert_eq)
        local sim = newSim(assert_eq, { world = oreWorld() })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow
        departAndTravel(sim)
        assert_eq(flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK), true)
        scanAndMine(sim, assert_eq)

        -- The chunky item goes missing mid-sector (dropped, or lost to a full
        -- inventory on some other path). Now nothing can restore self-loading.
        local cSlot = eq.findSlot(CHUNKY)
        assert_eq(cSlot ~= nil, true, "test setup: chunky is stowed during mining")
        sim.c.inv[cSlot] = nil

        sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
        sim.face(PLACE_FACING)
        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "chunky_missing")
        sim.at("retrieval refused: chunky cannot be restored")
        assert_eq(sim.c.world[LOADER_POS.x .. "," .. LOADER_POS.y .. "," .. LOADER_POS.z], LOADER,
            "never dig the loader up without chunky in hand -- it is the only thing loading us")
        assert_eq(gf.isActive(), true, "the fence must still be armed: it is all we have")
        assert_eq(ls.hasPlaced(), true)

        -- soloReturn must refuse to fly: a miner parked inside a loaded
        -- footprint is recoverable, one frozen in an unloaded chunk is not.
        assert_eq(soloReturn(sim, assert_eq), false)
        sim.at("parked, still fenced, waiting for an operator")
        assert_eq(gf.isActive(), true, "the fence must not be traded for an unloaded flight")
        assert_eq(gf.contains(sim.c.pos.x, sim.c.pos.z), true, "and we are still inside it")
        assert_eq(ls.hasPlaced(), true, "the loader is genuinely still out there")
    end,

    -- ─── Equip failure part-way through the retrieval swap ──────────────────

    ["an equip failure on the retrieval swap-IN leaves the loader standing and chunky off -- the fence carries us"] = function(assert_eq)
        local sim = newSim(assert_eq, { world = oreWorld() })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow
        departAndTravel(sim)
        assert_eq(flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK), true)
        scanAndMine(sim, assert_eq)

        -- Mine mode is modem(left) + pickaxe(right), so retrievalSwapIn puts
        -- chunky on the MODEM's side. Break exactly that equip.
        assert_eq(eq.sideOf("modem"), "left", "test setup: modem is on the left in mine mode")
        sim.c.equipFail.left = true

        sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
        sim.face(PLACE_FACING)
        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason ~= nil and reason:match("^equip_failed") ~= nil, true,
            "expected an equip_failed reason, got " .. tostring(reason))
        sim.at("retrieval aborted mid-swap")
        assert_eq(eq.sideOf("chunky"), nil, "the swap never landed")
        assert_eq(sim.c.world[LOADER_POS.x .. "," .. LOADER_POS.y .. "," .. LOADER_POS.z], LOADER,
            "the loader must still be standing -- it is the only thing loading this chunk")
        assert_eq(gf.isActive(), true, "and the fence must still be armed around it")
        assert_eq(ls.hasPlaced(), true)

        -- prepareToFly's documented fallback: the modem side is broken, so take
        -- the PICKAXE's side for chunky instead. Loaded and unable to dig still
        -- beats unloaded, so we can fly home -- leaving the loader behind, which
        -- is the loss an operator has to be told about.
        assert_eq(soloReturn(sim, assert_eq), true)
        assert_eq(eq.sideOf("chunky"), "right", "chunky took the pickaxe's side")
        assert_eq(ls.hasPlaced(), true, "loader_left_behind: the record must survive")
    end,

    ["an equip failure on the retrieval swap-OUT still ends self-loaded, with the loader recovered and comms down"] = function(assert_eq)
        local sim = newSim(assert_eq, { world = oreWorld() })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow
        departAndTravel(sim)
        assert_eq(flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK), true)
        scanAndMine(sim, assert_eq)

        -- Break the side the modem comes back onto: swap-in (left) succeeds,
        -- the dig succeeds, and only the comms restore fails.
        sim.c.equipFail.right = true

        sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
        sim.face(PLACE_FACING)
        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_recovered_comms_down")
        sim.at("loader recovered, comms down")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunk loading is the one thing never given up")
        assert_eq(eq.sideOf("modem"), nil, "comms really are down -- that is the recoverable half")
        assert_eq(eq.findSlot(LOADER) ~= nil, true, "the loader is back in inventory")
        assert_eq(ls.hasPlaced(), false, "nothing is standing out there anymore")
        assert_eq(gf.isActive(), false, "so the fence must not still claim there is")

        assert_eq(soloReturn(sim, assert_eq), true)
        sim.at("home, offline but loaded")
    end,

    -- Regression, found by this harness: equipment.lua's swap() used
    -- `(side == "left") and turtle.equipLeft() or turtle.equipRight()`, which
    -- runs equipRight() whenever equipLeft() returns FALSE -- silently equipping
    -- onto the opposite side and reporting success. With the upgrade sides
    -- mirrored (chunky left / modem right in travel mode), retrievalSwapOut
    -- puts the modem back on the LEFT, so a failed equip there landed the modem
    -- on chunky's side instead: chunk loading knocked off, in the field, with
    -- the loader already dug up and the fence already released. Unrecoverable
    -- freeze. Verified red against the original expression, green after.
    ["a failed equip during the retrieval swap-out never lands the modem on chunky's side"] = function(assert_eq)
        local sim = newSim(assert_eq, {
            equipped = { left = CHUNKY, right = MODEM },   -- mirrored sides
            world    = oreWorld(),
        })
        local eq, gf, ls, flow = sim.eq, sim.gf, sim.ls, sim.flow
        departAndTravel(sim)
        assert_eq(flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK), true)
        scanAndMine(sim, assert_eq)

        -- Mine mode here is pickaxe(left) + modem(right), so retrievalSwapIn
        -- puts chunky on the RIGHT and retrievalSwapOut must put the modem back
        -- on the LEFT. Break exactly that equip.
        assert_eq(eq.sideOf("pickaxe"), "left")
        assert_eq(eq.sideOf("modem"), "right")
        sim.c.equipFail.left = true

        sim.moveTo(STAND.x, TRAVEL_Y, STAND.z)
        sim.face(PLACE_FACING)
        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "loader_recovered_comms_down")
        sim.at("swap-out failed after a successful dig")
        assert_eq(eq.sideOf("chunky"), "right",
            "the modem must never be equipped over chunky -- that is the unrecoverable freeze")
        assert_eq(eq.sideOf("modem"), nil, "comms are the half we can afford to lose")
        assert_eq(eq.findSlot(LOADER) ~= nil, true, "the loader really is back aboard")

        assert_eq(soloReturn(sim, assert_eq), true)
        assert_eq(eq.sideOf("chunky") ~= nil, true, "flew home loaded, just offline")
    end,

    -- ─── Reboot mid-sector ──────────────────────────────────────────────────

    ["after a reboot mid-sector the persisted record is enough to re-establish the invariant and retrieve"] = function(assert_eq)
        local sim = newSim(assert_eq, { world = oreWorld() })
        departAndTravel(sim)
        assert_eq(sim.flow.placeLoader(FENCE_CHUNK_RADIUS, ANCHOR_CHUNK), true)
        scanAndMine(sim, assert_eq)
        assert_eq(sim.gf.isActive(), true)

        -- ── power cut ──
        -- Everything in memory dies: the geofence anchor, mine_flow's
        -- _expectedLoaderPos, loader_state's cache. The world, the inventory,
        -- the equipped upgrades and loader_state.dat survive.
        local sim2 = newSim(assert_eq, {
            world     = sim.c.world,
            inv       = sim.c.inv,
            equipped  = sim.c.equipped,
            pos       = sim.c.pos,
            files     = sim.c.files,
        })
        local eq, gf, ls, flow = sim2.eq, sim2.gf, sim2.ls, sim2.flow

        assert_eq(eq.sideOf("chunky"), nil, "the reboot left us in mine mode, not self-loading")
        assert_eq(gf.isActive(), false, "the fence is in memory only -- it is gone")
        assert_eq(ls.hasPlaced(), true, "the record is the only surviving evidence")

        -- Boot recovery. The record carries the sector and the radius, so the
        -- software half of the invariant can be rebuilt from disk BEFORE the
        -- turtle does anything physical. (ore_turtle's recoverPlacedLoader
        -- reaches the same safety by restoring chunky before it moves; the
        -- probes accept either, but nothing may move before one of them.)
        local rec = ls.get()
        assert_eq(rec.x, LOADER_POS.x); assert_eq(rec.y, LOADER_POS.y); assert_eq(rec.z, LOADER_POS.z)
        gf.setAnchorChunk(rec.sector.cx, rec.sector.cz, rec.radius)
        sim2.at("boot: fence re-armed from the persisted record")

        -- _expectedLoaderPos is in-memory only, so beacons are ignored until the
        -- record is adopted -- without this a loader that is genuinely alive
        -- reads as dead forever.
        flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_POS } })
        assert_eq(flow.beaconSeenWithin(9999), false, "not adopted yet, so nothing registers")
        assert_eq(flow.adoptRecordedLoader(), true)
        flow.noteBeacon({ type = "LOADER_BEACON", payload = { position = LOADER_POS } })
        assert_eq(flow.beaconSeenWithin(9999), true, "the loader is still alive out there")

        -- Restore self-loading before flying anywhere (mine mode -> chunky+pickaxe).
        assert_eq(eq.retrievalSwapIn(), true)
        sim2.at("boot: self-loading restored")

        local sx, sy, sz, facing = approachFor(rec, sim2.c.pos)
        sim2.moveTo(sx, sy, sz)
        sim2.face(facing)
        sim2.at("boot: standing at the recorded loader")
        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        sim2.at("boot: loader recovered")
        assert_eq(ls.hasPlaced(), false)
        assert_eq(gf.isActive(), false)
        assert_eq(eq.sideOf("chunky") ~= nil, true)
        assert_eq(eq.findSlot(LOADER) ~= nil, true)

        assert_eq(soloReturn(sim2, assert_eq), true)
        assert_eq(eq.validate("travel"), true, "home, ready for the next job")
    end,
}
