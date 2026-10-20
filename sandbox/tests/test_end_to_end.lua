-- The real fleet files, unchanged, on the synthetic world. Slow on purpose: it is the whole point.
package.path = "sandbox/?.lua;" .. package.path
local Runner = require("scenario.runner")
local H = dofile("sandbox/tests/helpers.lua")

local result -- one run, shared by every check below
local function run()
  if result then return result end
  local run_dir = H.tmpdir()
  local sim, ok, err = Runner.run("sandbox/scenarios/smoke_two_miners.lua", { run_dir = run_dir, code = "worktree:." })
  result = { sim = sim, ok = ok, err = err, run_dir = run_dir }
  return result
end

return {
  ["a two-miner job completes on the synthetic world using the real fleet files"] = function(t)
    local r = run()
    t.ok(r.ok, "scenario steps raised: " .. tostring(r.err))
    for _, e in ipairs(r.sim.expectations or {}) do t.ok(e.ok, "expectation failed: " .. e.message) end
    t.ok(#(r.sim.expectations or {}) > 0, "the scenario made no expectations")
  end,

  ["ore from the job reaches storage"] = function(t)
    local r = run()
    local st = r.sim.sched.storage
    local ore = 0
    for name, n in pairs(st.amounts) do if name:find("_ore") then ore = ore + n end end
    t.ok(ore > 100, "only " .. ore .. " ore blocks reached storage")
  end,

  ["no computer hit an API the sandbox lacks"] = function(t)
    local r = run()
    local bad = {}
    for _, c in ipairs(r.sim.sched.computers) do
      for _, line in ipairs(c.output) do
        if line.text:find("sandbox: ", 1, true) and line.text:find("not implemented", 1, true) then
          bad[#bad + 1] = c.name .. ": " .. line.text:sub(1, 160)
        end
      end
    end
    t.eq(#bad, 0, table.concat(bad, "\n"))
  end,
}
