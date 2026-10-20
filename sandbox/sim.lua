-- Command line for the sandbox. Run through the launcher:  sandbox/sim <command> ...
--   run <scenario.lua> [--seed N] [--speed max|N] [--code worktree:<p>|rev:<r>] [--only a,b] [--world dir]
--                      [--run-dir dir]
--   test [pattern]          the sandbox's own tests
--   view <run_dir> [port]   the live view: a read-only file server and the dashboard page (default port 3101)
package.path = "sandbox/?.lua;" .. package.path

local Safety = require("core.safety")

local function usage(code)
  io.stderr:write([[
usage: sandbox/sim run <scenario.lua> [--seed N] [--speed max|N] [--code worktree:<path>|rev:<rev>]
                       [--only node_11,node_12] [--world <dir>] [--run-dir <dir>]
       sandbox/sim test [pattern]
       sandbox/sim view <run_dir> [port]
]])
  os.exit(code or 2)
end

local function parse(args)
  local o, pos = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      o[key] = args[i + 1]
      if o[key] == nil then usage() end
      i = i + 2
    else pos[#pos + 1] = a; i = i + 1 end
  end
  return o, pos
end

local cmd = arg[1]
if cmd == "run" then
  local opts, pos = parse({ table.unpack(arg, 2) })
  if not pos[1] then usage() end
  -- nothing on the command line may point at the live server or any non-local host
  Safety.check_config({ unpack(arg) }, "command line")
  local Runner = require("scenario.runner")
  local Report = require("report.report")
  local speed = opts.speed
  if speed == "max" then speed = nil else speed = speed and tonumber(speed) or nil end
  local only
  if opts.only then
    only = {}
    for name in opts.only:gmatch("[^,%s]+") do only[#only + 1] = name end
  end
  local sim, ok, err = Runner.run(pos[1], { seed = tonumber(opts.seed), code = opts.code, speed = speed, only = only,
    world = opts.world, run_dir = opts["run-dir"] })
  print("run folder: " .. sim.run_dir)
  print(string.format("simulated %.1f hours in %.1f s of wall time (%.0fx)", sim.sim_ms / 3600000, sim.wall_s,
    sim.wall_s > 0 and sim.sim_ms / 1000 / sim.wall_s or 0))
  Report.write(sim, { ok = ok, err = err })
  for _, e in ipairs(sim.expectations or {}) do print((e.ok and "PASS " or "FAIL ") .. e.message) end
  if not ok then print("scenario error: " .. tostring(err)) end
  os.exit(ok and 0 or 1)
elseif cmd == "view" then
  local run_dir, port = arg[2], arg[3] or "3101"
  if not run_dir then usage() end
  print("live view: http://127.0.0.1:" .. port .. "/  (Ctrl+C to stop)")
  os.exit(os.execute(string.format('node sandbox/bridge/fileserver.js "%s" %s', run_dir, port)) == 0 and 0 or 1)
else
  usage()
end
