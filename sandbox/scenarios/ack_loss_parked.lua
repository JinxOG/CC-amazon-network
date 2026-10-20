-- Ack loss with the whole fleet parked at the base and no job (the live regime that lost 11-18% of acks before the
-- per-turtle private channel; spec owner's request 2026-10-20). Run it on the code to be judged:
--   sandbox/sim run sandbox/scenarios/ack_loss_parked.lua --code rev:23f5a97^     (before the private channel)
--   sandbox/sim run sandbox/scenarios/ack_loss_parked.lua --code rev:105d104      (step 3, the shared channel off the air)
-- The report's gate_check / ack_loss output reads the "loop baseline ... acks for ... beats" lines the turtles log.
-- sim.results.queue holds, per cause, how many modem messages were lost between the radio and the program: queue
-- overflow (the 256-event cap) against events eaten by a filtered yield, summed over the workers.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  workers = 6,
  steps = function(sim)
    sim:run_for((tonumber(os.getenv("ACK_HOURS")) or 2) * 3600 * 1000)
    local total = { discarded = 0, overflowed = 0, delivered = 0 }
    local per = {}
    for _, c in ipairs(sim.sched.computers) do
      local st = c.stats
      if st and c.name:match("^node_%d+$") then
        local d, o, v = st.discarded.modem_message or 0, st.overflowed.modem_message or 0, st.delivered.modem_message or 0
        total.discarded = total.discarded + d; total.overflowed = total.overflowed + o; total.delivered = total.delivered + v
        local a = st.acks
        per[#per + 1] = string.format("%s delivered=%d discarded=%d overflowed=%d | acks to it: queued=%d handed-to-program=%d dropped-by-filtered-yield=%d dropped-by-overflow=%d",
          c.name, v, d, o, a.queued or 0, a.delivered or 0, a.discarded or 0, a.overflowed or 0)
      end
    end
    table.sort(per)
    sim.results.queue = total
    sim.results.queue_per_node = per
    for _, line in ipairs(per) do sim:expect(true, line) end
    sim:expect(true, string.format("modem messages over all nodes: delivered %d, dropped by a filtered yield %d, dropped by queue overflow %d",
      total.delivered, total.discarded, total.overflowed))
  end,
}
