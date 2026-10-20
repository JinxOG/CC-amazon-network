-- The stand-in against server.js's contract. The fixtures were written from reading server.js (the
-- routes' replies and /state's keys); Task 22's one live /state read can refine them.
package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Standin = require("bridge.standin")
local JSON = require("core.json")
local H = dofile("sandbox/tests/helpers.lua")

local START = 1790000000000

local function new_standin()
  local dir = H.tmpdir()
  local sched = Scheduler.new{ clock = Clock.new(START), rng = Rng.new(1) }
  return Standin.new{ run_dir = dir, sched = sched }, sched, dir
end

local function post(s, path, tbl) return s:handle("POST", path, JSON.encode(tbl)) end
local function decode(body) return JSON.decode(body, JSON.NULL, true) end
local function fixture(name) return decode(H.read("sandbox/tests/fixtures/bridge/" .. name .. ".json")) end

-- A comparable picture of a value: scalars by type, arrays as "array", objects by their keys.
local function shape(v)
  if v == JSON.NULL then return "null" end
  if type(v) ~= "table" then return type(v) end
  if getmetatable(v) ~= JSON.OBJECT then return "array" end
  local o = {}
  for k, x in pairs(v) do o[k] = shape(x) end
  return o
end

-- An empty object in the fixture means "any object".
local function same_shape(a, b, path, errs)
  if type(a) == "table" and type(b) == "table" then
    if next(a) == nil then return end
    for k, x in pairs(a) do
      if b[k] == nil then errs[#errs + 1] = path .. "." .. k .. " missing"
      else same_shape(x, b[k], path .. "." .. k, errs) end
    end
    for k in pairs(b) do if a[k] == nil then errs[#errs + 1] = path .. "." .. k .. " is not in server.js" end end
  elseif a ~= b then
    -- a null in the fixture (or in the reply) may be any value once the bridge has data
    if a ~= "null" and b ~= "null" then errs[#errs + 1] = path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
  end
end

local function contract(t, name, status, body, want_status)
  t.eq(status, want_status or 200, name .. " status")
  local errs = {}
  same_shape(shape(fixture(name)), shape(decode(body)), "$", errs)
  t.eq(#errs, 0, name .. ": " .. table.concat(errs, "; "))
end

local PUSH = { turtles = { node_1 = { x = 1, y = 64, z = 2, status = "IDLE", fuel = 100, online = true } }, jobs = {},
  version = "1.9.140", storage = {}, storageTs = START - 5000, mineZones = { job_0001 = { total = 10, done = 2 } },
  serverLog = { { ts = START + 10, level = "INFO", msg = "hello\nworld", seq = 1, bootId = 7 } },
  turtleLogs = { node_1 = { { ts = START + 20, msg = "[node_1][WARN] low fuel", seq = 1, bootId = 3 } } } }

local function day_file(dir, ms) return dir .. "/logs/" .. os.date("!%Y-%m-%d", math.floor(ms / 1000)) .. ".txt" end

return {
  ["update then state returns serverTime as simulated now"] = function(t)
    local s, sched = new_standin()
    t.eq((post(s, "/update", PUSH)), 200)
    sched.clock:set(START + 90000)
    local st = decode(select(3, s:handle("GET", "/state")))
    t.eq(st.serverTime, START + 90000)
    t.eq(st.version, "1.9.140")
    t.eq(st.turtles.node_1.lastSeen, START)
    t.eq(st.updatedAt, START)
  end,

  ["log lines land in the simulated day's file"] = function(t)
    local s, sched, dir = new_standin()
    post(s, "/update", PUSH)
    sched.clock:set(START + 86400000 * 2)
    local p2 = {}
    for k, v in pairs(PUSH) do p2[k] = v end
    p2.serverLog = { { ts = START + 86400000 * 2, msg = "later", seq = 2, bootId = 7 } }
    post(s, "/update", p2)
    s:flush()
    t.ok(H.read(day_file(dir, START)), "no file for the first day")
    t.ok(H.read(day_file(dir, START + 86400000 * 2)):find("later", 1, true), "later line not in its own day's file")
  end,

  ["log line format matches server.js"] = function(t)
    local s, _, dir = new_standin()
    post(s, "/update", PUSH)
    s:flush()
    local text = H.read(day_file(dir, START))
    -- "<iso>  <source#seq padded to 14> <level padded to 6> <msg, newlines collapsed>"
    t.ok(text:find("2026%-%d%d%-%d%dT%d%d:%d%d:%d%d%.010Z  server#1       INFO   hello world\n"), text)
    t.ok(text:find("%.020Z  node_1#1       WARN   %[node_1%]%[WARN%] low fuel\n"), text)
  end,

  ["a resent log line is written once"] = function(t)
    local s, _, dir = new_standin()
    post(s, "/update", PUSH); post(s, "/update", PUSH)
    s:flush()
    local _, n = H.read(day_file(dir, START)):gsub("hello world", "")
    t.eq(n, 1)
  end,

  ["storage keeps the newest storageTs"] = function(t)
    local s = new_standin()
    t.eq((post(s, "/storage", { storage = { { name = "a", amount = 1 } }, storageTs = 2000, source = "warehouse" })), 200)
    local status, _, body = post(s, "/storage", { storage = {}, storageTs = 1000 })
    t.eq(status, 400)
    t.ok(body:find("older than the snapshot already held"), body)
    local st = decode(select(3, s:handle("GET", "/state")))
    t.eq(st.storageTs, 2000); t.eq(#st.storage, 1); t.eq(st.storageSource, "warehouse")
  end,

  ["state.json is overwritten, not appended"] = function(t)
    local s, _, dir = new_standin()
    post(s, "/update", PUSH); s:flush()
    local first = H.read(dir .. "/state.json")
    post(s, "/update", PUSH); s:flush(); s:flush()
    local second = H.read(dir .. "/state.json")
    t.ok(JSON.decode(second), "state.json should be one JSON document")
    t.ok(#second < #first * 1.2, "file grew like an append: " .. #first .. " -> " .. #second)
  end,

  ["a turtle absent from the next push vanishes, and a long silence clears stale state"] = function(t)
    local s, sched = new_standin()
    post(s, "/update", PUSH)
    local p2 = {}
    for k, v in pairs(PUSH) do p2[k] = v end
    p2.turtles = { node_2 = { status = "IDLE" } }
    sched.clock:set(START + 3000)
    post(s, "/update", p2)
    local st = decode(select(3, s:handle("GET", "/state")))
    t.ok(st.turtles.node_1 == nil and st.turtles.node_2 ~= nil, "snapshot should be authoritative")
    sched.clock:set(START + 3000 + 25000)
    post(s, "/update", { version = "x" })
    st = decode(select(3, s:handle("GET", "/state")))
    t.ok(next(st.turtles) == nil, "a gap over 20s should clear turtles")
  end,

  ["commands queue and are handed to the next update"] = function(t)
    local s = new_standin()
    t.ok(s:dispatch({ type = "ORDER_MINE", params = { zone = "Z1" } }))
    local reply = decode(select(3, post(s, "/update", PUSH)))
    t.eq(#reply.commands, 1); t.eq(reply.commands[1].type, "ORDER_MINE")
    local again = decode(select(3, post(s, "/update", PUSH)))
    t.eq(#again.commands, 0)
    t.ok(again.logAck.server, "logAck should ride beside commands")
  end,

  ["contract: update ok"] = function(t)
    local s = new_standin()
    local status, _, body = post(s, "/update", PUSH)
    local reply = decode(body); reply.logAck = nil -- sequenced lines make logAck appear; checked separately
    contract(t, "update_ok", status, JSON.encode(reply))
  end,
  ["contract: update with command and logAck"] = function(t)
    local s = new_standin()
    s:dispatch({ type = "ORDER_MINE", params = JSON.object() })
    local status, _, body = post(s, "/update", PUSH)
    contract(t, "update_with_command", status, body)
  end,
  ["contract: update missing data"] = function(t)
    local s = new_standin()
    local status, _, body = post(s, "/update", { nothing = 1 })
    contract(t, "update_missing", status, body, 400)
  end,
  ["contract: storage ok"] = function(t)
    local s = new_standin()
    local status, _, body = post(s, "/storage", { storage = {}, storageTs = 5 })
    contract(t, "storage_ok", status, body)
  end,
  ["contract: storage rejected"] = function(t)
    local s = new_standin()
    local status, _, body = post(s, "/storage", { storageTs = 5 })
    contract(t, "storage_rejected", status, body, 400)
  end,
  ["contract: command ok"] = function(t)
    local s = new_standin()
    local status, _, body = post(s, "/command", { type = "RECALL_ALL" })
    contract(t, "command_ok", status, body)
  end,
  ["contract: command missing type"] = function(t)
    local s = new_standin()
    local status, _, body = post(s, "/command", { params = {} })
    contract(t, "command_missing_type", status, body, 400)
  end,
  ["contract: ping"] = function(t)
    local s = new_standin()
    local status, _, body = s:handle("GET", "/ping")
    contract(t, "ping", status, body)
  end,
  ["contract: state"] = function(t)
    local s = new_standin()
    post(s, "/update", PUSH)
    local status, _, body = s:handle("GET", "/state")
    contract(t, "state", status, body)
  end,

  ["a bridge that is down refuses the connection"] = function(t)
    local s = new_standin()
    s.down = true
    local status, msg = s:handle("GET", "/ping")
    t.eq(status, nil); t.ok(msg:find("connect"), msg)
  end,
}
