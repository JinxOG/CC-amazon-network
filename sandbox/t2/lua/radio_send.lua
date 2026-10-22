-- T2 radio probe sender (sandbox code, not a fleet file): transmits a known message on a known channel every N seconds, with its
-- own send time in the text, and starts a timer so the event log has a known event for this computer.
-- probe.txt lines: channel, reply channel, text, interval seconds (default 5).
local modem = peripheral.find("modem")
if not modem then error("radio_send: no modem", 0) end
local f = fs.open("probe.txt", "r")
local channel, reply, text, interval = f.readLine(), f.readLine(), f.readLine(), f.readLine()
f.close()
channel, reply, interval = tonumber(channel), tonumber(reply), tonumber(interval) or 5
local n = 0
while true do
  n = n + 1
  modem.transmit(channel, reply, text .. " #" .. n .. " t=" .. os.epoch("utc"))
  local t = os.startTimer(interval)
  repeat local _, id = os.pullEvent("timer") until id == t
end
