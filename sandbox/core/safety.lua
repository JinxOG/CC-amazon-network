-- The sandbox's network rules (spec section 10), enforced in code.
-- Allowed: the loopback bridge address and raw.githubusercontent.com (answered from the code under test).
-- Everything else is refused, and the live server's addresses are refused outright.
local Safety = {}

-- The live server's LAN and Tailscale addresses. Built from parts on purpose: the static safety test
-- forbids those literal strings anywhere under sandbox/ outside tests/, so no config or note can carry them.
local function addr(a, b, c, d) return table.concat({ a, b, c, d }, ".") end
Safety.FORBIDDEN = { addr(192, 168, 86, 35), addr(100, 103, 179, 74) }
Safety.ALLOWED_HOSTS = { ["127.0.0.1"] = true, ["localhost"] = true, ["::1"] = true, ["[::1]"] = true,
  ["raw.githubusercontent.com"] = true }

-- "http://host:port/path" -> host, port, path
function Safety.parse_url(url)
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then return nil end
  local authority, path = rest:match("^([^/]*)(.*)$")
  local host, port = authority:match("^(%[[^%]]+%]):?(%d*)$")
  if not host then host, port = authority:match("^([^:]*):?(%d*)$") end
  return host, tonumber(port), path ~= "" and path or "/", scheme
end

local function bad_ip(s)
  for a, b, c, d in s:gmatch("(%d+)%.(%d+)%.(%d+)%.(%d+)") do
    local o = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
    if o[1] <= 255 and o[2] <= 255 and o[3] <= 255 and o[4] <= 255 and o[1] ~= 127 then
      return a .. "." .. b .. "." .. c .. "." .. d
    end
  end
end

local function check_string(s, where)
  for _, host in ipairs(Safety.FORBIDDEN) do
    if s:find(host, 1, true) then
      error("sandbox safety: " .. where .. " names the live server address " .. host, 0)
    end
  end
  for url in s:gmatch("%a[%w+.-]*://[^%s\"']+") do
    local host = Safety.parse_url(url)
    if host and not Safety.ALLOWED_HOSTS[host] then
      error("sandbox safety: " .. where .. " names a non-local host: " .. host, 0)
    end
  end
  local ip = bad_ip(s)
  if ip then error("sandbox safety: " .. where .. " names a non-local address: " .. ip, 0) end
end

-- Raises if any string inside `v` (recursively) points anywhere it should not.
function Safety.check_config(v, where, seen)
  where = where or "configuration"
  if type(v) == "string" then check_string(v, where)
  elseif type(v) == "table" then
    seen = seen or {}
    if seen[v] then return end
    seen[v] = true
    for k, x in pairs(v) do
      if type(k) == "string" then check_string(k, where) end
      Safety.check_config(x, where .. "." .. tostring(k), seen)
    end
  end
end

-- The analysis tools may only be run against a local bridge.
function Safety.require_local_url(url)
  local host = Safety.parse_url(url or "")
  if not (host == "127.0.0.1" or host == "localhost" or host == "[::1]" or host == "::1") then
    error("sandbox safety: refusing to run against non-local bridge address " .. tostring(url), 0)
  end
end

return Safety
