-- W3 card "A staged update can be stale" -- what the audit found instead, 2026-10-28.
-- The card's path cannot happen (every deploy reboots the server, which starts an empty registry, so nothing staged
-- survives to the next deploy). This one can: the server wrote a deploy's commit as "the last deploy" BEFORE its own
-- update ran. When that update failed it stayed on its old code -- but from its next restart (the daily one) it named
-- the failed commit as the last deploy, and a lagging turtle was sent code AHEAD of its server, the very outcome the
-- failed-update guard (dropFanOut) exists to prevent.
-- Deploy OLD succeeds; deploy NEW fails on the server (the code is hidden from the simulated GitHub while the server
-- updates, so every download fails); the server is restarted; a miner made to lag (its protocol.lua says 1.9.1) comes
-- back and is caught up. It must be sent OLD, and the server's deploy_ref.txt must say OLD.
-- Fails on cb16d9a (deploy_ref.txt says NEW and the miner fetches NEW); passes on the fix.
local OLD, NEW = string.rep("a", 40), string.rep("b", 40)

local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

local function fetches(sim, from_byte, ref)
  local f = io.open(sim.run_dir .. "/trace.log", "rb")
  if not f then return 0 end
  f:seek("set", from_byte)
  local n = 0
  for line in f:lines() do
    if line:find("github-raw ref=" .. ref, 1, true) then n = n + 1 end
  end
  f:close()
  return n
end

local function trace_size(sim)
  local f = io.open(sim.run_dir .. "/trace.log", "rb")
  if not f then return 0 end
  local n = f:seek("end"); f:close(); return n
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local restarted = sim:capture_log("Restarted for a deploy")
    local fanned    = sim:capture_log("UPDATE_ALL: sent to")
    local failed    = sim:capture_log("UPDATE FAILED")
    local online    = sim:capture_log("Central server online")
    local caught    = sim:capture_log("queued for the current release")
    local delivered = sim:capture_log("UPDATE_ALL: delivered to")
    sim:run_for(120000)
    local server, miner = node(sim, "server"), node(sim, "miner")
    sim:expect(server ~= nil and miner ~= nil, "a server and a miner")
    if not (server and miner) then return end

    sim:dispatch{ type = "UPDATE_ALL", params = { ref = OLD } }               -- deploy N: succeeds
    sim:expect(sim:run_until(function() return #fanned.lines >= 1 end, 10 * 60000), "deploy OLD reached the fleet")
    sim:run_for(180000)

    local code_dir = sim.sched.code_dir
    sim.sched.code_dir = nil                                                    -- THE TEST: deploy N+1 fails
    sim:dispatch{ type = "UPDATE_ALL", params = { ref = NEW } }
    local f = sim:run_until(function() return #failed.lines >= 1 end, 10 * 60000)
    sim.sched.code_dir = code_dir
    sim:expect(f, "the server's own update of NEW failed and it stayed on its code")
    sim:run_for(30000)

    local o0 = #online.lines
    sim:reboot(server.name)                                                     -- a later restart (the daily one)
    sim:run_until(function() return #online.lines > o0 end, 5 * 60000)
    sim:run_for(60000)
    local ref = sim:read_file(server.name, "deploy_ref.txt")
    sim:expect(ref == OLD, "deploy_ref.txt names the deploy the server runs, OLD (" .. tostring(ref) .. ")")

    local proto = sim:read_file(miner.name, "protocol.lua")
    sim:write_file(miner.name, "protocol.lua", (proto:gsub('proto%.VERSION = "[^"]*"', 'proto.VERSION = "1.9.1"', 1)))
    local mark, c0, d0 = trace_size(sim), #caught.lines, #delivered.lines
    sim:reboot(miner.name)                                                      -- a lagging turtle comes back
    sim:run_until(function() return #delivered.lines > d0 end, 10 * 60000)
    sim:run_for(120000)
    sim:expect(#caught.lines > c0, "the lagging miner was queued for the current release")
    local old_n, new_n = fetches(sim, mark, OLD), fetches(sim, mark, NEW)
    sim.results.fetched_old, sim.results.fetched_new = old_n, new_n
    sim:expect(old_n > 0, "it fetched OLD, the commit its server runs (" .. old_n .. " file(s))")
    sim:expect(new_n == 0, "and nothing of NEW, the commit the server failed to install (" .. new_n .. ")")
  end,
}
