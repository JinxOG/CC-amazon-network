-- W3 card "Warn about low server disk while there is still room" (fix 2ca13d6). The dispatch computer's disk is
-- filled with a dummy file until 340 KB is free (below the 350 KB warning, above the 300 KB floor), then to 290 KB.
-- The server checks once a minute: it must WARN ("Disk low on the server computer") within 2 minutes, then ERROR
-- ("below the 300 KB floor") within 2 minutes of crossing the floor. On 2ca13d6~1 the warning fired only below
-- 120 KB, so neither line appears (the 2026-09-10 disk drop that nobody was told about).
local Disk = require("core.disk")

local function server(sim)
  for _, c in ipairs(sim.sched.computers) do if c.role == "server" then return c end end
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local warned  = sim:capture_log("Disk low on the server computer")
    local floored = sim:capture_log("below the 300 KB floor")
    sim:run_for(120000)
    local s = server(sim)
    sim:expect(s ~= nil, "found the dispatch computer")
    if not s then return end
    local function free() return Disk.new(s.disk, s.quota):free_space() end   -- a fresh view each time
    local function fillTo(freeBytes, name)
      local need = free() - freeBytes
      if need > 0 then sim:write_file(s.name, name, string.rep("x", need)) end
      return free()
    end
    local w0 = #warned.lines
    local f1 = fillTo(340000, "w3_filler_1.bin")                      -- THE TEST, step 1
    local warn = sim:run_until(function() return #warned.lines > w0 end, 3 * 60000)
    sim:expect(warn, string.format("WARN within 3 minutes at %d bytes free", f1))
    local e0 = #floored.lines
    local f2 = fillTo(290000, "w3_filler_2.bin")                      -- step 2
    local err = sim:run_until(function() return #floored.lines > e0 end, 3 * 60000)
    sim:expect(err, string.format("ERROR 'below the 300 KB floor' within 3 minutes at %d bytes free", f2))
    sim:delete_file(s.name, "w3_filler_1.bin")
    sim:delete_file(s.name, "w3_filler_2.bin")
    local quiet0 = #warned.lines + #floored.lines
    sim:run_for(10 * 60000)
    sim:expect(#warned.lines + #floored.lines == quiet0, "no disk warning once the space is back")
    sim.results.free_at_warn, sim.results.free_at_floor = f1, f2
  end,
}
