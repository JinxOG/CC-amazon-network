-- beaconlisten.lua — diagnostic for `loader_no_beacon`.
--
-- Standalone: requires NOTHING from the codebase. Drop it on any bare computer
-- or turtle that has an ender modem and run it. (An earlier version did
-- require("protocol"), which meant it only ran where the fleet code was
-- already installed -- exactly the machines you are least likely to be
-- standing next to when diagnosing.)
--
-- Run near a placed chunk loader. Prints every LOADER_BEACON heard, with the
-- sender's id and the position carried in the payload.
--
-- This separates the three things a failed beacon gate cannot distinguish:
--   nothing printed         -> the loader is not transmitting at all
--   printed, position nil   -> the loader has no GPS fix where it stands
--   printed with a position -> the beacon IS on the air; compare that position
--                              against the "loader at x,y,z" the miner logs
--
-- Ctrl+T to stop.

-- Channel numbers copied from protocol.lua. Duplicated deliberately so this
-- file has no dependencies; if the channel map ever changes, update here too.
local CH_SERVER, CH_BROADCAST, CH_PRIVATE, CH_WAREHOUSE, CH_LOCAL = 1, 2, 3, 4, 5

local modem = peripheral.find("modem")
if not modem then
    print("[LISTEN] No modem found. Attach or equip an ender modem and rerun.")
    return
end

for _, ch in ipairs({ CH_SERVER, CH_BROADCAST, CH_PRIVATE, CH_WAREHOUSE, CH_LOCAL }) do
    modem.open(ch)
end

print("[LISTEN] Listening on channels 1-5 (loader beacons ride CH_LOCAL=" ..
      CH_LOCAL .. " and CH_SERVER=" .. CH_SERVER .. ").")
print("[LISTEN] Waiting for LOADER_BEACON... (Ctrl+T to stop)")

local heard, other = 0, 0
local started = os.epoch("utc") / 1000

while true do
    -- Raw modem traffic on purpose: we want to see messages addressed to
    -- someone else too, so a routing problem is visible rather than filtered.
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
        -- Summarise other traffic occasionally, so "radio is dead" is
        -- distinguishable from "radio is fine, but no beacons".
        if other % 10 == 0 then
            local secs = math.floor(os.epoch("utc") / 1000 - started)
            print(string.format("[LISTEN] (%d other messages in %ds, %d beacons)",
                other, secs, heard))
        end
    end
end
