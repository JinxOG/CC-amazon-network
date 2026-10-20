-- Runs test_fileserver.sh and reports each of its checks as a test.
local H = dofile("sandbox/tests/helpers.lua")

local function run()
  local p = io.popen("bash sandbox/tests/test_fileserver.sh 2>&1")
  local text = p:read("*a")
  p:close()
  return text
end

local text -- run once, shared by every check below
local function result()
  text = text or run()
  return text
end

local function check(name)
  return function(t)
    local out = result()
    t.ok(out:find("ok " .. name, 1, true), "check '" .. name .. "' did not pass:\n" .. out)
    t.ok(not out:find("FAIL " .. name, 1, true), "check '" .. name .. "' failed:\n" .. out)
  end
end

local names = { "server starts", "state returns the fixture", "logs contains filter", "logs level and source parse",
  "audit sees the missing sequence number", "log list", "writes are refused", "dashboard page is served", "state timestamps read fresh while being written",
  "dynmap-frame is served", "map model has one marker per turtle", "map model cuts a 3-sector zone into 3 cells",
  "listens on 127.0.0.1 only", "gate_check completes against the fixture", "ack_loss completes against the fixture",
  "gate_check default address unchanged", "ack_loss default address unchanged" }

local tests = {}
for _, n in ipairs(names) do tests["fileserver: " .. n] = check(n) end
return tests
