-- Task 8b: the ore_turtle -> mine_flow hook contract, at the two points where
-- it can actually be exercised headlessly.
--
-- ore_turtle.lua itself is NOT requirable under this harness (it self-executes:
-- base.init at load, then initProtectedSlots / pcall(base.run) / os.reboot at
-- the bottom), the same limitation central_server.lua has. So the job flow,
-- boot recovery and the beacon monitor are covered by inspection, not here.
-- What IS covered here is the piece the whole placement depends on and that
-- lives in a requirable module: turtle_base's tracked facing.
--
--   pos() -> { x, y, z, facing }   facing is REQUIRED. mine_flow computes the
--   block turtle.place() will fill from it, so a facing that disagrees with the
--   turtle's real heading drops the chunk loader in the wrong chunk -- the one
--   placement error that cannot be undone, since recovering it needs a pickaxe
--   the miner is not holding at that moment.
--
-- The placement tests below wire mine_flow with exactly the hooks ore_turtle
-- installs (pos from base.getPos + base.getFacing) and let the pump beacon the
-- loader's ACTUAL position as found in the stub world. That means a facing bug
-- cannot pass: mine_flow only accepts a beacon whose position matches the block
-- IT computed, so a mismatch fails the gate instead of being papered over.

package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

sleep = function() end
os.epoch = os.epoch or function() return os.time() * 1000 end

local MODULES = { "turtle_base", "mine_flow", "equipment", "geofence", "loader_state" }

local function clearModules()
    for _, m in ipairs(MODULES) do package.loaded[m] = nil end
end

local function travelInv(eq)
    return {
        [1]  = { name = eq.ITEMS.SCANNER,       count = 1 },
        [2]  = { name = eq.ITEMS.LOADER_TURTLE, count = 1 },
        [3]  = { name = eq.ITEMS.PICKAXE,       count = 1 },
        [14] = { name = "minecraft:coal",       count = 32 },
        [15] = { name = "enderstorage:ender_chest", count = 1 },
        [16] = { name = "enderstorage:ender_chest", count = 1 },
    }
end

-- Fresh stub + freshly loaded modules, with turtle_base's dead-reckoned
-- position seeded from the stub's physical one (they are separate trackers and
-- only agree if something GPS-syncs them -- same trick test_bypass_geofence
-- uses).
local function fresh()
    clearModules()
    local eq = require("equipment")
    local c  = stub.install({
        equipped = { left  = eq.ITEMS.MODEM, right = eq.ITEMS.CHUNKY },
        inv      = travelInv(eq),
        pos      = { x = 0, y = 80, z = 0, facing = 0 },
        world    = {},
    })
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    local base = require("turtle_base")
    local flow = require("mine_flow")
    local gf   = require("geofence")
    base.gpsSync()
    return c, base, flow, gf, eq
end

-- Where the stub actually put the loader turtle, read back out of the world.
local function findLoader(c, name)
    for key, block in pairs(c.world) do
        if block == name then
            local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
            if x then return tonumber(x), tonumber(y), tonumber(z) end
        end
    end
    return nil
end

-- CC's facing convention, spelled out independently of every module under test
-- so agreement between them is asserted rather than assumed.
local function aheadOf(x, z, facing)
    if facing == 0 then return x, z - 1 end
    if facing == 1 then return x + 1, z end
    if facing == 2 then return x, z + 1 end
    return x - 1, z
end

local function chunkOf(x, z) return math.floor(x / 16), math.floor(z / 16) end

local suite = {}

for _, facing in ipairs({ 0, 1, 2, 3 }) do
    suite[string.format(
        "placeLoader puts the loader on the block base.getFacing() actually points at (facing %d)",
        facing)] = function(assert_eq)
        local c, base, flow, gf, eq = fresh()

        base.move.face(facing)
        assert_eq(base.getFacing(), facing, "base did not track the turn")
        assert_eq(c.pos.facing, facing, "the turtle itself did not end up on that heading")

        -- The chunk the sector would demand: derived from the TRUE heading, so
        -- a wrong base.getFacing() shows up as loader_target_wrong_chunk.
        local ex, ez   = aheadOf(0, 0, facing)
        local acx, acz = chunkOf(ex, ez)

        flow.setHooks({
            reportPhase = function() end,
            log         = function() end,
            pos         = function()
                local p = base.getPos()
                p.facing = base.getFacing()
                return p
            end,
            -- Beacon the loader's real position, exactly as a live loader's
            -- gps.locate() would. mine_flow accepts it only if it matches the
            -- block mine_flow itself computed from pos().facing.
            pump        = function()
                local lx, ly, lz = findLoader(c, eq.ITEMS.LOADER_TURTLE)
                if lx then
                    flow.noteBeacon({
                        type    = "LOADER_BEACON",
                        payload = { position = { x = lx, y = ly, z = lz } },
                    })
                end
            end,
        })

        local ok, reason = flow.placeLoader(1, { cx = acx, cz = acz })
        assert_eq(ok, true, tostring(reason))

        local lx, ly, lz = findLoader(c, eq.ITEMS.LOADER_TURTLE)
        assert_eq(lx, ex, "loader landed at the wrong x")
        assert_eq(lz, ez, "loader landed at the wrong z")
        assert_eq(ly, 80, "loader landed at the wrong y")

        local a = gf.anchor()
        assert_eq(a ~= nil, true, "fence must be armed once the pickaxe is on")
        assert_eq(a.cx, acx, "fence anchored on the wrong chunk x")
        assert_eq(a.cz, acz, "fence anchored on the wrong chunk z")
        assert_eq(eq.sideOf("chunky"), nil, "chunky must be stowed after the swap")
    end
end

suite["a pos() hook reporting a stale facing is refused, not silently mis-placed"] =
function(assert_eq)
    -- The failure this whole contract exists to prevent: a caller that hands
    -- mine_flow a facing the turtle is not actually on. The loader physically
    -- lands south (facing 2) while pos() claims north, so the block mine_flow
    -- expects to be holding the chunk is not the block that exists -- the
    -- beacon gate must refuse rather than surrender chunky.
    local c, base, flow, gf, eq = fresh()
    base.move.face(2)

    flow.setHooks({
        reportPhase = function() end,
        log         = function() end,
        pos         = function()
            local p = base.getPos()
            p.facing = 0                  -- lie: the turtle is on 2
            return p
        end,
        pump        = function()
            local lx, ly, lz = findLoader(c, eq.ITEMS.LOADER_TURTLE)
            if lx then
                flow.noteBeacon({
                    type    = "LOADER_BEACON",
                    payload = { position = { x = lx, y = ly, z = lz } },
                })
            end
        end,
    })

    -- Anchor chunk matches the LIE, so the wrong-chunk guard cannot catch it
    -- and the beacon position check is what has to.
    local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
    assert_eq(ok, false, "a stale facing must not produce a successful placement")
    assert_eq(reason, "loader_beacon_mismatch")
    assert_eq(eq.sideOf("chunky") ~= nil, true,
        "chunky must NOT be given up when the loader cannot be verified")
    assert_eq(gf.isActive(), false, "fence must not arm on an unverified loader")
end

suite["base.getFacing tracks every turn primitive the miner uses"] = function(assert_eq)
    local c, base = fresh()
    assert_eq(base.getFacing(), 0)
    base.move.turnRight()
    assert_eq(base.getFacing(), 1);  assert_eq(c.pos.facing, 1)
    base.move.turnLeft()
    assert_eq(base.getFacing(), 0);  assert_eq(c.pos.facing, 0)
    base.move.face(3)
    assert_eq(base.getFacing(), 3);  assert_eq(c.pos.facing, 3)
    -- And the heading means what the movement primitive thinks it means.
    base.move.forward()
    assert_eq(base.getPos().x, -1, "facing 3 must be -x")
end

suite["a send with no usable modem is lost, not fatal"] = function(assert_eq)
    -- The miner unequips its modem on purpose during the retrieval swap, which
    -- detaches the wrapped peripheral: calling it RAISES. That error used to
    -- come out of the heartbeat inside controlLoop and kill the whole
    -- parallel.waitForAny runner -- i.e. the running job -- on every single
    -- loader retrieval. base.init is never called here, so _self.modem is nil,
    -- which reaches proto.send the same way a detached wrapper does.
    local _, base = fresh()
    local ok, err = pcall(base.sendProgress, "progress during a comms gap")
    assert_eq(ok, true, "sendProgress raised: " .. tostring(err))

    local ok2, err2 = pcall(base.sendToServer, "MINE_PHASE", { phase = "RETRIEVING" })
    assert_eq(ok2, true, "sendToServer raised: " .. tostring(err2))
end

return suite
