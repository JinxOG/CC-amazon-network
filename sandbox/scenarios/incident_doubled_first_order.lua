-- Incident 1.9.108: a sector order arriving while the job waited reached the job AND the control loop, so every miner
-- held a spare copy of its first order and reported its first sector done twice. Signature in the server log:
-- two "Survey (x,z) done by node_N" lines in a row for the same sector and the same miner.
-- Run it on code before 8dc699c (doubles) and on the fix (does not). It hands its verdict to the test in sim.results.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  workers = 6,
  steps = function(sim)
    local done = sim:capture_log("done by node_")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    sim:run_for(90 * 60000)

    -- strip the timestamp, the log sequence and the "[job: n/16 surveyed]" counter, keep "Survey (x,z) done by node_N"
    local doubled, first = false, nil
    local previous = {}
    for _, line in ipairs(done.lines) do
      local what, who = line:match("(Survey %b() done by node_%d+)")
      if what then
        local node = what:match("node_%d+")
        if previous[node] == what then doubled = true; first = first or what end
        previous[node] = what
      end
    end
    sim.results.doubled_first_order = doubled
    sim.results.duplicate_line = first
    sim.results.survey_lines = #done.lines
  end,
}
