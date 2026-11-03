-- W3 disk card, part 4 (the user's ruling 2026-11-02): the updater writes Lua to disk without its comments and
-- indentation, line breaks kept, so the server's ~425 KB of code fits the default 1,000,000-byte disk with room for
-- state. Here the fleet is updated (UPDATE_ALL, so every computer runs the real updater), and then must WORK on the
-- stripped code: the server's startup.lua is under 200 KB and has no comment lines, the miner's
-- turtle_base.lua is stripped too, and a one-sector mining job completes with no crash on any computer.
-- Before the change the files are written as they are (startup.lua ~346 KB).
local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

local function commentLines(text)
  local n = 0
  for line in text:gmatch("[^\n]*") do if line:match("^%s*%-%-") then n = n + 1 end end
  return n
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local fanned  = sim:capture_log("UPDATE_ALL: sent to")
    local disp    = sim:capture_log("Dispatched job_")
    local done    = sim:capture_log("Job complete: job_")
    sim:run_for(120000)
    local server, miner = node(sim, "server"), node(sim, "miner")
    local free0 = server.disk_obj:free_space()
    sim:dispatch{ type = "UPDATE_ALL", params = {} }                  -- THE TEST: the real updater writes the fleet
    sim:expect(sim:run_until(function() return #fanned.lines >= 1 end, 10 * 60000), "the update reached the fleet")
    sim:run_for(180000)
    local s = sim:read_file(server.name, "startup.lua") or ""
    local tb = sim:read_file(miner.name, "turtle_base.lua") or ""
    local free1 = server.disk_obj:free_space()
    sim.results.server_startup_bytes, sim.results.free_before, sim.results.free_after = #s, free0, free1
    sim:expect(#s > 0 and #s < 200000, "the server's startup.lua is under 200 KB (" .. #s .. " bytes)")
    sim:expect(commentLines(s) == 0, "and has no comment lines (" .. commentLines(s) .. ")")
    sim:expect(commentLines(tb) == 0 and #tb > 0, "the miner's turtle_base.lua is stripped too (" .. #tb .. " bytes)")
    -- (Free space is recorded, not judged: the installer leaves an unused central_server.lua that the update does not
    -- touch -- the retention pass removes it, see w3_disk_retention.lua.)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1, minerCount = 1 } }
    sim:expect(sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000), "a job was dispatched on the stripped code")
    local ok = sim:run_until(function() return #done.lines >= 1 end, 6 * 3600000)
    sim:expect(ok, "and completed")
    local crashes = 0
    local f = io.open(sim.run_dir .. "/trace.log", "rb")
    if f then for line in f:lines() do if line:find(" crash ", 1, true) then crashes = crashes + 1 end end; f:close() end
    sim:expect(crashes == 0, "no computer crashed (" .. crashes .. ")")
  end,
}
