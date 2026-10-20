-- Every fault of spec section 7 changes behaviour, and its test can fail: at the end each test is run again with
-- the fault turned into a no-op and must fail then.
package.path = "sandbox/?.lua;" .. package.path
local Sim = require("core.sim")
local World = require("world.world")
local Faults = require("faults.faults")
local TIMINGS = require("timings")
local H = dofile("sandbox/tests/helpers.lua")

local START = 1790000000000

-- A small sim with no installer: computers are given their programs directly.
local function mini()
  local meta = { base_loaded = { { -200, -200, 200, 200 } }, gps_hosts = {} }
  local world = World.new_empty(meta)
  local dir = H.tmpdir()
  return Sim.new{ world = world, run_dir = dir, code_dir = dir, seed = 5, start_ms = START }
end

local function add(sim, spec, program)
  local comp = sim:add_computer(spec)
  H.write(comp.disk .. "/startup.lua", program)
  return comp
end

local function boot_all(sim)
  for _, c in ipairs(sim.sched.computers) do if c.state == "off" and c.kind ~= "gps_host" then c:boot() end end
end

local function lines(comp)
  local o = {}
  for i, l in ipairs(comp.output) do o[i] = l.text end
  return o
end

local function field(line, n) local i = 0 for w in line:gmatch("[^\t]+") do i = i + 1; if i == n then return w end end end

local COUNT_BOOTS = [[
local n = 0
if fs.exists("boots") then local f = fs.open("boots", "r"); n = tonumber(f.readAll()) or 0; f.close() end
n = n + 1
local f = fs.open("boots", "w"); f.write(tostring(n)); f.close()
print("boot", n, os.epoch("utc"))
]]

local function four_gps(sim)
  local hosts = { { 150, 120, -2800 }, { 235, 120, -2800 }, { 150, 120, -2780 }, { 235, 110, -2820 } }
  for i, h in ipairs(hosts) do sim:add_computer{ id = 100 + i, kind = "gps_host", pos = { x = h[1], y = h[2], z = h[3] } } end
end

local TESTS = {}

TESTS.server_crash = function(t)
  local function run(fault)
    local sim = mini()
    local s = add(sim, { id = 1, kind = "computer", role = "server", pos = { x = 0, y = 64, z = 0 } },
      COUNT_BOOTS .. "sleep(100000)")
    boot_all(sim)
    if fault then sim:server_crash(2000, 5000) end
    sim:run_for(20000)
    return s
  end
  local base, hit = run(false), run(true)
  t.eq(#lines(base), 1, "baseline boots once")
  t.eq(#lines(hit), 2, "a crash makes it boot twice")
  t.eq(field(lines(hit)[2], 2), "2", "the disk survived the crash")
  t.ok(tonumber(field(lines(hit)[2], 3)) >= START + 2000 + 5000, "back before the downtime was over")
end

TESTS.world_restart = function(t)
  local function run(fault)
    local sim = mini()
    four_gps(sim)
    local a = add(sim, { id = 1, kind = "computer", role = "server", pos = { x = 0, y = 64, z = 0 } }, COUNT_BOOTS .. "sleep(100000)")
    boot_all(sim)
    if fault then sim:world_restart(2000, { gps_delay = 30000 }) end
    sim:run_for(20000)
    local gps_mid = sim.by_id[101].state
    sim:run_for(20000)
    return a, gps_mid, sim.by_id[101].state
  end
  local base_a, base_mid = run(false)
  local a, mid, late = run(true)
  t.eq(#lines(base_a), 1)
  t.eq(#lines(a), 2, "every computer reboots")
  t.eq(base_mid, "waiting")
  t.eq(mid, "off", "the GPS host is still down")
  t.eq(late, "waiting", "and comes back late")
end

TESTS.server_lag = function(t)
  local PROG = [[ sleep(2); local a = os.epoch("utc"); for i = 1, 500000 do end; print(os.epoch("utc") - a) ]]
  local function run(fault)
    local sim = mini()
    local s = add(sim, { id = 1, kind = "computer", role = "server", pos = { x = 0, y = 64, z = 0 } }, PROG)
    boot_all(sim)
    if fault then sim:server_lag(0, 60000, 10) end
    sim:run_for(30000)
    return tonumber(lines(s)[1])
  end
  local base, lagged = run(false), run(true)
  t.ok(base and base > 0)
  t.ok(lagged >= base * 8, "lagged work took " .. tostring(lagged) .. " vs " .. tostring(base))
end

TESTS.tps_drop = function(t)
  local PROG = [[ sleep(2); local a = os.epoch("utc"); turtle.up(); print(os.epoch("utc") - a) ]]
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 5, kind = "turtle", pos = { x = 0, y = 64, z = 0, facing = 0 }, turtle = {} }, PROG)
    boot_all(sim)
    if fault then sim:tps_drop(0, 60000, 10) end
    sim:run_for(10000)
    return tonumber(lines(c)[1])
  end
  t.eq(run(false), TIMINGS.up_ms)
  t.eq(run(true), TIMINGS.up_ms * 2)
end

local function radio_pair(sim)
  local rx = add(sim, { id = 2, kind = "computer", pos = { x = 0, y = 64, z = 0 }, modems = { "top" } }, [[
    local m = peripheral.find("modem"); m.open(5)
    while true do local _, _, _, _, msg = os.pullEvent("modem_message"); print(os.epoch("utc"), msg.n) end ]])
  add(sim, { id = 3, kind = "computer", pos = { x = 10, y = 64, z = 0 }, modems = { "top" } }, [[
    local m = peripheral.find("modem"); local n = 0
    while true do n = n + 1; m.transmit(5, 5, { n = n }); sleep(1) end ]])
  return rx
end

TESTS.radio_loss = function(t)
  local function run(fault)
    local sim = mini()
    local rx = radio_pair(sim)
    boot_all(sim)
    if fault then sim:radio_loss(10000, 20000, 1.0, { channel = 5 }) end
    sim:run_for(60000)
    return #lines(rx)
  end
  local base, lossy = run(false), run(true)
  t.ok(base >= 55, "baseline hears nearly every message: " .. base)
  t.ok(lossy <= base - 15, "the loss window should have cost about 20 messages: " .. lossy .. " vs " .. base)
end

TESTS.radio_latency = function(t)
  local function run(fault)
    local sim = mini()
    local rx = radio_pair(sim)
    boot_all(sim)
    if fault then sim:radio_latency(10000, 20000, 700) end
    sim:run_for(40000)
    -- delay of the message sent at about t+15 s: arrival minus its send time
    local worst = 0
    for _, l in ipairs(lines(rx)) do
      local arrive, n = tonumber(field(l, 1)), tonumber(field(l, 2))
      local sent = START + (n - 1) * 1050 -- sleep(1) rounds to 1000 ms plus startup; compare against the baseline instead
      worst = math.max(worst, arrive - sent)
    end
    return lines(rx)
  end
  local base, slow = run(false), run(true)
  local function gap(ls) -- time between consecutive arrivals, smallest first difference around the window
    local m = 0
    for i = 2, #ls do m = math.max(m, tonumber(field(ls[i], 1)) - tonumber(field(ls[i - 1], 1))) end
    return m
  end
  -- messages are 1000 ms apart; latency that starts at 10 s stretches one gap by 700 ms and shrinks one by 700
  t.ok(gap(slow) >= gap(base) + 600, "latency should open a gap of 1700 ms: " .. gap(slow) .. " vs " .. gap(base))
end

TESTS.gps_down = function(t)
  local function run(fault)
    local sim = mini()
    four_gps(sim)
    local c = add(sim, { id = 5, kind = "turtle", pos = { x = 13, y = 64, z = -7, facing = 0 },
      turtle = { equipped = { left = "computercraft:wireless_modem_advanced" } } }, [[
      while true do print(gps.locate(2)); sleep(10) end ]])
    boot_all(sim)
    if fault then sim:gps_down(15000, 20000) end
    sim:run_for(60000)
    return lines(c)
  end
  local base, down = run(false), run(true)
  for i, l in ipairs(base) do t.eq(l, "13\t64\t-7", "baseline fix " .. i) end
  local failed = 0
  for _, l in ipairs(down) do if l == "nil" then failed = failed + 1 end end
  t.ok(failed >= 1 and failed < #down, "some fixes should fail during the outage and others succeed: " .. table.concat(down, "|"))
end

local function rs_sim()
  local sim = mini()
  sim.world:set(1, 64, 0, "advancedperipherals:rs_bridge")
  sim.sched.storage:add("minecraft:coal", 5)
  return sim
end

TESTS.rs_stall = function(t)
  local PROG = [[ local rs = peripheral.find("rsBridge"); while true do local a = os.epoch("utc"); rs.listItems(); print(os.epoch("utc") - a); sleep(10) end ]]
  local function run(fault)
    local sim = rs_sim()
    local c = add(sim, { id = 1, kind = "computer", role = "server", pos = { x = 0, y = 64, z = 0, facing = 0 } }, PROG)
    boot_all(sim)
    if fault then sim:rs_stall(12000, 30000, 7) end
    sim:run_for(60000)
    local worst = 0
    for _, l in ipairs(lines(c)) do worst = math.max(worst, tonumber(l)) end
    return worst
  end
  t.eq(run(false), TIMINGS.rs_list_ms)
  t.ok(run(true) >= 7000 + TIMINGS.rs_list_ms, "a stalled listItems takes at least the stall")
end

TESTS.rs_offline = function(t)
  local PROG = [[ local rs = peripheral.find("rsBridge"); while true do print(pcall(rs.listItems)); sleep(10) end ]]
  local function run(fault)
    local sim = rs_sim()
    local c = add(sim, { id = 1, kind = "computer", role = "server", pos = { x = 0, y = 64, z = 0, facing = 0 } }, PROG)
    boot_all(sim)
    if fault then sim:rs_offline(12000, 25000) end
    sim:run_for(60000)
    local failures = 0
    for _, l in ipairs(lines(c)) do if l:find("^false") then failures = failures + 1 end end
    return failures
  end
  t.eq(run(false), 0)
  t.ok(run(true) >= 2, "listItems should fail while the network is offline")
end

TESTS.turtle_reboot = function(t)
  local PROG = COUNT_BOOTS .. [[ turtle.select(1); while true do turtle.refuel(1); sleep(2) end ]]
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 5, kind = "turtle", pos = { x = 0, y = 64, z = 0, facing = 0 },
      turtle = { fuel = 1000, inv = { [1] = { name = "minecraft:coal", count = 10 } } } }, PROG)
    boot_all(sim)
    if fault then sim:turtle_reboot(3000, 5, { at_action = "refuel" }) end
    sim:run_for(20000)
    return c
  end
  local base, hit = run(false), run(true)
  t.eq(#lines(base), 1, "no fault, one boot")
  t.eq(#lines(hit), 2, "the refuel in progress was interrupted by a reboot")
  t.ok(hit.reboot_on_action == nil, "the trap fires once")
end

TESTS.chunk_unload = function(t)
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 5, kind = "turtle", pos = { x = 0, y = 64, z = 0, facing = 0 }, turtle = {} },
      [[ while true do print("alive"); sleep(2) end ]])
    boot_all(sim)
    if fault then sim:chunk_unload(5000, { -10, -10, 10, 10 }) end
    sim:run_for(20000)
    return c
  end
  local base, hit = run(false), run(true)
  t.ok(#lines(base) >= 9)
  t.ok(#lines(hit) <= 4, "a frozen computer stops printing: " .. #lines(hit))
  t.eq(hit.state, "off")
end

TESTS.disk_full = function(t)
  local PROG = [[ local n = 0; while true do n = n + 1; local ok = pcall(function() local f = fs.open("data", "w"); f.write(string.rep("x", 5000 + n * 500)); f.close() end); print(ok); sleep(5) end ]]
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 1, kind = "computer", role = "server", pos = { x = 0, y = 64, z = 0 } }, PROG)
    boot_all(sim)
    if fault then sim:disk_full(12000, 1, 0) end
    sim:run_for(40000)
    local bad = 0
    for _, l in ipairs(lines(c)) do if l == "false" then bad = bad + 1 end end
    return bad
  end
  t.eq(run(false), 0)
  t.ok(run(true) >= 3, "writes should fail once the disk is full")
end

TESTS.bridge_down = function(t)
  local PROG = [[ while true do http.request("http://127.0.0.1:3000/ping"); local ev = os.pullEvent(); print(ev); sleep(5) end ]]
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 1, kind = "computer", pos = { x = 0, y = 64, z = 0 } }, PROG)
    boot_all(sim)
    if fault then sim:bridge_down(8000, 12000) end
    sim:run_for(40000)
    local fails = 0
    for _, l in ipairs(lines(c)) do if l == "http_failure" then fails = fails + 1 end end
    return fails
  end
  t.eq(run(false), 0)
  t.ok(run(true) >= 2, "requests should fail while the bridge is down")
end

TESTS.bridge_slow = function(t)
  local PROG = [[ sleep(20); local a = os.epoch("utc"); http.request("http://127.0.0.1:3000/ping"); os.pullEvent(); print(os.epoch("utc") - a) ]]
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 1, kind = "computer", pos = { x = 0, y = 64, z = 0 } }, PROG)
    boot_all(sim)
    if fault then sim:bridge_slow(10000, 30000, 4000) end
    sim:run_for(40000)
    return tonumber(lines(c)[1])
  end
  local base, slow = run(false), run(true)
  t.eq(base, TIMINGS.http_reply_ms)
  t.ok(slow >= 4000, "a slow bridge answers late: " .. tostring(slow))
end

TESTS.remove_item = function(t)
  local PROG = [[ sleep(1); print(turtle.getItemCount(5)); sleep(4); print(turtle.getItemCount(5)) ]]
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 5, kind = "turtle", pos = { x = 0, y = 64, z = 0, facing = 0 },
      turtle = { inv = { [5] = { name = "enderstorage:ender_chest", count = 1 } } } }, PROG)
    boot_all(sim)
    if fault then sim:remove_item(2000, 5, 5) end
    sim:run_for(10000)
    return lines(c)
  end
  t.eq(table.concat(run(false), "|"), "1|1")
  t.eq(table.concat(run(true), "|"), "1|0")
end

TESTS.event_queue_flood = function(t)
  local PROG = [[ sleep(1); for i = 1, 60000000 do end; sleep(1000) ]]
  local function run(fault)
    local sim = mini()
    local c = add(sim, { id = 5, kind = "computer", pos = { x = 0, y = 64, z = 0 } }, PROG)
    boot_all(sim)
    if fault then sim:event_queue_flood(1500, 5, 400) end
    sim:run_for(1600)
    return #c.queue, c.state
  end
  local base_q = run(false)
  local q, state = run(true)
  t.eq(base_q, 0)
  t.eq(state, "busy", "the flood must land while the computer is busy")
  t.eq(q, 256, "the queue holds 256 and drops the rest")
end

local out = {}
for name, fn in pairs(TESTS) do out["fault " .. name .. " changes behaviour"] = fn end

-- The tests above can fail: with each fault turned into a no-op, its test must fail.
for _, name in ipairs(Faults.NAMES) do
  out["fault " .. name .. " test fails when the fault does nothing"] = function(t)
    local fn = assert(TESTS[name], "no test for fault " .. name)
    local original = Sim[name]
    Sim[name] = function() end
    local ok = pcall(fn, H)
    Sim[name] = original
    t.ok(not ok, "the test for " .. name .. " still passes when the fault is a no-op")
  end
end

return out
