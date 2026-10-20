-- gps.locate over the simulated radio, as tweaked.cc documents it: ping channel 65534, collect {x,y,z}
-- replies with the distance each arrived over, narrow the possible positions as fixes come in.
-- Rebuilt from the documented behaviour, not copied.
local CCEnv = require("cc.env")

local M = {}

local CHANNEL_GPS = 65534

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function len(a) return math.sqrt(dot(a, a)) end
local function scale(a, k) return { a[1] * k, a[2] * k, a[3] * k } end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function cross(a, b)
  return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

-- Where three spheres meet: two points, or one (and nil) when they touch. Returns nothing when they do
-- not meet or the centres lie on a line.
local function trilaterate(f1, f2, f3)
  local p1, p2, p3 = f1.p, f2.p, f3.p
  local d12 = sub(p2, p1)
  local d = len(d12)
  if d < 1e-9 then return nil end
  local ex = scale(d12, 1 / d)
  local d13 = sub(p3, p1)
  local i = dot(ex, d13)
  local ey_raw = sub(d13, scale(ex, i))
  local j = len(ey_raw)
  if j < 1e-9 then return nil end
  local ey = scale(ey_raw, 1 / j)
  local ez = cross(ex, ey)
  local r1, r2, r3 = f1.d, f2.d, f3.d
  local x = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
  local y = (r1 * r1 - r3 * r3 + i * i + j * j) / (2 * j) - (i / j) * x
  local z2 = r1 * r1 - x * x - y * y
  if z2 < -1e-6 then return nil end
  local base = add(add(p1, scale(ex, x)), scale(ey, y))
  if z2 < 1e-6 then return base, nil end
  local z = math.sqrt(z2)
  return add(base, scale(ez, -z)), add(base, scale(ez, z))
end

local function narrow(s1, s2, fix)
  local function err(s) return math.abs(len(sub(s, fix.p)) - fix.d) end
  local e1, e2 = err(s1), err(s2)
  if math.abs(e1 - e2) < 0.01 then return s1, s2 end -- this fix cannot tell them apart
  if e1 < e2 then return s1, nil end
  return s2, nil
end

-- `gps host x y z`: the ROM program a real GPS host computer runs.
require("cc.shell").builtins.gps = function(comp, E, cmd, x, y, z)
  if cmd ~= "host" then comp:print("Usage: gps host <x> <y> <z>"); return false end
  x, y, z = tonumber(x), tonumber(y), tonumber(z)
  if not (x and y and z) then comp:print("Usage: gps host <x> <y> <z>"); return false end
  local modem = E.peripheral.find("modem")
  if not modem then comp:print("No wireless modems found. 1 required."); return false end
  modem.open(CHANNEL_GPS)
  comp:print("Position is " .. x .. "," .. y .. "," .. z)
  while true do
    local _, _, channel, reply, msg = E.os.pullEvent("modem_message")
    if channel == CHANNEL_GPS and msg == "PING" and type(reply) == "number" then
      modem.transmit(reply, CHANNEL_GPS, { x, y, z })
    end
  end
end

function M.install(comp, E)
  local G = { CHANNEL_GPS = CHANNEL_GPS }
  local pack = function(...) return { n = select("#", ...), ... } end

  function G.locate(timeout, debug)
    timeout = timeout or 2
    local modems = {}
    for _, name in ipairs(E.peripheral.getNames()) do
      if E.peripheral.getType(name) == "modem" then modems[#modems + 1] = name end
    end
    if #modems == 0 then return nil end
    local reply = 50000 + comp.id % 10000
    local opened = {}
    for _, name in ipairs(modems) do
      local m = E.peripheral.wrap(name)
      if not m.isOpen(reply) then m.open(reply); opened[#opened + 1] = m end
      m.transmit(CHANNEL_GPS, reply, "PING")
    end

    local fixes, pos1, pos2 = {}, nil, nil
    local timer = E.os.startTimer(timeout)
    while true do
      local ev = pack(E.os.pullEvent())
      if ev[1] == "modem_message" then
        local channel, msg, dist = ev[3], ev[5], ev[6]
        if channel == reply and type(msg) == "table" and #msg == 3 and tonumber(msg[1]) and tonumber(msg[2])
            and tonumber(msg[3]) and dist then
          local fix = { p = { msg[1], msg[2], msg[3] }, d = dist }
          local known = false
          for _, f in ipairs(fixes) do if f.p[1] == fix.p[1] and f.p[2] == fix.p[2] and f.p[3] == fix.p[3] then known = true end end
          if not known then
            fixes[#fixes + 1] = fix
            if #fixes >= 3 then
              if not pos1 then pos1, pos2 = trilaterate(fixes[1], fixes[2], fixes[3])
              else pos1, pos2 = narrow(pos1, pos2, fix) end
              if #fixes > 3 and not pos1 then break end
            end
            if pos1 and not pos2 then break end
          end
        end
      elseif ev[1] == "timer" and ev[2] == timer then
        break
      end
    end
    for _, m in ipairs(opened) do m.close(reply) end
    if pos1 and pos2 then
      if debug then E.print("Ambiguous position"); E.print("Could be " .. pos1[1] .. "," .. pos1[2] .. "," .. pos1[3] .. " or " .. pos2[1] .. "," .. pos2[2] .. "," .. pos2[3]) end
      return nil
    elseif pos1 then
      return math.floor(pos1[1] + 0.5), math.floor(pos1[2] + 0.5), math.floor(pos1[3] + 0.5)
    end
    if debug then E.print("Could not determine position") end
    return nil
  end

  E.gps = CCEnv.api(comp, "gps", G)
end

return M
