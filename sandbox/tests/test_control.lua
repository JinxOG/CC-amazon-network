-- Every control action of spec section 7.1: its effect, that it is recorded as an intervention when it changes
-- the world, and that snapshots and the interactive mode work.
package.path = "sandbox/?.lua;" .. package.path
local Sim = require("core.sim")
local World = require("world.world")
require("faults.faults")
require("control.control")
require("control.snapshot")
local Repl = require("control.repl")
local H = dofile("sandbox/tests/helpers.lua")

local START = 1790000000000
local MODEM = "computercraft:wireless_modem_advanced"

local function mini()
  local meta = { base_loaded = { { -300, -300, 300, 300 } }, gps_hosts = {} }
  local dir = H.tmpdir()
  local sim = Sim.new{ world = World.new_empty(meta), run_dir = dir, code_dir = dir, seed = 5, start_ms = START }
  return sim
end

local function add(sim, spec, program)
  local comp = sim:add_computer(spec)
  if comp.disk then H.write(comp.disk .. "/startup.lua", program or "sleep(100000)") end
  if comp.state == "off" and comp.kind ~= "gps_host" then comp:boot() end
  return comp
end

local function turtle(sim, id, program, extra)
  local spec = { id = id, kind = "turtle", pos = { x = 0, y = 64, z = 0, facing = 0 },
    turtle = { fuel = 500, equipped = { left = MODEM } } }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return add(sim, spec, program)
end

local COUNT = [[
local n = 0
if fs.exists("boots") then local f = fs.open("boots", "r"); n = tonumber(f.readAll()) or 0; f.close() end
n = n + 1; local f = fs.open("boots", "w"); f.write(tostring(n)); f.close()
print("boot", n)
sleep(100000)
]]

local function interventions(sim) return #sim.interventions end

local T = {}

T["control pause resume step run_until set_speed"] = function(t)
  local sim = mini()
  local c = add(sim, { id = 1, kind = "computer", pos = { x = 0, y = 64, z = 0 } }, [[ while true do print(os.epoch("utc")); sleep(1) end ]])
  sim:run_for(3500)
  local before = #c.output
  sim:pause()
  t.eq(sim:run_for(5000), "paused")
  t.eq(#c.output, before, "a paused sandbox does not advance")
  sim:resume()
  sim:step(5)
  t.ok(sim.clock:now() >= START, "step ran")
  t.ok(sim:run_until(10000), "run_until a time")
  t.ok(sim.clock:now() >= START + 10000)
  local flag = false
  t.ok(sim:run_until(function() flag = flag or sim.clock:now() > START + 12000; return flag end, 60000), "run_until a condition")
  sim:set_speed(1000000); sim:set_speed("max")
  t.eq(interventions(sim), 0, "none of these is an intervention")
end

T["control teleport and recover"] = function(t)
  local sim = mini()
  local c = turtle(sim, 5)
  sim:teleport(5, 10, 70, -4, "south")
  t.eq(c.pos.x, 10); t.eq(c.pos.y, 70); t.eq(c.pos.z, -4); t.eq(c.pos.facing, 2)
  t.ok(sim.world.occupants["10,70,-4"] == c and sim.world.occupants["0,64,0"] == nil, "occupancy follows")
  sim:recover(5)
  t.eq(c.pos.x, 0); t.eq(c.pos.y, 64)
  t.eq(interventions(sim), 2)
end

T["control inventory: set_slot clear_slot give set_fuel equip"] = function(t)
  local sim = mini()
  local c = turtle(sim, 5)
  sim:set_slot("node_5", 3, "minecraft:coal", 12)
  t.eq(c.tstate.inv[3].count, 12)
  sim:give(5, "minecraft:coal", 60)
  local total = 0
  for _, s in pairs(c.tstate.inv) do total = total + s.count end
  t.eq(total, 72)
  sim:clear_slot(5, 3)
  t.eq(c.tstate.inv[3], nil)
  sim:set_fuel(5, 77); t.eq(c.tstate.fuel, 77)
  sim:equip(5, "right", "advancedperipherals:chunk_controller")
  t.eq(c.tstate.equipped.right, "advancedperipherals:chunk_controller")
  t.ok(sim.sched.loading.tickets["computer:5"], "equipping a chunky upgrade opens a chunk ticket")
  t.eq(interventions(sim), 5)
end

T["control spawn_turtle spawn_computer remove"] = function(t)
  local sim = mini()
  local orig = turtle(sim, 5, COUNT)
  orig.chunk_identity = "uuid-A"
  sim:run_for(1000)
  local copy = sim:spawn_turtle{ id = 6, copy_of = 5, pos = { x = 4, y = 64, z = 4, facing = 0 } }
  t.eq(copy.chunk_identity, "uuid-A", "a copy keeps the chunk-loading identity")
  t.ok(copy.disk_obj:exists("startup.lua"), "the disk was copied")
  sim:run_for(1000)
  t.eq(copy:effective_state(), "waiting", "the copy booted")
  local plain = sim:spawn_computer{ id = 7, pos = { x = 1, y = 64, z = 1 } }
  t.ok(plain, "a bare computer")
  sim:remove(6)
  t.eq(sim.by_id[6], nil)
  t.eq(sim.world.occupants["4,64,4"], nil)
end

T["control reboot shutdown start"] = function(t)
  local sim = mini()
  local c = turtle(sim, 5, COUNT)
  sim:run_for(1000)
  sim:shutdown(5); t.eq(c.state, "off")
  sim:start(5); sim:run_for(1000); t.eq(c:effective_state(), "waiting")
  sim:reboot(5); sim:run_for(3000)
  t.eq(c.disk_obj:read("boots"), "3", "three boots in all")
  t.eq(interventions(sim), 3)
end

T["control read_file write_file delete_file"] = function(t)
  local sim = mini()
  turtle(sim, 5)
  sim:write_file(5, "note.txt", "hello")
  t.eq(sim:read_file(5, "note.txt"), "hello")
  sim:delete_file(5, "note.txt")
  t.eq(sim:read_file(5, "note.txt"), nil)
  t.eq(interventions(sim), 2, "reads are not interventions")
end

T["control eval runs inside the computer's environment"] = function(t)
  local sim = mini()
  turtle(sim, 5, [[ counter = 41; sleep(100000) ]])
  sim:run_for(1000)
  t.eq(sim:eval(5, "counter + 1"), 42)
  t.eq(sim:eval(5, "os.getComputerID()"), 5)
  t.eq(interventions(sim), 0, "a read-only eval is not an intervention")
  sim:eval(5, "counter = 7")
  t.eq(sim:eval(5, "counter"), 7)
  t.eq(interventions(sim), 1, "an eval that assigns is")
  t.raises(function() sim:eval(5, "nosuchfunction()") end, "eval")
end

T["control output and queue"] = function(t)
  local sim = mini()
  local c = turtle(sim, 5, [[ print("one"); print("two"); local m = peripheral.find("modem"); m.open(7); m.open(3); os.startTimer(100); sleep(100000) ]])
  sim:run_for(1000)
  t.eq(sim:output(5), "one\ntwo")
  local q = sim:queue(5)
  t.eq(q.length, 0); t.eq(q.state, "waiting"); t.eq(q.channels[1], 3); t.eq(q.channels[2], 7)
  t.ok(#q.timers >= 1, "pending timers are listed")
  c.state = "busy"; c.busy_until = sim.clock:now() + 1000; c:queue_event({ "x" })
  t.eq(sim:queue(5).events[1], "x")
  c.state = "waiting"
end

T["control get_block set_block fill"] = function(t)
  local sim = mini()
  t.eq(sim:get_block(1, 64, 1), nil)
  sim:set_block(1, 64, 1, "minecraft:diamond_ore")
  t.eq(sim:get_block(1, 64, 1), "minecraft:diamond_ore")
  sim:fill({ 0, 70, 0, 2, 71, 2 }, "minecraft:stone")
  t.eq(sim:get_block(2, 71, 2), "minecraft:stone"); t.eq(sim:get_block(3, 71, 2), nil)
  t.eq(interventions(sim), 2)
end

T["control load_chunks and unload_chunks"] = function(t)
  local sim = mini()
  local c = turtle(sim, 5, nil, { pos = { x = 400, y = 64, z = 400, facing = 0 } })
  t.eq(c.state, "waiting", "the helper booted it directly")
  c:shutdown(); c.frozen = nil
  sim:load_chunks({ 392, 392, 410, 410 })
  t.ok(sim.sched.loading:is_loaded(25, 25))
  sim:unload_chunks({ 392, 392, 410, 410 })
  t.ok(not sim.sched.loading:is_loaded(25, 25))
  t.eq(interventions(sim), 2)
end

T["control send_radio and drop_radio and trace_radio"] = function(t)
  local sim = mini()
  local rx = add(sim, { id = 2, kind = "computer", pos = { x = 0, y = 64, z = 0 }, modems = { "top" } },
    [[ local m = peripheral.find("modem"); m.open(9); while true do local _, _, ch, rep, msg = os.pullEvent("modem_message"); print(ch, rep, msg.type) end ]])
  local rec = sim:trace_radio{ channel = 9 }
  sim:send_radio(9, 4, { type = "PROBE" })
  sim:run_for(100)
  t.eq(sim:output(2), "9\t4\tPROBE")
  t.eq(#rec, 1); t.eq(rec[1].to, "node_2"); t.eq(rec[1].from, "sandbox")
  sim:drop_radio{ channel = 9, type = "PROBE" }
  sim:send_radio(9, 4, { type = "PROBE" })
  sim:send_radio(9, 4, { type = "OTHER" })
  sim:run_for(100)
  t.eq(sim:output(2), "9\t4\tPROBE\n9\t4\tOTHER", "only the dropped type is lost")
  t.ok(rec[2].dropped, "the trace says which message was dropped")
  t.eq(interventions(sim), 4)
end

T["control storage kv ender"] = function(t)
  local sim = mini()
  sim:storage_set("minecraft:iron_ore", 50); sim:storage_add("minecraft:iron_ore", 5)
  t.eq(sim.sched.storage:amount("minecraft:iron_ore"), 55)
  t.eq(sim:storage_remove("minecraft:iron_ore", 10), 10)
  t.eq(sim.sched.storage:amount("minecraft:iron_ore"), 45)
  sim:kv_set("z:one", "v"); t.eq(sim:kv_get("z:one"), "v")
  sim:kv_clear(); t.eq(sim:kv_get("z:one"), nil)
  sim:ender_set("delivery", { { name = "minecraft:coal", count = 70 } })
  t.eq(sim.sched.ender:inventory("delivery"):count("minecraft:coal"), 70)
  t.raises(function() sim:ender_set("fuel", {}) end, "endless")
  t.eq(interventions(sim), 7)
end

T["control gps_host and place_gps_host"] = function(t)
  local sim = mini()
  local h = sim:place_gps_host(10, 100, 10)
  t.ok(h and h.state ~= "off")
  sim:gps_host(h.id, false); t.eq(h.state, "off")
  sim:gps_host(h.id, true); t.eq(h.state, "waiting")
  t.eq(interventions(sim), 3)
end

T["control watch and status"] = function(t)
  local sim = mini()
  add(sim, { id = 1, kind = "computer", role = "server", pos = { x = 0, y = 64, z = 0 } }, [[ while true do sleep(1) end ]])
  local fired = 0
  sim:watch(function(s) return s.clock:now() > START + 5000 end, function() fired = fired + 1 end)
  sim:watch(function(s) return s.clock:now() > START + 8000 end, "pause")
  sim:run_for(20000)
  t.eq(fired, 1)
  t.ok(sim.paused, "the pause action stopped the run")
  t.ok(sim.clock:now() < START + 12000, "and it stopped near the moment")
  local rows = sim:status()
  t.eq(rows[1].name, "node_1"); t.eq(rows[1].role, "server"); t.ok(rows[1].state == "waiting" or rows[1].state == "busy", rows[1].state)
  t.eq(interventions(sim), 0, "watch and status are not interventions")
end

T["control snapshot then restore returns the world and disks exactly"] = function(t)
  local sim = mini()
  local c = turtle(sim, 5, COUNT, { turtle = { fuel = 321, equipped = { left = MODEM }, inv = { [4] = { name = "minecraft:coal", count = 9 } } } })
  sim:set_block(3, 64, 3, "minecraft:gold_ore")
  sim:storage_set("minecraft:coal", 100)
  sim:kv_set("a", "1")
  sim.world.containers["7,64,7"] = nil
  sim:run_for(1000)
  sim:write_file(5, "keep.txt", "original")
  sim:snapshot("one")
  local t_snap = sim.clock:now()

  sim:set_block(3, 64, 3, nil)
  sim:storage_remove("minecraft:coal", 100)
  sim:kv_set("a", "2")
  sim:write_file(5, "keep.txt", "changed"); sim:write_file(5, "extra.txt", "new")
  sim:teleport(5, 50, 90, 50, "west")
  c.tstate.inv[4].count = 1
  sim:run_for(30000)

  sim:restore("one")
  local c2 = sim.by_id[5]
  t.eq(sim.clock:now(), t_snap, "the clock is rewound")
  t.eq(sim:get_block(3, 64, 3), "minecraft:gold_ore")
  t.eq(sim.sched.storage:amount("minecraft:coal"), 100)
  t.eq(sim:kv_get("a"), "1")
  t.eq(c2.pos.x, 0); t.eq(c2.pos.y, 64)
  t.eq(c2.tstate.fuel, 321); t.eq(c2.tstate.inv[4].count, 9)
  t.eq(sim:read_file(5, "keep.txt"), "original")
  t.eq(sim:read_file(5, "extra.txt"), nil, "files created later are gone")
  sim:run_for(2000)
  t.eq(c2:effective_state(), "waiting", "the turtle rebooted from its restored disk")
  t.eq(c2.disk_obj:read("boots"), "2", "its disk showed one earlier boot, and now it has booted again")
  t.ok(sim.world.occupants["0,64,0"] == c2)
  local joined = table.concat(sim.extra_assumptions or {}, " ")
  t.ok(joined:find("snapshot was restored", 1, true), "the report must say a restore happened")
end

T["control fork leaves the original untouched"] = function(t)
  local sim = mini()
  turtle(sim, 5)
  sim:set_block(1, 64, 1, "minecraft:stone")
  sim:run_for(500)
  sim:snapshot("base")
  local child = sim:fork("base")
  child:set_block(1, 64, 1, "minecraft:diamond_block")
  child:run_for(5000)
  t.eq(sim:get_block(1, 64, 1), "minecraft:stone", "the original world is untouched")
  t.eq(sim.clock:now(), START + 500)
  t.eq(child:get_block(1, 64, 1), "minecraft:diamond_block")
  t.ok(child.run_dir ~= sim.run_dir)
end

T["control interventions are recorded and reads are not"] = function(t)
  local sim = mini()
  turtle(sim, 5)
  sim:get_block(0, 0, 0); sim:status(); sim:queue(5); sim:output(5); sim:read_file(5, "startup.lua"); sim:kv_get("x")
  sim:snapshot("s")
  t.eq(interventions(sim), 0)
  sim:set_block(0, 0, 0, "minecraft:stone")
  t.eq(interventions(sim), 1)
  t.ok(sim.interventions[1].what:find("set_block", 1, true))
  local report = require("report.report").build(
    setmetatable({ sim_ms = 1, wall_s = 1, scenario_path = "x", scenario = { world = "synthetic" }, code_spec = "worktree:.",
      expectations = {}, initial_storage = {} }, { __index = sim }), { ok = true })
  t.eq(#report.interventions, 1, "the report lists them")
end

T["control repl works from piped input"] = function(t)
  local sim = mini()
  turtle(sim, 5, [[ counter = 3; print("hi"); sleep(100000) ]])
  local input = H.tmpdir() .. "/in.txt"
  H.write(input, "status\nstep 3\nrun_for 2000\neval node_5 counter * 2\nteleport node_5 2 64 2 north\noutput node_5\nget_block 0 0 0\nbogus\nquit\n")
  local out_path = H.tmpdir() .. "/out.txt"
  local inf, outf = io.open(input, "rb"), io.open(out_path, "wb")
  Repl.run(sim, inf, outf)
  inf:close(); outf:close()
  local text = H.read(out_path)
  t.ok(text:find("paused at t+0s", 1, true), text)
  t.ok(text:find("node_5%s+turtle%s+waiting"), text)
  t.ok(text:find("\n6\n", 1, true), "eval answer missing:\n" .. text)
  t.ok(text:find("hi", 1, true), "output missing")
  t.ok(text:find("unknown command: bogus", 1, true), text)
  t.eq(sim.by_id[5].pos.x, 2)
end

T["control repl runs from a plain shell with a scenario"] = function(t)
  local p = io.popen("printf 'status\\nquit\\n' | bash sandbox/sim repl sandbox/scenarios/smoke_short.lua 2>&1")
  local text = p:read("*a"); p:close()
  t.ok(text:find("sandbox repl: paused", 1, true), text:sub(1, 600))
  t.ok(text:find("node_11", 1, true) and text:find("miner", 1, true), "the fleet should be listed:\n" .. text:sub(1, 600))
end

local out = {}
for name, fn in pairs(T) do out[name] = fn end
return out
