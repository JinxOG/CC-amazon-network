-- The stand-in bridge: server.js's contract on simulated time, in Lua (spec section 4.1).
--   POST /update   the dispatch server's state push and its log lines
--   POST /storage  the warehouse's storage snapshot
--   POST /command  what the dashboard sends (scenarios use Standin:dispatch)
--   GET  /state    the merged state, serverTime = simulated now
--   GET  /ping
-- Logs go to <run_dir>/logs/<simulated UTC day>.txt in server.js's exact line format; state.json is
-- overwritten. The read-only Node file server (bridge/fileserver.js) serves both. Reading /logs belongs to
-- that server, not to this one.
-- It is NOT server.js: bridge-busy accounting, dynmap markers, RCON and auth are not modelled
-- (listed under NOT MODELLED in every report).
local JSON = require("core.json")

local Standin = {}
Standin.__index = Standin

local CC_RESTART_GAP_MS = 20 * 1000
local LOG_DISPLAY_MAX = 200
local TURTLE_DISPLAY_MAX = 30
local LOG_DEDUPE_MAX = 5000
local FLUSH_WALL_SECONDS = 1.0   -- at most this often in real time, so the live view lags a second but the simulator is not slowed

local BRIDGE_OWNED = { locations = true, players = true, updatedAt = true, storageSource = true, storageAt = true }
local EXPLICITLY_MERGED = { turtles = true, jobs = true, version = true, storage = true, storageTs = true,
  mineZones = true, serverLog = true, turtleLogs = true }

local OBJ = JSON.object

local function iso(ms)
  local s = math.floor(ms / 1000)
  return os.date("!%Y-%m-%dT%H:%M:%S", s) .. string.format(".%03dZ", ms % 1000)
end

local function day_of(ms) return os.date("!%Y-%m-%d", math.floor(ms / 1000)) end

local function pad_end(s, n) if #s >= n then return s end return s .. string.rep(" ", n - #s) end

local function level_of(entry)
  if type(entry.level) == "string" and entry.level ~= "" then return entry.level end
  local lvl = tostring(entry.msg or ""):match("^%[[^%]]*%]%[([A-Z]+)%]")
  return lvl or "-"
end

local function format_line(source, entry)
  local ms = (type(entry.ts) == "number") and entry.ts or 0
  local msg = tostring(entry.msg == nil and "" or entry.msg):gsub("\r?\n", " ")
  local src = entry.seq ~= nil and (source .. "#" .. string.format("%.0f", entry.seq)) or source
  return iso(ms) .. "  " .. pad_end(src, 14) .. " " .. pad_end(level_of(entry), 6) .. " " .. msg .. "\n"
end

function Standin.new(opts)
  local self = setmetatable({}, Standin)
  self.run_dir, self.sched = opts.run_dir, opts.sched
  self.boot_id = self.sched.clock:now()
  self.pending = {}
  self.log_seen, self.log_order = {}, {}
  self.seq_high = OBJ()
  self.continuity = {}
  self.log_buf = {}      -- day -> { lines }
  self.log_days = {}
  self.last_flush_wall = os.clock()
  self.dirty_state = false
  self.extra_latency_ms = 0   -- bridge_slow fault
  self.down = false           -- bridge_down fault
  self.updates = 0
  self.watchers = {}
  self.job_lines = {}   -- server lines about jobs and zones, for the report (first 500)
  self.state = {
    turtles = OBJ(), jobs = {}, version = JSON.NULL, storage = {}, storageTs = 0, mineZones = OBJ(),
    serverLog = {}, turtleLogs = OBJ(), players = {}, locations = OBJ(), updatedAt = JSON.NULL,
    oreThresholds = OBJ(), recentFailures = {}, storageHealth = OBJ(),
    zoneStoreHealthy = JSON.NULL, persistenceHealthy = JSON.NULL, diskFree = -1,
  }
  return self
end

-- JSON replies ---------------------------------------------------------------------------------

local function json(status, tbl) return status, { ["Content-Type"] = "application/json" }, JSON.encode(tbl) end

-- Logs -------------------------------------------------------------------------------------------

local function dedupe_key(source, e)
  if e.seq ~= nil then return source .. "|" .. tostring(e.bootId or "") .. "|" .. string.format("%.0f", e.seq) end
  return source .. "|" .. tostring(e.ts) .. "|" .. tostring(e.msg)
end

function Standin:already_written(key)
  if self.log_seen[key] then return true end
  self.log_seen[key] = true
  self.log_order[#self.log_order + 1] = key
  if #self.log_order > LOG_DEDUPE_MAX then
    for _ = 1, #self.log_order - LOG_DEDUPE_MAX do self.log_seen[table.remove(self.log_order, 1)] = nil end
  end
  return false
end

function Standin:note_seq(source, e)
  if e.seq == nil then return end
  local cur = self.seq_high[source]
  local boot = e.bootId == nil and JSON.NULL or e.bootId
  if not cur or cur.bootId ~= boot then
    self.seq_high[source] = OBJ({ bootId = boot, seq = e.seq })
  elseif e.seq > cur.seq then
    cur.seq = e.seq
  end
end

function Standin:note_continuity(source, e)
  if e.seq == nil then return end
  local boot = e.bootId
  local c = self.continuity[source]
  if not c or c.bootId ~= boot then
    c = { bootId = boot, min = e.seq, max = e.seq, count = 0, reboots = c and c.reboots + 1 or 0 }
    self.continuity[source] = c
  end
  if e.seq < c.min then c.min = e.seq end
  if e.seq > c.max then c.max = e.seq end
  c.count = c.count + 1
end

function Standin:loss_summary()
  local received, expected = 0, 0
  local sources = OBJ()
  for src, c in pairs(self.continuity) do
    local span = c.max - c.min + 1
    local missing = math.max(0, span - c.count)
    received = received + c.count
    expected = expected + span
    sources[src] = OBJ({ received = c.count, missing = missing, reboots = c.reboots,
      lossPct = span > 0 and math.floor(missing / span * 1000 + 0.5) / 10 or JSON.NULL })
  end
  local missing = math.max(0, expected - received)
  return OBJ({ since = self.boot_id, received = received, expected = expected, missing = missing,
    lossPct = expected > 0 and math.floor(missing / expected * 1000 + 0.5) / 10 or JSON.NULL, sources = sources })
end

function Standin:ingest_logs(body)
  local lines = {}
  local function take(source, entries)
    if type(entries) ~= "table" then return end
    for _, e in ipairs(entries) do
      if type(e) == "table" then
        self:note_seq(source, e)
        if not self:already_written(dedupe_key(source, e)) then
          self:note_continuity(source, e)
          local line = format_line(source, e)
          lines[#lines + 1] = line
          if source == "server" and #self.job_lines < 500 and (line:find("Job ", 1, true) or line:find("Zone job_", 1, true)) then
            self.job_lines[#self.job_lines + 1] = (line:gsub("\n$", ""))
          end
          for _, w in ipairs(self.watchers) do
            if line:find(w.pattern, 1, true) then
              w.count = w.count + 1
              if w.lines and #w.lines < 2000 then w.lines[#w.lines + 1] = (line:gsub("\n$", "")) end
            end
          end
        end
      end
    end
  end
  take("server", body.serverLog)
  if type(body.turtleLogs) == "table" then
    local ids = {}
    for id in pairs(body.turtleLogs) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do take(id, body.turtleLogs[id]) end
  end
  if #lines == 0 then return end
  table.sort(lines)
  local day = day_of(self.sched.clock:now())
  local buf = self.log_buf[day]
  if not buf then buf = {}; self.log_buf[day] = buf end
  for _, l in ipairs(lines) do buf[#buf + 1] = l end
  self.log_days[day] = true
end

-- Files ------------------------------------------------------------------------------------------

function Standin:state_view()
  local out = OBJ()
  for k, v in pairs(self.state) do out[k] = v end
  out.serverTime = self.sched.clock:now()
  out.logLoss = self:loss_summary()
  out.bridgeBusy = JSON.NULL
  return out
end

function Standin:flush()
  if self.run_dir then
    local logdir = self.run_dir .. "/logs"
    for day, buf in pairs(self.log_buf) do
      if #buf > 0 then
        os.execute((package.config:sub(1, 1) == "\\") and ('mkdir "' .. logdir:gsub("/", "\\") .. '" >nul 2>nul') or ('mkdir -p "' .. logdir .. '"'))
        local f = assert(io.open(logdir .. "/" .. day .. ".txt", "ab"))
        f:write(table.concat(buf)); f:close()
        self.log_buf[day] = {}
      end
    end
    -- the state file is overwritten whole every time
    local f = assert(io.open(self.run_dir .. "/state.json.tmp", "wb"))
    f:write(JSON.encode(self:state_view())); f:close()
    os.remove(self.run_dir .. "/state.json")
    os.rename(self.run_dir .. "/state.json.tmp", self.run_dir .. "/state.json")
  end
  self.dirty_state = false
  self.last_flush_wall = os.clock()
end

function Standin:maybe_flush()
  self.dirty_state = true
  if os.clock() - self.last_flush_wall >= FLUSH_WALL_SECONDS then self:flush() end
end

-- Storage ----------------------------------------------------------------------------------------

function Standin:accept_storage(payload, source)
  local list, ts = payload.storage, payload.storageTs
  local st = self.state
  if getmetatable(list) == JSON.RAW then
    if list.text:sub(1, 1) ~= "[" then return { ok = false, reason = "storage is not an array" } end
  elseif type(list) ~= "table" then return { ok = false, reason = "storage is not an array" } end
  if type(ts) ~= "number" or ts ~= ts or ts <= 0 then return { ok = false, reason = "missing or unusable storageTs" } end
  if type(st.storageTs) == "number" and st.storageTs > 0 and ts < st.storageTs then
    return { ok = false, reason = "older than the snapshot already held" }
  end
  st.storage, st.storageTs, st.storageSource = list, ts, source
  st.storageAt = self.sched.clock:now()
  return { ok = true, items = (getmetatable(list) == JSON.RAW) and 0 or #list, source = source }
end

-- Commands ---------------------------------------------------------------------------------------

function Standin:command(type_, params)
  local st = self.state
  local now = self.sched.clock:now()
  if type_ == "ADD_LOCATION" then
    local p = params or {}
    if not p.name or p.x == nil or p.z == nil then return 400, { error = "missing fields" } end
    st.locations[p.name] = OBJ({ name = p.name, x = math.floor(tonumber(p.x) or 0), y = math.floor(tonumber(p.y) or 67),
      z = math.floor(tonumber(p.z) or 0) })
    return 200, { ok = true }
  elseif type_ == "REMOVE_LOCATION" then
    local p = params or {}
    if p.name then st.locations[p.name] = nil end
    return 200, { ok = true }
  elseif type_ == "REMOVE_TURTLE" and params and params.turtleId then
    st.turtles[params.turtleId] = nil
  end
  self.pending[#self.pending + 1] = OBJ({ type = type_, params = params or OBJ(), ts = now })
  return 200, { ok = true }
end

-- Counts server/turtle log lines containing `pattern` (plain text) from now on. Returns a table whose
-- .count grows; scenarios use it to wait for "Job complete".
function Standin:watch_log(pattern, store)
  local w = { pattern = pattern, count = 0, lines = store and {} or nil }
  self.watchers[#self.watchers + 1] = w
  return w
end

-- For scenarios: same effect as POST /command.
function Standin:dispatch(cmd)
  local status, reply = self:command(cmd.type, cmd.params)
  if status ~= 200 then error("dispatch refused: " .. tostring(reply.error), 2) end
  return true
end

-- Requests ---------------------------------------------------------------------------------------

-- Members that are carried as text and never parsed: the storage list is about 500 items, re-sent every few
-- seconds, and nothing here needs to look inside it.
local RAW_KEYS = { storage = true }

local function decode_body(body)
  if body == nil or body == "" then return OBJ() end
  local v, err = JSON.decode_object(body, RAW_KEYS, nil, true)
  if v == nil then return nil end
  return v
end

function Standin:update(body)
  local st = self.state
  local now = self.sched.clock:now()
  local turtles, jobs, version = body.turtles, body.jobs, body.version
  if not turtles and not jobs and not version then return 400, { error = "missing data" } end

  if type(st.updatedAt) == "number" and (now - st.updatedAt) > CC_RESTART_GAP_MS then
    st.turtles, st.jobs, st.mineZones = OBJ(), {}, OBJ()
  end

  if turtles then
    local new = OBJ()
    for id, data in pairs(turtles) do
      local merged = OBJ()
      for k, v in pairs(st.turtles[id] or {}) do merged[k] = v end
      for k, v in pairs(data) do merged[k] = v end
      merged.lastSeen = now
      new[id] = merged
    end
    st.turtles = new
  end
  if jobs then st.jobs = jobs end
  if version then st.version = version end
  if body.storage ~= nil or body.storageTs ~= nil then
    self:accept_storage({ storage = body.storage, storageTs = body.storageTs }, "dispatch")
  end
  if body.mineZones then st.mineZones = body.mineZones end

  if type(body.serverLog) == "table" and #body.serverLog > 0 then
    local merged = st.serverLog
    for _, e in ipairs(body.serverLog) do merged[#merged + 1] = e end
    while #merged > LOG_DISPLAY_MAX do table.remove(merged, 1) end
  end
  if type(body.turtleLogs) == "table" then
    for id, entries in pairs(body.turtleLogs) do
      if type(entries) == "table" and #entries > 0 then
        local cur = st.turtleLogs[id] or {}
        for _, e in ipairs(entries) do cur[#cur + 1] = e end
        while #cur > TURTLE_DISPLAY_MAX do table.remove(cur, 1) end
        st.turtleLogs[id] = cur
      end
    end
  end

  for k, v in pairs(body) do
    if not BRIDGE_OWNED[k] and not EXPLICITLY_MERGED[k] then st[k] = v end
  end
  st.updatedAt = now

  self:ingest_logs(body)

  local reply = OBJ({ ok = true, commands = self.pending, bridgeBootId = self.boot_id })
  self.pending = {}
  if next(self.seq_high) ~= nil then reply.logAck = self.seq_high end
  self.updates = self.updates + 1
  self:maybe_flush()
  return 200, reply
end

-- Returns status, headers, body for the request, or nil, message when the bridge is down.
function Standin:handle(method, path, body, headers)
  if self.down then return nil, "Could not connect" end
  local route = path:match("^([^?]*)")
  if method == "GET" and route == "/state" then
    return json(200, self:state_view())
  elseif method == "GET" and route == "/ping" then
    return json(200, OBJ({ ok = true, uptime = (self.sched.clock:now() - self.boot_id) / 1000 }))
  elseif method == "POST" and (route == "/update" or route == "/storage" or route == "/command") then
    local data = decode_body(body)
    if type(data) ~= "table" then return json(400, { error = "bad request" }) end
    if route == "/update" then return json(self:update(data))
    elseif route == "/storage" then
      local result = self:accept_storage(data, tostring(data.source or "warehouse"))
      if not result.ok then return json(400, { ok = false, error = result.reason }) end
      self:maybe_flush()
      return json(200, { ok = true })
    else
      if not data.type then return json(400, { error = "missing type" }) end
      return json(self:command(data.type, data.params))
    end
  end
  return json(404, { error = "not found" })
end

return Standin
