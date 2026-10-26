-- T2 one-shot sender (sandbox code, not a fleet file): transmits one already-serialised fleet message on a channel,
-- the way a turtle's proto.send does, then stops. say.txt lines: channel, reply channel, the message text.
local modem = peripheral.find("modem")
if not modem then error("w3_say: no modem", 0) end
local f = fs.open("say.txt", "r")
local channel, reply, text = tonumber(f.readLine()), tonumber(f.readLine()), f.readLine()
f.close()
modem.transmit(channel, reply, text)
print("w3_say: sent on " .. channel .. ": " .. text:sub(1, 80))
