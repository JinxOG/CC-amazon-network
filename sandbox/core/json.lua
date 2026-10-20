-- JSON as CC's textutils writes and reads it, shared by the CC textutils and the stand-in bridge.
--   encode: integers without ".0"; an empty table is [] unless it carries the JSON.OBJECT marker
--   decode: arrays are plain tables; objects optionally get the marker so an empty {} survives a round trip
local JSON = {}

JSON.OBJECT = { __json = "object" } -- metatable marking a table that must encode as an object

-- A value that encodes as null (a Lua table cannot hold nil).
JSON.NULL = setmetatable({}, { __tostring = function() return "null" end })

function JSON.object(t) return setmetatable(t or {}, JSON.OBJECT) end

-- A piece of JSON text carried through untouched: encode writes it back as it is. For big fields nobody needs
-- to look inside (the storage list), so they are never parsed into tables.
JSON.RAW = { __json = "raw" }
function JSON.raw(text) return setmetatable({ text = text }, JSON.RAW) end

local find, sub, byte, format = string.find, string.sub, string.byte, string.format

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function escape(s)
  if not find(s, '[%c"\\]') then return s end
  return (s:gsub('[%c"\\]', function(c) return ESC[c] or format("\\u%04x", byte(c)) end))
end

local floor = math.floor

-- Appends the JSON for v to buf (a list of string pieces) after position n and returns the new n. One shared
-- buffer and one table.concat at the end: no intermediate string per table. This runs inside the computers
-- (it is textutils.serialiseJSON) and in the stand-in, thousands of times a simulated hour.
local function encode(v, buf, n, seen)
  local t = type(v)
  if t == "string" then
    n = n + 1
    if find(v, '[%c"\\]') then buf[n] = '"' .. escape(v) .. '"' else buf[n] = '"' .. v .. '"' end
    return n
  elseif t == "number" then
    n = n + 1
    if v ~= v or v == math.huge or v == -math.huge then error("Unserializable number: " .. tostring(v), 0) end
    if v < 1e15 and v > -1e15 and v % 1 == 0 then buf[n] = format("%.0f", v) else buf[n] = tostring(v) end
    return n
  elseif t == "boolean" then
    n = n + 1; buf[n] = v and "true" or "false"; return n
  elseif t == "nil" then
    n = n + 1; buf[n] = "null"; return n
  elseif t == "table" then
    if v == JSON.NULL then n = n + 1; buf[n] = "null"; return n end
    local mt = getmetatable(v)
    if mt == JSON.RAW then n = n + 1; buf[n] = v.text; return n end
    if seen[v] then error("Cannot serialize table with repeated entries", 0) end
    seen[v] = true
    local forced_object = mt == JSON.OBJECT
    local len = #v
    local is_array = false
    if len > 0 and not forced_object and next(v, len) == nil then
      -- a sequence 1..len and nothing else
      is_array = true
      for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or k > len or k % 1 ~= 0 then is_array = false; break end
      end
    end
    if is_array then
      n = n + 1; buf[n] = "["
      for i = 1, len do
        if i > 1 then n = n + 1; buf[n] = "," end
        n = encode(v[i], buf, n, seen)
      end
      n = n + 1; buf[n] = "]"
    elseif next(v) == nil then
      n = n + 1; buf[n] = forced_object and "{}" or "[]"
    else
      n = n + 1; buf[n] = "{"
      local first = true
      for k, item in pairs(v) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then
          error("Tables with keys of type " .. kt .. " cannot be serialized as JSON", 0)
        end
        if first then first = false else n = n + 1; buf[n] = "," end
        if kt == "string" and not find(k, '[%c"\\]') then
          n = n + 1; buf[n] = '"' .. k .. '":'
        else
          n = n + 1; buf[n] = '"' .. escape(kt == "string" and k or tostring(k)) .. '":'
        end
        n = encode(item, buf, n, seen)
      end
      n = n + 1; buf[n] = "}"
    end
    seen[v] = nil
    return n
  end
  error("Unserializable type " .. t, 0)
end

function JSON.encode(v)
  local buf = {}
  local n = encode(v, buf, 0, {})
  return table.concat(buf, "", 1, n)
end

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64) end
  return string.char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end

local UNESCAPE = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

-- The end of the JSON value that starts at `pos` (the index just after it), found without building anything:
-- strings are hopped over, brackets counted. Returns nil if the text is cut off.
local function skip_value(s, pos)
  local c = byte(s, pos)
  if c == 34 then -- string
    local i = pos + 1
    while true do
      local q = find(s, '["\\]', i)
      if not q then return nil end
      if byte(s, q) == 34 then return q + 1 end
      i = q + 2
    end
  elseif c == 123 or c == 91 then -- object or array
    -- Fast path: Lua's own balanced-bracket matcher runs in C. It cannot tell a bracket inside a string from a
    -- real one, so the result is accepted only if the quotes inside pair up and what follows is a JSON separator;
    -- otherwise the careful scan below decides.
    local s0, e0 = find(s, c == 91 and "%b[]" or "%b{}", pos)
    if s0 == pos then
      -- Take the strings out (escaped characters first, then whole strings): what is left must be exactly one
      -- balanced group. A bracket hiding inside a string would have fooled the match above and fails this.
      local flat = sub(s, pos, e0):gsub("\\.", ""):gsub('"[^"]*"', "")
      if not find(flat, '"', 1, true) then -- every string was whole
        local _, open_b = flat:gsub("{", "")
        local _, close_b = flat:gsub("}", "")
        local _, open_a = flat:gsub("%[", "")
        local _, close_a = flat:gsub("%]", "")
        if open_b == close_b and open_a == close_a then return e0 + 1 end
      end
    end
    local depth, i = 0, pos
    while true do
      local q = find(s, '[%[%]{}"]', i)
      if not q then return nil end
      local b = byte(s, q)
      if b == 34 then
        local e = skip_value(s, q)
        if not e then return nil end
        i = e
      else
        if b == 123 or b == 91 then depth = depth + 1 else depth = depth - 1 end
        i = q + 1
        if depth == 0 then return i end
      end
    end
  end
  local e = find(s, "[,}%]%s]", pos)
  return e or #s + 1
end

-- Decodes a JSON object, except that the members named in `raw_keys` stay unparsed (as JSON.raw). The body is
-- scanned once at the top level only. Returns the table, or nil and a message.
function JSON.decode_object(s, raw_keys, null_value, mark_objects)
  local pos = find(s, "[^ \t\r\n]", 1)
  if not pos or byte(s, pos) ~= 123 then return nil, "not a JSON object" end
  local out = mark_objects and setmetatable({}, JSON.OBJECT) or {}
  pos = pos + 1
  while true do
    pos = find(s, "[^ \t\r\n]", pos)
    if not pos then return nil, "cut off" end
    local c = byte(s, pos)
    if c == 125 then return out end
    if c == 44 then pos = pos + 1
    elseif c == 34 then
      local kend = skip_value(s, pos)
      if not kend then return nil, "cut off" end
      local key = JSON.decode(sub(s, pos, kend - 1))
      pos = find(s, "[^ \t\r\n]", kend)
      if not pos or byte(s, pos) ~= 58 then return nil, "expected ':'" end
      pos = find(s, "[^ \t\r\n]", pos + 1)
      if not pos then return nil, "cut off" end
      local vend = skip_value(s, pos)
      if not vend then return nil, "cut off" end
      local text = sub(s, pos, vend - 1)
      if raw_keys and raw_keys[key] then out[key] = JSON.raw(text)
      else
        local v, err = JSON.decode(text, null_value, mark_objects)
        if v == nil and err then return nil, err end
        out[key] = v
      end
      pos = vend
    else return nil, "unexpected character in object" end
  end
end

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
