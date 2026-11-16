-- W3, the ATC card (2026-11-03): the base air-traffic control computer on the small fleet, first. The ATC boots
-- with the fleet, every turtle hears it and starts asking before each step into the base, and ordinary work still
-- gets done: three deliveries to three destinations and a one-sector mine job complete, then every turtle is back
-- on a dock cell, nobody reported STUCK, and no computer crashed.
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
  atc = os.getenv("W3_NO_ATC") == nil,
  steps = function(sim)
    local online = sim:capture_log("ATC online")
    local heard = sim:capture_log("ATC heard")
    local done = sim:capture_log("Job complete: job_")
    local dispatched = sim:capture_log("Dispatched job_")
    local stuck = sim:capture_log("STUCK ")
    local waits = sim:capture_log("ATC: waiting")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)   -- the warehouse ships every order in a chest
    sim:run_for(180000)
    if sim.layout_has_atc ~= false and os.getenv("W3_NO_ATC") == nil then
      sim:expect(#online.lines >= 1, "the ATC computer booted (" .. #online.lines .. ")")
      sim:expect(#heard.lines >= 10, "the fleet heard it (" .. #heard.lines .. " turtles)")
    end
    for i = 1, 3 do
      sim:dispatch{ type = "ORDER_DELIVERY", params = {
        items = { { name = "minecraft:cobblestone", count = 64 } },
        destination = { x = 112 + 6 * i, y = 67, z = -2830 } } }   -- inside base_loaded (x 110..260), west of the base
    end
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1, minerCount = 1 } }
    -- The SERVER's "Job complete" for each job it dispatched (2026-11-16). Counting any four lines passed on the
    -- warehouse's own "[WH] Job complete" for the deliveries while the mine job was still being worked: the run then
    -- ended with the miner out, and "every turtle is back on a dock" failed for a reason no check named.
    local function tally()
      local want, got, kinds = {}, {}, { DELIVER = 0, MINE = 0 }
      for _, l in ipairs(dispatched.lines) do
        local j, kind = l:match("Dispatched (job_%d+) %[(%u+)%]")
        if j and kinds[kind] then want[j] = kind end
      end
      for _, l in ipairs(done.lines) do
        local j = l:match("server#.-Job complete: (job_%d+)%s*$")
        if j and want[j] and not got[j] then got[j] = true; kinds[want[j]] = kinds[want[j]] + 1 end
      end
      return kinds.DELIVER, kinds.MINE
    end
    local ok = sim:run_until(function() local d, m = tally(); return d >= 3 and m >= 1 end, 4 * 3600000)
    local nd, nm = tally()
    sim:expect(ok, string.format("three deliveries and a mine job completed (the server's lines: %d deliveries, %d mine)", nd, nm))
    sim:run_for(15 * 60000)
    local off = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support" or c.role == "miner") then
        if not atDock(c.pos) then off[#off + 1] = string.format("%s@%s,%s,%s", c.name, tostring(c.pos and c.pos.x),
          tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z)) end
      end
    end
    sim.results.off_dock = table.concat(off, " ")
    sim:expect(#off == 0, "every turtle is back on a dock cell (" .. #off .. " not: " .. table.concat(off, " ") .. ")")
    sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. #stuck.lines .. ")")
    sim.results.atc_wait_lines = #waits.lines
    local crashes = 0
    local f = io.open(sim.run_dir .. "/trace.log", "rb")
    if f then for line in f:lines() do if line:find(" crash ", 1, true) then crashes = crashes + 1 end end; f:close() end
    -- With SANDBOX_NO_TRACE there is no trace to read: say so rather than pass on nothing.
    sim:expect(crashes == 0, "no computer crashed (" .. crashes .. (f and "" or "; NO TRACE, nothing judged") .. ")")
  end,
}
