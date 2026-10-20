-- os, timers, sleep, print/write on the virtual clock.
local CCEnv = require("cc.env")
local unpack = table.unpack or unpack

local M = {}

local INGAME_FACTOR = 72 -- a 20-minute game day is 24 hours

local function pack(...) return { n = select("#", ...), ... } end

function M.install(comp, E)
  local sched = comp.sched
  local O = {}

  local function ms_now() return comp:now() end
  local function ingame_ms() return ms_now() * INGAME_FACTOR end

  function O.epoch(kind)
    kind = kind or "ingame"
    if kind == "utc" or kind == "local" then return ms_now() end
    if kind == "ingame" then return ingame_ms() end
    error("Unsupported operation", 2)
  end
  function O.clock() return (ms_now() - comp.booted_ms) / 1000 end
  function O.time(kind)
    kind = kind or "ingame"
    if type(kind) == "table" then
      error("sandbox: os.time(table) is not implemented (computer " .. comp.id .. ")", 2)
    end
    local ms = (kind == "ingame") and ingame_ms() or ms_now()
    return (ms / 3600000) % 24
  end
  function O.day(kind)
    kind = kind or "ingame"
    local ms = (kind == "ingame") and ingame_ms() or ms_now()
    return math.floor(ms / 86400000) + 1
  end
  function O.date(fmt, t)
    fmt = fmt or "%c"
    t = t or math.floor(ms_now() / 1000)
    if fmt:sub(1, 1) ~= "!" then fmt = "!" .. fmt end -- the sandbox keeps everything in UTC
    return os.date(fmt, t)
  end

  -- timers: tick-aligned, tied to this boot, cancellable
  comp.timers = {}
  comp.next_timer_id = 0
  function O.startTimer(s)
    comp.next_timer_id = comp.next_timer_id + 1
    local id, gen = comp.next_timer_id, comp.gen
    comp.timers[id] = true
    local ms = math.max(50, math.ceil((tonumber(s) or 0) * 20) * 50)
    sched:at(ms_now() + ms, function()
      if comp.gen ~= gen or not comp.timers[id] then return end
      comp.timers[id] = nil
      comp:queue_event({ "timer", id })
    end)
    return id
  end
  function O.cancelTimer(id) comp.timers[id] = nil end

  function O.pullEventRaw(filter) return coroutine.yield(filter) end
  function O.pullEvent(filter)
    local ev = pack(coroutine.yield(filter))
    if ev[1] == "terminate" then error("Terminated", 0) end
    return unpack(ev, 1, ev.n)
  end
  function O.queueEvent(name, ...)
    if name == nil then error("bad argument #1 (string expected, got nil)", 2) end
    comp:queue_event({ name, ... })
  end

  function O.getComputerID() return comp.id end
  O.computerID = O.getComputerID
  function O.getComputerLabel() return comp.label end
  O.computerLabel = O.getComputerLabel
  function O.setComputerLabel(l) comp.label = l end
  function O.version() return "CraftOS 1.9" end

  function O.reboot() comp:reboot(); while true do coroutine.yield() end end
  function O.shutdown() comp:shutdown(); while true do coroutine.yield() end end

  E.os = CCEnv.api(comp, "os", O)

  -- sleep is a timer plus a filtered wait, exactly as in CC: it eats every other event
  E.sleep = function(s)
    local timer = O.startTimer(s or 0)
    repeat local _, p = O.pullEvent("timer") until p == timer
  end

  -- output
  local partial = ""
  E.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    comp:print(partial .. table.concat(parts, "\t")); partial = ""
  end
  E.write = function(text)
    text = tostring(text)
    while true do
      local nl = text:find("\n", 1, true)
      if not nl then partial = partial .. text; return end
      comp:print(partial .. text:sub(1, nl - 1)); partial = ""; text = text:sub(nl + 1)
    end
  end
  -- Reading a line waits for typed characters. Nothing types in a sandbox run, so it waits for ever,
  -- eating every event it is offered, exactly as CC's read does.
  local function read_line()
    local buf = {}
    while true do
      local ev = pack(O.pullEvent())
      if ev[1] == "char" then buf[#buf + 1] = ev[2]
      elseif ev[1] == "key" and ev[2] == 257 then return table.concat(buf) end
    end
  end
  E.read = function() return read_line() end
  E.io = CCEnv.api(comp, "io", {
    write = function(...) for i = 1, select("#", ...) do E.write((select(i, ...))) end end,
    read = function() return read_line() end,
  })
  E.keys = { enter = 257, backspace = 259, tab = 258, space = 32, up = 265, down = 264, left = 263, right = 262 }
end

return M
