-- W3 card "Crash messages: delivery and support send their last log lines, and delivery reboots after a crash" (fix
-- 0c70325). Layer 1 only (spec owner, 2026-10-26): there is no way to make a running turtle's program raise on the local
-- test server. Here the crash is put into an idle delivery turtle's own environment with sim:eval -- its next
-- os.startTimer raises once -- so its main loop dies the way a real fault would.
-- It must ship its last line ('[DELIVERY] Fatal crash: ...' reaches the server's log, which needs the flush before the
-- 20 s sleep) and reboot (a new '=== node_X [DELIVERY] ... booting' line). On 0c70325~1 delivery had no crash handler:
-- it dropped to the shell, never rebooted, and the line was never shipped.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local fatal = sim:capture_log("Fatal crash")
    local boots = sim:capture_log("[DELIVERY] v")
    sim:run_for(120000)
    local d
    for _, c in ipairs(sim.sched.computers) do
      if not d and c.env and c.label == nil and tostring(c.role) == "delivery" then d = c end
    end
    if not d then
      for _, c in ipairs(sim.sched.computers) do if not d and tostring(c.role) == "delivery" then d = c end end
    end
    sim:expect(d ~= nil, "found a delivery turtle")
    if not d then return end
    local b0, f0 = #boots.lines, #fatal.lines
    -- One raise only, then the real function is back: the crash handler's own sleep(20) needs os.startTimer.
    sim:eval(d.name, "local o = os.startTimer; os.startTimer = function() os.startTimer = o; error('w3 injected crash', 0) end")   -- THE TEST
    local said = sim:run_until(function()
      for i = f0 + 1, #fatal.lines do if fatal.lines[i]:find(d.name, 1, true) then return true end end
      return false
    end, 3 * 60000)
    sim:expect(said, d.name .. "'s '[DELIVERY] Fatal crash' line reached the server's log")
    local rebooted = sim:run_until(function()
      for i = b0 + 1, #boots.lines do if boots.lines[i]:find(d.name, 1, true) then return true end end
      return false
    end, 3 * 60000)
    sim:expect(rebooted, "and it rebooted (a new boot line)")
    sim.results.node = d.name
  end,
}
