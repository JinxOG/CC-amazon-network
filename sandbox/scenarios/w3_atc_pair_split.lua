-- W3, the ATC card, a fault the 150-turtle week found (sim 20261104-183352, 2026-09-23 06:48-06:52): A DELIVERY PAIR
-- SPLIT AT THE DISPATCH HOLE. The delivery reached the hole and waited 60 s for its support to stage; the ATC was holding
-- the support back (a returning turtle had the crossings booked, 100 s); the delivery went down alone; the support came
-- out a minute later, chased the delivery's latest position in a straight line along the wrong tunnel row, met rock (it
-- cannot dig) and stayed in the departure tunnel -- and every later departure piled up behind it.
--
-- Here: one delivery. The moment the delivery is in the dispatch corner (it has left crossing J1 behind), a computer
-- that is not a turtle steps into J1 through the ATC and then says nothing, as a turtle that died there would. The
-- ATC lets a silent holder go after STALE_MS (180 s). The support's route needs J1, so it is held back ~3 minutes.
-- CHECKS: the support was really held back over 60 s (evidence); the pair still went down TOGETHER; the job
-- completed; both turtles docked; nobody's return home failed.
-- On the code before the fix the delivery stops waiting at 60 s and goes alone.
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
proto.send(m, proto.CH_ATC, proto.encode(proto.MSG.ATC_ENTER, "node_hog", "atc", { sec = "J1", route = {}, nonce = 1 }))
print("hog: asked for J1")
while true do sleep(3600) end
]]

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,   -- the server knows the docks, as a real base does (no start-up dock swap in the way)
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local together = sim:capture_log("Support staged")
    local done = sim:capture_log("Job complete: job_")
    local failed = sim:capture_log("Return home failed")
    local waits = sim:capture_log("departure waiting to be let in (busy at J1)")
    local stuck = sim:capture_log("STUCK ")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    -- the holder boots now and waits for the word, so it can act the moment the delivery is out of J1
    local hog = sim:add_computer{ id = 990, label = "node_hog", kind = "computer", modems = { "top" },
      pos = { x = 184, y = 67, z = -2820 } }
    local dir = sim.run_dir .. "/computers/990"
    local function put(name, text) local f = assert(io.open(dir .. "/" .. name, "wb")); f:write(text); f:close() end
    local pf = assert(io.open(sim.sched.code_dir .. "/protocol.lua", "rb")); put("protocol.lua", pf:read("*a")); pf:close()
    put("startup.lua", HOG)
    hog:boot()
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }        -- the incident's destination
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
    -- THE FAULT: the moment the delivery has stepped out of J1 (into W1), J1 is taken by a holder that then goes silent.
    local outOfJ1 = sim:run_until(function()
      local p = dcomp.pos
      return p and p.x and Wl.atcSection(p.x, p.y, p.z) == "W1"
    end, 10 * 60000)
    sim:expect(outOfJ1, dname .. " left crossing J1 on its way to the dispatch hole")
    if not outOfJ1 then return end
    hog:queue_event({ "hog_go" })
    local ok = sim:run_until(function() return #done.lines >= 1 end, 3 * 3600000)
    sim:run_for(10 * 60000)
    local held = 0
    for _, l in ipairs(waits.lines) do
      if l:find(sname, 1, true) then
        local s = tonumber(l:match("Still waiting (%d+)s")) or 0
        if s > held then held = s end
      end
    end
    local joint = false
    for _, l in ipairs(together.lines) do if l:find(dname, 1, true) then joint = true end end
    sim:expect(held > 60, string.format("%s was held back over 60 s by the silent holder of J1 (longest wait %d s): "
      .. "the check below has something to judge", sname, held))
    sim:expect(joint, dname .. " waited for its support and they went down together ('Support staged')")
    sim:expect(ok, "the delivery completed (" .. #done.lines .. ")")
    sim:expect(#failed.lines == 0, "nobody's return home failed (" .. (failed.lines[1] or "none") .. ")")
    sim:expect(atDock(dcomp.pos) and atDock(scomp.pos), string.format("both docked (%s %s,%s,%s; %s %s,%s,%s)",
      dname, tostring(dcomp.pos.x), tostring(dcomp.pos.y), tostring(dcomp.pos.z),
      sname, tostring(scomp.pos.x), tostring(scomp.pos.y), tostring(scomp.pos.z)))
    sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. #stuck.lines .. ")")
    sim.results.held_s, sim.results.together = held, joint
  end,
}
