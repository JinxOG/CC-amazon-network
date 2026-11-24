-- loader_turtle.lua
-- Rename to startup.lua on any turtle used as a placed chunk loader.
--
-- One-time setup per physical loader turtle (a turtle keeps its computer ID
-- and filesystem through place -> break -> re-place, so this only needs
-- doing once, ever, per turtle):
--   1. Equip the chunky upgrade (advancedperipherals:chunk_controller) on
--      one side.
--   2. Equip an ender/wireless modem on the other side.
--   3. Copy this file to startup.lua on the turtle.
--   4. Label it for a stable identity, e.g. `label set loader_1`.
--
-- Equipped: chunky upgrade + ender modem. Never moves, never digs, holds no
-- cargo, needs no fuel. Its entire job is to hold a chunk and say so.
--
-- The beacon is what makes chunk loading verifiable: a miner that stops
-- hearing it can re-equip its own chunky immediately rather than mining on
-- inside a chunk that may no longer be loaded. That verification/monitoring
-- logic lives in mine_flow.lua (added in a later task) -- this program's only
-- job is to produce the beacon.
--
-- Invariant this file must hold: there is no failure mode in which this
-- program stops running. The chunky upgrade holds the chunk regardless of
-- whether the program is alive, but a halted program can never report
-- itself -- which defeats the whole point of a beacon. So every step past
-- "no modem" (startup, and each loop iteration) is wrapped so a transient
-- fault costs one missed beacon, or one retried startup attempt, never the
-- program.

local proto = require("protocol")

local BEACON_INTERVAL = 5

local modem = peripheral.find("modem")
if not modem then
    -- Nothing useful can be done without comms, but the chunky upgrade still
    -- works, so keep holding the chunk rather than halting. A halted loader
    -- that stops holding its chunk is far worse than a silent one.
    print("[LOADER] No modem — holding chunk silently.")
    while true do sleep(60) end
end

-- Startup must not be able to kill the program before the beacon loop is
-- even entered. Neither call is expected to throw in normal operation, but
-- retrying under pcall rather than letting either be fatal costs nothing.
local selfId
while not selfId do
    local ok, err = pcall(function()
        proto.openChannels(modem, { proto.CH_SERVER, proto.CH_BROADCAST,
                                    proto.CH_PRIVATE, proto.CH_LOCAL })
        selfId = proto.selfId()
    end)
    if not ok then
        print("[LOADER] Startup error, retrying in 5s: " .. tostring(err))
        sleep(5)
    end
end

-- deployedBy is intentionally left nil here: this turtle has no way to learn
-- which miner placed it -- the miner cannot write to a separate turtle's
-- filesystem after placement. The server instead joins beacon reports to the
-- deployer from the placement record it already has (see the PLACING_LOADER
-- phase detail written by mine_flow.placeLoader), so nothing needs to travel
-- through this beacon's payload for that to work.
local deployedBy = nil

-- Re-measure the position every Nth beacon instead of every single one.
-- 12 beacons at BEACON_INTERVAL = 5 s is about once a minute.
local FIX_EVERY = 12
local _fix, _beaconsOnFix = nil, math.huge

local function position()
    -- A PLACED LOADER CANNOT MOVE. It is a block in the world from the moment
    -- the miner puts it down until the miner digs it up, so measuring its
    -- position twelve times a minute is measuring something that by
    -- construction has not changed.
    --
    -- WHY THAT MATTERS SO MUCH MORE THAN IT LOOKS, measured by W3 in
    -- shakeout-payload-j: a gps.locate is not one message. CC pings with reply
    -- channel 65534, all TWELVE gps hosts answer on 65534, and every host also
    -- listens there -- so each reply wakes the other eleven. That is about 130
    -- radio wake-ups per locate, not the five a message count suggests. With 39
    -- loaders locating every 5 s it came to 3,132 deliveries/s on 65534, and 34
    -- miners were pausing in the climb shaft because the server was being
    -- starved of ComputerCraft's one shared thread (it got 2.4-3.5% of it).
    -- Dropping to one locate per minute removes roughly 2,300 of those
    -- wake-ups/s: about 28% of all radio work in that run.
    --
    -- NOT CACHED INDEFINITELY, for the same reason we never trust a stored
    -- facing: something outside this program could move the loader, and a
    -- beacon that lies about where it is would be worse than one that costs
    -- too much. A minute is short enough to self-correct and long enough to
    -- stop being the fleet's biggest radio consumer.
    --
    -- THE BEACON RATE IS UNCHANGED, deliberately. The miner reads beacon
    -- ARRIVAL as "my chunk is still loaded", so slowing the beacon would trade a
    -- radio problem for a chunk-loading one. This changes the cost of a beacon,
    -- not how often one goes out.
    if _fix and _beaconsOnFix < FIX_EVERY then
        _beaconsOnFix = _beaconsOnFix + 1
        return _fix
    end

    -- pcall belt-and-suspenders: gps.locate() already returns nil (not an
    -- error) on a plain timeout, but a wrapped GPS/peripheral hiccup must
    -- cost this one position lookup, not the beacon that carries it.
    local ok, x, y, z = pcall(gps.locate, 2)
    if ok and x then
        _fix, _beaconsOnFix = { x = x, y = y, z = z }, 0
        return _fix
    end
    -- A FAILED LOCATE MUST NOT WIPE A GOOD FIX, and must not be cached either:
    -- keep beaconing the last known position and try again on the next beacon,
    -- which is exactly what this did before caching existed.
    return _fix
end

print("[LOADER] " .. selfId .. " holding chunk. Beaconing every "
      .. BEACON_INTERVAL .. "s.")

-- Tracks consecutive send failures so a human standing next to the loader
-- can tell "beaconing but nobody's listening" apart from "the program
-- silently died" -- exactly the ambiguity this beacon exists to remove for
-- everyone else, so it should be visible on the loader's own terminal too.
local consecutiveFailures = 0

while true do
    local ok, err = pcall(function()
        local pos = position()
        local payload = proto.payloadLoaderBeacon(pos, deployedBy)
        -- CH_LOCAL so a nearby miner can verify directly without a server
        -- round trip; CH_SERVER so the fleet view knows this loader exists.
        proto.send(modem, proto.CH_LOCAL,
            proto.encode(proto.MSG.LOADER_BEACON, selfId, "broadcast", payload))
        proto.send(modem, proto.CH_SERVER,
            proto.encode(proto.MSG.LOADER_BEACON, selfId, "server", payload))
    end)

    if ok then
        if consecutiveFailures >= 3 then
            print("[LOADER] Beacon recovered after " .. consecutiveFailures
                  .. " failed attempt(s).")
        end
        consecutiveFailures = 0
    else
        consecutiveFailures = consecutiveFailures + 1
        -- Log the first failure immediately, then every 3rd repeat -- loud
        -- enough to notice, not a line-per-5s scroll on a stuck modem.
        if consecutiveFailures == 1 or consecutiveFailures % 3 == 0 then
            print("[LOADER] Beacon send failed (" .. consecutiveFailures
                  .. " in a row): " .. tostring(err))
        end
    end

    sleep(BEACON_INTERVAL)
end
