-- Builds a fleet in a Sim: adds every computer, then installs the real fleet files on each by running the
-- real install.lua inside it (served from the code under test), exactly as a player would.
local Fleet = {}

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

local INSTALL_ROLES = { server = true, warehouse = true, admin = true, miner = true, loader = true, delivery = true, support = true }

local function bootstrap(role)
  return string.format([[
shell.run("wget", %q, "install.lua")
shell.run("install", %q)
os.reboot()
]], REPO .. "install.lua", role)
end

-- layout: list of specs for Sim:add_computer. Entries with `role` get the real files installed; entries
-- with `installed = true` already have their disk (an imported world).
function Fleet.provision(sim, layout, opts)
  opts = opts or {}
  local installing, from_disk = {}, {}
  for _, spec in ipairs(layout) do
    local comp = sim:add_computer(spec)
    if spec.installed then
      -- an imported computer arrives with its own disk, exactly as the world had it
      if spec.disk_from then
        local Disk = require("core.disk")
        Disk.new(spec.disk_from):copy_all_to(Disk.new(comp.disk, comp.quota))
      end
      if spec.on ~= false and not spec.carried then from_disk[#from_disk + 1] = comp end
    end
    if spec.role and not spec.installed then
      if not INSTALL_ROLES[spec.role] then error("unknown role " .. tostring(spec.role) .. " for computer " .. spec.id, 0) end
      comp.disk_obj = comp.disk_obj or require("core.disk").new(comp.disk, comp.quota)
      comp.disk_obj:write("startup.lua", bootstrap(spec.role))
      installing[#installing + 1] = { comp = comp, spec = spec }
    end
  end

  for _, comp in ipairs(from_disk) do
    sim.sched.loading:apply(comp)
    if comp.state == "off" and not comp.frozen then comp:boot() end
  end

  -- let every installer run; carried turtles are only booted for this and then put back in the pack
  for _, i in ipairs(installing) do
    sim.sched.loading:apply(i.comp)
    if i.comp.state == "off" and not i.comp.frozen then i.comp:boot() end
  end
  local deadline = opts.install_timeout_ms or 600000
  local ok = sim:run_until(function()
    for _, i in ipairs(installing) do
      if not i.comp.disk_obj:exists("role.txt") then return false end
    end
    return true
  end, deadline)
  if not ok then
    local missing = {}
    for _, i in ipairs(installing) do
      if not i.comp.disk_obj:exists("role.txt") then
        local c = i.comp
        local last = c.output[#c.output]
        missing[#missing + 1] = c.name .. " (" .. tostring(i.spec.role) .. ", " .. c.state .. ")" .. (last and (": " .. last.text) or "")
      end
    end
    error("install did not finish on:\n  " .. table.concat(missing, "\n  "), 0)
  end
  -- the installers reboot their computer into the real program; carried turtles stay in the pack, off
  for _, i in ipairs(installing) do
    if i.spec.carried then i.comp:shutdown() end
  end
  return installing
end

return Fleet
