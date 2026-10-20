package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local H = dofile("sandbox/tests/helpers.lua")

-- A minimal environment for these tests; Task 4 supplies the real CC one.
local function test_env(comp, extra)
  return setmetatable({
    print = function(...) local p = {} for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end comp:print(table.concat(p, " ")) end,
    yield = coroutine.yield,
    charge = function(ms) comp.cost_ms = comp.cost_ms + ms end,
    now = function() return comp.sched.clock:now() end,
    reboot = function() comp:reboot(); coroutine.yield() end,
    read = H.read, write = H.write, disk = comp.disk,
    seen = extra,
  }, { __index = _G })
end

local function rig(startup)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(1), trace = dir .. "/trace.log" }
  local comp = Computer.new{ id = 1, kind = "computer", disk = dir, sched = sched,
    env_builder = function(c) return test_env(c) end }
  sched:add(comp)
  return comp, sched, dir
end

local function trace(sched, dir) sched:close(); return H.read(dir .. "/trace.log") end

return {
  ["a filtered wait discards non-matching events"] = function(t)
    local comp, sched, dir = rig([[ local e = yield("b"); seen_b = e; print("got", e) ]])
    comp:boot(); sched:run{ until_ms = 0 }
    sched:post(1, comp, { "a" }); sched:post(2, comp, { "b" })
    sched:run{ until_ms = 10 }
    t.eq(comp.output[1].text, "got b")
    t.ok(trace(sched, dir):find("node_1 discard a", 1, true), "no discard line")
  end,

  ["an unfiltered wait receives everything in order"] = function(t)
    local comp, sched = rig([[ for i = 1, 3 do local e = yield(); print(e) end ]])
    comp:boot()
    sched:post(1, comp, { "x" }); sched:post(2, comp, { "y" }); sched:post(3, comp, { "z" })
    sched:run{ until_ms = 10 }
    t.eq(#comp.output, 3)
    t.eq(comp.output[1].text .. comp.output[2].text .. comp.output[3].text, "xyz")
  end,

  ["terminate is delivered even through a filter"] = function(t)
    local comp, sched = rig([[ local e = yield("never"); print(e) ]])
    comp:boot(); sched:post(1, comp, { "terminate" }); sched:run{ until_ms = 5 }
    t.eq(comp.output[1].text, "terminate")
  end,

  ["the 257th queued event is dropped and logged as overflow"] = function(t)
    local comp, sched, dir = rig([[ charge(1000); yield() ]])
    comp:boot() -- charges 1000ms at boot, so it is busy
    t.eq(comp.state, "busy")
    for i = 1, 257 do t.eq(comp:queue_event({ "e" .. i }), i <= 256, "event " .. i) end
    t.eq(#comp.queue, 256)
    t.ok(trace(sched, dir):find("node_1 overflow e257", 1, true), "no overflow line")
  end,

  ["events arriving while busy are queued, not lost"] = function(t)
    local comp, sched = rig([[
      local a = yield(); print("A", now()); charge(100)
      local b = yield(); print("B", now())
    ]])
    comp:boot(); sched:post(0, comp, { "a" }); sched:post(50, comp, { "b" })
    sched:run{ until_ms = 500 }
    t.eq(comp.output[1].text, "A 0")
    t.eq(comp.output[2].text, "B 100")
  end,

  ["reboot restarts from startup and keeps the disk"] = function(t)
    local comp, sched, dir = rig([[
      local prev = read(disk .. "/mark")
      if prev then print("second", prev) else write(disk .. "/mark", "kept"); reboot() end
    ]])
    comp:boot(); sched:run{ until_ms = 5000 }
    t.eq(comp.output[#comp.output].text, "second kept")
  end,

  ["memory does not survive reboot"] = function(t)
    local comp, sched = rig([[
      print(tostring(marker)); marker = "set"; if not rebooted then rebooted = true; reboot() end
    ]])
    comp:boot(); sched:run{ until_ms = 5000 }
    t.eq(comp.output[1].text, "nil")
    t.eq(comp.output[2].text, "nil", "global survived the reboot")
  end,

  ["output captures print with virtual timestamps"] = function(t)
    local comp, sched = rig([[ yield(); print("hi") ]])
    comp:boot(); sched:post(250, comp, { "go" }); sched:run{ until_ms = 1000 }
    t.eq(comp.output[1].t, 250)
    t.eq(comp.output[1].text, "hi")
  end,

  ["a crashing program stops the computer and says why"] = function(t)
    local comp, sched = rig([[ error("boom") ]])
    comp:boot(); sched:run{ until_ms = 10 }
    t.eq(comp.state, "off")
    t.ok(comp.output[#comp.output].text:find("boom"), "error not printed")
  end,
}
