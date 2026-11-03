-- W3 disk card, part 2: the server keeps its own disk tidy (no in-game visits), on the default 1,000,000-byte quota.
-- The fleet is updated first, so the server runs as startup.lua and the installer's central_server.lua is left
-- unused, exactly as on a real server. Then the leftovers a long-running server collects are put on its disk (a temp
-- file from an interrupted save, a 40 KB crash log), two miners are given a job each, and the server runs for 70
-- minutes -- across its hourly tidy -- while both jobs hold live state. The tidy must remove the dead copy and the
-- leftovers, trim the crash log to its newest 8 KB, log what it freed, and leave the live job state alone: both
-- jobs complete. Before the change none of it is removed.
local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local fanned = sim:capture_log("UPDATE_ALL: sent to")
    local tidy   = sim:capture_log("Disk tidy: freed")
    local disp   = sim:capture_log("Dispatched job_")
    local done   = sim:capture_log("Job complete: job_")
    sim:run_for(120000)
    local server = node(sim, "server")
    local d = server.disk_obj
    -- A server installed before 2026-11-02 carries the installer's unused central_server.lua (346 KB); the installer
    -- now writes the server as startup.lua, so it is put there as an old install has it.
    if not d:exists("central_server.lua") then
      sim:write_file(server.name, "central_server.lua", string.rep("-- old install\n", 23000))
    end
    sim:expect(d:exists("central_server.lua"), "the old installer's central_server.lua is on the server's disk")
    sim:write_file(server.name, "jobs.tmp", string.rep("t", 20000))                  -- THE TEST: what a long-running
    sim:write_file(server.name, "crash.log", string.rep("[crash] a line of a traceback\n", 1400))  -- server collects
    local free0 = d:free_space()
    sim:dispatch{ type = "UPDATE_ALL", params = {} }   -- the server now runs as startup.lua; the old copy is unused
    sim:expect(sim:run_until(function() return #fanned.lines >= 1 end, 10 * 60000), "the fleet was updated")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x1 + 32, z2 = area.z1, minerCount = 2 } }
    sim:run_until(function() return #disp.lines >= 2 end, 10 * 60000)
    sim:run_for(70 * 60000)                                                           -- across the hourly tidy
    local free1 = d:free_space()
    local crash = sim:read_file(server.name, "crash.log") or ""
    sim.results.free_before, sim.results.free_after = free0, free1
    sim:expect(#tidy.lines >= 1, "the tidy ran and said what it freed (" .. tostring(tidy.lines[1]) .. ")")
    sim:expect(not d:exists("central_server.lua"), "the unused central_server.lua is gone")
    sim:expect(not d:exists("jobs.tmp"), "the interrupted save's temp file is gone")
    sim:expect(#crash > 0 and #crash <= 8192, "the crash log keeps its newest 8 KB (" .. #crash .. " bytes)")
    sim:expect(d:exists("jobs.dat") and d:exists("active_zones.dat"), "the live job state is still there")
    sim:expect(free1 > free0 + 200000, string.format("the disk gained over 200 KB across the update and the tidy (%d -> %d free)", free0, free1))
    local finished = sim:run_until(function() return #done.lines >= 2 end, 8 * 3600000)
    sim:expect(finished, "both jobs completed (" .. #done.lines .. ")")
  end,
}
