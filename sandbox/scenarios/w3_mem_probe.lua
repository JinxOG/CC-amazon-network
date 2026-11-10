-- W3, 2026-11-04: what grows in a 150-turtle run? The capacity week grows ~70 MB a simulated hour (2.7 GB at hour 11),
-- and capping each computer's printed lines (computer.lua OUTPUT_KEEP) changed nothing measurable. This runs the same
-- traffic as the capacity study for W3_PROBE_HOURS (default 3) and, every hour, counts the table entries reachable from
-- each computer's Lua environment by its top-level names, plus the scheduler and the stand-in bridge. The report lists
-- what grew the most between the first and the last sample, summed over all computers of one role.
local HOURS = tonumber(os.getenv("W3_PROBE_HOURS") or "3")

local function size(v, seen, depth)
  if type(v) ~= "table" or seen[v] or depth > 12 then return 0 end
  seen[v] = true
  local n = 0
  for k, x in next, v do
    n = n + 1
    if type(k) == "string" then n = n + 0 end
    n = n + size(x, seen, depth + 1)
    if type(k) == "table" then n = n + size(k, seen, depth + 1) end
  end
  return n
end

local function sample(sim)
  local out = {}
  local function add(key, n) out[key] = (out[key] or 0) + n end
  for _, c in ipairs(sim.sched.computers) do
    local role = c.role or c.kind or "?"
    if c.env then
      local seen = { [_G] = true, [string] = true, [table] = true, [math] = true }
      for k, v in next, c.env do
        if type(v) == "table" then add(role .. ".env." .. tostring(k), size(v, seen, 0)) end
      end
      -- the server's and turtles' own state lives in locals of the running chunk: walk the coroutine's stack
      if c.co and coroutine.status(c.co) == "suspended" then
        for level = 1, 40 do
          if not debug.getinfo(c.co, level, "S") then break end
          for i = 1, 250 do
            local name, v = debug.getlocal(c.co, level, i)
            if not name then break end
            if type(v) == "table" then add(role .. ".local." .. name, size(v, seen, 0)) end
          end
          local info = debug.getinfo(c.co, level, "f")
          local fn = info and info.func
          if fn then
            for i = 1, 255 do
              local name, v = debug.getupvalue(fn, i)
              if not name then break end
              if type(v) == "table" then add(role .. ".up." .. name, size(v, seen, 0)) end
            end
          end
        end
      end
    end
    add(role .. ".queue", #(c.queue or {}))
    add(role .. ".output", #(c.output or {}))
    for k, v in pairs(c) do
      if type(v) == "table" and k ~= "env" and k ~= "sched" and k ~= "queue" and k ~= "output" and k ~= "peripherals" then
        add(role .. ".comp." .. tostring(k), size(v, {}, 0))
      end
    end
  end
  for k, v in pairs(sim.sched) do
    if type(v) == "table" and k ~= "computers" then add("sched." .. tostring(k), size(v, {}, 0)) end
  end
  return out
end

return {
  world = "synthetic",
  seed = 1,
  -- per-bay docks (shakeout, 2026-11-10): worker/support bay 1 hold 16 delivery / 16 support, the other eight
  -- bays 128 miners, so the 150 are 118 miners (each with its loader), 16 delivery and 16 support. per_bay lays
  -- the same out on code from before per-bay types.
  miners = 118,
  workers = 150,
  per_bay = true,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    sim:storage_set("minecraft:cobblestone", 10000000)
    sim:storage_set("minecraft:chest", 100000)
    sim:run_for(5 * 60000)
    local area = sim.world:meta().areas[1]
    local nextZone, nextDest, ordered = 0, 0, 0
    local function orderZone()
      local x = area.x1 + 64 * 3 * (nextZone % 40)
      local z = area.z1 + 64 * 3 * math.floor(nextZone / 40)
      nextZone = nextZone + 1
      sim:dispatch{ type = "ORDER_MINE", params = { x1 = x, z1 = z, x2 = x + 64, z2 = z, minerCount = 2 } }
    end
    local function mines()
      local n = 0
      for _, j in pairs(sim.sched.standin.state.jobs or {}) do
        if type(j) == "table" and j.type == "MINE" and (j.status == "PENDING" or j.status == "ASSIGNED" or j.status == "IN_PROGRESS") then n = n + 1 end
      end
      return n
    end
    for _ = 1, 4 do orderZone() end
    local samples = {}
    collectgarbage("collect")
    samples[1] = { hour = 0, kb = collectgarbage("count"), s = sample(sim) }
    for hour = 1, HOURS do
      for tick = 1, 6 do
        sim:run_for(10 * 60000)
        local m = mines()
        while m < 4 do orderZone(); m = m + 1 end
        if tick % 3 == 0 then
          nextDest = nextDest % 4 + 1
          ordered = ordered + 1
          sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 32 + ordered % 32 } },
            destination = { x = 112 + 12 * nextDest, y = 67, z = -2820 - 4 * nextDest } } }
        end
      end
      collectgarbage("collect")
      samples[#samples + 1] = { hour = hour, kb = collectgarbage("count"), s = sample(sim) }
      io.stderr:write(string.format("probe hour %d: Lua heap %.0f MB\n", hour, samples[#samples].kb / 1024))
    end
    local a, b = samples[2] or samples[1], samples[#samples]
    local grew = {}
    for k, n in pairs(b.s) do grew[#grew + 1] = { k = k, d = n - (a.s[k] or 0), n = n } end
    table.sort(grew, function(x, y) return x.d > y.d end)
    local lines = {}
    for i = 1, math.min(25, #grew) do lines[i] = string.format("%s +%d (now %d)", grew[i].k, grew[i].d, grew[i].n) end
    sim.results.heap_mb = {}
    for i, s in ipairs(samples) do sim.results.heap_mb[i] = string.format("h%d %.0f", s.hour, s.kb / 1024) end
    sim.results.grew = table.concat(lines, "; ")
    local f = io.open(sim.run_dir .. "/mem_probe.txt", "w")
    f:write(table.concat(sim.results.heap_mb, "\n"), "\n\n", table.concat(lines, "\n"), "\n")
    f:close()
    sim:expect(true, "probe ran")
  end,
}
