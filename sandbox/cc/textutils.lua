-- textutils: serialise/unserialise and JSON in the formats CC writes.
-- The table format was read off real CC-written files (loader_state.dat, jobs.dat, dock_assignments.dat),
-- not copied from CC code: two-space indent, array items bare, `name = v` for identifier keys,
-- `[ "key" ] = v` for the rest, trailing commas, no newline after the final brace.
local CCEnv = require("cc.env")
local JSON = require("core.json")

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
    return JSON.encode(v)
  end
  T.serializeJSON = T.serialiseJSON

  function T.unserialiseJSON(s, opts)
    if type(s) ~= "string" then error("bad argument #1 to 'unserialiseJSON' (string expected, got " .. type(s) .. ")", 2) end
    local null = (type(opts) == "table" and opts.parse_null) and json_null or nil
    return JSON.decode(s, null)
  end
  T.unserializeJSON = T.unserialiseJSON
  T.json_null = json_null

  E.textutils = CCEnv.api(comp, "textutils", T)
end

return M
