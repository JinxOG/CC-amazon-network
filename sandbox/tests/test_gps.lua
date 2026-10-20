package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local Radio = require("net.radio")
local Modem = require("periph.modem")
local GpsHost = require("periph.gps_host")
local H = dofile("sandbox/tests/helpers.lua")

local HOSTS = { { 24, 255, 24 }, { -24, 255, 24 }, { 24, 255, -24 }, { -24, 250, -24 } }

local function world(n_hosts)
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(8) }
  sched.radio = Radio.new{ sched = sched, rng = sched.rng }
  local hosts = {}
  for i = 1, n_hosts do local h = HOSTS[i]; hosts[i] = GpsHost.place(sched, 100 + i, h[1], h[2], h[3]) end
  return sched, hosts
end

local function locator(sched, at, program)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", program or [[ print(gps.locate(2)) ]])
  local c = Computer.new{ id = 5, kind = "computer", disk = dir, sched = sched, pos = at }
  sched:add(c); Modem.place(c, "right"); c:boot()
  return c
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end

return {
  ["locate returns the turtle's true position with four hosts up"] = function(t)
    local sched = world(4)
    local c = locator(sched, { x = 13, y = 64, z = -7 })
    sched:run{ until_ms = 5000 }
    t.eq(out(c), "13\t64\t-7")
  end,

  ["locate returns nil with fewer than three hosts"] = function(t)
    local sched = world(2)
    local c = locator(sched, { x = 13, y = 64, z = -7 })
    sched:run{ until_ms = 5000 }
    t.eq(out(c), "nil")
  end,

  ["locate fails while all hosts are off"] = function(t)
    local sched, hosts = world(4)
    for _, h in ipairs(hosts) do GpsHost.set_on(h, false) end
    local c = locator(sched, { x = 13, y = 64, z = -7 })
    sched:run{ until_ms = 5000 }
    t.eq(out(c), "nil")
    for _, h in ipairs(hosts) do GpsHost.set_on(h, true) end
    local c2 = locator(sched, { x = 1, y = 70, z = 2 })
    sched:run{ until_ms = 10000 }
    t.eq(out(c2), "1\t70\t2")
  end,

  ["radio loss on 65534 makes locate fail"] = function(t)
    local sched = world(4)
    sched.radio:add_rule{ channel = 65534, drop_rate = 1 }
    local c = locator(sched, { x = 13, y = 64, z = -7 })
    sched:run{ until_ms = 5000 }
    t.eq(out(c), "nil")
  end,

  ["locate takes the timeout when positions stay ambiguous but returns early when sure"] = function(t)
    local sched = world(4)
    local c = locator(sched, { x = 3, y = 64, z = 3 }, [[ local a = os.epoch("utc"); gps.locate(2); print(os.epoch("utc") - a) ]])
    sched:run{ until_ms = 5000 }
    t.ok(tonumber(out(c)) < 2000, "should return as soon as four fixes agree, took " .. out(c))
    local sched2 = world(3)
    local c2 = locator(sched2, { x = 3, y = 64, z = 3 }, [[ local a = os.epoch("utc"); print(gps.locate(2)); print(os.epoch("utc") - a) ]])
    sched2:run{ until_ms = 5000 }
    t.eq(out(c2), "nil|2000")
  end,

  ["a gps host program answers pings"] = function(t)
    local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(8) }
    sched.radio = Radio.new{ sched = sched, rng = sched.rng }
    for i, h in ipairs(HOSTS) do
      local dir = H.tmpdir()
      H.write(dir .. "/startup.lua", string.format('shell.run("gps", "host", %d, %d, %d)', h[1], h[2], h[3]))
      local c = Computer.new{ id = 200 + i, kind = "computer", disk = dir, sched = sched, pos = { x = h[1], y = h[2], z = h[3] } }
      sched:add(c); Modem.place(c, "top"); c:boot()
    end
    local c = locator(sched, { x = -9, y = 80, z = 40 })
    sched:run{ until_ms = 5000 }
    t.eq(out(c), "-9\t80\t40")
  end,
}
