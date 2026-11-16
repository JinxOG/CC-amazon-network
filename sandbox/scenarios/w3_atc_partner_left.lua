-- W3, the card "TOP PRIORITY (shakeout blocker) - ATC x delivery/support deadlock at the dispatch hole" (2026-11-11).
-- In the per-bay 150 sim (w3_bay_types150) a delivery waited STAGE_WAIT_S (600 s) at the hole for its support, gave up
-- and went down alone; the support was let in later, went down the hole after a turtle that had gone, ended at
-- "Delivery ascending - holding position" and held the dispatch hole (DH) for the rest of the run: waits of 19,353 s.
--
-- Here: one delivery. The moment it has stepped out of crossing J1, a computer that is not a turtle steps into J1 through
-- the ATC and KEEPS TALKING (so the ATC never sweeps it) for HOLD_S = 720 s -- longer than the delivery's 600 s wait --
-- then leaves J1. The support's way to the hole needs J1. So the delivery gives up; the support must stand down
-- instead of following.
-- 2026-11-16 (T2 shakeout-side-c): a delivery never goes out without its support, which carries its chunk loading --
-- one that went alone froze in unloaded ground. It now tells the support to stand down, goes home, and the job goes
-- back to be sent again with a support.
-- CHECKS: the delivery gave up waiting (evidence: "never staged"); the support stood down ("stood me down"); neither
-- went down the dispatch hole except together (every descent after the fault matched by a "Support staged"); the order
-- was delivered all the same, the job sent again served with no warehouse timeout or stray recall; at the end both are
-- on a dock and nobody holds DH.
-- On 67fa474 the delivery goes down alone.
local HOLD_S = 720
local function atDock(p)
  if not p or p.y ~= 67 then return false end
  for _, row in ipairs({ -2806, -2810, -2797, -2793 }) do
    if p.z == row then
      for b = 0, 4 do
        local dx = p.x - (157 + 14 * b)
        if dx ~= 0 and dx >= -4 and dx <= 4 then return true end
      end
    end
  end
  return false
end

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
print("hog: left J1")
while true do sleep(3600) end
]]

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local alone = sim:capture_log("never staged in")
    local stood = sim:capture_log("stood me down")
    local together = sim:capture_log("Support staged")
    local retries = sim:capture_log(" retry ")
    local descend = sim:capture_log("Descending dispatch hole")
    local holding = sim:capture_log("holding position")
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
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local line = dispatched.lines[1] or ""
    local djob, dname, sname = line:match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(dname ~= nil and sname ~= nil, "a delivery and its support were dispatched (" .. line:sub(-80) .. ")")
    if not dname then return end
    local dcomp, scomp
    for _, c in ipairs(sim.sched.computers) do
      if c.name == dname then dcomp = c end
      if c.name == sname then scomp = c end
    end
    local Wl = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
      setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
    local outOfJ1 = sim:run_until(function()
      local p = dcomp.pos
      return p and p.x and Wl.atcSection(p.x, p.y, p.z) == "W1"
    end, 10 * 60000)
    sim:expect(outOfJ1, dname .. " left crossing J1 on its way to the dispatch hole")
    if not outOfJ1 then return end
    local d0, t0 = #descend.lines, #together.lines
    hog:queue_event({ "hog_go" })                         -- THE FAULT: J1 held, and kept, past the delivery's wait
    -- Delivered: the server's "Job complete" for a job the delivery holds (not the warehouse's, not a failed try).
    local function delivered()
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(djob .. "$") then return true end end
      return false
    end
    sim:run_until(delivered, 3 * 3600000)
    sim:run_for(20 * 60000)

    local function by(lines, who, from)
      local n = 0
      for i = from or 1, #lines do if lines[i]:find("[" .. who .. "]", 1, true) or lines[i]:find(who .. "#", 1, true) then n = n + 1 end end
      return n
    end
    local gaveUp = by(alone.lines, dname) > 0
    local joint = by(together.lines, dname, t0 + 1)
    local delDescended = by(descend.lines, dname, d0 + 1)
    local supDescended = by(descend.lines, sname, d0 + 1)
    -- The job goes back and the support may well be given it again with another delivery: those descents are together
    -- too. Every delivery it was paired with, and the times they went down with it.
    local supJoint = 0
    for _, l in ipairs(dispatched.lines) do
      local d2, s2 = l:match("%-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
      if s2 == sname then supJoint = supJoint + by(together.lines, d2, t0 + 1) end
    end
    local supHeld = by(holding.lines, sname)
    local lastSummary = summary.lines[#summary.lines] or ""
    local dhHeld = lastSummary:match("DH=([%w_+]+)")
    sim:expect(gaveUp, dname .. " gave up waiting for its support ('never staged'): the checks below have "
      .. "something to judge")
    sim:expect(by(stood.lines, sname) > 0, sname .. " stood down ('stood me down')")
    sim:expect(delDescended <= joint, string.format("%s never went down the hole without its support (%d descents, "
      .. "%d together)", dname, delDescended, joint))
    -- ("holding position" is what a support says at every destination; DH held for good is the check at the end.)
    sim:expect(supDescended <= supJoint, string.format("%s never went down the hole except with a delivery that went "
      .. "with it (%d descents, %d together; %d 'holding position')", sname, supDescended, supJoint, supHeld))
    sim:expect(delivered(), "the order was delivered all the same, " .. tostring(djob) .. " (the server's 'Job complete'; last: " .. tostring(done.lines[#done.lines]):sub(1, 140) .. ")")
    -- The job sent again is served: before the server told the warehouse to drop it, the warehouse kept serving the
    -- first delivery under the same job id, the next holder timed out at the destination (warehouse_chest_timeout),
    -- and the warehouse's abort recalled the holder after that ("retry 3/3: recalled").
    local bad = {}
    for _, l in ipairs(retries.lines) do
      if l:find("Job " .. djob .. " retry", 1, true) and (l:find("warehouse_chest_timeout", 1, true) or l:find(": recalled", 1, true)) then
        bad[#bad + 1] = l:match("retry .*$")
      end
    end
    sim:expect(#bad == 0, "the job sent again was served, with no warehouse timeout or stray recall (" .. table.concat(bad, "; ") .. ")")
    sim:expect(atDock(dcomp.pos) and atDock(scomp.pos), string.format("both on a dock at the end (%s %s,%s,%s; %s %s,%s,%s)",
      dname, tostring(dcomp.pos.x), tostring(dcomp.pos.y), tostring(dcomp.pos.z),
      sname, tostring(scomp.pos.x), tostring(scomp.pos.y), tostring(scomp.pos.z)))
    sim:expect(dhHeld == nil, "nobody holds the dispatch hole at the end (last ATC summary: " .. lastSummary:sub(-140) .. ")")
  end,
}
