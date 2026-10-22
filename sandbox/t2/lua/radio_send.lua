-- T2 radio probe sender (sandbox code, not a fleet file): every 5 seconds transmits a known message on a known channel, and
-- starts a timer so the event log has a known event for this computer. Parameters come from probe.txt: channel, reply, text.
local modem = peripheral.find("modem")
if not modem then error("radio_send: no modem", 0) end
local f = fs.open("probe.txt", "r")
local channel, reply, text = f.readLine(), f.readLine(), f.readLine()
f.close()
channel, reply = tonumber(channel), tonumber(reply)
local n = 0
while true do
  n = n + 1
  modem.transmit(channel, reply, text .. " #" .. n)
  local t = os.startTimer(5)
  repeat local _, id = os.pullEvent("timer") until id == t
end
