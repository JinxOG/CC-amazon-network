-- Plain Lua value <-> text, for sandbox files (not CC's textutils format).
-- Keys are sorted, so the same value always gives the same bytes.
local M = {}

local function key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta < tb end
  return a < b
end

local function dump(v, out, indent)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, key_less)
    out[#out + 1] = "{\n"
    for _, k in ipairs(keys) do
      out[#out + 1] = indent .. "  ["
      dump(k, out, indent .. "  ")
      out[#out + 1] = "] = "
      dump(v[k], out, indent .. "  ")
      out[#out + 1] = ",\n"
    end
    out[#out + 1] = indent .. "}"
  elseif t == "string" then out[#out + 1] = string.format("%q", v):gsub("\\\n", "\\n")
  elseif t == "number" then
    if v ~= v then out[#out + 1] = "0/0"
    elseif v == math.huge then out[#out + 1] = "math.huge"
    elseif v == -math.huge then out[#out + 1] = "-math.huge"
    elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%.0f", v)
    else out[#out + 1] = string.format("%.17g", v) end
  elseif t == "boolean" or t == "nil" then out[#out + 1] = tostring(v)
  else error("luaser: cannot dump a " .. t, 0) end
end

function M.dump(v)
  local out = { "return " }
  dump(v, out, "")
  return table.concat(out)
end

function M.parse(text)
  local fn, err = load(text, "luaser", "t", { math = { huge = math.huge } })
  if not fn then return nil, err end
  local ok, res = pcall(fn)
  if not ok then return nil, res end
  return res
end

return M
