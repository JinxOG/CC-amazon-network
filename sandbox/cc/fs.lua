-- CC's fs API over the computer's own disk folder, with a size quota.
-- Rebuilt from the documented behaviour at tweaked.cc; no CC:Tweaked ROM code.
local CCEnv = require("cc.env")
local Disk = require("core.disk")

local M = {}

local function check_path(p, fname)
  if type(p) ~= "string" then
    error(string.format("bad argument #1 to '%s' (string expected, got %s)", fname, type(p)), 3)
  end
end

local function handle_api(comp, name, tbl) return CCEnv.api(comp, "fs handle (" .. name .. ")", tbl) end

function M.install(comp, E)
  comp.disk_obj = comp.disk_obj or Disk.new(comp.disk, comp.quota)
  local D = comp.disk_obj
  local F = {}

  function F.exists(p) check_path(p, "exists"); return D:exists(p) end
  function F.isDir(p) check_path(p, "isDir"); return D:isdir(p) end
  function F.isReadOnly(p) check_path(p, "isReadOnly"); return false end
  function F.getDrive(p) check_path(p, "getDrive"); return D:exists(p) and "hdd" or nil end
  function F.getSize(p)
    check_path(p, "getSize")
    if not D:exists(p) then error("/" .. Disk.clean(p) .. ": No such file", 2) end
    return D:size(p)
  end
  function F.getFreeSpace(p) check_path(p, "getFreeSpace"); return D:free_space() end
  function F.getCapacity(p) check_path(p, "getCapacity"); return D.quota end
  function F.list(p)
    check_path(p, "list")
    local l, err = D:list(p)
    if not l then error("/" .. Disk.clean(p) .. ": " .. (err or "Not a directory"), 2) end
    return l
  end
  function F.makeDir(p) check_path(p, "makeDir"); D:mkdir(p) end
  function F.delete(p) check_path(p, "delete"); D:delete(p) end
  function F.move(a, b)
    local ok, err = D:move(a, b)
    if not ok then error("/" .. Disk.clean(a) .. ": " .. tostring(err), 2) end
  end
  function F.copy(a, b)
    local ok, err = D:copy(a, b)
    if not ok then error("/" .. Disk.clean(a) .. ": " .. tostring(err), 2) end
  end
  function F.combine(base, ...)
    local parts = { base, ... }
    return Disk.clean(table.concat(parts, "/"))
  end
  function F.getName(p)
    local c = Disk.clean(p)
    if c == "" then return "root" end
    return c:match("([^/]+)$")
  end
  function F.getDir(p)
    local c = Disk.clean(p)
    if c == "" then return ".." end
    return c:match("^(.*)/[^/]+$") or ""
  end

  function F.open(path, mode)
    check_path(path, "open")
    local clean = Disk.clean(path)
    local m = tostring(mode)
    local binary = m:find("b", 1, true) ~= nil
    local base = m:sub(1, 1)

    if base == "r" then
      if not D:exists(clean) or D:isdir(clean) then return nil, "/" .. clean .. ": No such file" end
      local data, pos = D:read(clean), 1
      local h = {}
      -- readAll gives nil when nothing is left, as tweaked.cc documents.
      function h.readAll()
        if pos > #data then return nil end
        local s = data:sub(pos); pos = #data + 1; return s
      end
      function h.readLine(trailing)
        if pos > #data then return nil end
        local nl = data:find("\n", pos, true)
        local line
        if nl then line = data:sub(pos, trailing and nl or nl - 1); pos = nl + 1
        else line = data:sub(pos); pos = #data + 1 end
        if not trailing then line = line:gsub("\r$", "") end
        return line
      end
      function h.read(n)
        if pos > #data then return nil end
        if n == nil then
          local c = data:sub(pos, pos); pos = pos + 1
          return binary and c:byte() or c
        end
        local s = data:sub(pos, pos + n - 1); pos = pos + #s
        return s
      end
      function h.seek(whence, off)
        whence, off = whence or "cur", off or 0
        local base_pos = (whence == "set" and 0) or (whence == "end" and #data) or (pos - 1)
        pos = math.max(0, base_pos + off) + 1
        return pos - 1
      end
      function h.close() end
      return handle_api(comp, "read", h)
    end

    if base == "w" or base == "a" then
      if D:isdir(clean) then return nil, "/" .. clean .. ": Cannot write to directory" end
      local buf, appending = {}, base == "a"
      local closed = false
      local function commit()
        local ok, err = D:write(clean, table.concat(buf), appending)
        if not ok then error("/" .. clean .. ": " .. tostring(err), 3) end
        buf, appending = {}, true -- later flushes add to what is already there
      end
      -- the file exists as soon as it is opened; its old contents are replaced on the first flush or close,
      -- so a write that does not fit leaves the old file intact
      if not D:exists(clean) then D:write(clean, "") end
      local h = {}
      local function put(s, fn)
        if closed then error("attempt to use a closed file", 3) end
        local piece = tostring(s)
        local pending = 0
        for _, b in ipairs(buf) do pending = pending + #b end
        local replaced = appending and 0 or (D:size(clean) or 0)
        if D:used() - replaced + pending + #piece > D.quota then error("/" .. clean .. ": Out of space", 3) end
        buf[#buf + 1] = piece
      end
      function h.write(s) put(s) end
      function h.writeLine(s) put(tostring(s) .. "\n") end
      function h.flush() if not closed then commit() end end
      function h.close() if not closed then commit(); closed = true end end
      return handle_api(comp, "write", h)
    end

    return nil, "Unsupported mode"
  end

  E.fs = CCEnv.api(comp, "fs", F)
end

return M
