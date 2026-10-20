package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local H = dofile("sandbox/tests/helpers.lua")

-- Boots a real CC environment running `startup`, started at virtual time `start`.
local function rig(startup, start)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  local sched = Scheduler.new{ clock = Clock.new(start or 1000000), rng = Rng.new(5), trace = dir .. "/trace.log" }
  local comp = Computer.new{ id = 7, kind = "computer", disk = dir, sched = sched }
  sched:add(comp)
  comp:boot()
  return comp, sched
end

local function lines(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return o end

return {
  ["epoch reads the virtual clock"] = function(t)
    local comp = rig([[ print(os.epoch("utc")) ]], 123456)
    t.eq(comp.output[1].text, "123456")
  end,

  ["startTimer fires a timer event with its id at the right virtual time"] = function(t)
    local comp, sched = rig([[
      local id = os.startTimer(2)
      local _, got = os.pullEvent("timer")
      print(got == id, os.epoch("utc"))
    ]], 10000)
    sched:run{ until_ms = 20000 }
    t.eq(comp.output[1].text, "true\t12000")
  end,

  ["cancelTimer prevents the event"] = function(t)
    local comp, sched = rig([[
      local id = os.startTimer(1); os.cancelTimer(id)
      local keep = os.startTimer(3)
      local _, got = os.pullEvent("timer")
      print(got == keep)
    ]], 0)
    sched:run{ until_ms = 10000 }
    t.eq(comp.output[1].text, "true")
  end,

  ["sleep discards a modem_message that arrives during it"] = function(t)
    local comp, sched = rig([[
      sleep(2)
      print("woke")
      local e = os.pullEvent()
      print("next", e)
    ]], 0)
    sched:post(500, comp, { "modem_message", "x" })
    sched:post(3000, comp, { "later" })
    sched:run{ until_ms = 10000 }
    t.eq(table.concat(lines(comp), "|"), "woke|next\tlater")
  end,

  ["pullEvent raises Terminated on terminate"] = function(t)
    local comp, sched = rig([[
      local ok, err = pcall(os.pullEvent, "never")
      print(ok, err)
    ]], 0)
    sched:post(5, comp, { "terminate" })
    sched:run{ until_ms = 100 }
    t.eq(comp.output[1].text, "false\tTerminated")
  end,

  ["randomseed makes math.random deterministic per computer"] = function(t)
    local prog = [[ math.randomseed(99); print(math.random(1, 1000), math.random(1, 1000), math.random()) ]]
    local a = rig(prog); local b = rig(prog)
    t.eq(a.output[1].text, b.output[1].text)
    local c = rig([[ print(math.random(1,1000)) ]])
    local d = rig([[ print(math.random(1,1000)) ]])
    t.eq(c.output[1].text, d.output[1].text, "same seed, same computer id, same stream")
  end,

  ["unimplemented API raises with its name"] = function(t)
    local comp = rig([[ os.setAlarm(5) ]])
    t.ok(comp.output[1].text:find("sandbox: os.setAlarm is not implemented (computer 7)", 1, true), comp.output[1].text)
    local comp2 = rig([[ rednet.open("top") ]])
    t.ok(comp2.output[1].text:find("sandbox: rednet is not implemented", 1, true), comp2.output[1].text)
  end,

  ["a busy loop of N instructions costs N*ns_per_instr"] = function(t)
    local TIMINGS = require("timings")
    local comp = rig([[ local x = 0; for i = 1, 1000000 do x = x + i end ]])
    -- ~3-4 VM instructions per iteration; allow a generous band around 1e6 iterations.
    local ms = comp.cost_ms
    t.ok(ms > 1000000 * 2 * TIMINGS.ns_per_instr / 1e6 * 0.9, "cost too low: " .. ms)
    t.ok(ms < 1000000 * 8 * TIMINGS.ns_per_instr / 1e6, "cost too high: " .. ms)
  end,

  ["os.clock counts from this computer's boot"] = function(t)
    local comp, sched = rig([[ sleep(5); print(os.clock()) ]], 777000)
    sched:run{ until_ms = 800000 }
    t.eq(comp.output[1].text, "5")
  end,

  ["computation moves the computer's own clock"] = function(t)
    local comp = rig([[ local a = os.epoch("utc"); for i = 1, 2000000 do end; print(os.epoch("utc") > a) ]])
    t.eq(comp.output[1].text, "true")
  end,
}
