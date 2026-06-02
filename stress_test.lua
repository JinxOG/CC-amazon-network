-- stress_test.lua
-- Queues a batch of delivery jobs to stress-test the turtle fleet.
-- Install on any CC computer with an ender modem attached.
-- Run:  lua stress_test.lua
--
-- Jobs are spread across 8 destinations in a ring ~90 blocks out.
-- With 4 pairs and a 60s dispatch stagger, all 8 jobs will complete
-- in roughly 8-12 minutes total.

local proto = require("protocol")

-- ─── Config ──────────────────────────────────────────────────────────────────

local MODEM_SIDE = "top"   -- change if your modem is on a different side

-- 8 destinations ~90 blocks out in different directions from dispatch hole (143,y,-2813)
-- y=64 is a safe underground-exit height; adjust if terrain is higher at a spot
local DESTINATIONS = {
    { x = 143, y = 64, z = -2903, label = "North"     },  -- 90 N
    { x = 143, y = 64, z = -2723, label = "South"     },  -- 90 S
    { x = 233, y = 64, z = -2813, label = "East"      },  -- 90 E
    { x =  53, y = 64, z = -2813, label = "West"      },  -- 90 W
    { x = 207, y = 64, z = -2877, label = "NE"        },  -- ~90
    { x =  79, y = 64, z = -2877, label = "NW"        },  -- ~90
    { x = 207, y = 64, z = -2749, label = "SE"        },  -- ~90
    { x =  79, y = 64, z = -2749, label = "SW"        },  -- ~90
}

-- Items to request per job (must exist in your RS network)
local ITEMS = {
    { name = "minecraft:cobblestone", count = 64 },
}

-- Delay between submitting each job (seconds).
-- Jobs queue up on the server regardless — this just avoids flooding the modem.
local SUBMIT_DELAY = 2

-- ─── Main ────────────────────────────────────────────────────────────────────

local modem = peripheral.find("modem") or peripheral.wrap(MODEM_SIDE)
if not modem then
    error("No modem found! Attach an ender modem and set MODEM_SIDE correctly.")
end

modem.open(proto.CH_SERVER)

local myId = "stress_test_" .. tostring(os.computerID())
print(string.format("=== Stress Test (%s) ===", myId))
print(string.format("Submitting %d jobs with %ds gap between each.", #DESTINATIONS, SUBMIT_DELAY))
print("")

for i, dest in ipairs(DESTINATIONS) do
    local msg = proto.encode(proto.MSG.JOB_REQUEST, myId, "server", {
        destination = { x = dest.x, y = dest.y, z = dest.z },
        items       = ITEMS,
        priority    = 5,
    })
    modem.transmit(proto.CH_SERVER, proto.CH_SERVER, textutils.serialise(msg))
    print(string.format("[%d/%d] Queued job → %s (%d,%d,%d)",
        i, #DESTINATIONS, dest.label, dest.x, dest.y, dest.z))
    if i < #DESTINATIONS then
        sleep(SUBMIT_DELAY)
    end
end

print("")
print("All " .. #DESTINATIONS .. " jobs submitted.")
print("With 60s stagger and 4 pairs, expect ~2 jobs per pair.")
print("Watch the admin monitor for live status.")
