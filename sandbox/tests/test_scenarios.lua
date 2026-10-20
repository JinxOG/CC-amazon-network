-- Each named scenario (spec section 12) runs once and produces a report. They are slow; pattern "scenarios" runs only them.
package.path = "sandbox/?.lua;" .. package.path
local Runner = require("scenario.runner")
local Report = require("report.report")
local H = dofile("sandbox/tests/helpers.lua")

local NAMES = { "server_crash", "world_restart_gps_late", "rs_stall", "reboot_mid_refuel", "radio_loss_5", "radio_loss_20" }

local tests = {}
for _, name in ipairs(NAMES) do
  tests["scenario " .. name .. " runs and writes a report"] = function(t)
    local run_dir = H.tmpdir()
    local sim, ok, err = Runner.run("sandbox/scenarios/" .. name .. ".lua", { run_dir = run_dir, code = "worktree:." })
    t.ok(ok, "the scenario raised: " .. tostring(err))
    Report.write(sim, { ok = ok, err = err }, { skip_tools = true })
    local md = H.read(run_dir .. "/report.md")
    t.ok(md and md:find("## NOT MODELLED", 1, true), "no report")
    t.ok(#sim.faults >= 1, "the scenario injected no fault")
    t.ok(md:find(sim.faults[1].name, 1, true), "the report does not list the fault")
    print(string.format("    %s: %.1f h in %.0f s; checks: %s", name, sim.sim_ms / 3600000, sim.wall_s,
      (function() local o = {} for _, e in ipairs(sim.expectations or {}) do o[#o + 1] = (e.ok and "PASS" or "FAIL") end return table.concat(o, ",") end)()))
  end
end
return tests
