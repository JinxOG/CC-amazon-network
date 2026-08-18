-- beaconlisten.lua — diagnostic for `loader_no_beacon`.
--
-- Run on ANY computer or turtle with an ender modem, standing near a placed
-- chunk loader. Prints every LOADER_BEACON it hears, with the sender's id and
-- the position carried in the payload.
--
-- This separates the three things a failed beacon gate cannot distinguish:
--   nothing printed        -> the loader is not transmitting at all
--   printed, position nil  -> the loader has no GPS fix where it stands
--   printed with a position-> the beacon IS on the air; compare that position
--                             against where the miner said it placed the loader
--
-- Ctrl+T to stop.

local proto = require("protocol")

local modem = peripheral.find("modem")
if not modem then
    print("[LISTEN] No modem equipped/attached. Attach an ender modem and rerun.")
    return
end

proto.openChannels(modem, { proto.CH_SERVER, proto.CH_BROADCAST,
                            proto.CH_PRIVATE, proto.CH_LOCAL })

print("[LISTEN] Listening on CH_LOCAL(" .. proto.CH_LOCAL ..
      ") and CH_SERVER(" .. proto.CH_SERVER .. ").")
print("[LISTEN] Waiting for LOADER_BEACON... (Ctrl+T to stop)")

local heard, other = 0, 0
local started = os.epoch("utc") / 1000

while true do
    -- Deliberately NOT proto.receive: we want to see raw traffic, including
    -- messages addressed to someone else, so a routing problem is visible
    -- rather than silently filtered out.
    local _, _, ch, _, raw = os.pullEvent("modem_message")
    local msg = type(raw) == "table" and raw or textutils.unserialise(raw)

    if type(msg) == "table" and msg.type == "LOADER_BEACON" then
        heard = heard + 1
        local p = msg.payload and msg.payload.position
        local where = p and string.format("%d,%d,%d", p.x, p.y, p.z)
                        or "NO GPS FIX (position is nil)"
        print(string.format("[LISTEN] #%d ch=%d from=%s to=%s at %s",
            heard, ch, tostring(msg.from), tostring(msg.to), where))
    elseif type(msg) == "table" and msg.type then
        other = other + 1
        -- Summarise other traffic occasionally so "radio is dead" is
        -- distinguishable from "radio is fine, no beacons".
        if other % 10 == 0 then
            local secs = math.floor(os.epoch("utc") / 1000 - started)
            print(string.format("[LISTEN] (%d other messages in %ds, %d beacons)",
                other, secs, heard))
        end
    end
end
