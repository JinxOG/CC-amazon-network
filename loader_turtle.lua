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

proto.openChannels(modem, { proto.CH_SERVER, proto.CH_BROADCAST,
                            proto.CH_PRIVATE, proto.CH_LOCAL })

local selfId = proto.selfId()

-- deployedBy is intentionally left nil here: this turtle has no way to learn
-- which miner placed it -- the miner cannot write to a separate turtle's
-- filesystem after placement. The server instead joins beacon reports to the
-- deployer from the placement record it already has (see the PLACING_LOADER
-- phase detail written by mine_flow.placeLoader), so nothing needs to travel
-- through this beacon's payload for that to work.
local deployedBy = nil

local function position()
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z } end
    return nil
end

print("[LOADER] " .. selfId .. " holding chunk. Beaconing every "
      .. BEACON_INTERVAL .. "s.")

while true do
    local pos = position()
    local payload = proto.payloadLoaderBeacon(pos, deployedBy)
    -- CH_LOCAL so a nearby miner can verify directly without a server round
    -- trip; CH_SERVER so the fleet view knows this loader exists at all.
    proto.send(modem, proto.CH_LOCAL,
        proto.encode(proto.MSG.LOADER_BEACON, selfId, "broadcast", payload))
    proto.send(modem, proto.CH_SERVER,
        proto.encode(proto.MSG.LOADER_BEACON, selfId, "server", payload))
    sleep(BEACON_INTERVAL)
end
