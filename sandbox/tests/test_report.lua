package.path = "sandbox/?.lua;" .. package.path
local Report = require("report.report")
local Runner = require("scenario.runner")
local H = dofile("sandbox/tests/helpers.lua")

-- A scenario that provisions nothing and then does what the test needs.
local function tiny_scenario(body)
  local path = H.tmpdir() .. "/tiny.lua"
  H.write(path, "return { world = 'synthetic', seed = 3, layout = {}, steps = function(sim)\n" .. body .. "\nend }")
  return path
end

local function fake_sim(sim_ms, wall_s, computers)
  local sched = { computers = computers or {}, trace_lines = 123, standin = { job_lines = {} }, storage = { amounts = {} } }
  return { sim_ms = sim_ms, wall_s = wall_s, sched = sched, seed = 9, scenario_path = "x.lua", scenario = { world = "synthetic" },
    code_spec = "worktree:.", wall_started = "t0", wall_finished = "t1", expectations = {}, faults = {}, interventions = {},
    initial_storage = {}, clock = { now = function() return 0 end } }
end

local result -- one real run shared by the tests that need a finished folder
local function real_run()
  if result then return result end
  local run_dir = H.tmpdir()
  local sim, ok, err = Runner.run("sandbox/scenarios/smoke_short.lua", { run_dir = run_dir, code = "worktree:." })
  local report = Report.write(sim, { ok = ok, err = err })
  result = { sim = sim, report = report, md = H.read(run_dir .. "/report.md"), json = H.read(run_dir .. "/report.json"), dir = run_dir }
  return result
end

return {
  ["NOT MODELLED is never empty"] = function(t)
    local r = Report.build(fake_sim(1000, 1), { ok = true })
    t.ok(#r.not_modelled > 0)
    t.ok(Report.render(r):find("## NOT MODELLED\n\nReal%-server behaviours"), "section missing from the text")
    -- a mutation of the list cannot empty it for later reports
    t.ok(#Report.NOT_MODELLED >= 5)
  end,

  ["speed is reported"] = function(t)
    local r = Report.build(fake_sim(6 * 3600 * 1000, 60), { ok = true })
    t.near(r.speed_ratio, 360, 0.01)
    local text = Report.render(r)
    t.ok(text:find("Speed achieved: 360x real time", 1, true), text)
    t.ok(not text:find("BELOW THE BAR", 1, true), "360x is above the bar")
  end,

  ["below 300x names the slowest computer"] = function(t)
    local quick = { name = "node_1", role = "server", wall_s = 1, cost_total_ms = 10, max_resume_s = 0.001 }
    local slow = { name = "node_12", role = "miner", wall_s = 30, cost_total_ms = 99000, max_resume_s = 0.5, max_resume_at = 777 }
    local r = Report.build(fake_sim(3600 * 1000, 100, { quick, slow }), { ok = true })
    t.near(r.speed_ratio, 36, 0.01)
    t.eq(r.slowest.computer, "node_12")
    t.eq(r.slowest_step.computer, "node_12")
    local text = Report.render(r)
    t.ok(text:find("BELOW THE BAR", 1, true), text)
    t.ok(text:find("Slowest computer: node_12", 1, true), text)
  end,

  ["a crashed run still writes an INCOMPLETE report"] = function(t)
    local scenario = tiny_scenario("sim:run_for(5000); error('the scenario blew up')")
    local run_dir = H.tmpdir()
    local sim, ok, err = Runner.run(scenario, { run_dir = run_dir, code = "worktree:." })
    t.ok(not ok)
    Report.write(sim, { ok = ok, err = err }, { skip_tools = true })
    local md = H.read(run_dir .. "/report.md")
    t.ok(md:find("^# INCOMPLETE run report"), md:sub(1, 80))
    t.ok(md:find("the scenario blew up", 1, true), "the reason is missing")
    t.ok(md:find("## NOT MODELLED", 1, true))
    t.ok(H.read(run_dir .. "/report.json"):find('"status":"INCOMPLETE"', 1, true))
  end,

  ["a real run's report has every section and embeds the tools' output"] = function(t)
    local r = real_run()
    for _, heading in ipairs({ "## Checks", "## Faults injected", "## INTERVENTIONS", "## Jobs", "## ASSUMPTIONS", "## NOT MODELLED" }) do
      t.ok(r.md:find(heading, 1, true), "missing " .. heading)
    end
    t.ok(r.md:find("Speed achieved: %d+x real time"), "no speed line")
    t.ok(r.md:find("### gate_check", 1, true) and r.md:find("### ack_loss", 1, true), "tool sections missing")
    t.ok(not r.md:find("(not run)", 1, true), "tools were not run")
    t.ok(r.md:find("exit code %d"), "no tool exit code")
    t.ok(r.md:find("worktree:%.@%x+"), "the code commit is missing")
    t.ok(r.json:find('"speed_ratio":', 1, true))
  end,

  ["the unverified timings are listed as assumptions"] = function(t)
    local r = Report.build(fake_sim(1000, 1), { ok = true })
    local found = false
    for _, a in ipairs(r.assumptions) do if a:find("timings.lua", 1, true) then found = true end end
    t.ok(found, "TIMINGS assumption missing")
  end,
}
