-- W3, 2026-11-16 (sim w3_side_atc on 17d6b30; T2 shakeout-side-d): a turtle that waits inside the base without asking
-- the ATC anything -- for a GPS fix to measure its facing after a reboot, or behind a turtle that does not move -- was
-- taken for dead at 180 s of silence; the ATC gave its section away under it, let another turtle into the next one,
-- and the two met head-on, each in the section the other needed: STUCK both, the base jammed.
--
-- Here: one delivery leaves; once it is inside the base on its way to the dispatch hole (crossing J1 or the lane W1),
-- every GPS host goes off for 5 minutes and the delivery reboots: it cannot measure its facing and waits where it
-- stands. A second order is placed straight away, so another pair wants the same sections. A computer that is not a
-- turtle sends the ATC an empty report every 10 s, as a busy base's other turtles would: a base where nobody talks to
-- the ATC is counted as the ATC being deaf, and nobody's silence counts then (the server holds dispatch with no GPS).
-- CHECKS: the delivery rebooted in a base section and waited there over 180 s (evidence); the ATC never dropped a
-- section it stood in; nobody reported STUCK; both deliveries completed; every delivery and support ends on a dock;
-- the ATC holds nothing at the end. On 17d6b30 the ATC drops the rebooted delivery's section at 180 s.
local CHATTER = [[
local proto = require("protocol")
local m = peripheral.find("modem")
m.open(9999)
local n = 0
while true do n = n + 1; proto.send(m, proto.CH_ATC, proto.encode(proto.MSG.ATC_REPORT, "node_chatter", "atc", { route = {}, nonce = n })); sleep(10) end
]]

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

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local noFix = sim:capture_log("NOT moving until both are measured")
    local measured = sim:capture_log("Position and facing measured after")
    local dropped = sim:capture_log("booking dropped, including")
    local stuck = sim:capture_log("STUCK ")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    local ch = sim:add_computer{ id = 990, label = "node_chatter", kind = "computer", modems = { "top" },
      pos = { x = 184, y = 67, z = -2820 } }
    local dir = sim.run_dir .. "/computers/990"
    local function put(name, text) local f = assert(io.open(dir .. "/" .. name, "wb")); f:write(text); f:close() end
    local pf = assert(io.open(sim.sched.code_dir .. "/protocol.lua", "rb")); put("protocol.lua", pf:read("*a")); pf:close()
    put("startup.lua", CHATTER)
    ch:boot()
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local djob, dname = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)")
    sim:expect(dname ~= nil, "a delivery was dispatched")
    if not dname then return end
    local dcomp
    for _, c in ipairs(sim.sched.computers) do if c.name == dname then dcomp = c end end
    local Wl = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
      setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
    local inside = sim:run_until(function()
      local p = dcomp.pos
      local s = p and p.x and Wl.atcSection(p.x, p.y, p.z)
      return s == "J1" or s == "W1"
    end, 10 * 60000)
    sim:expect(inside, dname .. " was inside the base on its way to the hole")
    if not inside then return end
    local sec = Wl.atcSection(dcomp.pos.x, dcomp.pos.y, dcomp.pos.z)
    -- THE FAULT: no GPS for 5 minutes, and the delivery reboots where it stands.
    local n0, d0 = #noFix.lines, #dropped.lines
    sim:gps_down(sim.clock:now() - sim.t0, 5 * 60000)
    dcomp:reboot()
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 130, y = 67, z = -2824 } } }
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    local function second()
      for _, l in ipairs(dispatched.lines) do
        local j = l:match("Dispatched (job_%d+) %[DELIVER%]")
        if j and j ~= djob then return j end
      end
    end
    sim:run_until(function() return second() and serverDone(djob) and serverDone(second()) end, 3 * 3600000)
    sim:run_for(15 * 60000)

    local function by(lines, who, from)
      local out = {}
      for i = from or 1, #lines do local l = lines[i]; if l:find("[" .. who .. "]", 1, true) or l:find(who .. "#", 1, true) then out[#out + 1] = l end end
      return out
    end
    local waitedLine = by(noFix.lines, dname, n0 + 1)[1]
    local measuredLine = by(measured.lines, dname)[#by(measured.lines, dname)]
    local tries = tonumber(measuredLine and measuredLine:match("measured after (%d+) retries")) or 0
    sim:expect(waitedLine ~= nil and tries * 10 > 180, string.format("%s rebooted in %s and waited there over 180 s for a fix "
      .. "(%d tries of 10 s): the checks below have something to judge", dname, tostring(sec), tries))
    local lost = {}
    for i = d0 + 1, #dropped.lines do if dropped.lines[i]:find(dname, 1, true) then lost[#lost + 1] = dropped.lines[i] end end
    sim:expect(#lost == 0, "the ATC never gave away a section " .. dname .. " stood in (" .. tostring((lost[1] or "none"):sub(1, 150)) .. ")")
    sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. tostring((stuck.lines[1] or "none"):sub(1, 150)) .. ")")
    local j2 = second()
    sim:expect(serverDone(djob) and j2 ~= nil and serverDone(j2), string.format("both deliveries completed (%s, %s)", djob, tostring(j2)))
    local off = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support") and not atDock(c.pos) then
        off[#off + 1] = string.format("%s@%s,%s,%s", c.name, tostring(c.pos and c.pos.x), tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z))
      end
    end
    sim:expect(#off == 0, "every delivery and support turtle is on a dock at the end (" .. table.concat(off, " ") .. ")")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "the ATC holds nothing at the end (" .. last:sub(-110) .. ")")
  end,
}
