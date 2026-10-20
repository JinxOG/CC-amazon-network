-- One test per row of spec section 5's table that Tasks 3-6 cover.
package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local CCEnv = require("cc.env")
local H = dofile("sandbox/tests/helpers.lua")

local function rig(startup)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(3), trace = dir .. "/trace.log" }
  local comp = Computer.new{ id = 9, kind = "computer", disk = dir, sched = sched }
  sched:add(comp)
  return comp, sched, dir
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end

return {
  ["queue cap 256"] = function(t)
    -- a computer that is busy computing cannot take events off its queue
    local comp, sched = rig([[ for i = 1, 3000000 do end; sleep(10) ]])
    comp:boot()
    t.eq(comp.state, "busy")
    local accepted = 0
    for i = 1, 300 do if comp:queue_event({ "e" }) then accepted = accepted + 1 end end
    t.eq(accepted, 256)
  end,

  ["filtered wait discards"] = function(t)
    local comp, sched = rig([[ local e = os.pullEvent("want"); print(e); print(tostring(os.pullEvent())) ]])
    comp:boot()
    sched:post(1, comp, { "noise" }); sched:post(2, comp, { "want" }); sched:post(3, comp, { "after" })
    sched:run{ until_ms = 10 }
    t.eq(out(comp), "want|after")
  end,

  ["waitForAny gives every coroutine every event"] = function(t)
    local comp, sched = rig([[
      local got = {}
      parallel.waitForAny(
        function() local e = os.pullEvent("a"); got[#got + 1] = "A:" .. e end,
        function() local e = os.pullEvent("b"); got[#got + 1] = "B:" .. e; os.pullEvent("never") end)
      print(table.concat(got, ","))
    ]])
    comp:boot()
    sched:post(1, comp, { "b" }); sched:post(2, comp, { "a" })
    sched:run{ until_ms = 10 }
    t.eq(out(comp), "B:b,A:a")
  end,

  ["doubled delivery when two coroutines both accept the same event"] = function(t)
    local comp, sched = rig([[
      local seen = 0
      local function listener() while true do local e = os.pullEvent("modem_message"); seen = seen + 1 end end
      parallel.waitForAny(listener, listener, function() sleep(1); print(seen) end)
    ]])
    comp:boot()
    sched:post(100, comp, { "modem_message", "top", 5, 5, "hello", 3 })
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "2")
  end,

  ["a yielding peripheral call makes the computer deaf to other events"] = function(t)
    local comp, sched = rig([[
      local dev = peripheral.find("slowdev")
      print(dev.slow())
      print(tostring(os.pullEvent()))
    ]])
    comp:attach("back", "slowdev", { slow = function()
      return CCEnv.main_thread_call(comp, 1000, function() return "done", 7 end)
    end })
    comp:boot()
    sched:post(500, comp, { "x" })   -- arrives during the call: lost
    sched:post(2000, comp, { "y" })
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "done\t7|y")
  end,

  ["a peripheral error reaches the caller"] = function(t)
    local comp, sched = rig([[ local d = peripheral.wrap("left"); print(pcall(d.boom)) ]])
    comp:attach("left", "bad", { boom = function()
      return CCEnv.main_thread_call(comp, 10, function() error("kaput", 0) end)
    end })
    comp:boot(); sched:run{ until_ms = 100 }
    t.eq(out(comp), "false\tkaput")
  end,

  ["os.reboot keeps disk loses memory"] = function(t)
    local comp, sched, dir = rig([[
      local f = fs.open("count", "r")
      if f then print("again", f.readAll(), tostring(mem)); return end
      mem = "volatile"
      local w = fs.open("count", "w"); w.write("1"); w.close()
      os.reboot()
    ]])
    comp:boot(); sched:run{ until_ms = 5000 }
    t.eq(out(comp), "again\t1\tnil")
  end,

  ["timer events carry their id"] = function(t)
    local comp, sched = rig([[
      local a, b = os.startTimer(1), os.startTimer(2)
      local _, first = os.pullEvent("timer"); local _, second = os.pullEvent("timer")
      print(first == a, second == b, a ~= b)
    ]])
    comp:boot(); sched:run{ until_ms = 5000 }
    t.eq(out(comp), "true\ttrue\ttrue")
  end,

  ["peripheral find wrap getType getNames"] = function(t)
    local comp, sched = rig([[
      local m = peripheral.find("modem")
      print(peripheral.getType(m), peripheral.getName(m), table.concat(peripheral.getNames(), ","), peripheral.isPresent("top"))
      print(peripheral.find("nothing"))
    ]])
    comp:attach("top", "modem", { isWireless = function() return true end })
    comp:attach("left", "kv_storage", {})
    comp:boot()
    t.eq(out(comp), "modem\ttop\tleft,top\ttrue|")
  end,
}
