-- Golden fidelity: our textutils against files the real CC:Tweaked wrote (the imported computers' disks).
-- It reads the world copy on the Game Drive; it fails (never silently passes) if the import has not been done.
-- Key order inside a table is the order of the VM that wrote it, which differs between CC's VM and ours, so the
-- comparison is on content: the parsed tables are equal, and every LINE of the output (indent, quoting, brackets,
-- trailing commas) appears in the original the same number of times.
package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local H = dofile("sandbox/tests/helpers.lua")

local DATA = (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
-- every computer folder of the untouched world copy (read-only), not just the imported fleet
local DISKS = DATA .. "/worlds/unpacked/2026-10-18_1700/world_live/computercraft/computer"

local function list(cmd)
  local out = {}
  local p = io.popen(cmd)
  for l in p:lines() do out[#out + 1] = l end
  p:close()
  return out
end

-- Runs textutils inside a computer so it is exactly the code the fleet uses.
local textutils_env
local function tu()
  if textutils_env then return textutils_env end
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", "sleep(1)")
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(1) }
  local comp = Computer.new{ id = 1, kind = "computer", disk = dir, sched = sched }
  sched:add(comp); comp:boot()
  textutils_env = comp.env.textutils
  return textutils_env
end

local function line_counts(text)
  local c = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do c[l] = (c[l] or 0) + 1 end
  return c
end

local function equal_values(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal_values(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

return {
  ["textutils.serialise reproduces every CC-written file"] = function(t)
    local check = io.open(DISKS .. "/95/jobs.dat", "rb")
    t.ok(check, "no world copy at " .. DISKS .. " - unpack the backup first (see sandbox/README.md)")
    check:close()
    local T = tu()
    -- every data file (not a program, not a log) on every imported disk
    local files = list('find "' .. DISKS .. '" -type f -not -name "*.lua" -not -name "*.log" -not -name "*.txt" -not -name "install" -size -400k')
    local compared, bad = 0, {}
    for _, path in ipairs(files) do
      local text = H.read(path)
      if text and text:sub(1, 1) == "{" then
        local value = T.unserialise(text)
        if type(value) == "table" then
          compared = compared + 1
          local back = T.serialise(value)
          local again = T.unserialise(back)
          local ca, cb = line_counts(text), line_counts(back)
          local same_lines = true
          for l, n in pairs(ca) do if cb[l] ~= n then same_lines = false end end
          for l, n in pairs(cb) do if ca[l] ~= n then same_lines = false end end
          if not equal_values(value, again) then bad[#bad + 1] = path .. ": value changed on the way round" end
          if not same_lines then bad[#bad + 1] = path .. ": formatted differently from the file CC wrote" end
        end
      end
    end
    t.ok(compared >= 5, "only " .. compared .. " CC-written data files found; the check proves nothing")
    t.eq(#bad, 0, table.concat(bad, "\n"))
  end,
}
