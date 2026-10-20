-- shell.run, require/package and the programs the fleet launches by name.
local CCEnv = require("cc.env")
local Disk = require("core.disk")
local unpack = table.unpack or unpack

local M = {}

-- Programs that live in CC's ROM, supplied by other modules (wget by the HTTP layer, gps by the GPS layer).
-- Each is function(comp, E, ...) -> boolean.
M.builtins = {}

function M.install(comp, E)
  local S = {}
  local running = { "startup.lua" }

  local function find_program(name)
    local D = comp.disk_obj
    for _, cand in ipairs({ name, name .. ".lua" }) do
      if D:exists(cand) and not D:isdir(cand) then return Disk.clean(cand) end
    end
  end

  function S.run(name, ...)
    if type(name) ~= "string" then error("bad argument #1 (string expected)", 2) end
    local file = find_program(name)
    if file then
      local src = comp.disk_obj:read(file)
      local fn, err = load(src, "@" .. file, "t", E)
      if not fn then comp:print(file .. ": " .. tostring(err)); return false end
      running[#running + 1] = file
      local args = { ... }
      local n = select("#", ...)
      local ok, res = pcall(fn, unpack(args, 1, n))
      running[#running] = nil
      if not ok then
        if res == "Terminated" then error(res, 0) end
        comp:print(tostring(res)); return false
      end
      return true
    end
    local builtin = M.builtins[name]
    if builtin then return builtin(comp, E, ...) end
    comp:print("No such program")
    return false
  end

  function S.getRunningProgram() return running[#running] end
  function S.dir() return "" end
  function S.resolve(p) return Disk.clean(p) end
  function S.exit() end

  E.shell = CCEnv.api(comp, "shell", S)

  -- require: modules are loaded from the disk root and cached for this boot, as in CC
  local pkg = { path = "?;?.lua;?/init.lua", loaded = {}, preload = {} }
  E.package = pkg
  E.require = function(name)
    if type(name) ~= "string" then error("bad argument #1 to 'require' (string expected, got " .. type(name) .. ")", 2) end
    if pkg.loaded[name] ~= nil then return pkg.loaded[name] end
    if pkg.preload[name] then
      local v = pkg.preload[name](name)
      pkg.loaded[name] = v == nil and true or v
      return pkg.loaded[name]
    end
    local tried = {}
    local rel = name:gsub("%.", "/")
    for template in pkg.path:gmatch("[^;]+") do
      local file = template:gsub("%?", rel)
      if comp.disk_obj:exists(file) and not comp.disk_obj:isdir(file) then
        local fn, err = load(comp.disk_obj:read(file), "@" .. file, "t", E)
        if not fn then error("error loading module '" .. name .. "' from file '" .. file .. "':\n\t" .. tostring(err), 2) end
        local v = fn(name, file)
        if v ~= nil then pkg.loaded[name] = v
        elseif pkg.loaded[name] == nil then pkg.loaded[name] = true end
        return pkg.loaded[name]
      end
      tried[#tried + 1] = "no file '" .. file .. "'"
    end
    error("module '" .. name .. "' not found:\n\t" .. table.concat(tried, "\n\t"), 2)
  end
end

return M
