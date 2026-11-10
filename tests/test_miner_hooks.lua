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

-- logship must clear with turtle_base: it owns the global print, and a stale
-- instance left in package.loaded keeps capturing into a queue nobody flushes.
local MODULES = { "turtle_base", "logship", "mine_flow", "equipment", "geofence", "loader_state" }

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

-- ─── Modem recovery across an upgrade swap ──────────────────────────────────
-- equipment.retrievalSwapIn takes the MODEM's side for chunky, and
-- retrievalSwapOut puts the modem back on the side OPPOSITE chunky -- the
-- pickaxe's old side. So the modem changes side on every loader retrieval,
-- while turtle_base's _self.modem is a wrapper bound to a side name, acquired
-- once in comms.init, with the channel list opened on that instance. Without
-- re-acquisition the miner goes permanently deaf and mute after its first
-- retrieval, and pcall'ing the send turns that from a loud crash into silence.
--
-- These drive base.recoverModem directly (comms.init cannot run headlessly --
-- it registers, which blocks on a server reply), with peripheral.find replaced
-- by a stand-in that hands out a DIFFERENT object each call, exactly as
-- re-wrapping a peripheral on a new side does.

local function withFakeModems(makers)
    local calls = { n = 0 }
    peripheral = peripheral or {}
    peripheral.find = function(kind)
        if kind ~= "modem" then return nil end
        calls.n = calls.n + 1
        return makers[math.min(calls.n, #makers)]
    end
    return calls
end

local function recordingModem()
    local m = { opened = {}, sent = 0 }
    m.open     = function(ch) table.insert(m.opened, ch) end
    m.isOpen   = function() return true end
    m.transmit = function() m.sent = m.sent + 1 end
    return m
end

local function detachedModem()
    local m = { opened = {} }
    m.open     = function() error("peripheral detached", 0) end
    m.isOpen   = function() return false end
    -- What a wrapper bound to a side the modem no longer occupies does.
    m.transmit = function() error("No peripheral attached", 0) end
    return m
end

suite["recoverModem rebinds the wrapper and re-opens the listening channels"] =
function(assert_eq)
    local _, base = fresh()
    local proto = require("protocol")
    local first, second = recordingModem(), recordingModem()
    local calls = withFakeModems({ first, second })

    assert_eq(base.recoverModem(), true)
    assert_eq(base.getModem() == first, true, "first acquisition")
    -- Same channel set comms.init opens; both read it from one CHANNELS local.
    assert_eq(#first.opened, 3)
    local want = { [proto.CH_BROADCAST] = true, [proto.CH_PRIVATE] = true,
                   [proto.CH_LOCAL] = true }
    for _, ch in ipairs(first.opened) do
        assert_eq(want[ch], true, "unexpected channel opened: " .. tostring(ch))
    end

    -- The swap moved the modem: a second call must take the NEW instance and
    -- open the channels on it, not keep the stale wrapper.
    assert_eq(base.recoverModem(), true)
    assert_eq(base.getModem() == second, true, "wrapper was not rebound after the swap")
    assert_eq(#second.opened, 3, "channels not re-opened on the new instance")
    assert_eq(calls.n, 2)
end

suite["a send through a detached wrapper is lost, not fatal, and escalates to recovery"] =
function(assert_eq)
    local _, base = fresh()
    local dead, live = detachedModem(), recordingModem()
    -- First find hands out the stale/detached wrapper; every later find (i.e.
    -- the recovery attempt) hands out the working one.
    local calls = withFakeModems({ dead, live })

    assert_eq(base.recoverModem(), false, "a modem whose open() raises is not recovered")
    assert_eq(base.getModem() == dead, true)

    -- Three consecutive failures must escalate to a re-acquire rather than
    -- warning forever. None of them may raise: this is the heartbeat path
    -- inside controlLoop, and an error there kills the parallel runner.
    for i = 1, 3 do
        local ok, err = pcall(base.sendProgress, "progress during a comms gap")
        assert_eq(ok, true, "send " .. i .. " raised: " .. tostring(err))
    end

    assert_eq(calls.n, 2, "expected exactly one recovery attempt after 3 failures")
    assert_eq(base.getModem() == live, true, "escalation did not rebind the modem")

    -- And the next send actually goes out on the recovered modem.
    local ok, err = pcall(base.sendToServer, "MINE_PHASE", { phase = "RETRIEVING" })
    assert_eq(ok, true, tostring(err))
    assert_eq(live.sent, 1, "send did not reach the recovered modem")
end

suite["a send with no modem at all is still lost, not fatal"] = function(assert_eq)
    local _, base = fresh()
    peripheral.find = function() return nil end
    assert_eq(base.recoverModem(), false)
    local ok, err = pcall(base.sendProgress, "no modem anywhere")
    assert_eq(ok, true, "sendProgress raised: " .. tostring(err))
end

-- A recall must stop the miner BEFORE it commits to a sector.
--
-- 2026-09-22: node_119 logged "RECALL: job_cancelled" at 08:59, flew 1,700
-- blocks anyway, placed its loader at 09:08 and began scanning -- nine minutes
-- after being told to come home, with no job on the server. Between the two it
-- was orphaned: nothing tracked it, and it deployed a chunk loader nobody
-- expected. A second recall, sent once it was at work, was obeyed in a minute.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle.lua self-executes base.init at
-- load and pcall(base.run)/os.reboot at the bottom, so its sector loop cannot
-- be driven from this harness (see the note at the top of test_control_loop).
-- This pins the two call sites by reading the file.
suite["a recall is checked before departing and before the loader goes down (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()

    -- Anchored on the sector loop's own progress line: setStatus(TRAVELLING)
    -- appears more than once in this file, and the first one is not this path.
    local travelAt = src:find("%sTravelling to sector %d,%d", 1, true)
    assert_eq(travelAt ~= nil, true, "the sector travel call site moved or vanished")
    local beforeTravel = src:sub(math.max(1, travelAt - 700), travelAt)
    assert_eq(beforeTravel:find("if base.isRecalled() then", 1, true) ~= nil, true,
        "a recalled miner must not set off for the sector at all")

    local placeAt = src:find("mine_flow.placeLoader(FENCE_CHUNK_RADIUS", 1, true)
    assert_eq(placeAt ~= nil, true, "the loader placement call site moved or vanished")
    local beforePlace = src:sub(math.max(1, placeAt - 700), placeAt)
    assert_eq(beforePlace:find("if base.isRecalled() then", 1, true) ~= nil, true,
        "placing the loader is the point of no return: a recall that arrived "
        .. "during the flight must be caught here, or the turtle is orphaned "
        .. "with a chunk loader standing")
end

-- A JOB MUST NOT DECIDE WHERE IT IS ON A GUESS EITHER.
--
-- 1.9.132 made recoverPlacedLoader wait for a real GPS fix, after four miners
-- were lost on 2026-10-05: the GPS hosts came up after the turtles, each miner
-- believed it was at 0,0,0 and flew off from there.
--
-- mineJob has the same shape and was not covered. Its first act is to read its
-- position and ask "did I reboot mid-job?"; if the answer is yes it flies a
-- solo return immediately. On an unfixed position the answer is always yes --
-- 0,0,0 is not the depot -- so a miner that booted without a fix and was then
-- handed a job flew home from a guess. The no_gps_fix refusal that would have
-- stopped it sits fifty lines further down, after this branch has already gone.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load, so its
-- job path cannot be driven from this harness. Same technique as the
-- recoverPlacedLoader ordering test in test_shaft_sidestep.
suite["a job waits for a real position before deciding it rebooted mid-job (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()
    -- Built with string.char(10) rather than an escape: the newline is what
    -- terminates the function at column 0, and a literal one here would end
    -- this string instead.
    local NL = string.char(10)
    local body = src:match("local function mineJob%(job%)(.-)" .. NL .. "end" .. NL)
    assert_eq(body ~= nil, true, "mineJob moved or vanished")

    local waitAt   = body and body:find("base.waitForPositionFix(", 1, true)
    local readAt   = body and body:find("local startPos = base.getPos()", 1, true)
    -- The anchor lost its closing quote when the reason became part of the
    -- string: a reboot in the field now decides whether to resume where it
    -- stands, and names which reason sent it home when it did not.
    local flyAt    = body and body:find('recallReturn("reboot_recovery', 1, true)
    local decideAt = body and body:find("mine_flow.resumeDecision(", 1, true)
    assert_eq(waitAt ~= nil, true,
        "mineJob must wait for a real fix before it reads its own position")
    assert_eq(readAt ~= nil and flyAt ~= nil, true, "the reboot-recovery branch moved")
    assert_eq(waitAt < readAt and waitAt < flyAt, true,
        "the fix must come BEFORE the position is read and before the flight home: "
        .. "an unfixed position makes 'I rebooted in the field' always true")
    -- And before the DECISION, which is the same trap one step along: on an
    -- unfixed position every fact the decision reads is a guess, and resuming
    -- on a guess is how four miners were lost on 2026-10-05.
    assert_eq(decideAt ~= nil, true,
        "the reboot branch must ask mine_flow.resumeDecision, not always fly home")
    assert_eq(waitAt < decideAt, true, "the fix must come BEFORE the resume decision")
end

-- The recorded label must be consulted BEFORE the unlabelled refusal, or the
-- refusal fires first and the rescue still needs a manual file delete. The
-- matching logic itself is behavioural in test_mine_flow; this pins the order.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["a recorded label is checked before the unlabelled refusal (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()
    local byLabelAt = src:find("mine_flow.carriedLoaderSlotByLabel(s.label)", 1, true)
    local refuseAt  = src:find("equipment.LOADER_LABEL == nil", 1, true)
    assert_eq(byLabelAt ~= nil, true,
        "clearStaleLoaderRecord must consult the label recorded at placement")
    assert_eq(refuseAt ~= nil, true, "the unlabelled refusal moved or vanished")
    assert_eq(byLabelAt < refuseAt, true,
        "proof by label has to come first, or the refusal fires and the operator "
        .. "still has to delete loader_state.dat by hand")
end

-- A LATE GPS START MUST NOT STRAND A FIELD MINER FOREVER.
--
-- The boot loop tried GPS six times over two minutes and then gave up: nothing
-- retried, and recoverPlacedLoader was skipped because it sat in the else. A
-- miner whose GPS came back later stranded permanently, loader standing and
-- chunk force-loaded. Measured on master by the head engineer and by
-- sandbox/scenarios/world_restart_gps_late.lua, which fails on the old code.
--
-- Two properties, and the second is the one that made it permanent:
--   * the no-fix path waits forever (base.waitForPositionFix reports
--     stuck_no_fix once a minute, so parked is visible, not silent);
--   * the loader recovery runs on BOTH paths -- the restart that took GPS away
--     is exactly the restart that left the loader standing.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load. The
-- behaviour is proven at layer 1 by the scenario; this keeps a revert from
-- needing a six-minute run to notice.
suite["a late GPS start parks and retries, and still recovers the loader (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()

    local parkedAt = src:find("no_gps_fix: parked", 1, true)
    local waitAt   = src:find("base.waitForPositionFix(\"boot recovery after a late GPS start\")", 1, true)
    local recovAt  = src:find("pcall(recoverPlacedLoader)", 1, true)
    assert_eq(parkedAt ~= nil, true, "the no-fix path must say it is parked and retrying")
    assert_eq(waitAt ~= nil, true,
        "it must wait for a fix forever rather than giving up after six tries")
    assert_eq(recovAt ~= nil and recovAt > waitAt, true,
        "the loader recovery must come after the wait")

    -- The recovery must NOT be reachable only on the had-a-fix path. Anything
    -- between the wait and the recovery that opens an else branch puts it back
    -- where it was.
    -- Not just the literal else: re-gating it on the flag by any means puts it
    -- back where it was, so neither an else nor a mention of the flag may sit
    -- between the wait and the recovery.
    local between = src:sub(waitAt, recovAt)
    assert_eq(between:find("else", 1, true) == nil, true,
        "the loader recovery must run whether or not GPS was there at boot: "
        .. "skipping it on the no-fix path is what made the stranding permanent")
    assert_eq(between:find("_haveGpsFix", 1, true) == nil, true,
        "and it must not be re-gated on the boot fix flag either")
end

-- THE ORE CHEST IS WIRED INTO THE LEDGER (W1's card, ruled 2026-10-08).
--
-- Three things, and the recovery itself is turtle_base's: registering the kind
-- is what makes base.ledger.recover handle it at all, passing the ledger into
-- bankPayload is what records the chest before it goes down, and recovering the
-- ledger before the loader is what stops a chest being abandoned for a whole
-- flight to the sector.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load. What
-- bankPayload DOES with a ledger is behavioural in test_mine_flow.
suite["the ore chest is a registered ledger kind, recorded and recovered first (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()

    assert_eq(src:find('base.ledger.registerKind("ore_chest"', 1, true) ~= nil, true,
        "an unregistered kind is unknown to base.ledger.recover, which refuses it")
    assert_eq(src:find("ledger    = oreChestLedger", 1, true) ~= nil, true,
        "bankPayload must be given the ledger, or nothing records the chest")
    assert_eq(src:find('base.ledger.clearIfHome("ore_chest", S_ORE_EC)', 1, true) ~= nil, true,
        "and the home slot it is cleared against must be the ore chest's own")

    local ledgerAt = src:find("pcall(base.recoverLedger)", 1, true)
    local loaderAt = src:find("pcall(recoverPlacedLoader)", 1, true)
    assert_eq(ledgerAt ~= nil, true, "boot must recover the ledger")
    assert_eq(loaderAt ~= nil and ledgerAt < loaderAt, true,
        "the chest is adjacent and cheap; the loader recovery flies to the "
        .. "sector, so a chest recovered after it waits out the whole trip")
end

-- The per-ore pick must go through mine_flow.takeNearest, and mineOreList must
-- keep no sort of its own.
--
-- This matters more than it looks. takeNearest is covered behaviourally in
-- test_mine_flow -- minimality, route equivalence, no ore lost -- but none of
-- that proves the MINER calls it. A call site that quietly went back to
-- table.sort, or to table.remove(remaining, 1) with no distance check at all,
-- would leave every one of those tests green while the fleet walked a
-- different route. So this pins the wiring, and the mutation harness has an
-- entry for exactly that reversion.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["the per-ore pick goes through mine_flow.takeNearest, with no sort left behind (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()
    -- string.char(10), not an escape: a literal newline would end this string.
    local NL   = string.char(10)
    local body = src:match("local function mineOreList%(ores, jobId, sx, sz, sy(.-)"
                           .. NL .. "end" .. NL)
    assert_eq(body ~= nil, true, "mineOreList moved or vanished")

    assert_eq(body:find("mine_flow.takeNearest(remaining, p)", 1, true) ~= nil, true,
        "mineOreList must pick the next ore via mine_flow.takeNearest -- that is "
        .. "the only version of the pick that anything can test")
    assert_eq(body:find("table.sort", 1, true), nil,
        "and keep no sort of its own: sorting the whole remaining list to read "
        .. "element 1 is the cost this replaced (SPEC-OWNER, mail 2026-10-20)")
    assert_eq(body:find("table.remove(remaining", 1, true), nil,
        "nor a positional removal: takeNearest owns removal, and an extra one "
        .. "here would drop an ore per pick")
end

-- A skipped ore's reason must survive from move.to to the log line.
--
-- Three separate links, and a break in any one of them leaves the classifier's
-- own tests green while the log goes back to reporting a bare count: navToOre
-- must RETURN the reason, mineOreList must bucket it, and the line must render
-- the buckets. W3 lost an answerable question to exactly this gap (2026-10-08).
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["a skipped ore's reason reaches the log, not just its count (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()
    local NL = string.char(10)

    local nav = src:match("local function navToOre%(ore, jobId%)(.-)" .. NL .. "end" .. NL)
    assert_eq(nav ~= nil, true, "navToOre moved or vanished")
    assert_eq(nav:find("return false, why1", 1, true) ~= nil, true,
        "navToOre must pass move.to's reason back, not just false -- the reason "
        .. "is already there and was being discarded")

    local body = src:match("local function mineOreList%(ores, jobId, sx, sz, sy(.-)"
                           .. NL .. "end" .. NL)
    assert_eq(body ~= nil, true, "mineOreList moved or vanished")
    assert_eq(body:find("mine_flow.classifySkip(whyNot)", 1, true) ~= nil, true,
        "the reason must be bucketed, or every skip is unknown")
    assert_eq(body:find("mine_flow.renderSkipReasons(skipReasons)", 1, true) ~= nil, true,
        "and the buckets must reach the printed line, or nothing is reported")
    assert_eq(body:find("bedrock/fenced/blocked", 1, true), nil,
        "the old line claimed it could identify bedrock; nothing in the move "
        .. "layer can tell bedrock from any other unbreakable block")
end

-- The dock tidy must bank with noDig, and must NOT refuse on what is below.
--
-- The behaviour of noDig is covered in test_mine_flow; what cannot be covered
-- there is that tidyAtDock passes it and has dropped the refusal. Restore that
-- early return and every noDig test stays green while docked miners go back to
-- never banking -- which is how it survived unnoticed from 2026-10-08.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["the dock tidy banks with noDig instead of refusing on the station chest (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()
    local NL   = string.char(10)
    local body = src:match("local function tidyAtDock%(%)(.-)" .. NL .. "end" .. NL)
    assert_eq(body ~= nil, true, "tidyAtDock moved or vanished")

    assert_eq(body:find("dumpOres(nil, true)", 1, true) ~= nil, true,
        "tidyAtDock must bank with noDig set, or it digs the station chest")
    assert_eq(body:find("if turtle.detectDown() then", 1, true), nil,
        "and must NOT refuse on a block below: at a dock that is always the "
        .. "station chest, so the refusal cancelled every bank (W3 measured 12 "
        .. "'kept aboard' and 0 'banking' across miners 177-183)")

    -- The reorient runs first and unconditionally: it needs no chest and cannot
    -- fail destructively, so hardware gets home even when banking is impossible.
    local rescueAt = body:find("rescueProtectedItems()", 1, true)
    local dumpAt   = body:find("dumpOres(", 1, true)
    assert_eq(rescueAt ~= nil and dumpAt ~= nil and rescueAt < dumpAt, true,
        "rescueProtectedItems must still come before the bank")

    -- AND IT HAS TO NOTICE THE FUEL BUFFER. The "am I carrying anything?" scan
    -- ran over the mining slots (5-13) only, so a miner whose single stranded
    -- item sat in slot 14 returned to its bay, concluded it carried nothing and
    -- left again with the stack aboard -- node_119 with a full stack of
    -- redstone there (user screenshot, 2026-10-03). Making the dump FILTER
    -- willing to take slot 14 does nothing on its own: this early return fires
    -- first, so both halves are needed and both are asserted.
    assert_eq(body:find("turtle.getItemCount(S_COAL) > 0", 1, true) ~= nil, true,
        "the carrying check must look at the fuel buffer too, or the dock tidy "
        .. "returns before the bank it was going to do")
    -- The NEGATION is asserted, not just the call. A mutant that dropped the
    -- `not` survived an assertion on the call alone: a buffer full of coal then
    -- counts as cargo, and every docked miner deploys the ore chest to bank
    -- nothing. Coal there is the buffer working, not cargo.
    assert_eq(body:find("if not mine_flow.isFuelItem(it and it.name) then carrying = true end",
        1, true) ~= nil, true,
        "the buffer counts as carried only when what is in it will NOT burn")
    local coalAt = body:find("turtle.getItemCount(S_COAL) > 0", 1, true)
    local retAt  = body:find("if not carrying then return end", 1, true)
    assert_eq(coalAt ~= nil and retAt ~= nil and coalAt < retAt, true,
        "and it must be checked BEFORE the early return, not after it")
end

-- noDig has to survive THREE hops to reach the bank:
--   tidyAtDock -> dumpOres(quiet, noDig) -> dumpToEC(noDig) -> bankPayload{noDig}
--
-- Added because a mutant proved it was needed: setting the flag to false where
-- dumpToEC builds its opts left every noDig test in test_mine_flow green and
-- the tidyAtDock test green too, while docked miners went straight back to
-- digging the station chest. Asserting the two ends is not asserting the chain.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["noDig survives every hop from the dock tidy to the bank (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()
    local NL = string.char(10)

    assert_eq(src:find("local function dumpOres(quiet, noDig)", 1, true) ~= nil, true,
        "dumpOres must accept noDig")
    assert_eq(src:find("return dumpToEC(noDig)", 1, true) ~= nil, true,
        "dumpOres must forward it to dumpToEC, not drop it at the equipment swap")
    assert_eq(src:find("local function dumpToEC(noDig)", 1, true) ~= nil, true,
        "dumpToEC must accept noDig")

    local body = src:match("local function dumpToEC%(noDig%)(.-)" .. NL .. "end" .. NL)
    assert_eq(body ~= nil, true, "dumpToEC moved or vanished")
    assert_eq(body:find("noDig     = noDig,", 1, true) ~= nil, true,
        "and must pass the flag itself into bankPayload -- a hardcoded true or "
        .. "false here silently decides the dock's behaviour for every caller")
end

-- Ore below the dig floor must be removed BEFORE it is counted as found.
--
-- The order is the whole fix. dropBelowFloor's own tests cannot see it: build
-- scanFound/sectorFound from the unfiltered list and every one of them stays
-- green while the server is told again about ore nobody may dig, re-queues the
-- sector, and the miner reports 0 mined until "re-mine exhausted" (W6,
-- 2026-09-10: 12 wasted sectors; jobs 0043/0044 found 454 and mined 0).
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["below-floor ore is dropped before it is counted as found (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()

    local dropAt = src:find("mine_flow.dropBelowFloor(fresh, MIN_ORE_Y)", 1, true)
    assert_eq(dropAt ~= nil, true,
        "the scan must split its ore at the dig floor via mine_flow.dropBelowFloor")

    local foundAt = src:find("sectorFound[o.name] = (sectorFound[o.name] or 0) + 1", 1, true)
    assert_eq(foundAt ~= nil, true, "the found-ore tally moved or vanished")
    assert_eq(dropAt < foundAt, true,
        "the floor split must come BEFORE the tally -- counting first is the bug: "
        .. "the server is told about ore the miner will then refuse, sees 'ore "
        .. "remains', and re-queues the sector forever")

    -- Ordering alone is not enough, and a mutant proved it: swapping the tally
    -- to iterate the UNFILTERED list leaves the order untouched and restores the
    -- bug completely. `fresh` is built by a loop over rawOres and must never be
    -- iterated itself -- anything counted from it is ore the miner will refuse.
    assert_eq(src:find("ipairs(fresh)", 1, true), nil,
        "nothing may iterate the unfiltered scan: the tally must read the list "
        .. "dropBelowFloor returned, or the server is told about ore nobody may dig")
    assert_eq(src:find("for _, o in ipairs(ores) do", 1, true) ~= nil, true,
        "the found-ore tally must read the filtered list")

    -- And the dropped count must be said out loud. Removing it from the tally
    -- without reporting it swaps a wrong number for a missing one, and "found 0"
    -- then reads as "the ground was empty".
    assert_eq(src:find("ore below the Y=%d dig floor", 1, true) ~= nil, true,
        "the below-floor count must be printed, not silently discarded")
end

-- DIGGING AN ORE WE ALREADY STAND BESIDE (adjacent-block dig card).
--
-- The geometry is mine_flow.adjacentDir and has its own tests. What cannot be
-- tested without a world is the three safeguards around it, and each one is a
-- way this could quietly go wrong:
--
--   * the block must be IDENTIFIED before it is dug. move.to digs whatever
--     occupies the cell and the loop then credits it to ore.name, so a stale
--     scan entry has always been able to book a block of stone as an ore. This
--     path must check the name and decline otherwise.
--   * a fleet member in that cell must come back as a REFUSAL, not as a
--     fallback -- falling through would walk into it, and the move layer's own
--     guard is the only thing that has ever stopped a miner mining a miner.
--   * everything else must come back NIL, so the caller uses the old move-in
--     path and behaves exactly as before. A `false` there would turn "nothing
--     was there" into a skip and corrupt the buckets the skip-reason card
--     exists to make trustworthy.
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["the adjacent dig identifies the block, refuses a turtle, and otherwise declines (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()
    local NL = string.char(10)

    local body = src:match("local function digAdjacentOre%(ore%)(.-)" .. NL .. "end" .. NL)
    assert_eq(body ~= nil, true, "digAdjacentOre moved or vanished")

    assert_eq(body:find("mine_flow.adjacentDir(base.getPos(), ore)", 1, true) ~= nil, true,
        "the geometry must come from mine_flow.adjacentDir, where it is tested")

    assert_eq(body:find("block.name == ore.name", 1, true) ~= nil, true,
        "the block must be identified before it is dug, or a stale scan entry "
        .. "books a block of stone as an ore")
    local lookAt = body:find("inspectAt(dir)", 1, true)
    local digAt  = body:find("mine_flow.digGuarded(dir)", 1, true)
    assert_eq(lookAt ~= nil and digAt ~= nil and lookAt < digAt, true,
        "and identified BEFORE the dig, not after it")

    assert_eq(body:find('why == "would_dig_turtle"', 1, true) ~= nil, true,
        "a fleet member in that cell must be reported as a refusal")
    assert_eq(body:find("return false, why", 1, true) ~= nil, true,
        "and reported as false with its reason, so the skip bucket is right")

    -- The dig guard, not turtle.dig: this is the one site where digging the
    -- wrong thing costs a fleet member rather than a block of stone.
    assert_eq(body:find("turtle.dig", 1, true), nil,
        "it must dig through mine_flow.digGuarded, never turtle.dig directly")

    -- And the caller has to use the three-valued answer. `if near then` would
    -- treat a refusal as "not applicable" and walk into the turtle.
    assert_eq(src:find("if near ~= nil then return near, nearWhy, \"beside\" end", 1, true) ~= nil, true,
        "navToOre must distinguish nil (not applicable) from false (refused), and "
        .. "say which path it took")
end

-- A LEVEL THAT DID NOT HAPPEN IS NOT A LEVEL WITH NO ORE.
--
-- scanSector returned a bare {} from seven different refusals -- no scanner in
-- slot 1, the placement record not persisting, placeDown failing, the
-- peripheral not wrapping, the scan throwing, the scan returning nil, and the
-- guard that refuses to dig a fleet member off the scan square. Every one of
-- them rendered exactly like a level with no ore in it, so the loop counted the
-- level as scanned and the sector was reported DONE with 0 ore. The server
-- cannot tell those apart, so it never re-queued the sector: job_0058, node_138
-- reported (1888,-2912) done with 0 ore while node_139 had found 81 ore there
-- (W3, 2026-09-16).
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["a scan level that did not run is never counted as scanned (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()

    local from, to = src:find("local function scanSector%(%).-\nend\n")
    assert_eq(from ~= nil, true, "scanSector moved or was renamed")
    local body = src:sub(from, to)

    -- Not one bare empty return may survive in it. This is the exact shape of
    -- the bug, so it is asserted directly rather than by counting reasons: a
    -- single `return {}` left behind restores one silent refusal.
    assert_eq(body:find("return {}%s*\n") == nil, true,
        "every refusal in scanSector must return a reason beside the empty "
        .. "list -- a bare `return {}` is indistinguishable from empty ground, "
        .. "which is the whole fault")

    -- And each one has to say something DIFFERENT, or the caller can report
    -- that a level failed but never which way, and the next person is back to
    -- guessing from a log that says nothing.
    local seen, n = {}, 0
    for reason in body:gmatch('return {}, "([%w_]+)"') do
        assert_eq(seen[reason], nil, "two refusals share the reason '" .. reason .. "'")
        seen[reason] = true; n = n + 1
    end
    assert_eq(n >= 7, true,
        "all seven refusal paths must carry a reason (found " .. n .. ")")
    assert_eq(seen.blocked_by_turtle, true,
        "the turtle guard is the one this card was raised for and must be named")

    -- The caller is the half that actually fixes the accounting. A reason it
    -- cannot clear must abandon the sector through `abort` -- the path
    -- loader_beacon_lost already takes, which goes home and reports the job
    -- failed BUT RECOVERABLE, so the server re-dispatches the sector.
    -- The anchor gained a third return value when the survey started reporting
    -- how much it dropped outside the lease (the ore-index card's condition 6),
    -- so it is matched up to scanFail rather than to the end of the line. The
    -- invariant is unchanged: the caller must take the REASON, not just the list.
    local callAt = src:find("local rawOres, scanFail", 1, true)
    assert_eq(callAt ~= nil, true,
        "the caller must take scanSector's reason, not just its list")
    local tail = src:sub(callAt, callAt + 2000)
    assert_eq(tail:find("abort = string.format(\"scan_level_incomplete", 1, true) ~= nil, true,
        "an unclearable refusal must set abort, so the sector is NOT reported "
        .. "done and the server re-queues it")

    -- Retried before it is given up. A turtle on the scan square is usually one
    -- crossing a shaft; abandoning the sector on the first refusal would turn a
    -- two-second encounter into a re-dispatched job. A fix that only aborts
    -- passes the check above and is still wrong in the common case.
    assert_eq(tail:find("for try = 1, SCAN_RETRIES do", 1, true) ~= nil, true,
        "the level must be retried before the sector is abandoned")
    assert_eq(src:find("local SCAN_RETRIES", 1, true) ~= nil, true,
        "SCAN_RETRIES must be a named constant, not a literal in the loop")
end

-- A SURVEY MUST REPORT ITS OWN BLIND SPOTS (coordinate ore-index card,
-- conditions 2 and 6).
--
-- The card sets six conditions a count has to meet before a build planner may
-- source materials from it. Two are about what the number does NOT include:
-- state the vertical band (the four scan levels at radius 16 cover one
-- continuous band and nothing outside it, so "how much iron is in this zone" is
-- really "in a 100-block band"), and publish the ore dropped as unreachable --
-- below the dig floor or outside the lease -- alongside the usable count. Both
-- numbers already existed per level, were printed, and were thrown away.
--
-- The card's own words for why: a survey that cannot report its own blind spots
-- is "a number whose pass state and no-data state look identical".
--
-- SOURCE-ONLY, weaker, and labelled: ore_turtle self-executes at load.
suite["a finished sector reports what it could not see, and its band (SOURCE-ONLY, weaker)"] =
function(assert_eq)
    local f = assert(io.open("ore_turtle.lua", "r"))
    local src = f:read("*a"); f:close()

    -- Totalled across the sector, not per level: the server is told once, when
    -- the sector finishes, so a per-level number would be the last level's.
    assert_eq(src:find("sectorBelowFloor = sectorBelowFloor + belowFloor", 1, true) ~= nil, true,
        "the below-floor count must accumulate across the sector's scan levels")
    assert_eq(src:find("sectorOutsideLease = sectorOutsideLease + (outsideLease or 0)", 1, true) ~= nil, true,
        "and so must the count dropped outside the lease")

    -- And both must actually leave the turtle. Accumulating them and not
    -- sending them is the same as printing them: nothing a consumer can read.
    local sendAt = src:find("proto.payloadSectorDone(jobId, sx, sz, count, sectorFound, sectorMined,", 1, true)
    assert_eq(sendAt ~= nil, true, "SECTOR_DONE must carry the extra arguments")
    local tail = src:sub(sendAt, sendAt + 400)
    assert_eq(tail:find("belowFloor = sectorBelowFloor", 1, true) ~= nil, true,
        "the below-floor total must be sent")
    assert_eq(tail:find("outsideLease = sectorOutsideLease", 1, true) ~= nil, true,
        "the outside-lease total must be sent")
    assert_eq(tail:find("floorY = MIN_ORE_Y", 1, true) ~= nil, true,
        "and the floor it was measured against, or the number cannot be read")

    -- The band is DERIVED from the scan levels and the radius, never written
    -- out by hand: a literal would silently stop matching the day either
    -- changes, which is exactly how a survey starts lying about its own extent.
    assert_eq(tail:find("SCAN_LEVELS[#SCAN_LEVELS] - SCAN_RADIUS", 1, true) ~= nil, true,
        "the band's floor must be derived from the deepest level and the radius")
    assert_eq(tail:find("SCAN_LEVELS[1] + SCAN_RADIUS", 1, true) ~= nil, true,
        "and its ceiling from the shallowest")
end

return suite
