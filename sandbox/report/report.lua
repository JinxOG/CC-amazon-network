-- The run report (spec section 11): report.md for people, report.json for tools.
-- Every report has ASSUMPTIONS, INTERVENTIONS and a NOT MODELLED list that is never empty. A run that ended by
-- error or interruption is headed INCOMPLETE with the reason: a missing or optimistic report is worse than none.
local JSON = require("core.json")

local Report = {}

Report.SPEED_BAR = 300

-- Real-server behaviours this sandbox does not exercise. Fixed; a report adds to it, never removes.
Report.NOT_MODELLED = {
  "Mod-level chunk tickets beyond the simple 3x3 loader model (how many tickets the server will hold, ticket expiry).",
  "Forge registry sync and any mod behaviour not reimplemented in Lua.",
  "Real TPS curves: turtle actions take the fixed times in sandbox/timings.lua, scaled only by the tps_drop fault.",
  "Refined Storage internals beyond listItems/exportItem/importItem timing and contents (no autocrafting, no network cables).",
  "server.js internals: bridge-busy accounting, the log writer's disk behaviour, dynmap, RCON, authentication, /self-update.",
  "Rendering, players, mobs, redstone, fluids, falling blocks, or anything else the fleet never touches.",
  "Real network behaviour of the radio (range limits, dimension crossing, packet size limits).",
  "Computation cost is an instruction count at a fixed rate, not real CPU time.",
}

local function git_sha(path)
  local p = io.popen('git -C "' .. path .. '" rev-parse HEAD 2>nul')
  if not p then return nil end
  local sha = p:read("*l")
  p:close()
  if sha and sha:match("^%x+$") then return sha end
  return nil
end

local function code_label(sim)
  local spec = sim.code_spec or "worktree:."
  local kind, value = spec:match("^(%a+):(.+)$")
  if kind == "worktree" then
    local sha = git_sha(value)
    return spec .. (sha and ("@" .. sha:sub(1, 10)) or "")
  elseif kind == "rev" then
    local sha = git_sha(".")
    local p = io.popen('git rev-parse ' .. value .. ' 2>nul')
    local r = p and p:read("*l"); if p then p:close() end
    return spec .. (r and r:match("^%x+$") and ("@" .. r:sub(1, 10)) or "")
  end
  return spec
end

local function ore_summary(sim)
  local by, total = {}, 0
  local final, initial = sim.sched.storage.amounts, sim.initial_storage or {}
  for name, n in pairs(final) do
    if name:find("ore", 1, true) then
      local gained = n - (initial[name] or 0)
      if gained > 0 then by[name] = gained; total = total + gained end
    end
  end
  return { total = total, by_type = by }
end

-- A table of everything the report says. Pure: it reads the sim and does no I/O beyond git for the commit.
function Report.build(sim, result)
  result = result or { ok = true }
  local sim_ms, wall_s = sim.sim_ms or 0, sim.wall_s or 0
  local ratio = (wall_s > 0) and (sim_ms / 1000 / wall_s) or nil
  local r = {
    status = result.ok and "COMPLETE" or "INCOMPLETE",
    incomplete_reason = (not result.ok) and tostring(result.err or "unknown") or nil,
    scenario = sim.scenario_path,
    seed = sim.seed,
    code = code_label(sim),
    world = (sim.scenario and sim.scenario.world) == nil and ("synthetic (seed " .. tostring(sim.seed) .. ")")
      or tostring(sim.scenario.world == "synthetic" and ("synthetic (seed " .. tostring(sim.seed) .. ")") or sim.scenario.world),
    fleet = sim.only and ("only: " .. table.concat(sim.only, ", ")) or "whole fleet",
    wall_started = sim.wall_started,
    wall_finished = sim.wall_finished,
    simulated_hours = sim_ms / 3600000,
    wall_seconds = wall_s,
    speed_ratio = ratio,
    speed_bar = Report.SPEED_BAR,
    faults = sim.faults or {},
    interventions = sim.interventions or {},
    expectations = sim.expectations or {},
    jobs = sim.sched.standin and sim.sched.standin.job_lines or {},
    ore = ore_summary(sim),
    trace_lines = sim.sched.trace_lines,
    not_modelled = Report.NOT_MODELLED,
  }

  -- below the bar: say which computer cost the most
  if ratio and ratio < Report.SPEED_BAR then
    local worst, worst_cost, worst_step
    for _, c in ipairs(sim.sched.computers) do
      if not worst or (c.wall_s or 0) > (worst.wall_s or 0) then worst = c end
      if (c.max_resume_s or 0) > (worst_step and worst_step.max_resume_s or 0) then worst_step = c end
    end
    if worst then
      r.slowest = { computer = worst.name, role = worst.role, wall_seconds = worst.wall_s or 0,
        virtual_cost_ms = worst.cost_total_ms or 0 }
    end
    if worst_step then
      r.slowest_step = { computer = worst_step.name, wall_ms = (worst_step.max_resume_s or 0) * 1000,
        at_sim_ms = worst_step.max_resume_at }
    end
  end

  local assumptions = {}
  for _, a in ipairs(require("assumptions")) do assumptions[#assumptions + 1] = a end
  for _, a in ipairs(sim.extra_assumptions or {}) do assumptions[#assumptions + 1] = a end
  if sim.only then assumptions[#assumptions + 1] = "This run booted only part of the fleet (--only); the speed bar is measured on the whole fleet." end
  r.assumptions = assumptions
  return r
end

local function section(out, title) out[#out + 1] = ""; out[#out + 1] = "## " .. title; out[#out + 1] = "" end

function Report.render(r)
  local o = {}
  if r.status == "INCOMPLETE" then
    o[#o + 1] = "# INCOMPLETE run report"
    o[#o + 1] = ""
    o[#o + 1] = "**This run did not finish: " .. r.incomplete_reason .. "**"
    o[#o + 1] = "The numbers below describe only what happened before it stopped."
  else
    o[#o + 1] = "# Run report"
  end
  o[#o + 1] = ""
  o[#o + 1] = "- Scenario: " .. tostring(r.scenario)
  o[#o + 1] = "- Seed: " .. tostring(r.seed)
  o[#o + 1] = "- Code: " .. tostring(r.code)
  o[#o + 1] = "- World: " .. tostring(r.world)
  o[#o + 1] = "- Fleet: " .. tostring(r.fleet)
  o[#o + 1] = "- Started: " .. tostring(r.wall_started) .. "   Finished: " .. tostring(r.wall_finished)
  o[#o + 1] = string.format("- Simulated %.2f hours in %.1f s of wall time", r.simulated_hours, r.wall_seconds)
  if r.speed_ratio then
    o[#o + 1] = string.format("- **Speed achieved: %.0fx real time** (bar: %dx)%s", r.speed_ratio, r.speed_bar,
      r.speed_ratio < r.speed_bar and " — BELOW THE BAR" or "")
  else
    o[#o + 1] = "- **Speed achieved: not measurable** (no wall time recorded)"
  end
  if r.slowest then
    o[#o + 1] = string.format("- Slowest computer: %s (%s), %.2f s of wall time, %d ms of virtual computation cost",
      r.slowest.computer, tostring(r.slowest.role), r.slowest.wall_seconds, r.slowest.virtual_cost_ms)
  end
  if r.slowest_step then
    o[#o + 1] = string.format("- Longest single step: %s, %.1f ms, at simulated time %s", r.slowest_step.computer,
      r.slowest_step.wall_ms, tostring(r.slowest_step.at_sim_ms))
  end
  o[#o + 1] = "- Trace lines: " .. tostring(r.trace_lines)

  section(o, "Checks")
  if #r.expectations == 0 then o[#o + 1] = "(the scenario made no checks)" end
  for _, e in ipairs(r.expectations) do o[#o + 1] = (e.ok and "- PASS " or "- FAIL ") .. e.message end

  section(o, "Faults injected")
  if #r.faults == 0 then o[#o + 1] = "None." end
  for _, f in ipairs(r.faults) do o[#o + 1] = string.format("- t+%ds %s %s", math.floor((f.t_ms or 0) / 1000), f.name, f.args or "") end

  section(o, "INTERVENTIONS")
  if #r.interventions == 0 then
    o[#o + 1] = "None. Nobody reached into the run."
  else
    o[#o + 1] = "These were done by hand during the run. A run that needed one to pass is not evidence the fleet works, "
      .. "unless the intervention is the test."
    for _, i in ipairs(r.interventions) do o[#o + 1] = string.format("- t+%ds %s", math.floor((i.t_ms or 0) / 1000), i.what or "?") end
  end

  section(o, "Jobs")
  if #r.jobs == 0 then o[#o + 1] = "No job lines were logged." end
  for _, l in ipairs(r.jobs) do o[#o + 1] = "    " .. l end
  o[#o + 1] = ""
  o[#o + 1] = "Ore that reached storage: **" .. tostring(r.ore.total) .. "**"
  local names = {}
  for n in pairs(r.ore.by_type) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do o[#o + 1] = "- " .. n .. ": " .. r.ore.by_type[n] end

  section(o, "Analysis tools, run against this run")
  for _, tool in ipairs({ "gate_check", "ack_loss" }) do
    local t = r.tools and r.tools[tool]
    o[#o + 1] = "### " .. tool
    o[#o + 1] = ""
    if t then
      o[#o + 1] = "exit code " .. tostring(t.exit)
      if (t.output or ""):find("Traceback", 1, true) then
        o[#o + 1] = ""
        o[#o + 1] = "**THIS TOOL CRASHED. Its output below is not a verdict on the run.**"
      end
      o[#o + 1] = ""
      o[#o + 1] = "```"
      o[#o + 1] = t.output or ""
      o[#o + 1] = "```"
    else
      o[#o + 1] = "(not run)"
    end
    o[#o + 1] = ""
  end

  section(o, "ASSUMPTIONS")
  o[#o + 1] = "Behaviours chosen without evidence from the real game or the live fleet:"
  o[#o + 1] = ""
  for _, a in ipairs(r.assumptions) do o[#o + 1] = "- " .. a end

  section(o, "NOT MODELLED")
  o[#o + 1] = "Real-server behaviours this run could not exercise. A pass here says nothing about them:"
  o[#o + 1] = ""
  for _, a in ipairs(r.not_modelled) do o[#o + 1] = "- " .. a end
  o[#o + 1] = ""
  return table.concat(o, "\n")
end

local function run_tools(sim)
  local t0_ms = sim.clock and (sim.clock:now() - (sim.sim_ms or 0)) or 0
  local since = os.date("!%Y-%m-%dT%H:%M:%S", math.floor(t0_ms / 1000))
  local p = io.popen(string.format('python sandbox/tools/run_tools.py "%s" %s 2>&1', sim.run_dir, since))
  if not p then return nil end
  local text = p:read("*a")
  p:close()
  local ok, parsed = pcall(JSON.decode, text, nil, false)
  if ok and type(parsed) == "table" then return parsed end
  return { gate_check = { exit = nil, output = "could not run: " .. text:sub(1, 400) },
           ack_loss = { exit = nil, output = "could not run: " .. text:sub(1, 400) } }
end

-- Writes report.md and report.json into the run folder. `skip_tools` is for tests that only need the shape.
function Report.write(sim, result, opts)
  opts = opts or {}
  sim:flush()
  local r = Report.build(sim, result)
  if not opts.skip_tools then r.tools = run_tools(sim) end
  local f = assert(io.open(sim.run_dir .. "/report.md", "wb")); f:write(Report.render(r)); f:close()
  local j = assert(io.open(sim.run_dir .. "/report.json", "wb")); j:write(JSON.encode(r)); j:close()
  return r
end

return Report
