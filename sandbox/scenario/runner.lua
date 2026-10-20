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

-- opts: seed, code (spec string), run_dir (override), repo
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
  if scenario.world == nil or scenario.world == "synthetic" then world = Synth.generate(scenario.world_seed or seed)
  else world = World.open(scenario.world) end

  local sim = Sim.new{ world = world, run_dir = run_dir, code_dir = code_dir, seed = seed,
    start_ms = scenario.start_ms, storage = scenario.storage, config = { scenario = scenario_path, code = opts.code } }
  sim.scenario, sim.scenario_path, sim.code_spec = scenario, scenario_path, opts.code or "worktree:."

  local layout = scenario.layout
  if type(layout) == "function" then layout = layout(load_waypoints(code_dir)) end
  layout = layout or Synth.layout(load_waypoints(code_dir), { miners = scenario.miners })
  sim.layout = layout
  Fleet.provision(sim, layout)

  local ok, err = pcall(scenario.steps, sim)
  sim:flush()
  return sim, ok, err
end

return Runner
