-- Runs a scenario file: builds the world and the fleet, hands a `sim` to the scenario's steps, and writes
-- the run folder.
--   scenario = { world = "synthetic" | <world dir>, seed = , start_ms = , layout = list|function(waypoints),
--                miners = n, steps = function(sim) ... end }
local Sim = require("core.sim")
local Fleet = require("core.fleet")
local CodeDir = require("core.code_dir")
local Synth = require("world.synth")
local World = require("world.world")

local Runner = {}

local function data_root()
  return (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
end

local function load_waypoints(code_dir)
  local fn = assert(loadfile(code_dir .. "/waypoints.lua", "t", setmetatable({}, { __index = _G })))
  return fn()
end

-- Keeps only the named nodes (ids, "node_<id>" or labels), plus the GPS hosts and the loaders the kept miners carry.
local function apply_only(layout, only)
  local want = {}
  for _, n in ipairs(only) do want[tostring(n)] = true; want[tostring(n):gsub("^node_", "")] = true end
  local keep, carried = {}, {}
  for _, spec in ipairs(layout) do
    if spec.kind == "gps_host" or want[tostring(spec.id)] or (spec.label and want[spec.label]) then
      keep[spec.id] = true
      local inv = spec.turtle and spec.turtle.inv
      for _, stack in pairs(inv or {}) do if stack.computer_id then carried[stack.computer_id] = true end end
    end
  end
  local out = {}
  for _, spec in ipairs(layout) do
    if keep[spec.id] or carried[spec.id] then out[#out + 1] = spec end
  end
  return out
end

-- opts: seed, code (spec string), run_dir (override), repo, speed (nil = as fast as possible), only (node list),
-- world (a world folder, overriding the scenario's)
function Runner.run(scenario_path, opts)
  opts = opts or {}
  local scenario = assert(loadfile(scenario_path))()
  local seed = opts.seed or scenario.seed or 1
  local name = scenario_path:match("([^/\\]+)%.lua$") or "scenario"
  local run_dir = opts.run_dir
  if not run_dir then
    run_dir = string.format("%s/run/%s-%s-%d", data_root(), os.date("%Y%m%d-%H%M%S"), name, seed)
  end
  require("core.disk").new(run_dir)
  local code_dir = CodeDir.prepare(opts.code or "worktree:.", run_dir, opts.repo)

  local world
  local world_spec = opts.world or scenario.world
  if world_spec == nil or world_spec == "synthetic" then world = Synth.generate(scenario.world_seed or seed)
  else world = World.open(world_spec) end

  local sim = Sim.new{ world = world, run_dir = run_dir, code_dir = code_dir, seed = seed,
    start_ms = scenario.start_ms, storage = scenario.storage, config = { scenario = scenario_path, code = opts.code } }
  sim.scenario, sim.scenario_path, sim.code_spec = scenario, scenario_path, opts.code or "worktree:."

  local layout = scenario.layout
  if type(layout) == "function" then layout = layout(load_waypoints(code_dir)) end
  layout = layout or Synth.layout(load_waypoints(code_dir), { miners = scenario.miners, workers = scenario.workers })
  if opts.only then layout = apply_only(layout, opts.only); sim.only = opts.only end
  sim.layout = layout

  local wall0, sim0 = os.clock(), sim.clock:now()
  sim.wall_started = os.date("%Y-%m-%d %H:%M:%S")
  local ok, err = pcall(function()
    Fleet.provision(sim, layout)
    if opts.speed then sim.sched:set_pace(opts.speed) end
    scenario.steps(sim)
  end)
  sim.sim_ms, sim.wall_s = sim.clock:now() - sim0, os.clock() - wall0
  sim.wall_finished = os.date("%Y-%m-%d %H:%M:%S")
  sim:flush()
  return sim, ok, err
end

return Runner
