-- W3, 2026-11-24 (Head Engineer, (D)'s throughput condition): a turtle walking back along the departures' tunnel books
-- the cells of its way back inside the zone near the base; a departure through those cells waits its turn and goes
-- after it, and a departure the other way is not held. w3_retrace_head_on's walk (43 s) was shorter than the server's
-- 60 s dispatch stagger, so no departure could be dispatched during it.
--
-- Here: one pair out to 250,67,-2700; out there the support reboots, finds the holding line behind rock and walks back
-- the way it came: 50 cells to the zone, then about 170 inside it. Once it is in the zone, walking its booked path,
-- a second order goes out --
-- W3_LONGWALK_OTHER unset: to 249,67,-2700, out along the walker's row (THROUGH its cells);
-- W3_LONGWALK_OTHER=1: to 124,67,-2824, west from the shaft's foot (none of its cells).
-- CHECKS: evidence -- the walk back's booked path is long, and the walk inside the zone took over 60 s; the second
-- pair was dispatched while it walked. THROUGH: the second pair waited "busy at path of" the walker, and was let out
-- only after the walker's climb was booked. OTHER: the second pair was let out while the walker walked, and never
-- waited for a path. Both: nobody gave up blocked by a turtle; the second order completed; all four end on a dock;
-- the ATC holds nothing at the end.
local OTHER = os.getenv("W3_LONGWALK_OTHER") ~= nil

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

local DEST = { x = 250, y = 67, z = -2700 }
local SECOND = OTHER and { x = 124, y = 67, z = -2824 } or { x = 249, y = 67, z = -2700 }

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local retracing = sim:capture_log("retracing the")
    local gaveUp = sim:capture_log("Gave up after 120s blocked by a turtle")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    local admitted = sim:capture_log("[ATC] admitted")
    local heldForPath = sim:capture_log("path of ")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    local function order(dest)
      sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
        destination = dest } }
    end
    order(DEST)
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d, s = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local function mine(cap, who)
      for _, l in ipairs(cap.lines) do if l:find(who .. "#", 1, true) or l:find("[" .. who .. "]", 1, true) then return l end end
      return nil
    end
    local function tOf(l) return l and l:match("^(%S+)") end
    -- THE FAULT: the support reboots out near the destination.
    local where
    sim:watch(function() local p = comps[s].pos; return p and p.y == 60 and p.z >= -2706 end,
      function(x) local p = comps[s].pos; where = string.format("%d,%d,%d", p.x, p.y, p.z); x:reboot(s) end)
    sim:run_until(function() return where ~= nil end, 40 * 60000)
    sim:expect(where ~= nil, s .. " rebooted out near the destination at " .. tostring(where))
    if not where then return end
    -- THE TRAFFIC: the second order as it starts back -- by its position: its log lines reach the sim in batches,
    -- and waiting for "retracing" sent the order two minutes late, after the walk.
    local sent
    -- Inside the zone (it ends at z -2750), so it walks its booked path as the second pair asks.
    sim:watch(function() local p = comps[s].pos; return p and p.y == 60 and p.z <= -2755 end,
      function() sent = true; order(SECOND) end)
    sim:run_until(function() return sent and #dispatched.lines >= 2 end, 30 * 60000)
    local job2, d2, s2 = (dispatched.lines[2] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job2 ~= nil, "a second pair was dispatched as it walked back")
    local all = { d, s, d2, s2 }
    local function home()
      for _, n in ipairs(all) do if n and not atDock(comps[n] and comps[n].pos) then return false end end
      return true
    end
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_for(5 * 60000)
    sim:run_until(function() return home() and (not job2 or serverDone(job2)) end, 3 * 3600000)
    sim:run_for(3 * 60000)
    -- the walk: its path's admission, and its climb's
    local pathAt, pathCells, climbAt, secondAt
    for _, l in ipairs(admitted.lines) do
      if l:find("admitted " .. s .. ":", 1, true) and l:find("(path of", 1, true) and not pathAt then
        pathAt, pathCells = tOf(l), tonumber(l:match("%(path of (%d+) cells%)"))
      elseif l:find("admitted " .. s .. ": DH", 1, true) and pathAt and not climbAt then
        climbAt = tOf(l)
      end
      if d2 and l:find(d2, 1, true) and not secondAt then secondAt = tOf(l) end
    end
    local function secs(a, b)
      local function ms(t) local h, m, sec = t:match("T(%d+):(%d+):([%d.]+)"); return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(sec)) end
      return (a and b) and (ms(b) - ms(a)) or nil
    end
    local walkS = secs(pathAt, climbAt)
    sim:expect(pathCells ~= nil and pathCells >= 150, "its way back in the zone is booked, " .. tostring(pathCells) .. " cells")
    sim:expect(walkS ~= nil and walkS > 60, "and it walked it for over 60 s (" .. tostring(walkS) .. " s)")
    local secondWaited = 0
    for _, l in ipairs(heldForPath.lines) do
      if (d2 and (l:find(d2 .. "#", 1, true) or l:find("[" .. d2 .. "]", 1, true)))
         or (s2 and (l:find(s2 .. "#", 1, true) or l:find("[" .. s2 .. "]", 1, true))) then
        if l:find("path of " .. s, 1, true) then secondWaited = secondWaited + 1 end
      end
    end
    if OTHER then
      sim:expect(secondAt ~= nil and pathAt ~= nil and climbAt ~= nil and secondAt > pathAt and secondAt < climbAt,
        "the pair going the other way was let out while it walked (" .. tostring(secondAt) .. " in " .. tostring(pathAt) .. " .. " .. tostring(climbAt) .. ")")
      sim:expect(secondWaited == 0, "and never waited for its path (" .. secondWaited .. ")")
    else
      sim:expect(secondWaited > 0, "the pair through its cells waited its turn (" .. secondWaited .. " times 'busy at path of " .. s .. "')")
      sim:expect(secondAt ~= nil and climbAt ~= nil and secondAt > climbAt,
        "and was let out after it, once its climb was booked (" .. tostring(secondAt) .. " after " .. tostring(climbAt) .. ")")
    end
    sim:expect(#gaveUp.lines == 0, "nobody gave up blocked by a turtle (" .. #gaveUp.lines .. ": " .. tostring((gaveUp.lines[1] or ""):sub(-100)) .. ")")
    sim:expect(job2 ~= nil and serverDone(job2), "the second order completed (" .. tostring(job2) .. ")")
    for _, n in ipairs(all) do
      if n then
        local p = comps[n] and comps[n].pos
        sim:expect(atDock(p), n .. " ends on a dock (" .. (p and string.format("%d,%d,%d", p.x, p.y, p.z) or "?") .. ")")
      end
    end
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find("0 section%(s%) held") ~= nil, "the ATC holds nothing at the end (" .. last:sub(-80) .. ")")
  end,
}
