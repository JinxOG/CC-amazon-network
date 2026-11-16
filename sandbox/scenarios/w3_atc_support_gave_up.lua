-- W3, the card "TOP PRIORITY (shakeout blocker) - ATC x delivery/support deadlock at the dispatch hole", the second
-- circle (w3_bay_types150 run 20261112-004658): under the ATC a delivery can wait minutes to be let out of its dock; its
-- support waits only 180 s for HOLE_READY (support_turtle.lua, frozen), gives up, JOB_ABORTs its delivery and goes home;
-- the delivery reached the hole later and waited its full STAGE_WAIT_S (600 s) for a support that had gone, holding the
-- dispatch hole -- so every pair behind timed out the same way (12 supports, a 16,140 s wait).
--
-- 2026-11-16 (T2 shakeout-side-c, the 160,-2752 turtle): the support must not give up at all while the ATC holds its
-- delivery, and a delivery never goes out without its support -- the support carries its chunk loading, and a lone
-- delivery froze in unloaded ground 11 times. The delivery now tells its support it is still coming (HOLE_PENDING).
--
-- Here: before the job, a computer that is not a turtle takes crossing J1 (every departure needs it) and keeps talking
-- for 240 s, then leaves. The delivery waits over 180 s to be let out.
-- CHECKS: the delivery was held over 180 s (evidence); the support did not give up (no no_hole_ready_from_delivery);
-- the delivery never went down alone; they went down together; the delivery completed; nobody holds the dispatch hole
-- at the end. On 67fa474 the support gives up at 180 s and the delivery goes down alone.
local HOLD_S = 240

local HOG = [[
local proto = require("protocol")
local m = peripheral.find("modem")
m.open(9999)
os.pullEvent("hog_go")
local n = 0
local function say(t, p) n = n + 1; p.nonce = n; proto.send(m, proto.CH_ATC, proto.encode(t, "node_hog", "atc", p)) end
local stop = os.clock() + ]] .. HOLD_S .. [[

while os.clock() < stop do say(proto.MSG.ATC_ENTER, { sec = "J1", route = {} }); sleep(20) end
say(proto.MSG.ATC_LEAVE, { sec = "J1" })
while true do sleep(3600) end
]]

local function secs(line) local h, m, s = line:match("T(%d+):(%d+):([%d%.]+)Z"); return h and (h * 3600 + m * 60 + s) end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local noReady = sim:capture_log("no_hole_ready_from_delivery")
    local goingAlone = sim:capture_log("going down alone")
    local together_ = sim:capture_log("Support staged")
    local waits = sim:capture_log("Still waiting")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    local hog = sim:add_computer{ id = 990, label = "node_hog", kind = "computer", modems = { "top" },
      pos = { x = 184, y = 67, z = -2820 } }
    local dir = sim.run_dir .. "/computers/990"
    local function put(name, text) local f = assert(io.open(dir .. "/" .. name, "wb")); f:write(text); f:close() end
    local pf = assert(io.open(sim.sched.code_dir .. "/protocol.lua", "rb")); put("protocol.lua", pf:read("*a")); pf:close()
    put("startup.lua", HOG)
    hog:boot()
    sim:run_for(180000)
    hog:queue_event({ "hog_go" })                     -- THE FAULT: J1 taken before the job, for 240 s
    sim:run_for(5000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local dname, sname = (dispatched.lines[1] or ""):match("%-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(dname ~= nil and sname ~= nil, "a delivery and its support were dispatched")
    if not dname then return end
    sim:run_until(function() return #done.lines >= 1 end, 3 * 3600000)
    sim:run_for(20 * 60000)
    local function first(lines, who)
      for _, l in ipairs(lines) do if l:find("[" .. who .. "]", 1, true) or l:find(who .. "#", 1, true) then return l end end
    end
    local supGave = false
    supGave = #noReady.lines > 0   -- the server's "retry: no_hole_ready_from_delivery", or the delivery hearing it
    local alone = first(goingAlone.lines, dname)
    local together = first(together_.lines, dname)
    local last = summary.lines[#summary.lines] or ""
    local heldLine
    for _, l in ipairs(waits.lines) do
      if l:find(dname .. "#", 1, true) and l:find("ATC: departure", 1, true) and (tonumber(l:match("Still waiting (%d+)s")) or 0) >= 180 then heldLine = l end
    end
    sim:expect(heldLine ~= nil, dname .. " was held at its dock over 180 s by the ATC, so the checks below "
      .. "have something to judge (" .. tostring((heldLine or "nothing"):sub(1, 120)) .. ")")
    sim:expect(not supGave, sname .. " did not give up on a delivery the ATC was still holding (no_hole_ready_from_delivery)")
    sim:expect(alone == nil, dname .. " never went out without its support, which carries its chunk loading ("
      .. tostring((alone or ""):sub(1, 120)) .. ")")
    sim:expect(together ~= nil, "they went down together ('Support staged')")
    sim:expect(#done.lines >= 1, "the delivery completed (" .. #done.lines .. ")")
    sim:expect(not last:find("DH=", 1, true), "nobody holds the dispatch hole at the end (" .. last:sub(-100) .. ")")
  end,
}
