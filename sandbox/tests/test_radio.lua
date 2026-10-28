package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local Radio = require("net.radio")
local Modem = require("periph.modem")
local H = dofile("sandbox/tests/helpers.lua")

local function net()
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(4) }
  sched.radio = Radio.new{ sched = sched, rng = sched.rng }
  return sched
end

local function node(sched, id, startup, x)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  local c = Computer.new{ id = id, kind = "computer", disk = dir, sched = sched, pos = { x = x or 0, y = 64, z = 0 } }
  sched:add(c)
  Modem.place(c, "top")
  return c
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end

local LISTEN = function(ch) return string.format([[
  local m = peripheral.find("modem"); m.open(%d)
  while true do
    local _, side, c, r, msg, d = os.pullEvent("modem_message")
    print(side, c, r, type(msg) == "table" and msg.type or msg, d)
  end ]], ch) end

local SEND = function(ch, msg_lua, at_s) return string.format([[
  local m = peripheral.find("modem"); sleep(%d); m.transmit(%d, 77, %s) ]], at_s or 1, ch, msg_lua) end

return {
  ["only computers with the channel open receive"] = function(t)
    local sched = net()
    local a = node(sched, 1, LISTEN(5), 0)
    local b = node(sched, 2, LISTEN(6), 10)
    local s = node(sched, 3, SEND(5, '{ type = "hello" }'), 30)
    for _, c in ipairs({ a, b, s }) do c:boot() end
    sched:run{ until_ms = 5000 }
    t.eq(out(a), "top\t5\t77\thello\t30")
    t.eq(out(b), "")
  end,

  ["transmit deep-copies the message"] = function(t)
    local sched = net()
    local a = node(sched, 1, [[
      local m = peripheral.find("modem"); m.open(5)
      local _, _, _, _, msg = os.pullEvent("modem_message"); msg.x = "changed"; sleep(2); print("a done")
    ]])
    local s = node(sched, 2, [[
      local m = peripheral.find("modem"); sleep(1)
      local msg = { x = "orig", nested = { 1 } }; m.transmit(5, 5, msg); sleep(3); print(msg.x, #msg.nested)
    ]])
    a:boot(); s:boot(); sched:run{ until_ms = 10000 }
    t.eq(out(s), "orig\t1")
  end,

  ["a function in a message raises"] = function(t)
    local sched = net()
    local s = node(sched, 2, [[
      local m = peripheral.find("modem"); print(pcall(m.transmit, 5, 5, { f = print }))
    ]])
    s:boot()
    t.ok(out(s):find("^false\t.*serialize function"), out(s))
  end,

  ["drop_rate 1 drops everything on that channel"] = function(t)
    local sched = net()
    local a = node(sched, 1, LISTEN(5)); local c = node(sched, 4, LISTEN(9))
    local s = node(sched, 3, SEND(5, '{ type = "x" }') .. "\n" .. [[ m.transmit(9, 9, { type = "y" }) ]])
    sched.radio:add_rule{ channel = 5, drop_rate = 1 }
    for _, n in ipairs({ a, c, s }) do n:boot() end
    sched:run{ until_ms = 5000 }
    t.eq(out(a), "")
    t.ok(out(c):find("y"), "channel 9 should still arrive")
  end,

  -- The fleet sends serialised strings (proto.send), so a rule's type has to be read out of the string: its
  -- top-level `type = "X"` line, never a nested field of the same name.
  ["a type rule drops a serialised message of that type, and only that type"] = function(t)
    local sched = net()
    local a = node(sched, 1, LISTEN(5))
    local s = node(sched, 3, [[
      local m = peripheral.find("modem")
      sleep(1); m.transmit(5, 5, textutils.serialise({ type = "JOB_COMPLETE", payload = { jobId = "j1" } }))
      sleep(1); m.transmit(5, 5, textutils.serialise({ type = "HEARTBEAT", payload = { type = "JOB_COMPLETE" } }))
    ]])
    sched.radio:add_rule{ drop_rate = 1, type = "JOB_COMPLETE" }
    a:boot(); s:boot(); sched:run{ until_ms = 10000 }
    t.ok(not out(a):find("jobId", 1, true), "the JOB_COMPLETE string was delivered: " .. out(a))
    t.ok(out(a):find('"HEARTBEAT"', 1, true), "the heartbeat, with a nested type field, should still arrive: " .. out(a))
  end,

  ["latency delays delivery by latency_ms"] = function(t)
    local sched = net()
    local a = node(sched, 1, [[
      local m = peripheral.find("modem"); m.open(5)
      os.pullEvent("modem_message"); print(os.epoch("utc"))
    ]])
    local s = node(sched, 3, SEND(5, "{}"))
    sched.radio:add_rule{ latency_ms = 700 }
    a:boot(); s:boot(); sched:run{ until_ms = 10000 }
    t.eq(out(a), tostring(1000 + 700))
  end,

  ["rules expire at until_ms"] = function(t)
    local sched = net()
    local a = node(sched, 1, LISTEN(5))
    local s = node(sched, 3, [[
      local m = peripheral.find("modem")
      sleep(1); m.transmit(5, 5, { type = "early" })
      sleep(4); m.transmit(5, 5, { type = "late" })
    ]])
    sched.radio:add_rule{ drop_rate = 1, from_ms = 0, until_ms = 3000 }
    a:boot(); s:boot(); sched:run{ until_ms = 10000 }
    t.ok(not out(a):find("early"), out(a))
    t.ok(out(a):find("late"), out(a))
  end,

  ["the sender's own modem does not hear itself"] = function(t)
    local sched = net()
    local s = node(sched, 3, [[
      local m = peripheral.find("modem"); m.open(5); m.transmit(5, 5, { type = "echo" }); sleep(2); print("quiet")
    ]])
    s:boot(); sched:run{ until_ms = 5000 }
    t.eq(out(s), "quiet")
  end,

  ["a turtle with an equipped modem gets a modem peripheral"] = function(t)
    local sched = net()
    sched.world = require("world.world").new_empty()
    local dir = H.tmpdir(); H.write(dir .. "/startup.lua", [[ print(peripheral.getType("left"), peripheral.getType("right")) ]])
    local c = Computer.new{ id = 8, kind = "turtle", disk = dir, sched = sched, pos = { x = 0, y = 64, z = 0, facing = 0 } }
    c.tstate = { inv = {}, selected = 1, fuel = 10, equipped = { left = "computercraft:wireless_modem_advanced" }, dropped = {}, block_name = "x" }
    sched:add(c); c:boot()
    t.eq(out(c), "modem\tnil")
  end,
}
