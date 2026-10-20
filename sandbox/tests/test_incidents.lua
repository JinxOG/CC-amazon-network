-- Two real incidents must reproduce on the code that had them and not on the code that fixed them (spec 8.3).
-- Old code comes from git (rev:<sha>), installed fresh on the synthetic world. What each revision actually does is
-- asserted, even where it differs from what the plan expected; the differences are reported to the spec owner.
package.path = "sandbox/?.lua;" .. package.path
local Runner = require("scenario.runner")
local H = dofile("sandbox/tests/helpers.lua")

local cache = {}
local function run(scenario, rev)
  local key = scenario .. "@" .. rev
  if not cache[key] then
    local sim, ok, err = Runner.run("sandbox/scenarios/" .. scenario .. ".lua", { run_dir = H.tmpdir(), code = "rev:" .. rev })
    assert(ok, "scenario " .. scenario .. " on " .. rev .. " failed: " .. tostring(err))
    cache[key] = sim.results
  end
  return cache[key]
end

return {
  ----------------------------------------------------------------------------------------------------------------
  -- Incident: the doubled first order (1.9.108). 8dc699c fixed the double delivery.
  ["doubled first order: 1.9.108 reports its first sector done twice"] = function(t)
    local r = run("incident_doubled_first_order", "8dc699c^")
    t.ok(r.doubled_first_order, "no duplicate 'done' line on 1.9.108; surveys seen: " .. tostring(r.survey_lines))
    t.ok(r.duplicate_line and r.duplicate_line:find("^Survey %b() done by node_%d+"), tostring(r.duplicate_line))
    t.ok(r.survey_lines >= 5, "the run should have completed several sectors, saw " .. tostring(r.survey_lines))
  end,

  ["doubled first order: 1.9.109 does not double it, but its miners never complete a sector (a different known bug)"] = function(t)
    local r = run("incident_doubled_first_order", "8dc699c")
    t.ok(not r.doubled_first_order, "1.9.109 still doubled: " .. tostring(r.duplicate_line))
    -- Take-once dropped the loader beacon (a live-only message), so every sector setup failed with loader_no_beacon.
    -- That is a real regression of 1.9.109, fixed by dc65935; the sandbox reproduces it.
    t.eq(r.survey_lines, 0, "1.9.109 is expected to complete no sector at all in this run")
  end,

  ["doubled first order: after dc65935 sectors complete and none is reported twice"] = function(t)
    local r = run("incident_doubled_first_order", "dc65935")
    t.ok(not r.doubled_first_order, "doubled again: " .. tostring(r.duplicate_line))
    t.ok(r.survey_lines >= 5, "dc65935 should complete sectors, saw " .. tostring(r.survey_lines))
  end,

  ----------------------------------------------------------------------------------------------------------------
  -- Incident 2026-10-05: miners lost after a world restart with late GPS.
  ["late GPS: the code before 1.9.132 loses a miner"] = function(t)
    local r = run("incident_gps_late_restart", "390cb52^")
    t.ok(r.lost_miners >= 1, "no miner lost; positions: " .. table.concat(r.miner_positions, "; "))
    t.ok(not r.not_moving_logged, "this code has no wait-for-a-fix line")
  end,

  ["late GPS: 1.9.132 (390cb52) still loses a miner when the fix arrives inside the boot wait"] = function(t)
    -- The plan expected 1.9.132 to fix this. It does not for a fix that comes back within the miner's 120 s boot wait:
    -- waitForPositionFix returns at once because the boot wait already set posFixed, and the facing is never measured.
    local r = run("incident_gps_late_restart", "390cb52")
    t.ok(r.lost_miners >= 1, "1.9.132 no longer loses a miner here; positions: " .. table.concat(r.miner_positions, "; "))
  end,

  ["late GPS: 1.9.134 (f437535, no moving on a guessed facing) does not lose it and recovers"] = function(t)
    local r = run("incident_gps_late_restart", "f437535")
    t.eq(r.lost_miners, 0, "positions: " .. table.concat(r.miner_positions, "; "))
  end,

  ["late GPS: the current code does not lose it either"] = function(t)
    local sim, ok, err = Runner.run("sandbox/scenarios/incident_gps_late_restart.lua", { run_dir = H.tmpdir(), code = "worktree:." })
    t.ok(ok, tostring(err))
    t.eq(sim.results.lost_miners, 0, table.concat(sim.results.miner_positions, "; "))
    -- current code says so out loud: not moving until a fix, then "can go ahead"
    t.ok(sim.results.not_moving_logged, "the miners should say they are not moving until they have a fix")
    t.ok(sim.results.can_go_ahead_logged, "and say they can go ahead once it arrives")
  end,
}
