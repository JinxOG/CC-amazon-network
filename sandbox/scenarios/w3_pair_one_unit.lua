-- W3, 2026-11-17: R2 of docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md -- THE PAIR'S DEPARTURE IS
-- ADMITTED AS ONE UNIT. The delivery used to be let out alone, and its support asked for its own way only once the
-- delivery stood at the hole: anything let in between held the support back while its delivery held the dispatch
-- hole. Every STAGE_WAIT_S expiry (600 s) of the last week sat in that gap (side-c, side-d, side-e, 150-turtle sims).
--
-- Here: one delivery. The moment it has stepped out of crossing J1, a computer that is not a turtle asks the ATC for
-- J1 and then says nothing (as in w3_atc_pair_split). The support's way needs J1.
-- CHECKS: the holder was started the moment the delivery left J1 (evidence: the check of that name); the delivery waited at the hole no
-- longer than its support's walk (from "At hole" to "Support staged" under 60 s); the support was never held back
-- once its delivery was at the hole; they went down together; the job completed; both docked.
-- On 7eae8d6 (R1+R4) the holder gets J1, the support waits behind it ~180 s and its delivery holds the hole.
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
    local waits = sim:capture_log("departure waiting to be let in")
    local atHole = sim:capture_log("At hole")
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
    local function secs(l) local h, m, s = l:match("T(%d+):(%d+):([%d%.]+)Z"); return h and (h * 3600 + m * 60 + s) end
    local function by(lines, who)
      local out = {}
      for _, l in ipairs(lines) do if l:find("[" .. who .. "]", 1, true) or l:find(who .. "#", 1, true) then out[#out + 1] = l end end
      return out
    end
    local hole = by(atHole.lines, dname)[1]
    local staged
    for _, l in ipairs(together.lines) do if l:find(dname, 1, true) then staged = staged or l end end
    local holeWait = (hole and staged) and (secs(staged) - secs(hole)) or nil
    local supHeld = 0
    for _, l in ipairs(by(waits.lines, sname)) do
      if hole and l:sub(1, 23) > hole:sub(1, 23) then supHeld = math.max(supHeld, tonumber(l:match("Still waiting (%d+)s")) or 0) end
    end
    sim:expect(holeWait ~= nil and holeWait < 60, string.format("%s waited at the hole no longer than its support's walk (%s s)",
      dname, tostring(holeWait and math.floor(holeWait))))
    sim:expect(supHeld == 0, string.format("%s was never held back once its delivery was at the hole (longest %d s)", sname, supHeld))
    sim:expect(staged ~= nil, dname .. " and its support went down together ('Support staged')")
    sim:expect(ok, "the delivery completed (" .. #done.lines .. ")")
    sim:expect(#failed.lines == 0, "nobody's return home failed (" .. (failed.lines[1] or "none") .. ")")
    sim:expect(atDock(dcomp.pos) and atDock(scomp.pos), string.format("both docked (%s %s,%s,%s; %s %s,%s,%s)",
      dname, tostring(dcomp.pos.x), tostring(dcomp.pos.y), tostring(dcomp.pos.z),
      sname, tostring(scomp.pos.x), tostring(scomp.pos.y), tostring(scomp.pos.z)))
  end,
}
