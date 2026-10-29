-- W3 card "A deploy within 5 minutes of a push installs stale files (GitHub raw cache)", the half that stayed open:
-- the bridge's /self-update sends UPDATE_ALL with no commit, so the server and every turtle fetched "master" from
-- raw.githubusercontent.com -- a 5-minute cache that can serve the previous release or a mixture -- and a busy turtle
-- took whatever master was when it next went idle (node_178, 15 h later, 2026-10-28).
-- Since 2026-10-28 the server asks GitHub's API which commit master is and pins the deploy to it. Here: an UPDATE_ALL
-- with no params; every file the server and the miner then fetch must come from that commit (the simulator's GitHub
-- answers sched.master_sha), none from "master".
-- Fails on f108215 (every fetch is ref=master); passes on the fix.
local SHA = string.rep("e", 40)

local function trace_size(sim)
  local f = io.open(sim.run_dir .. "/trace.log", "rb")
  if not f then return 0 end
  local n = f:seek("end"); f:close(); return n
end

local function fetches(sim, from_byte)
  local out = {}
  local f = io.open(sim.run_dir .. "/trace.log", "rb")
  if not f then return out end
  f:seek("set", from_byte)
  for line in f:lines() do
    local ref = line:match("github%-raw ref=(%S+)")
    if ref then out[ref] = (out[ref] or 0) + 1 end
  end
  f:close()
  return out
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local fanned = sim:capture_log("UPDATE_ALL: sent to")
    local pinned = sim:capture_log("pinned to " .. SHA)          -- the fan-out line, logged after the restart
    sim:run_for(120000)
    sim.sched.master_sha = SHA
    local mark = trace_size(sim)
    sim:dispatch{ type = "UPDATE_ALL", params = {} }                  -- THE TEST: a deploy naming no commit
    sim:expect(sim:run_until(function() return #fanned.lines >= 1 end, 10 * 60000), "the deploy reached the fleet")
    sim:run_for(180000)
    local got = fetches(sim, mark)
    local parts = {}
    for ref, n in pairs(got) do parts[#parts + 1] = ref:sub(1, 10) .. "=" .. n end
    table.sort(parts)
    sim.results.fetches = table.concat(parts, " ")
    sim:expect(#pinned.lines >= 1, "the fleet was sent master's commit (UPDATE_ALL ... pinned to " .. SHA:sub(1, 10) .. ")")
    sim:expect((got[SHA] or 0) > 0, "files were fetched from master's commit (" .. sim.results.fetches .. ")")
    sim:expect((got.master or 0) == 0, "and none from 'master' (" .. tostring(got.master or 0) .. ")")
  end,
}
