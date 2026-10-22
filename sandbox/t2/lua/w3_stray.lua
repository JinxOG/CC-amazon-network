-- T2 stray sender (sandbox code, not a fleet file). Speaks as another turtle, the way two computers labelled node_177
-- did live on 2026-10-15: SECTOR_REQUEST for a job the server has given to someone else, then a SECTOR_DONE for a
-- sector of it. The dispatch server must refuse both and recall the sender.
-- stray.txt lines: node id to speak as, job id, sector x, sector z.
local proto = require("protocol")
local modem = peripheral.find("modem")
if not modem then error("w3_stray: no modem", 0) end
local f = fs.open("stray.txt", "r")
local from, job, sx, sz = f.readLine(), f.readLine(), tonumber(f.readLine()), tonumber(f.readLine())
f.close()
local function say(msgType, payload)
  proto.send(modem, proto.CH_SERVER, proto.encode(msgType, from, "server", payload))
end
for _ = 1, 3 do
  say(proto.MSG.SECTOR_REQUEST, { jobId = job })
  sleep(5)
end
say(proto.MSG.SECTOR_DONE, { jobId = job, sectorX = sx, sectorZ = sz, oreCount = 0 })
print("w3_stray: done speaking as " .. from .. " for " .. job)
