package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local Safety = require("core.safety")
local H = dofile("sandbox/tests/helpers.lua")

local function rig(startup, code_files)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(2), trace = dir .. "/trace.log" }
  sched.standin = { calls = {}, handle = function(self, method, path, body)
    self.calls[#self.calls + 1] = method .. " " .. path .. " " .. tostring(body)
    if path == "/missing" then return 404, {}, "no such route" end
    return 200, { ["Content-Type"] = "application/json" }, '{"ok":true,"path":"' .. path .. '"}'
  end }
  if code_files then
    local cd = H.tmpdir()
    for name, text in pairs(code_files) do H.write(cd .. "/" .. name, text) end
    sched.code_dir = cd
  end
  local c = Computer.new{ id = 4, kind = "computer", disk = dir, sched = sched }
  sched:add(c); c:boot()
  return c, sched, dir
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end

return {
  ["bridge URL reaches the stand-in"] = function(t)
    local c, sched = rig([[
      http.request("http://127.0.0.1:3000/update", '{"a":1}', { ["Content-Type"] = "application/json" })
      local ev, url, res = os.pullEvent("http_success")
      print(ev, url, res.getResponseCode(), res.readAll())
    ]])
    sched:run{ until_ms = 1000 }
    t.eq(out(c), 'http_success\thttp://127.0.0.1:3000/update\t200\t{"ok":true,"path":"/update"}')
    t.eq(sched.standin.calls[1], 'POST /update {"a":1}')
  end,

  ["github raw is served from the code dir"] = function(t)
    local c, sched = rig([[
      local r = http.get("https://raw.githubusercontent.com/JinxOG/CC-amazon-network/0123456789abcdef0123456789abcdef01234567/protocol.lua")
      print(r.readAll())
      print(http.get("https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/nothere.lua"))
    ]], { ["protocol.lua"] = "return 'proto'" })
    sched:run{ until_ms = 1000 }
    t.ok(out(c):find("^return 'proto'|nil\tNot Found"), out(c))
    sched:close()
  end,

  ["any other host is refused and logged"] = function(t)
    local c, sched, dir = rig([[
      http.request("http://example.com/steal")
      local ev, url, why = os.pullEvent("http_failure")
      print(ev, url, why)
      print(http.get("http://192.168.86.35:3000/state"))
    ]])
    sched:run{ until_ms = 1000 }
    sched:close()
    t.eq(out(c), "http_failure\thttp://example.com/steal\tsandbox: network closed|nil\tsandbox: network closed")
    local trace = H.read(dir .. "/trace.log")
    t.ok(trace:find("http blocked GET http://example.com/steal", 1, true), "no blocked line")
    t.ok(trace:find("http blocked GET http://192.168.86.35:3000/state", 1, true), "live server request should be traced")
  end,

  ["a non-2xx answer is an http_failure carrying the response"] = function(t)
    local c, sched = rig([[
      http.request("http://127.0.0.1:3000/missing")
      local ev, url, why, res = os.pullEvent("http_failure")
      print(why, res.getResponseCode(), res.readAll())
    ]])
    sched:run{ until_ms = 1000 }
    t.eq(out(c), "Not Found\t404\tno such route")
  end,

  ["request is async and fires http_success"] = function(t)
    local c, sched = rig([[
      local before = os.epoch("utc")
      http.request("http://127.0.0.1:3000/state")
      local after = os.epoch("utc")
      print(after - before)
      local ev = os.pullEvent("http_success"); print(ev, os.epoch("utc") - before)
    ]])
    sched:run{ until_ms = 1000 }
    t.eq(out(c), "0|http_success\t3")
  end,

  ["http.get makes the computer deaf while it waits"] = function(t)
    local c, sched = rig([[
      http.get("http://127.0.0.1:3000/state")
      print(tostring(os.pullEvent()))
    ]])
    sched:post(1, c, { "lost" }); sched:post(100, c, { "kept" })
    sched:run{ until_ms = 1000 }
    t.eq(out(c), "kept")
  end,

  ["wget saves a file from the code dir"] = function(t)
    local c, sched, dir = rig([[ print(shell.run("wget", "https://raw.githubusercontent.com/o/r/master/hello.lua", "got.lua")) ]],
      { ["hello.lua"] = "print('hi')" })
    sched:run{ until_ms = 1000 }
    t.ok(out(c):find("true$"), out(c))
    t.eq(H.read(dir .. "/got.lua"), "print('hi')")
  end,

  ["startup refuses a scenario naming 192.168.86.35"] = function(t)
    t.raises(function() Safety.check_config({ bridge = "http://192.168.86.35:3000/update" }) end, "live server address")
    t.raises(function() Safety.check_config("ssh://192.168.86.35") end, "live server")
  end,

  ["startup refuses the Tailscale address"] = function(t)
    t.raises(function() Safety.check_config({ nested = { "100.103.179.74" } }) end, "live server address")
  end,

  ["startup refuses other hosts and accepts local ones"] = function(t)
    t.raises(function() Safety.check_config({ url = "https://example.org/x" }) end, "non%-local host")
    t.raises(function() Safety.check_config("10.0.0.5") end, "non%-local address")
    Safety.check_config({ a = "http://127.0.0.1:3000/update", b = "https://raw.githubusercontent.com/x/y/z/f.lua", v = "1.9.132" })
  end,

  ["tools only run against a local bridge"] = function(t)
    Safety.require_local_url("http://127.0.0.1:3101")
    t.raises(function() Safety.require_local_url("http://192.168.86.35:3000") end, "non%-local bridge")
    t.raises(function() Safety.require_local_url(nil) end, "non%-local bridge")
  end,
}
