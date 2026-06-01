-- test_turtle.lua
-- Minimal test script for a turtle. Does NOT need base.run().
-- Verifies: modem setup, server registration, heartbeat, message receipt.
-- Run on a turtle that has a wireless modem and can see the server computer.

local proto = require("protocol")

-- ─── Setup ───────────────────────────────────────────────────────────────────

local SELF_ID = proto.selfId()
print("=== Test Turtle: " .. SELF_ID .. " ===")
print("Fuel: " .. turtle.getFuelLevel())

local modem = peripheral.find("modem")
if not modem then
    error("No modem found! Attach a wireless modem.")
end

proto.openChannels(modem, { proto.CH_SERVER, proto.CH_BROADCAST, proto.CH_PRIVATE })
print("Modem open on channels " .. proto.CH_SERVER .. ", " .. proto.CH_BROADCAST .. ", " .. proto.CH_PRIVATE)

-- ─── Registration Test ───────────────────────────────────────────────────────

print("\n[1] Sending REGISTER...")
local regMsg = proto.encode(
    proto.MSG.REGISTER,
    SELF_ID,
    "server",
    proto.payloadRegister(proto.ROLE.DELIVERY, turtle.getFuelLevel(), turtle.getFuelLimit(), nil)
)
proto.send(modem, proto.CH_SERVER, regMsg)

print("    Waiting for REGISTER_ACK (5s)...")
local ack = proto.receive(SELF_ID, 5)

if ack then
    print("    ACK received from: " .. tostring(ack.from))
    print("    Server time: " .. tostring(ack.payload.serverTs))
    print("    [PASS] Registration OK")
else
    print("    [FAIL] No response from server. Is it running?")
    print("           Check: server has a modem, startup_server.lua is running.")
    return
end

-- ─── Heartbeat Test ──────────────────────────────────────────────────────────

print("\n[2] Sending 3 heartbeats (one every 3s)...")
for i = 1, 3 do
    local hb = proto.encode(
        proto.MSG.HEARTBEAT,
        SELF_ID,
        "server",
        proto.payloadHeartbeat(proto.STATUS.IDLE, turtle.getFuelLevel(), nil, nil)
    )
    proto.send(modem, proto.CH_SERVER, hb)
    print(string.format("    Heartbeat %d sent (fuel=%d)", i, turtle.getFuelLevel()))
    sleep(3)
end
print("    [PASS] Heartbeats sent. Check server log for receipt.")

-- ─── Listen Test ─────────────────────────────────────────────────────────────

print("\n[3] Listening for 10s for any incoming server message...")
print("    (On the server, run: require('central_server').recallAll('test'))")

local received = false
local deadline = os.clock() + 10
while os.clock() < deadline do
    local msg = proto.receive(SELF_ID, deadline - os.clock())
    if msg then
        received = true
        print("    Got message: type=" .. msg.type .. " from=" .. msg.from)
        if msg.type == proto.MSG.RECALL then
            print("    [PASS] RECALL received. Two-way comms working!")
        elseif msg.type == proto.MSG.JOB_ASSIGN then
            print("    [PASS] JOB_ASSIGN received: job=" .. msg.payload.jobId)
        else
            print("    [INFO] Unexpected type, but comms work.")
        end
        break
    end
end

if not received then
    print("    [INFO] Nothing received in 10s (server may not have sent anything).")
    print("          Outbound comms verified. Inbound unconfirmed.")
end

-- ─── Protocol Encode/Decode Unit Test ────────────────────────────────────────

print("\n[4] Protocol encode/decode self-test...")
local testMsg = proto.encode(proto.MSG.HEARTBEAT, "turtle_test", "server",
    proto.payloadHeartbeat(proto.STATUS.IDLE, 1000, {x=0,y=64,z=0}, nil))

local serialised = textutils.serialise(testMsg)
local parsed     = textutils.unserialise(serialised)
local valid, decoded = proto.decode(parsed)

if valid then
    print("    type=" .. decoded.type .. " from=" .. decoded.from .. " seq=" .. decoded.seq)
    print("    [PASS] Encode/decode round-trip OK")
else
    print("    [FAIL] Decode error: " .. tostring(decoded))
end

-- ─── Done ────────────────────────────────────────────────────────────────────

print("\n=== Test complete ===")
