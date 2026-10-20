-- One computer's disk: a folder, with CC path rules and a size quota.
-- All paths given to a Disk are "CC paths" (relative to the disk root, "/" separated).
local Disk = {}
Disk.__index = Disk

Disk.DEFAULT_QUOTA = 1000000 -- measured computer_space_limit

local WINDOWS = package.config:sub(1, 1) == "\\"

local function native(path) return WINDOWS and path:gsub("/", "\\") or path end

-- Turns any CC path into a clean "a/b/c" below the root; ".." past the root is clamped.
function Disk.clean(path)
  local out = {}
  for part in tostring(path):gsub("\\", "/"):gmatch("[^/]+") do
    if part == ".." then out[#out] = nil
    elseif part ~= "." then out[#out + 1] = part end
  end
  return table.concat(out, "/")
end

function Disk.new(root, quota)
  local self = setmetatable({ root = root:gsub("\\", "/"):gsub("/+$", ""), quota = quota or Disk.DEFAULT_QUOTA }, Disk)
  self:mkroot()
  return self
end

function Disk:mkroot()
  if not self:real_exists(self.root) then self:real_mkdir(self.root) end
end

-- real-filesystem helpers -----------------------------------------------------------------

function Disk:real_exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return os.rename(p, p) and true or false
end

function Disk:real_isdir(p)
  local f = io.open(p, "rb")
  if f then
    if WINDOWS then f:close(); return false end
    local _, _, code = f:read(1); f:close()
    return code == 21 -- EISDIR
  end
  return os.rename(p, p) and true or false
end

function Disk:real_mkdir(p)
  if WINDOWS then os.execute('mkdir "' .. native(p) .. '" >nul 2>nul')
  else os.execute('mkdir -p "' .. p .. '"') end
end

function Disk:real_list(p)
  local cmd = WINDOWS and ('dir /b "' .. native(p) .. '" 2>nul') or ('ls -1A "' .. p .. '" 2>/dev/null')
  local out = {}
  local h = io.popen(cmd)
  if h then for l in h:lines() do l = l:gsub("\r$", ""); if l ~= "" then out[#out + 1] = l end end h:close() end
  table.sort(out)
  return out
end

function Disk:real_rmdir(p)
  if WINDOWS then os.execute('rmdir /s /q "' .. native(p) .. '" >nul 2>nul')
  else os.execute('rm -rf "' .. p .. '"') end
end

-- CC-level operations ---------------------------------------------------------------------

function Disk:path(cc) local c = Disk.clean(cc); return c == "" and self.root or (self.root .. "/" .. c) end

function Disk:exists(cc) return Disk.clean(cc) == "" or self:real_exists(self:path(cc)) end
function Disk:isdir(cc) return Disk.clean(cc) == "" or self:real_isdir(self:path(cc)) end

function Disk:list(cc)
  if not self:isdir(cc) then return nil, "Not a directory" end
  return self:real_list(self:path(cc))
end

function Disk:read(cc)
  local f = io.open(self:path(cc), "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

function Disk:size(cc)
  local p = self:path(cc)
  if self:real_isdir(p) then return 0 end
  local f = io.open(p, "rb")
  if not f then return nil end
  local n = f:seek("end"); f:close(); return n
end

-- Bytes used by every file under the root (cached; kept current by write/delete).
function Disk:used()
  if self._used then return self._used end
  local total = 0
  local function walk(cc)
    for _, name in ipairs(self:real_list(self:path(cc))) do
      local child = cc == "" and name or (cc .. "/" .. name)
      if self:real_isdir(self:path(child)) then walk(child) else total = total + (self:size(child) or 0) end
    end
  end
  walk("")
  self._used = total
  return total
end

function Disk:free_space() return math.max(0, self.quota - self:used()) end

-- Replaces a file with `data` (or appends). The old file stays intact if the write does not fit.
function Disk:write(cc, data, append)
  local clean = Disk.clean(cc)
  if clean == "" or self:isdir(clean) then return nil, "Is a directory" end
  local old = self:exists(clean) and (self:size(clean) or 0) or 0
  local new_size = append and (old + #data) or #data
  if self:used() - old + new_size > self.quota then return nil, "Out of space" end
  local parent = clean:match("^(.*)/[^/]+$")
  if parent and not self:real_exists(self:path(parent)) then self:real_mkdir(self:path(parent)) end
  local f, err = io.open(self:path(clean), append and "ab" or "wb")
  if not f then return nil, err end
  f:write(data); f:close()
  self._used = self:used() - old + new_size
  return true
end

function Disk:delete(cc)
  local clean = Disk.clean(cc)
  if clean == "" then return nil, "Access denied" end
  if not self:exists(clean) then return true end
  if self:isdir(clean) then
    self:real_rmdir(self:path(clean))
    self._used = nil
  else
    local old = self:size(clean) or 0
    os.remove(self:path(clean))
    self._used = self:used() - old
  end
  return true
end

function Disk:mkdir(cc)
  local clean = Disk.clean(cc)
  if clean ~= "" and not self:exists(clean) then self:real_mkdir(self:path(clean)) end
  return true
end

function Disk:move(from, to)
  from, to = Disk.clean(from), Disk.clean(to)
  if not self:exists(from) then return nil, "No such file" end
  if self:exists(to) then return nil, "File exists" end
  local parent = to:match("^(.*)/[^/]+$")
  if parent then self:mkdir(parent) end
  local ok, err = os.rename(self:path(from), self:path(to))
  if not ok then return nil, err end
  return true
end

function Disk:copy(from, to)
  from, to = Disk.clean(from), Disk.clean(to)
  if not self:exists(from) then return nil, "No such file" end
  if self:exists(to) then return nil, "File exists" end
  if self:isdir(from) then
    self:mkdir(to)
    for _, name in ipairs(self:list(from)) do
      local ok, err = self:copy(from .. "/" .. name, to .. "/" .. name)
      if not ok then return nil, err end
    end
    return true
  end
  return self:write(to, self:read(from))
end

-- Copies every file of this disk into `other` (another Disk), replacing what is there.
function Disk:copy_all_to(other)
  local function walk(cc)
    for _, name in ipairs(self:list(cc) or {}) do
      local child = cc == "" and name or (cc .. "/" .. name)
      if self:isdir(child) then walk(child)
      else other:write(child, self:read(child) or "") end
    end
  end
  walk("")
end

return Disk
