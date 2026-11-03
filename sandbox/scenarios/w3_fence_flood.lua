-- W3 card "A refused move retries hundreds of times a second and floods the log" (node_118, 2026-09-29: ~294
-- refusal lines in three seconds). A copy of a miner, under a lease ceiling at its own height, asks to move up 300
-- times -- the retry loop of the incident. It counts its own "Geofence: refusing move" lines and how long the 300
-- refusals took. Each must still be refused; the lines must be at most a few (one per ten seconds), and the loop
-- must be slowed to about two attempts a second. Before the change: 300 lines, in no time at all.
local SCRIPT = [[
local base = require("turtle_base")
base.gpsSync()
local p = base.getPos()
base.geofence.setLease(p.x - 16, p.z - 16, p.x + 15, p.z + 15, p.y)
local lines, refused = 0, 0
local real = print
print = function(...)
  local s = table.concat({ ... }, " ")
  if s:find("refusing move", 1, true) then lines = lines + 1 end
  real(...)
end
local t0 = os.epoch("utc")
for _ = 1, 300 do
  local ok, why = base.move.up()
  if not ok and why == "geofence_breach" then refused = refused + 1 end
end
print = real
local f = fs.open("w3_result.txt", "w")
f.write(string.format("%d|%d|%d", refused, lines, os.epoch("utc") - t0))
f.close()
]]

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    sim:run_for(60000)
    local miner
    for _, c in ipairs(sim.sched.computers) do if c.role == "miner" then miner = c end end
    local area = sim.world:meta().areas[1]
    local t = sim:spawn_turtle{ copy_of = miner.name, id = 903, pos = { x = area.x1 + 40, y = 150, z = area.z1, facing = 0 } }
    sim:write_file(t.name, "startup.lua", SCRIPT)
    sim:set_fuel(t.name, 100000)
    sim:reboot(t.name)                                                -- THE TEST: 300 refused moves in a row
    local function result()
      local ok, s = pcall(function() return sim:read_file(t.name, "w3_result.txt") end)
      if ok and type(s) == "string" and s ~= "" then return s end
    end
    sim:run_until(function() return result() ~= nil end, 30 * 60000)
    local r = result() or ""
    local refused, lines, ms = r:match("^(%d+)|(%d+)|(%d+)$")
    refused, lines, ms = tonumber(refused), tonumber(lines), tonumber(ms)
    sim.results.refused, sim.results.lines, sim.results.ms = refused, lines, ms
    sim:expect(refused == 300, "all 300 were refused (" .. tostring(refused) .. ")")
    sim:expect(lines ~= nil and lines <= 20, "logged at most once per ten seconds (" .. tostring(lines) .. " lines)")
    sim:expect(ms ~= nil and ms >= 100000, string.format("and the retry loop was slowed (%.1f s for 300)", (ms or 0) / 1000))
  end,
}
