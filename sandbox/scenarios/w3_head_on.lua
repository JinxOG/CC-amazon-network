-- W3 card "Two turtles blocking each other for 120s fails the job permanently" (job_0058, 2026-09-16; fix 8e32f82,
-- 1.9.128): in a head-on meeting in one shaft the DESCENDING turtle steps one block sideways after ~3 s, a climber
-- only after ~35 s. Layer 1 with driven moves (the plan the spec owner named, 2026-10-26).
-- Two copies of a miner are spawned in one column in the sky over the mining area, 30 blocks apart, and each runs
-- base.move.to through the other's position: one climbs, one descends. Each writes the result of its move to a file.
-- Both must arrive; on the code before the fix they wait for each other 120 s and give up "blocked by turtle".
local SCRIPT = [[
local base = require("turtle_base")
base.gpsSync()
local t0 = os.epoch("utc")
local ok, why = base.move.to(%d, %d, %d)
local p = base.getPos and base.getPos() or {}
local f = fs.open("w3_result.txt", "w")
f.write(string.format("%%s|%%s|%%s|%%d", tostring(ok), tostring(why), (tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)), os.epoch("utc") - t0))
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
    local x, z = area.x1 + 40, area.z1
    local top, bottom = 150, 120
    local down = sim:spawn_turtle{ copy_of = miner.name, id = 901, pos = { x = x, y = top, z = z, facing = 0 } }
    local up   = sim:spawn_turtle{ copy_of = miner.name, id = 902, pos = { x = x, y = bottom, z = z, facing = 0 } }
    for _, t in ipairs({ { down, bottom }, { up, top } }) do
      sim:write_file(t[1].name, "startup.lua", string.format(SCRIPT, x, t[2], z))
      sim:set_fuel(t[1].name, 100000)
      sim:reboot(t[1].name)                                         -- THE TEST: they meet head-on in one column
    end
    local function result(t)
      local ok, s = pcall(function() return sim:read_file(t.name, "w3_result.txt") end)
      if ok and type(s) == "string" and s ~= "" then return s end
      return nil
    end
    sim:run_until(function() return result(down) and result(up) end, 10 * 60000)
    local rd, ru = result(down), result(up)
    sim.results.down, sim.results.up = rd, ru
    sim.results.down_screen = sim:output(down.name):sub(-400)
    sim.results.up_screen = sim:output(up.name):sub(-400)
    sim:expect(rd ~= nil and rd:find("^true|") ~= nil, "the descender reached y=" .. bottom .. " (" .. tostring(rd) .. ")")
    sim:expect(ru ~= nil and ru:find("^true|") ~= nil, "the climber reached y=" .. top .. " (" .. tostring(ru) .. ")")
    local slow = 0
    for _, r in ipairs({ rd or "", ru or "" }) do
      local ms = tonumber(r:match("|(%d+)$") or "0")
      if ms > slow then slow = ms end
    end
    sim:expect(slow < 120000, string.format("neither waited out the 120 s give-up (slowest %.1f s)", slow / 1000))
  end,
}
