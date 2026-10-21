-- T2 action probe (sandbox code, not a fleet file): times turtle actions in real CC:Tweaked and writes probe_results.json.
-- It runs as the startup of a spawned turtle with a diamond pickaxe on the right and a wireless modem on the left. Before it
-- starts, sandbox/t2/probe_actions.py has put stone in front of it and a chest above, and left free air around it.
-- Real UTC milliseconds are used (os.epoch("utc")); run it at tick rate 20 so they equal game time.
local results = {}

local function timed(label, n, fn)
  local ok = 0
  local t0 = os.epoch("utc")
  for _ = 1, n do
    local r = fn()
    if r then ok = ok + 1 end
  end
  local dt = os.epoch("utc") - t0
  results[label] = { n = n, ok = ok, total_ms = dt, per_ms = dt / n }
end

local function save()
  local f = fs.open("probe_results.json", "w")
  f.write(textutils.serialiseJSON(results))
  f.close()
end

-- movement in free air: out and back (back first: the block in front is stone, the block below is a chest)
timed("back", 20, turtle.back)
timed("forward", 20, turtle.forward)
timed("up", 20, turtle.up)
timed("down", 20, turtle.down)
timed("turnLeft", 20, turtle.turnLeft)
timed("turnRight", 20, turtle.turnRight)
save()

-- actions that fail: a move into the stone in front, a dig with nothing in front (after the stone is gone), an empty-slot place
timed("forward_blocked", 5, turtle.forward)
timed("up_blocked_none", 1, function() return true end)
-- what the probe is standing in front of, and what it carries: a failed dig has to be explainable
do
  local ok, info = turtle.inspect()
  results.front = ok and info.name or tostring(info)
  local eq = turtle.getEquippedRight and turtle.getEquippedRight()
  results.equipped_right = eq and eq.name or "none"
  local eql = turtle.getEquippedLeft and turtle.getEquippedLeft()
  results.equipped_left = eql and eql.name or "none"
  local d1, e1 = turtle.dig()
  results.first_dig = { ok = d1, err = e1 }
  if d1 then turtle.select(1); turtle.place() end
end
-- dig and place: the block in front is stone; dig it, put it back
turtle.select(1)
local dig_total, place_total, digs, places = 0, 0, 0, 0
for _ = 1, 20 do
  local t0 = os.epoch("utc")
  local ok = turtle.dig()
  dig_total = dig_total + (os.epoch("utc") - t0)
  if ok then digs = digs + 1 end
  turtle.select(1)
  t0 = os.epoch("utc")
  local pok = turtle.place()
  place_total = place_total + (os.epoch("utc") - t0)
  if pok then places = places + 1 end
end
results.dig = { n = 20, ok = digs, total_ms = dig_total, per_ms = dig_total / 20 }
-- the stone was put back by the last place; take it away and dig the empty air a few times
turtle.dig()
do
  local t0 = os.epoch("utc")
  local n_ok = 0
  for _ = 1, 10 do if turtle.dig() then n_ok = n_ok + 1 end end
  results.dig_air = { n = 10, ok = n_ok, total_ms = os.epoch("utc") - t0, per_ms = (os.epoch("utc") - t0) / 10 }
  t0 = os.epoch("utc")
  turtle.select(16)   -- an empty slot
  n_ok = 0
  for _ = 1, 10 do if turtle.place() then n_ok = n_ok + 1 end end
  results.place_empty_slot = { n = 10, ok = n_ok, total_ms = os.epoch("utc") - t0, per_ms = (os.epoch("utc") - t0) / 10 }
  turtle.select(1)
end
results.place = { n = 20, ok = places, total_ms = place_total, per_ms = place_total / 20 }
save()

-- cheap commands
timed("detect", 50, turtle.detect)
timed("inspect", 50, function() return turtle.inspect() end)
timed("select", 50, function() return turtle.select(1) end)
timed("getItemCount", 50, function() return turtle.getItemCount(1) >= 0 end)
timed("getItemDetail", 50, function() return turtle.getItemDetail(1) ~= nil or true end)
timed("getFuelLevel", 50, function() return turtle.getFuelLevel() >= 0 end)
timed("refuel0", 20, function() return turtle.refuel(0) end)
save()

-- the chest below: drop one item in, suck it back
turtle.select(1)
timed("dropDown", 10, function() return turtle.dropDown(1) end)
timed("suckDown", 10, function() return turtle.suckDown(1) end)
save()

-- the geo scanner, if the turtle has one on the right instead of the pickaxe (probe_actions.py sets ProbeScanner)
local scanner = peripheral.find("geoScanner")
if scanner then
  local first = os.epoch("utc")
  for i = 1, 5 do
    local t0 = os.epoch("utc")
    local data, err = scanner.scan(8)
    local dt = os.epoch("utc") - t0
    results["scan8_" .. i] = { total_ms = dt, ok = data ~= nil, err = err, blocks = data and #data or 0 }
    if not data then sleep(2) end
  end
  save()
end

results.done = os.epoch("utc")
save()
