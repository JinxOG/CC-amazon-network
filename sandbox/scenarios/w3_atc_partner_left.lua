-- W3, the card "TOP PRIORITY (shakeout blocker) - ATC x delivery/support deadlock at the dispatch hole" (2026-11-11).
-- In the per-bay 150 sim (w3_bay_types150) a delivery waited STAGE_WAIT_S (600 s) at the hole for its support, gave up
-- and went down alone; the support was let in later, went down the hole after a turtle that had gone, ended at
-- "Delivery ascending - holding position" and held the dispatch hole (DH) for the rest of the run: waits of 19,353 s.
--
-- Here: one delivery. The moment it has stepped out of crossing J1, a computer that is not a turtle steps into J1 through
-- the ATC and KEEPS TALKING (so the ATC never sweeps it) for HOLD_S = 720 s -- longer than the delivery's 600 s wait --
-- then leaves J1. The support's way to the hole needs J1. So the delivery gives up and goes alone; the support must
-- stand down instead of following.
-- CHECKS: the delivery gave up and went alone (evidence: "never staged"); the support stood down ("went down without
-- me") and never went down the dispatch hole for this job; the delivery completed; at the end both are on a dock and
-- nobody holds DH. On the code before the fix the support goes down the hole after the delivery has left.
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
    local stood = sim:capture_log("went down without me")
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
    local dname, sname = line:match("%-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
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
    local d0 = #descend.lines
    hog:queue_event({ "hog_go" })                         -- THE FAULT: J1 held, and kept, past the delivery's wait
    sim:run_until(function() return #done.lines >= 1 end, 3 * 3600000)
    sim:run_for(20 * 60000)

    local function by(lines, who, from)
      local n = 0
      for i = from or 1, #lines do if lines[i]:find("[" .. who .. "]", 1, true) or lines[i]:find(who .. "#", 1, true) then n = n + 1 end end
      return n
    end
    local wentAlone = by(alone.lines, dname) > 0
    local supDescended = by(descend.lines, sname, d0 + 1)
    local supHeld = by(holding.lines, sname)
    local lastSummary = summary.lines[#summary.lines] or ""
    local dhHeld = lastSummary:match("DH=([%w_+]+)")
    sim:expect(wentAlone, dname .. " gave up waiting and went down alone ('never staged'): the checks below have "
      .. "something to judge")
    sim:expect(by(stood.lines, sname) > 0, sname .. " stood down ('went down without me')")
    sim:expect(supDescended == 0 and supHeld == 0, string.format("%s never went down the hole after it (%d descents, "
      .. "%d 'holding position')", sname, supDescended, supHeld))
    sim:expect(#done.lines >= 1, "the delivery completed (" .. #done.lines .. ")")
    sim:expect(atDock(dcomp.pos) and atDock(scomp.pos), string.format("both on a dock at the end (%s %s,%s,%s; %s %s,%s,%s)",
      dname, tostring(dcomp.pos.x), tostring(dcomp.pos.y), tostring(dcomp.pos.z),
      sname, tostring(scomp.pos.x), tostring(scomp.pos.y), tostring(scomp.pos.z)))
    sim:expect(dhHeld == nil, "nobody holds the dispatch hole at the end (last ATC summary: " .. lastSummary:sub(-140) .. ")")
  end,
}
