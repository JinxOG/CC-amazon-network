-- Interactive mode: a paused run that takes one command per line from a plain shell, so an engineer (or an AI
-- working through a shell) can look, act, step and look again. No window needed:
--   printf 'status\nstep 100\nteleport node_11 10 64 5 north\nquit\n' | sandbox/sim repl scenario.lua
local luaser = require("core.luaser")

local Repl = {}

local TIME_COMMANDS = { step = true, run_for = true, run_until_time = true }

local HELP = [[
commands (arguments are separated by spaces):
  status                          the whole fleet
  step [n]                        advance n scheduler events (default 1)
  run_for <ms>                    advance that many simulated milliseconds
  run_until_time <ms>             advance to that many ms after the scenario started
  pause | resume                  see the sandbox design, section 7.1
  eval <node> <lua>               run Lua inside that computer's environment
  output <node> | queue <node>    what it printed | its event queue
  teleport <node> <x> <y> <z> [north|east|south|west]
  recover | reboot | shutdown | start <node>
  set_slot <node> <slot> <item> <count> | clear_slot <node> <slot> | give <node> <item> <count>
  set_fuel <node> <n> | equip <node> <left|right> <upgrade>
  read_file <node> <path> | delete_file <node> <path>
  get_block <x> <y> <z> | set_block <x> <y> <z> <name>
  storage_set|storage_add|storage_remove <item> <count>
  kv_get <key> | kv_set <key> <value> | kv_clear
  gps_host <id> true|false | place_gps_host <x> <y> <z>
  snapshot <name> | restore <name>
  every other control call of the design (fill, send_radio, ...) takes Lua tables; use a scenario for those
  quit]]

local function convert(word)
  if word == "true" then return true elseif word == "false" then return false elseif word == "nil" then return nil end
  return tonumber(word) or word
end

local function show(v)
  if v == nil then return "nil" end
  if type(v) == "table" then return (luaser.dump(v):gsub("^return ", "")) end
  return tostring(v)
end

local function status_lines(sim)
  local out = {}
  for _, row in ipairs(sim:status()) do
    local pos = row.pos and string.format("%d,%d,%d", row.pos.x, row.pos.y, row.pos.z) or "-"
    out[#out + 1] = string.format("%-10s %-10s %-8s pos=%-18s fuel=%-7s q=%d %s%s", row.name, tostring(row.role or row.kind),
      row.state, pos, tostring(row.fuel or "-"), row.queue, tostring(row.status or ""), row.job and (" job=" .. row.job) or "")
  end
  return table.concat(out, "\n")
end

-- Reads commands from `input` (a file handle) and writes answers to `output`.
function Repl.run(sim, input, output)
  local function say(s) output:write(s, "\n"); output:flush() end
  sim:pause()
  say("sandbox repl: paused at t+" .. math.floor((sim.clock:now() - sim.t0) / 1000) .. "s. Type help for commands.")
  for line in input:lines() do
    line = line:gsub("\r$", "")
    local cmd, rest = line:match("^%s*(%S+)%s*(.*)$")
    if cmd == nil then -- blank line
    elseif cmd == "quit" or cmd == "exit" then break
    elseif cmd == "help" then say(HELP)
    elseif cmd == "status" then say(status_lines(sim))
    elseif cmd == "eval" then
      local node, code = rest:match("^(%S+)%s+(.+)$")
      if not node then say("usage: eval <node> <lua>")
      else
        local r = table.pack(pcall(sim.eval, sim, node, code))
        if not r[1] then say("error: " .. tostring(r[2])) else
          local parts = {}
          for i = 2, r.n do parts[#parts + 1] = show(r[i]) end
          say(#parts > 0 and table.concat(parts, "\t") or "ok")
        end
      end
    elseif type(sim[cmd]) == "function" and cmd:sub(1, 1) ~= "_" then
      local args = {}
      local n = 0
      for word in rest:gmatch("%S+") do n = n + 1; args[n] = convert(word) end
      if TIME_COMMANDS[cmd] then sim:resume() end
      local r = table.pack(pcall(sim[cmd], sim, table.unpack(args, 1, n)))
      if not r[1] then say("error: " .. tostring(r[2])) else
        local parts = {}
        for i = 2, r.n do parts[#parts + 1] = show(r[i]) end
        if TIME_COMMANDS[cmd] then parts[#parts + 1] = "(now t+" .. math.floor((sim.clock:now() - sim.t0) / 1000) .. "s)" end
        say(#parts > 0 and table.concat(parts, "\t") or "ok")
      end
    else
      say("unknown command: " .. cmd .. " (try help)")
    end
  end
end

return Repl
