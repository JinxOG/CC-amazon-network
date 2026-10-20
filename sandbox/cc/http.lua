-- http for the fleet, with the network closed (spec section 10):
--   http://127.0.0.1:3000/*                       -> the run's stand-in bridge (sched.standin)
--   https://raw.githubusercontent.com/o/r/ref/f   -> the file f from the code under test (sched.code_dir)
--   anything else                                 -> refused ("sandbox: network closed") and traced
local CCEnv = require("cc.env")
local TIMINGS = require("timings")
local Safety = require("core.safety")

local M = {}

local STATUS_TEXT = { [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden", [404] = "Not Found",
  [405] = "Method Not Allowed", [409] = "Conflict", [413] = "Payload Too Large", [429] = "Too Many Requests",
  [500] = "Internal Server Error", [502] = "Bad Gateway", [503] = "Service Unavailable" }

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

-- Returns status, headers, body for an answered request, or nil, message for a refused/failed one.
function M.route(sched, method, url, body, headers)
  local host, port, path = Safety.parse_url(url)
  if not host then return nil, "URL malformed" end

  if (host == "127.0.0.1" or host == "localhost") and port == 3000 then
    if not sched.standin then return nil, "Could not connect" end
    sched:trace("http standin " .. method .. " " .. path)
    return sched.standin:handle(method, path, body, headers)
  end

  if host == "raw.githubusercontent.com" then
    local ref, file = path:match("^/[^/]+/[^/]+/([^/]+)/(.+)$")
    if not file then return 404, {}, "404: Not Found" end
    file = file:gsub("%?.*$", "")
    sched:trace("http github-raw ref=" .. ref .. " file=" .. file)
    if file:find("..", 1, true) or file:find("\\", 1, true) or not sched.code_dir then return 404, {}, "404: Not Found" end
    local data = read_file(sched.code_dir .. "/" .. file)
    if not data then return 404, {}, "404: Not Found" end
    return 200, { ["Content-Type"] = "text/plain" }, data
  end

  sched:trace("http blocked " .. method .. " " .. url)
  return nil, "sandbox: network closed"
end

local function response_handle(status, headers, body)
  local pos, closed = 1, false
  local h = {}
  function h.getResponseCode() return status, STATUS_TEXT[status] or (status == 200 and "OK" or "") end
  function h.getResponseHeaders() return headers or {} end
  function h.readAll()
    if pos > #body then return nil end
    local s = body:sub(pos); pos = #body + 1; return s
  end
  function h.readLine(trailing)
    if pos > #body then return nil end
    local nl = body:find("\n", pos, true)
    local line
    if nl then line = body:sub(pos, trailing and nl or nl - 1); pos = nl + 1
    else line = body:sub(pos); pos = #body + 1 end
    return line
  end
  function h.read(n)
    if pos > #body then return nil end
    local s = body:sub(pos, pos + (n or 1) - 1); pos = pos + #s; return s
  end
  function h.close() closed = true end
  return CCEnv.api({ id = "?" }, "http response", h)
end

function M.install(comp, E)
  local H = {}
  local sched = comp.sched

  local function request(url, body, headers, binary, method)
    if type(url) ~= "string" then error("bad argument #1 (string expected, got " .. type(url) .. ")", 3) end
    method = method or (body ~= nil and "POST" or "GET")
    local extra = sched.standin and sched.standin.extra_latency_ms or 0
    local gen = comp.gen
    sched:at(comp:now() + TIMINGS.http_reply_ms * (sched.action_scale or 1) + extra, function()
      if comp.gen ~= gen then return end
      local status, rheaders, rbody = M.route(sched, method, url, body, headers)
      if status == nil then
        comp:queue_event({ "http_failure", url, rheaders or "Could not connect" })
      elseif status >= 200 and status < 300 then
        comp:queue_event({ "http_success", url, response_handle(status, rheaders, rbody or "") })
      else
        comp:queue_event({ "http_failure", url, STATUS_TEXT[status] or ("HTTP " .. status), response_handle(status, rheaders, rbody or "") })
      end
    end)
  end

  function H.request(url, body, headers, binary)
    if type(url) == "table" then
      local t = url
      return request(t.url, t.body, t.headers, t.binary, t.method)
    end
    return request(url, body, headers, binary)
  end

  -- get blocks like CC's: it waits for the answer and every other event meanwhile is lost
  function H.get(url, headers, binary)
    if type(url) == "table" then
      local t = url
      url, headers, binary = t.url, t.headers, t.binary
    end
    request(url, nil, headers, binary, "GET")
    while true do
      local ev = { E.os.pullEvent() }
      if ev[1] == "http_success" and ev[2] == url then return ev[3]
      elseif ev[1] == "http_failure" and ev[2] == url then return nil, ev[3], ev[4] end
    end
  end

  function H.checkURL(url)
    local host = Safety.parse_url(url)
    if host == "127.0.0.1" or host == "localhost" or host == "raw.githubusercontent.com" then return true end
    return nil, "sandbox: network closed"
  end

  E.http = CCEnv.api(comp, "http", H)

  -- wget, as the updater and installer call it: shell.run("wget", url, dest)
  require("cc.shell").builtins.wget = function(c, E2, url, dest)
    local res, err = H.get(url)
    if not res then c:print("Failed to download " .. tostring(url) .. ": " .. tostring(err)); return false end
    local content = res.readAll() or ""
    res.close()
    dest = dest or url:match("([^/]+)$")
    local ok, werr = c.disk_obj:write(dest, content)
    if not ok then c:print("Failed to save " .. dest .. ": " .. tostring(werr)); return false end
    c:print("Downloaded as " .. dest)
    return true
  end
end

return M
