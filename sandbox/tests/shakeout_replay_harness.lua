-- Test harness for sandbox/scenarios/shakeout_replay.lua (driven by sandbox/tests/test_shakeout_schedule.py).
-- Run from the repo root:  SHAKEOUT_SCHEDULE=<schedule.json> <lua> sandbox/tests/shakeout_replay_harness.lua
--
-- It replays the schedule against a FAKE sim whose only methods are the simulator's real verbs: every function of
-- core.sim's Sim table once faults.faults, control.control and control.snapshot have added theirs (the same modules
-- scenario/runner.lua loads). Asking the fake for any other method raises "... is not a simulator verb", so a
-- replay that called a made-up verb would fail here. Each call is recorded; the fake clock follows run_until_time.
-- Prints one JSON line: { known_verbs, calls = [{verb, t}], handled = [fault names replayed], internals = [...] }.
-- SHAKEOUT_HARNESS_BAD_VERB=1 makes the harness itself call a verb that does not exist (the check's control arm).
package.path = "sandbox/?.lua;" .. package.path

local Sim = require("core.sim")
require("faults.faults")
require("control.control")
require("control.snapshot")
local JSON = require("core.json")

local known, known_list = {}, {}
for k, v in pairs(Sim) do
  if type(v) == "function" then known[k] = true; known_list[#known_list + 1] = k end
end
table.sort(known_list)

local calls, internals = {}, {}
local now = 0

local function turtle(id, role, x, z, pos)
  return { id = id, name = "node_" .. id, kind = "turtle", role = role, home_pos = { x = x, y = 67, z = z, facing = 0 },
           pos = pos or { x = x, y = 67, z = z, facing = 0 }, tstate = { inv = { [1] = { name = "x", count = 1 } } } }
end

local computers = {
  { id = 1, name = "dispatch", kind = "computer", role = "server", disk_obj = { quota = 1000000, used = function() return 400000 end } },
  { id = 2, name = "warehouse", kind = "computer", role = "warehouse" },
  { id = 3, name = "atc", kind = "computer", role = "atc" },
  { id = 101, name = "gps_101", kind = "gps_host" }, { id = 102, name = "gps_102", kind = "gps_host" },
  { id = 103, name = "gps_103", kind = "gps_host" }, { id = 104, name = "gps_104", kind = "gps_host" },
  turtle(11, "miner", 167, -2806, { x = 1920, y = 30, z = -2624, facing = 1 }),
  turtle(12, "miner", 168, -2806),
  turtle(31, "delivery", 153, -2806),
  turtle(51, "support", 153, -2797),
  { id = 21, name = "loader_1", kind = "turtle", role = "loader", carried = true },
}

local fake = { t0 = 0, clock = { now = function() return now end },
  sched = { computers = computers, loading = { clear_forced = function() internals[#internals + 1] = "loading:clear_forced @" .. now end } } }
setmetatable(fake, { __index = function(_, k)
  if not known[k] then error("fake sim: '" .. tostring(k) .. "' is not a simulator verb", 2) end
  return function(self, a)
    calls[#calls + 1] = { verb = k, t = now }
    if k == "run_until_time" then now = math.max(now, a) end
    return true
  end
end })

local scenario = dofile("sandbox/scenarios/shakeout_replay.lua")
local R = scenario.replay
local entries = R.load(assert(os.getenv("SHAKEOUT_SCHEDULE"), "set SHAKEOUT_SCHEDULE"))
local handled = R.run(fake, entries, { tail_ms = 0 })
if os.getenv("SHAKEOUT_HARNESS_BAD_VERB") then fake:not_a_real_verb() end
print(JSON.encode({ known_verbs = known_list, calls = calls, handled = handled, internals = internals }))
