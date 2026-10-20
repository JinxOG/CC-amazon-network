-- textutils: serialise/unserialise and JSON in the formats CC writes.
-- The table format was read off real CC-written files (loader_state.dat, jobs.dat, dock_assignments.dat),
-- not copied from CC code: two-space indent, array items bare, `name = v` for identifier keys,
-- `[ "key" ] = v` for the rest, trailing commas, no newline after the final brace.
local CCEnv = require("cc.env")

local M = {}

local KEYWORDS = {}
for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do
  KEYWORDS[w] = true
end

local function is_ident(k) return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil and not KEYWORDS[k] end

local function quote(s) return (string.format("%q", s):gsub("\\\n", "\\n")) end

local function serialise_value(v, opts, indent, seen)
  local t = type(v)
  if t == "table" then
    if seen[v] == "open" then error("Cannot serialize table with recursive entries", 0) end
    if seen[v] == "closed" then error("Cannot serialize table with repeated entries", 0) end
    if next(v) == nil then return "{}" end
    seen[v] = "open"
    local inner = indent .. "  "
    local out, done = { "{\n" }, {}
    for i, item in ipairs(v) do
      done[i] = true
      out[#out + 1] = inner .. serialise_value(item, opts, inner, seen) .. ",\n"
    end
    for k, item in pairs(v) do
      if not done[k] then
        local key = is_ident(k) and k or ("[ " .. serialise_value(k, opts, inner, seen) .. " ]")
        out[#out + 1] = inner .. key .. " = " .. serialise_value(item, opts, inner, seen) .. ",\n"
      end
    end
    out[#out + 1] = indent .. "}"
    seen[v] = (opts.allow_repetitions == true) and nil or "closed"
    return table.concat(out)
  elseif t == "string" then return quote(v)
  elseif t == "number" then
    if v ~= v then return "0/0" elseif v == math.huge then return "math.huge" elseif v == -math.huge then return "-math.huge" end
    return tostring(v)
  elseif t == "boolean" or t == "nil" then return tostring(v)
  end
  error("Cannot serialize type " .. t, 0)
end

local function json_escape(s)
  return (s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return map[c] or string.format("\\u%04x", c:byte())
  end))
end

local function json_value(v, seen, path)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("Unserializable number: " .. tostring(v), 0) end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%.0f", v) end
    return tostring(v)
  elseif t == "string" then return '"' .. json_escape(v) .. '"'
  elseif t == "table" then
    if seen[v] then error("Cannot serialize table with repeated entries", 0) end
    seen[v] = true
    local n, count = 0, 0
    for k in pairs(v) do
      count = count + 1
      if type(k) == "number" and k == math.floor(k) and k >= 1 then n = math.max(n, k) end
    end
    local out
    if count == 0 then out = "[]"
    elseif n == count then
      local items = {}
      for i = 1, n do items[i] = json_value(v[i], seen) end
      out = "[" .. table.concat(items, ",") .. "]"
    else
      local items = {}
      for k, item in pairs(v) do
        if type(k) ~= "string" and type(k) ~= "number" then error("Tables with keys of type " .. type(k) .. " cannot be serialized as JSON", 0) end
        items[#items + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_value(item, seen)
      end
      out = "{" .. table.concat(items, ",") .. "}"
    end
    seen[v] = nil
    return out
  end
  error("Unserializable type " .. t, 0)
end

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- Small recursive-descent JSON reader. Returns value, or nil + message.
local function json_parse(s, null_value)
  local pos = 1
  local function fail(msg) error({ msg = msg .. " at position " .. pos }, 0) end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local value
  local function str()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then fail("Unterminated string") end
      if c == '"' then pos = pos + 1; return table.concat(out) end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if map[e] then out[#out + 1] = map[e]; pos = pos + 2
        elseif e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or fail("Bad unicode escape")
          pos = pos + 6
          if cp >= 0xD800 and cp < 0xDC00 and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16) or fail("Bad unicode escape")
            cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00); pos = pos + 6
          end
          out[#out + 1] = utf8_char(cp)
        else fail("Bad escape") end
      else out[#out + 1] = c; pos = pos + 1 end
    end
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local o = {}
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return o end
      while true do
        ws(); if s:sub(pos, pos) ~= '"' then fail("Expected string key") end
        local k = str(); ws()
        if s:sub(pos, pos) ~= ":" then fail("Expected ':'") end
        pos = pos + 1
        o[k] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return o elseif d ~= "," then fail("Expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1; local a, n = {}, 0
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return a end
      while true do
        n = n + 1; a[n] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return a elseif d ~= "," then fail("Expected ',' or ']'") end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return null_value
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if not num or num == "" then fail("Unexpected character '" .. c .. "'") end
      pos = pos + #num
      return tonumber(num) or fail("Bad number")
    end
  end
  local ok, res = pcall(function()
    local v = value(); ws()
    if pos <= #s then fail("Unexpected trailing characters") end
    return v
  end)
  if ok then return res end
  if type(res) == "table" and res.msg then return nil, res.msg end
  error(res, 0)
end

function M.install(comp, E)
  local T = {}
  local json_null = setmetatable({}, { __tostring = function() return "null" end })

  function T.serialise(v, opts)
    if opts ~= nil and type(opts) ~= "table" then
      error("bad argument #2 to 'serialise' (table expected)", 2)
    end
    opts = opts or {}
    if opts.compact then
      error("sandbox: textutils.serialise compact is not implemented (computer " .. comp.id .. ")", 2)
    end
    return serialise_value(v, opts, "", {})
  end
  T.serialize = T.serialise

  function T.unserialise(s)
    if type(s) ~= "string" then error("bad argument #1 to 'unserialise' (string expected, got " .. type(s) .. ")", 2) end
    local fn = load("return " .. s, "unserialise", "t", {})
    if not fn then return nil end
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
  end
  T.unserialize = T.unserialise

  function T.serialiseJSON(v, opts)
    return json_value(v, {})
  end
  T.serializeJSON = T.serialiseJSON

  function T.unserialiseJSON(s, opts)
    if type(s) ~= "string" then error("bad argument #1 to 'unserialiseJSON' (string expected, got " .. type(s) .. ")", 2) end
    local null = (type(opts) == "table" and opts.parse_null) and json_null or nil
    return json_parse(s, null)
  end
  T.unserializeJSON = T.unserialiseJSON
  T.json_null = json_null

  E.textutils = CCEnv.api(comp, "textutils", T)
end

return M
