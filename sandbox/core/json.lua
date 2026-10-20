-- JSON as CC's textutils writes and reads it, shared by the CC textutils and the stand-in bridge.
--   encode: integers without ".0"; an empty table is [] unless it carries the JSON.OBJECT marker
--   decode: arrays are plain tables; objects optionally get the marker so an empty {} survives a round trip
local JSON = {}

JSON.OBJECT = { __json = "object" } -- metatable marking a table that must encode as an object

-- A value that encodes as null (a Lua table cannot hold nil).
JSON.NULL = setmetatable({}, { __tostring = function() return "null" end })

function JSON.object(t) return setmetatable(t or {}, JSON.OBJECT) end

local find, sub, byte, format = string.find, string.sub, string.byte, string.format

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function escape(s)
  if not find(s, '[%c"\\]') then return s end
  return (s:gsub('[%c"\\]', function(c) return ESC[c] or format("\\u%04x", byte(c)) end))
end

local floor = math.floor

local function encode(v, seen)
  local t = type(v)
  if t == "string" then return '"' .. escape(v) .. '"'
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("Unserializable number: " .. tostring(v), 0) end
    if v == floor(v) and v < 1e15 and v > -1e15 then return format("%.0f", v) end
    return tostring(v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "nil" then return "null"
  elseif t == "table" then
    if v == JSON.NULL then return "null" end
    if seen[v] then error("Cannot serialize table with repeated entries", 0) end
    seen[v] = true
    local forced_object = getmetatable(v) == JSON.OBJECT
    local n, count = 0, 0
    for k in pairs(v) do
      count = count + 1
      if type(k) == "number" and k == floor(k) and k >= 1 and k > n then n = k end
    end
    local out
    if count == 0 then out = forced_object and "{}" or "[]"
    elseif n == count and not forced_object then
      local items = {}
      for i = 1, n do items[i] = encode(v[i], seen) end
      out = "[" .. table.concat(items, ",") .. "]"
    else
      local items, m = {}, 0
      for k, item in pairs(v) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then
          error("Tables with keys of type " .. kt .. " cannot be serialized as JSON", 0)
        end
        m = m + 1
        items[m] = '"' .. escape(kt == "string" and k or tostring(k)) .. '":' .. encode(item, seen)
      end
      out = "{" .. table.concat(items, ",") .. "}"
    end
    seen[v] = nil
    return out
  end
  error("Unserializable type " .. t, 0)
end

function JSON.encode(v) return encode(v, {}) end

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64) end
  return string.char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end

local UNESCAPE = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

-- Returns the value, or nil and a message. null becomes null_value (nil by default).
-- Hot path (the stand-in decodes every push the server makes): scans with string.find, not char by char.
function JSON.decode(s, null_value, mark_objects)
  local pos = 1
  local function fail(msg) error({ msg = msg .. " at position " .. pos }, 0) end
  local value

  local function str() -- pos is at the opening quote
    local start = pos + 1
    local q = find(s, '["\\]', start)
    if not q then pos = #s + 1; fail("Unterminated string") end
    if byte(s, q) == 34 then pos = q + 1; return sub(s, start, q - 1) end
    -- escapes present: the slow path
    local out = {}
    pos = start
    while true do
      local run = s:match('^[^"\\]+', pos)
      if run then out[#out + 1] = run; pos = pos + #run end
      local c = sub(s, pos, pos)
      if c == "" then fail("Unterminated string") end
      if c == '"' then pos = pos + 1; return table.concat(out) end
      local e = sub(s, pos + 1, pos + 1)
      if UNESCAPE[e] then out[#out + 1] = UNESCAPE[e]; pos = pos + 2
      elseif e == "u" then
        local cp = tonumber(sub(s, pos + 2, pos + 5), 16) or fail("Bad unicode escape")
        pos = pos + 6
        if cp >= 0xD800 and cp < 0xDC00 and sub(s, pos, pos + 1) == "\\u" then
          local lo = tonumber(sub(s, pos + 2, pos + 5), 16) or fail("Bad unicode escape")
          cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00); pos = pos + 6
        end
        out[#out + 1] = utf8_char(cp)
      else fail("Bad escape") end
    end
  end

  function value()
    pos = find(s, "[^ \t\r\n]", pos) or #s + 1
    local c = byte(s, pos)
    if c == 123 then -- {
      pos = pos + 1
      local o = mark_objects and setmetatable({}, JSON.OBJECT) or {}
      pos = find(s, "[^ \t\r\n]", pos) or #s + 1
      if byte(s, pos) == 125 then pos = pos + 1; return o end
      while true do
        pos = find(s, "[^ \t\r\n]", pos) or #s + 1
        if byte(s, pos) ~= 34 then fail("Expected string key") end
        local k = str()
        pos = find(s, "[^ \t\r\n]", pos) or #s + 1
        if byte(s, pos) ~= 58 then fail("Expected ':'") end
        pos = pos + 1
        o[k] = value()
        pos = find(s, "[^ \t\r\n]", pos) or #s + 1
        local d = byte(s, pos); pos = pos + 1
        if d == 125 then return o elseif d ~= 44 then fail("Expected ',' or '}'") end
      end
    elseif c == 91 then -- [
      pos = pos + 1
      local a, n = {}, 0
      pos = find(s, "[^ \t\r\n]", pos) or #s + 1
      if byte(s, pos) == 93 then pos = pos + 1; return a end
      while true do
        n = n + 1; a[n] = value()
        pos = find(s, "[^ \t\r\n]", pos) or #s + 1
        local d = byte(s, pos); pos = pos + 1
        if d == 93 then return a elseif d ~= 44 then fail("Expected ',' or ']'") end
      end
    elseif c == 34 then return str()
    elseif c == 116 and sub(s, pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif c == 102 and sub(s, pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif c == 110 and sub(s, pos, pos + 3) == "null" then pos = pos + 4; return null_value
    else
      local e = find(s, "[^%d%.eE+%-]", pos) or #s + 1
      if e == pos then fail("Unexpected character '" .. sub(s, pos, pos) .. "'") end
      local num = tonumber(sub(s, pos, e - 1)) or fail("Bad number")
      pos = e
      return num
    end
  end

  local ok, res = pcall(function()
    local v = value()
    pos = find(s, "[^ \t\r\n]", pos) or #s + 1
    if pos <= #s then fail("Unexpected trailing characters") end
    return v
  end)
  if ok then return res end
  if type(res) == "table" and res.msg then return nil, res.msg end
  error(res, 0)
end

return JSON
