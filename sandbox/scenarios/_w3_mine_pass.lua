-- Shared steps for W3's "keep MINE-phase zones on reassign" proofs (spec owner, 2026-10-22; job_0210 live).
-- The survey finishes, a miner is a few minutes into its first MINE sector with nothing done, and then:
--   kind = "reboot"  -- that miner alone is rebooted in the field                     (proof 1, and the base case)
--   kind = "restart" -- the whole world restarts, dispatch server included, as at 12:03 (proof 3)
--   kind = "shared"  -- two miners share one zone; only one is rebooted                 (proof 2)
-- Every kind: the zone is surveyed once, never again; the job(s) complete; job time and ore are reported so the
-- keep can be compared with today's rebuild (run the same scenario with --code rev:bfc2770).
local M = {}

local function isMine(l) return not l:find("[SURVEY]", 1, true) and not l:find("[RESCAN]", 1, true) end

function M.steps(kind)
  return function(sim)
    local done      = sim:watch_log("Job complete: job_")
    local surveyed  = sim:capture_log("survey complete (")
    local assigned  = sim:capture_log("Assigned sector (")
    local doneBy    = sim:capture_log("done by node_")
    local requeued  = sim:capture_log("back to queue (from")
    local released  = sim:capture_log("Lease on (")
    local keptMine  = sim:capture_log("keeps its mine zone")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    local params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 }
    if kind == "shared" then params.minerCount = 2 end
    sim:dispatch{ type = "ORDER_MINE", params = params }
    local t0 = sim.clock:now()
    local jobsWanted = (kind == "shared") and 2 or 1

    -- Every miner wanted has its first MINE sector.
    local function mineHolders()
      local holders, n = {}, 0
      for _, l in ipairs(assigned.lines) do
        if isMine(l) then
          local m = l:match("to (node_%d+)")
          if m and not holders[m] then holders[m] = l:match("%((%-?%d+,%-?%d+)%)"); n = n + 1 end
        end
      end
      return holders, n
    end
    local mining = sim:run_until(function()
      local _, n = mineHolders()
      return #surveyed.lines >= 1 and n >= jobsWanted
    end, 12 * 3600 * 1000)
    sim:expect(mining, "the survey finished and " .. jobsWanted .. " miner(s) started a mine sector")
    if not mining then return end
    sim:run_for(8 * 60000)                               -- digging, nothing done yet
    local holders = mineHolders()
    local victim, other
    for m in pairs(holders) do if not victim then victim = m else other = m end end

    local function surveyLines()
      local n = 0
      for _, l in ipairs(doneBy.lines) do if l:find("Survey (", 1, true) then n = n + 1 end end
      return n
    end
    local surveysBefore, requeuedBefore, releasedBefore = surveyLines(), #requeued.lines, #released.lines

    if kind == "restart" then
      sim:world_restart(sim.clock:now() - sim.t0 + 1000)
    else
      sim:reboot(victim)
    end

    local back = sim:run_until(function() return #requeued.lines > requeuedBefore end, 15 * 60000)
    sim:expect(back, "the rebooted miner's job was requeued")
    local finished = sim:run_until(function() return done.count >= jobsWanted end, 30 * 3600 * 1000)
    sim:expect(finished, "the job(s) complete")
    sim:expect(#surveyed.lines == 1, "the zone was surveyed once, not again (" .. #surveyed.lines .. " survey passes)")
    sim:expect(surveysBefore > 0 and surveyLines() == surveysBefore,
      "no sector was surveyed again (" .. (surveyLines() - surveysBefore) .. " more, after " .. surveysBefore .. ")")

    if kind == "shared" then
      local otherReleased, victimReturned = 0, 0
      for i = releasedBefore + 1, #released.lines do
        local l = released.lines[i]
        if other and l:find("released by " .. other, 1, true) then otherReleased = otherReleased + 1 end
        if l:find("released by " .. victim, 1, true) and l:find("returned to pending", 1, true) then
          victimReturned = victimReturned + 1
        end
      end
      sim:expect(otherReleased == 0, "the other miner's lease was never released (" .. otherReleased .. ")")
      sim:expect(victimReturned == 1, "the rebooted miner's sector went back to pending exactly once (" .. victimReturned .. ")")
      -- No sector finished twice in the MINE pass of this run.
      local seen, twice = {}, 0
      for _, l in ipairs(doneBy.lines) do
        local s = l:match("^.-Sector %((%-?%d+,%-?%d+)%) done by")
        if s then
          if seen[s] then twice = twice + 1 end
          seen[s] = true
        end
      end
      sim:expect(twice == 0, "no sector was mined twice (" .. twice .. ")")
    end

    local ore = 0
    for _, l in ipairs(doneBy.lines) do
      local n = l:match("(%d+) ore mined")
      if n then ore = ore + tonumber(n) end
    end
    local minutes = (sim.clock:now() - t0) / 60000
    sim:expect(true, string.format("MEASURE (%s): job time %.1f min from dispatch, ore mined %d, 'keeps its mine zone' %d",
      kind, minutes, ore, #keptMine.lines))
  end
end

return M
