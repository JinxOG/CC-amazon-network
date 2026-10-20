-- The speed bar (spec section 9): a six-hour two-miner job, whole fleet, in at most 72 s of wall time (300x).
-- Slow by nature (about a minute); SANDBOX_SKIP_SLOW=1 leaves it out, naming it in a pattern runs it.
local JSON = require("core.json")
local H = dofile("sandbox/tests/helpers.lua")

return {
  ["six simulated hours take at most 72 wall seconds"] = function(t)
    local dir = H.tmpdir() .. "/speed"
    local p = io.popen(string.format('bash sandbox/sim run sandbox/scenarios/six_hour_two_miners.lua --run-dir "%s" 2>&1', dir))
    local out = p:read("*a")
    p:close()
    local text = H.read(dir .. "/report.json")
    t.ok(text, "no report.json:\n" .. out)
    local r = assert(JSON.decode(text))
    t.near(r.simulated_hours, 6, 0.01, "the run should cover six hours")
    t.ok(r.wall_seconds <= 72, string.format("took %.1f s of wall time (%.0fx); the bar is 72 s (300x). %s", r.wall_seconds,
      r.speed_ratio or 0, r.slowest and ("slowest computer: " .. r.slowest.computer) or ""))
    t.ok(r.speed_ratio >= 300)
  end,
}
