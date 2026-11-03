-- W3 disk card, the capacity study (the user's request, 2026-11-02). Shared by w3_capacity_week_1mb.lua and
-- w3_capacity_week_10mb.lua: 150 turtles (8 miners with their loaders, 71 delivery, 71 support) for a simulated
-- week, on a server disk of `quota` bytes, with the fleet's code as it ships (stripped by the installer) and the
-- disk tidy running hourly.
--   * mining: four zones at a time, two miners each, three sectors per zone, each on fresh ground; a finished zone
--     is replaced by the next;
--   * delivery: an order every 30 minutes (64 cobblestone to a point east of the depot), several in flight at once;
--   * the server restarts once a simulated day, as the live one does at ~12:00 UTC.
-- Every simulated hour the size of every file on the server's disk, the free space, and the number of jobs by type
-- and state are written to <run>/capacity.csv, so a run cut short still leaves its data. The report's results give
-- each file's peak and last size, the lowest free space, and the job counts at the peak.
local HOUR = 60 * 60000
local DAY = 24 * HOUR

return function(quota, days)
  return {
    world = "synthetic",
    seed = 1,
    miners = 8,
    workers = 150,
    steps = function(sim)
      local done = sim:capture_log("Job complete: job_")
      local server
      for _, c in ipairs(sim.sched.computers) do if c.role == "server" then server = c end end
      local d = server.disk_obj
      d.quota = quota
      server.quota = quota
      sim:storage_set("minecraft:cobblestone", 10000000)
      sim:run_for(5 * 60000)

      local area = sim.world:meta().areas[1]
      local nextZone = 0
      local function orderZone()
        local x = area.x1 + 64 * 3 * (nextZone % 40)
        local z = area.z1 + 64 * 3 * math.floor(nextZone / 40)
        nextZone = nextZone + 1
        sim:dispatch{ type = "ORDER_MINE", params = { x1 = x, z1 = z, x2 = x + 64, z2 = z, minerCount = 2 } }
      end
      local function jobs()
        local js = sim.sched.standin.state.jobs or {}
        local mine, del, active = 0, 0, 0
        for _, j in pairs(js) do
          if type(j) == "table" and (j.status == "PENDING" or j.status == "ASSIGNED" or j.status == "IN_PROGRESS") then
            active = active + 1
            if j.type == "MINE" then mine = mine + 1 elseif j.type == "DELIVER" then del = del + 1 end
          end
        end
        return mine, del, active
      end

      local csv = io.open(sim.run_dir .. "/capacity.csv", "w")
      csv:write("hour,free,mine_active,deliver_active,jobs_active,files\n")
      local peak, last, minFree, peakAt = {}, {}, math.huge, nil
      local function sample(hour)
        local files = {}
        for _, name in ipairs(d:list("")) do
          local ok, sz = pcall(d.size, d, name)
          if not ok or type(sz) ~= "number" then sz = 0 end
          files[#files + 1] = name .. "=" .. sz
          last[name] = sz
          if sz > (peak[name] or -1) then peak[name] = sz end
        end
        table.sort(files)
        local free = d:free_space()
        local m, dl, a = jobs()
        if free < minFree then minFree, peakAt = free, { hour = hour, mine = m, deliver = dl, active = a } end
        csv:write(string.format("%d,%d,%d,%d,%d,%s\n", hour, free, m, dl, a, table.concat(files, ";")))
        csv:flush()
      end

      for _ = 1, 4 do orderZone() end
      local total = math.floor(days * 24 + 0.5)
      for hour = 1, total do
        for tick = 1, 6 do
          sim:run_for(10 * 60000)
          local m = jobs()
          while m < 4 do orderZone(); m = m + 1 end
          if tick % 3 == 0 then
            sim:dispatch{ type = "ORDER_DELIVERY", params = {
              items = { { name = "minecraft:cobblestone", count = 64 } },
              destination = { x = 320, y = 67, z = -2800 } } }
          end
        end
        if hour % 24 == 12 then sim:reboot(server.name) end      -- the daily restart
        sample(hour)
      end
      csv:close()

      local names = {}
      for name in pairs(peak) do names[#names + 1] = name end
      table.sort(names, function(a, b) return peak[a] > peak[b] end)
      local summary = {}
      for _, name in ipairs(names) do summary[#summary + 1] = string.format("%s peak %d last %d", name, peak[name], last[name] or 0) end
      sim.results.files = table.concat(summary, "; ")
      sim.results.min_free = minFree
      sim.results.at_min_free = peakAt
      sim.results.quota = quota
      sim.results.zones_ordered = nextZone
      sim.results.jobs_completed = #done.lines
      sim:expect(minFree > 0, string.format("the disk never filled (lowest free %d of %d)", minFree, quota))
    end,
  }
end
