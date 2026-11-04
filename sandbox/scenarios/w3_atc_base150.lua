-- W3, the ATC card (2026-11-03): the 150-turtle base under the air-traffic control computer, with one fault.
--   W3_ATC_FAULT = none | atc | server | world | stuck   (default none)
--   W3_ATC_HOURS = simulated hours of traffic before the drain (default 6)
--   W3_ATC_DRAIN_MIN = the most the drain may take (default 90)
--   W3_NO_ATC=1  no ATC computer: the same traffic on code without one (today's master) -- every check must be
--                able to fail, and this is where they do
-- The fleet: 8 miners (each with its loader), 71 delivery, 71 support. At the start a BURST of 20 deliveries at
-- once (card addition C); then two zones mining at a time and a delivery every 10 minutes to four destinations
-- inside the loaded area. After the traffic, no new orders and a drain of up to 90 minutes.
-- CHECKS (bounds stated here, and in docs/superpowers/specs/2026-11-03-base-atc-design.md):
--   * every turtle ends on a dock cell (zero gridlock), and none is ERROR/STUCK unless the fault made it so
--   * no turtle logged a wait of more than 30 s at a section edge ('Still waiting Ns -- ATC: waiting to enter')
--   * nobody waited to enter the dispatch corner (the dispatch hole never holds a queue)
--   * inside the base, nobody was blocked by a turtle for more than 30 s
--   * per fault: atc -- while it is down no turtle enters a new section, and all resume after; server -- turtles
--     on their way home while it is down reach their docks before it returns; world -- the ATC rebuilds from
--     reports and the base clears; stuck -- the stuck turtle's job is back in the queue within 4 minutes
local HOUR = 3600000
local FAULT = os.getenv("W3_ATC_FAULT") or "none"
local HOURS = tonumber(os.getenv("W3_ATC_HOURS") or "6")
local NO_ATC = os.getenv("W3_NO_ATC") ~= nil
local DRAIN_MIN = tonumber(os.getenv("W3_ATC_DRAIN_MIN") or "90")   -- today's code jams, its log floods, and the
                                                                     -- sim runs out of memory near sim hour 1.9

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

-- Inside the building's traffic area (the floor of the base, off the docks): a rough box, for sampling.
local function inBase(p)
  return p and p.y == 67 and p.x >= 143 and p.x <= 228 and p.z >= -2813 and p.z <= -2782 and not atDock(p)
end

local function workers(sim)
  local out = {}
  for _, c in ipairs(sim.sched.computers) do
    if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support" or c.role == "miner") then
      out[#out + 1] = c
    end
  end
  return out
end

local function maxSeconds(lines, pattern)
  local m = 0
  for _, l in ipairs(lines) do
    local s = tonumber(l:match("Still waiting (%d+)s"))
    if s and l:find(pattern, 1, true) and s > m then m = s end
  end
  return m
end

return {
  world = "synthetic",
  seed = 1,
  miners = 8,
  workers = 150,
  atc = not NO_ATC,
  preset_docks = os.getenv("W3_ATC_BOOT_RUSH") == nil,   -- the server knows the docks, as a real base does
  steps = function(sim)
    local edgeWaits = sim:capture_log("ATC: waiting to enter")
    local blocked = sim:capture_log("a turtle is blocking")
    local stuck = sim:capture_log("STUCK ")
    local docked = sim:capture_log("Docked at bay")
    local done = sim:capture_log("Job complete: job_")
    local settled = sim:capture_log("settled: rebuilt")
    sim:storage_set("minecraft:cobblestone", 10000000)
    sim:storage_set("minecraft:chest", 100000)
    sim:run_for(5 * 60000)

    local area = sim.world:meta().areas[1]
    local nextZone, nextDest = 0, 0
    local function orderZone()
      local x = area.x1 + 64 * 3 * (nextZone % 40)
      local z = area.z1 + 64 * 3 * math.floor(nextZone / 40)
      nextZone = nextZone + 1
      sim:dispatch{ type = "ORDER_MINE", params = { x1 = x, z1 = z, x2 = x + 64, z2 = z, minerCount = 2 } }
    end
    local function orderDelivery()
      nextDest = nextDest % 4 + 1
      sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 64 } },
        destination = { x = 112 + 6 * nextDest, y = 67, z = -2830 } } }
    end
    local function activeMines()
      local n = 0
      for _, j in pairs(sim.sched.standin.state.jobs or {}) do
        if type(j) == "table" and j.type == "MINE" and (j.status == "PENDING" or j.status == "ASSIGNED" or j.status == "IN_PROGRESS") then n = n + 1 end
      end
      return n
    end

    -- THE BURST (addition C): twenty deliveries at once
    for _ = 1, 20 do orderDelivery() end
    orderZone(); orderZone()

    local faultAt = math.floor(HOURS / 2 * 60) * 60000      -- halfway
    local faultDone, faultInfo = false, {}
    local minute = 0
    local function stepMinute()
      sim:run_for(60000)
      minute = minute + 1
      if minute % 10 == 0 then orderDelivery() end
      while activeMines() < 2 do orderZone() end
    end

    while minute * 60000 < HOURS * HOUR do
      if not faultDone and minute * 60000 >= faultAt then
        faultDone = true
        if FAULT == "atc" and not NO_ATC then
          -- record every turtle's section-ish box position, then check nobody moves into the base while it is down
          sim:atc_crash(sim.clock:now() - sim.t0, 5 * 60000)
          sim:run_for(15000)                                  -- the crash has happened; in-flight steps finish
          local before = {}
          for _, c in ipairs(workers(sim)) do before[c.name] = { x = c.pos.x, y = c.pos.y, z = c.pos.z } end
          local entered = 0
          for _ = 1, 26 do                                     -- 4m20s of the 5 min down, every 10 s
            sim:run_for(10000)
            for _, c in ipairs(workers(sim)) do
              local b = before[c.name]
              if b and not inBase(b) and inBase(c.pos) then entered = entered + 1; before[c.name] = { x = c.pos.x, y = c.pos.y, z = c.pos.z } end
            end
          end
          faultInfo.entered_while_down = entered
          sim:expect(entered == 0, "with the ATC down, no turtle moved into the base (" .. entered .. ")")
          minute = minute + 5
        elseif FAULT == "server" then
          local d0 = #docked.lines
          sim:server_crash(sim.clock:now() - sim.t0, 20 * 60000)
          sim:run_for(20 * 60000 - 30000)
          faultInfo.docked_while_server_down = #docked.lines - d0
          local inside = 0
          for _, c in ipairs(workers(sim)) do if inBase(c.pos) then inside = inside + 1 end end
          faultInfo.in_base_at_end_of_outage = inside
          sim:expect(#docked.lines - d0 > 0, "with the server down, turtles still docked (" .. (#docked.lines - d0) .. ")")
          sim:expect(inside == 0, "and none was left on the base floor off a dock when it came back (" .. inside .. ")")
          minute = minute + 20
        elseif FAULT == "world" then
          local s0 = #settled.lines
          sim:world_restart(sim.clock:now() - sim.t0, { gps_delay = 30000 })
          sim:run_for(10 * 60000)
          if not NO_ATC then
            sim:expect(#settled.lines > s0, "the ATC rebuilt from reports after the restart ("
              .. (settled.lines[#settled.lines] or "no line") .. ")")
          end
          minute = minute + 10
        elseif FAULT == "stuck" then
          -- the first turtle with a job seen in a taxiway lane: its moves now find a turtle in the way, for ever
          local victim, jobId
          for _ = 1, 120 do
            for _, c in ipairs(workers(sim)) do
              local p = c.pos
              if p and p.y == 67 and p.z >= -2803 and p.z <= -2801 and p.x > 143 and p.x < 228 then
                for id, j in pairs(sim.sched.standin.state.jobs or {}) do
                  if type(j) == "table" and j.assignedTo == c.name and j.status == "IN_PROGRESS" then victim, jobId = c, id end
                end
              end
              if victim then break end
            end
            if victim then break end
            sim:run_for(5000)
          end
          sim:expect(victim ~= nil, "found a turtle with a job in a taxiway lane to make stuck")
          if victim then
            sim:eval(victim.name, "local t = { name = 'computercraft:turtle_advanced' }"
              .. "; turtle.forward = function() return false, 'Movement obstructed' end"
              .. "; turtle.back = turtle.forward; turtle.up = turtle.forward; turtle.down = turtle.forward"
              .. "; turtle.inspect = function() return true, t end; turtle.inspectUp = turtle.inspect"
              .. "; turtle.inspectDown = turtle.inspect")
            local t0 = sim.clock:now()
            local back = sim:run_until(function()
              local j = (sim.sched.standin.state.jobs or {})[jobId]
              return type(j) == "table" and j.assignedTo ~= victim.name
            end, 10 * 60000)
            faultInfo.stuck_victim, faultInfo.stuck_job = victim.name, tostring(jobId)
            faultInfo.stuck_job_back_after_s = back and math.floor((sim.clock:now() - t0) / 1000) or -1
            sim:expect(back and sim.clock:now() - t0 <= 4 * 60000,
              string.format("the stuck turtle's job %s went back to the queue within 4 minutes (%s s)", tostring(jobId),
                tostring(faultInfo.stuck_job_back_after_s)))
            faultInfo.victim = victim
          end
        end
      else
        stepMinute()
      end
    end

    -- the drain: no new orders; everybody home
    local function offDock()
      local off = {}
      for _, c in ipairs(workers(sim)) do
        if not atDock(c.pos) and c ~= faultInfo.victim then off[#off + 1] = c end
      end
      return off
    end
    sim:run_until(function() return #offDock() == 0 and activeMines() == 0 end, DRAIN_MIN * 60000)
    local off = offDock()
    local where = {}
    for i = 1, math.min(#off, 12) do
      local p = off[i].pos
      where[#where + 1] = string.format("%s@%s,%s,%s", off[i].name, tostring(p and p.x), tostring(p and p.y), tostring(p and p.z))
    end
    sim.results.fault = FAULT
    sim.results.atc = not NO_ATC
    sim.results.jobs_completed = #done.lines
    sim.results.off_dock = #off
    sim.results.off_dock_where = table.concat(where, " ")
    for k, v in pairs(faultInfo) do if type(v) ~= "table" then sim.results[k] = v end end
    sim:expect(#off == 0, "every turtle ended on a dock cell (" .. #off .. " not: " .. table.concat(where, " ") .. ")")
    local edge = maxSeconds(edgeWaits.lines, "waiting to enter")
    sim.results.max_edge_wait_s = edge
    sim:expect(edge <= 30, "no turtle waited more than 30 s at a section edge (worst " .. edge .. " s)")
    local dh = 0
    for _, l in ipairs(edgeWaits.lines) do if l:find("waiting to enter DH", 1, true) then dh = dh + 1 end end
    sim:expect(dh == 0, "nobody queued to enter the dispatch corner (" .. dh .. ")")
    -- The same two questions asked of the turtles themselves, so they can fail on code with no ATC (whose own wait
    -- lines a no-ATC run never prints): blocked by a turtle for over 30 s in the base, and at the dispatch hole.
    local inBaseBlocked, dhBlocked = 0, 0
    for _, l in ipairs(blocked.lines) do
      local x, y, z = l:match("blocking %a+ at (%-?%d+),(%-?%d+),(%-?%d+)")
      local s = tonumber(l:match("Still waiting (%d+)s"))
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      if x and s and s > 30 then
        if inBase({ x = x, y = y, z = z }) then inBaseBlocked = inBaseBlocked + 1 end
        if (x == 143 and z <= -2803 and z >= -2813 and y >= 60 and y <= 67) or (y == 67 and z == -2803 and x >= 144 and x <= 156) then
          dhBlocked = dhBlocked + 1
        end
      end
    end
    sim.results.dispatch_hole_blocked_over_30s = dhBlocked
    sim:expect(dhBlocked == 0, "nobody stood blocked over 30 s at the dispatch hole or in its lane (" .. dhBlocked .. " lines)")
    sim.results.in_base_blocked_over_30s = inBaseBlocked
    sim:expect(inBaseBlocked == 0, "inside the base nobody was blocked by a turtle for more than 30 s (" .. inBaseBlocked .. " lines)")
    if FAULT ~= "stuck" then
      sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. #stuck.lines .. ")")
    end
    sim.results.edge_wait_lines = #edgeWaits.lines
  end,
}
