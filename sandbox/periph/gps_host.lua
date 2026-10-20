-- A GPS host: a computer at a fixed spot that answers "PING" on channel 65534 with its own position.
-- Native (no Lua program runs on it); it can be switched off and on.
local Computer = require("core.computer")
local Modem = require("periph.modem")

local M = {}

local CHANNEL_GPS = 65534

-- Creates the host, adds it to the scheduler and boots it. Returns the computer.
function M.place(sched, id, x, y, z, label)
  local comp = Computer.new{
    id = id, label = label, kind = "gps_host", disk = nil, sched = sched, pos = { x = x, y = y, z = z },
    native = {
      on_boot = function(c) c.peripherals.top.methods.open(CHANNEL_GPS) end,
      on_event = function(c, ev)
        if ev[1] ~= "modem_message" or ev[3] ~= CHANNEL_GPS or ev[5] ~= "PING" then return end
        local reply = ev[4]
        if type(reply) ~= "number" then return end
        c.peripherals.top.methods.transmit(reply, CHANNEL_GPS, { c.pos.x, c.pos.y, c.pos.z })
      end,
    },
  }
  sched:add(comp)
  Modem.place(comp, "top")
  comp:boot()
  return comp
end

function M.set_on(comp, on)
  if on and comp.state == "off" then comp:boot()
  elseif not on and comp.state ~= "off" then comp:shutdown() end
end

return M
