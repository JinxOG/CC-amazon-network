-- T2 radio listener (sandbox code, not a fleet file): opens the channels listed in channels.txt on the wireless modem
-- beside this computer and writes every message it hears to numbered segment files radio.<n>.log, one line each:
--   <utc ms> <game seconds> <channel> <reply channel> <distance> <message with newlines as \n>
-- A segment holds about 150 KB; only the newest three are kept (the computer's disk is limited to 1 MB), so the T2
-- tool copies finished segments off the disk as it goes (control.RadioListener.harvest).
local SEGMENT_BYTES = 150000
local KEEP = 3

local modem = peripheral.find("modem")
if not modem then
  local f = fs.open("radio_error.txt", "w")
  f.write("no modem beside this computer; peripherals: " .. table.concat(peripheral.getNames(), ",") .. "\n")
  f.close()
  error("radio_log: no modem beside this computer", 0)
end
local count = 0
for line in io.lines("channels.txt") do
  local ch = tonumber(line)
  if ch and count < 128 then modem.open(ch); count = count + 1 end
end

local segment, size = 0, 0
local out = fs.open("radio.0.log", "w")
out.write(string.format("# listener %d opened %d channels at %d\n", os.getComputerID(), count, os.epoch("utc")))
out.flush()
while true do
  local _, _, ch, reply, message, distance = os.pullEvent("modem_message")
  local text = tostring(message):gsub("\\", "\\\\"):gsub("\n", "\\n")
  local line = string.format("%d %.2f %d %d %s %s\n", os.epoch("utc"), os.clock(), ch, reply or 0, tostring(distance and math.floor(distance) or "?"), text)
  out.write(line); out.flush()
  size = size + #line
  if size >= SEGMENT_BYTES then
    out.close()
    segment = segment + 1
    size = 0
    out = fs.open("radio." .. segment .. ".log", "w")
    local old = "radio." .. (segment - KEEP) .. ".log"
    if fs.exists(old) then fs.delete(old) end
  end
end
