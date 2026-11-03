-- W1 card "Crash messages: miner sends its last log lines before rebooting"
-- (cleanup design §5.2 card 5, must-do #3).
--
-- THE FAULT. ore_turtle's fatal-crash handler printed the error, printed
-- "Rebooting in 20s", slept and rebooted. print is logship's, so both lines
-- were queued on disk, and the control loop that would have flushed them died
-- with base.run -- so the single most valuable line a miner ever writes was the
-- one least likely to reach the log. os.reboot() then cleared the screen, and
-- the only copy was the queue. A miner that crashed came back as a turtle that
-- had simply rebooted, with nothing anywhere saying why.
--
-- base.flushLogs has existed since 1.9.89 for exactly this; the handler just
-- never called it. One pcall'd line.
--
-- SAME SHAPE AS W3'S HALF, AND DELIBERATELY THE SAME TEST. The delivery and
-- support half of this card was split to W3 and fixed in 0c70325, with
-- sandbox/scenarios/w3_crash_message.lua. This is that scenario pointed at a
-- miner: the crash is put into an idle miner's own environment with sim:eval,
-- so its next os.startTimer raises once and its loop dies the way a real fault
-- would. Writing a different mechanism for the same question would only make
-- the two incomparable.
--
-- ONE RAISE, THEN THE REAL FUNCTION IS BACK. The handler's own sleep(20) needs
-- os.startTimer, so a permanent replacement would hang the very path under
-- test and the run would fail for a reason that has nothing to do with the fix.
--
-- WHAT IT ASSERTS. Two positives. The line must REACH THE SERVER'S LOG -- not
-- merely be printed, which is what it already did -- and the miner must come
-- back, which is the behaviour the flush must not have cost. Both are matched
-- to the node that was made to crash, not to any line from any turtle, so
-- another miner's unrelated crash cannot satisfy them.
--
-- LAYER 2 IS NOT POSSIBLE for this card, by the same ruling W3's half got
-- (spec owner, 2026-10-26): the local test server has no way to make a running
-- turtle's program raise. M7 of the control mod was left undone on purpose
-- because no clean way exists. So this card is layer 1 plus the live watcher.
--
-- WHY IT FAILS ON THE OLD CODE: the handler never flushes, so the queued lines
-- die with the reboot and the first check finds nothing. The reboot itself
-- still happens, so the second check passes either way -- which is why the
-- first is the one this card turns on, and why the second is here at all: it
-- proves the flush did not break the recovery.
return {
  world  = "synthetic",
  seed   = 1,
  miners = 2,
  steps = function(sim)
    local fatal = sim:capture_log("[MINER] Fatal crash")
    local boots = sim:capture_log("[MINER] v")

    sim:run_for(120000)

    -- c.tstate as well as the role, which is how w3_dock_bank and
    -- w3_leftover_coal pick a miner: it is the turtle state, so it excludes
    -- anything that is a miner by role but not a running turtle. c.env because
    -- sim:eval needs an environment to reach into, and picking a computer
    -- without one would fail inside the injection rather than here.
    local m
    for _, c in ipairs(sim.sched.computers) do
      if not m and c.role == "miner" and c.tstate and c.env then m = c end
    end
    sim:expect(m ~= nil, "found a running miner turtle to crash")
    if not m then return end
    sim.results.node = m.name

    local f0, b0 = #fatal.lines, #boots.lines

    -- THE TEST. One raise, then os.startTimer is itself again.
    sim:eval(m.name, "local o = os.startTimer; os.startTimer = function() "
      .. "os.startTimer = o; error('w1 injected crash', 0) end")

    -- POSITIVE 1: the line reached the SERVER'S log. This is the whole card.
    -- It was always printed; printing is what logship intercepts, and the
    -- interception is what stranded it.
    local said = sim:run_until(function()
      for i = f0 + 1, #fatal.lines do
        if fatal.lines[i]:find(m.name, 1, true) then return true end
      end
      return false
    end, 3 * 60000)
    sim.results.fatal_lines = #fatal.lines - f0
    sim:expect(said,
      m.name .. "'s '[MINER] Fatal crash' line reached the server's log (new "
      .. "lines: " .. (#fatal.lines - f0) .. ")")

    -- POSITIVE 2: and it came back. The flush is inside the path that reboots,
    -- so a flush that hung or raised would strand the miner at a shell -- worse
    -- than the fault being fixed. pcall covers the raise; this covers the hang.
    local rebooted = sim:run_until(function()
      for i = b0 + 1, #boots.lines do
        if boots.lines[i]:find(m.name, 1, true) then return true end
      end
      return false
    end, 3 * 60000)
    sim.results.boot_lines = #boots.lines - b0
    sim:expect(rebooted,
      "and it rebooted, so the flush did not cost the recovery (new boot "
      .. "lines: " .. (#boots.lines - b0) .. ")")
  end,
}
