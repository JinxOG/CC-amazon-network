# Cloud KV Zone Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move mine-zone persistence off the dispatch computer's full 1 MB disk into Cloud Solutions KV storage, one key per zone, so a sector completion writes ~40 KB instead of re-serialising 505 KB.

**Architecture:** A new shared module `cloudstore.lua` wraps the `kv_storage` peripheral with namespacing, a declared key budget, and a health signal. `central_server.lua`'s existing `savePersistentZones` / `loadPersistentZones` are rewired to it, keeping the current disk path as an automatic fallback when no KV peripheral is attached. Zones become individually keyed, which turns a whole-table rewrite into a single-zone write.

**Tech Stack:** CC:Tweaked on Minecraft 1.21.x, Lua 5.2 subset. SirEdvin's Cloud Solutions (`kv_storage` peripheral). Existing headless harness under `tests/`.

## Global Constraints

Every task's requirements implicitly include this section.

- **Measured limits, verified in-world 2026-08-25:** `valueLimit` = **500000** bytes, `keyLimit` = **10240** keys, keys in use at start = **0**. Do not design against the documentation's 1000-key default; it is wrong for this server.
- **KV is player-bound and shared** across every computer this player owns. All keys MUST be namespaced (see Task 1 key budget). An un-namespaced key is a defect.
- **Mods add capability, never replace it.** If no `kv_storage` peripheral is attached, the server MUST behave exactly as it does today, using the disk path. A missing peripheral is not an error.
- **Invariant E is untouched.** Nothing on a turtle's survival path may depend on KV. This plan changes server-side zone persistence only. `loader_state.dat` stays on the turtle's local disk.
- **Invariant K — persistence failure must be visible.** A `pcall` is error handling, not error reporting. Every write path exposes a health signal reachable from `/state`.
- **`delivery_turtle.lua` and `support_turtle.lua` are frozen** (Invariant H). This plan does not touch them.
- **`proto.VERSION` MUST be bumped and pushed** with any change altering server behaviour. Current version at plan time: **1.9.43**.
- **Never trigger `/self-update` or `UPDATE_ALL` without asking the user first** — it restarts all turtles and interrupts active miners.
- **Baseline is green:** `lua tests/run.lua` reports **239 passed, 0 failed**. Any task that reduces the passing count has regressed something.
- **Mutation-test every new test** (§13.3): break the code under the assertion, watch it fail, restore it, watch it pass. A test that cannot fail is not done.
- Existing style: 4-space indent, `--` comments explaining *why*, `logInfo`/`logWarn`/`logError` at base level.

## Ownership

| Files | Owner |
|---|---|
| `cloudstore.lua`, `tests/test_cloudstore.lua` | **W6** — Storage |
| `central_server.lua`, `tests/run.lua` registration | **W3** — Dispatch |
| `protocol.lua` version bump | W3, announced |
| `install.lua`, `updater.lua` deployment entries | W3 |

W6 does Tasks 1 and 1b alone. W3 does Tasks 2–6 and consumes `cloudstore` through its documented interface only.

## File Structure

| File | Responsibility |
|---|---|
| `cloudstore.lua` *(new)* | The only code that touches the `kv_storage` peripheral. Namespacing, serialisation, health counters. No zone knowledge. |
| `tests/test_cloudstore.lua` *(new)* | Unit tests for the above against a fake peripheral. |
| `central_server.lua` *(modify)* | Zone save/load rewired. Knows about zones; knows nothing about KV mechanics. |

The split exists because `central_server.lua` executes its main loop at load and cannot be `require`d under the harness. All logic with edge cases lives in `cloudstore.lua`, which is pure and testable, leaving only thin wiring untested in the server.

---

### Task 1: `cloudstore.lua` — the KV wrapper

**Files:**
- Create: `cloudstore.lua`
- Create: `tests/test_cloudstore.lua`
- Modify: `tests/run.lua` (register the new suite)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `cloudstore.available() -> boolean`
  - `cloudstore.put(ns, key, tbl) -> ok:boolean, err:string|nil`
  - `cloudstore.get(ns, key) -> table|nil`
  - `cloudstore.delete(ns, key) -> boolean`
  - `cloudstore.listKeys(ns) -> table` (array of bare keys, namespace stripped)
  - `cloudstore.health() -> { available, writes, failures, lastError, lastOkAt }`
  - `cloudstore.NS` — namespace constants table
  - `cloudstore.BUDGET` — declared key budget table

- [ ] **Step 1: Write the failing test**

Create `tests/test_cloudstore.lua`:

```lua
-- cloudstore wraps the kv_storage peripheral. These tests use a fake peripheral
-- so they never touch a real world, and cover the two failure modes that matter:
-- no peripheral attached (must degrade, not error) and a put that exceeds the
-- 500000-byte value limit (must report, not corrupt).
local stub = require("tests.stub_cc")

local function fakeKV()
    local store = {}
    return {
        _store = store,
        put    = function(k, v) store[k] = v end,
        get    = function(k) return store[k] end,
        delete = function(k) store[k] = nil end,
        list   = function()
            local out = {}
            for k in pairs(store) do out[#out + 1] = k end
            return out
        end,
        getConfiguration = function() return { valueLimit = 500000, keyLimit = 10240 } end,
    }
end

local function fresh(kv)
    stub.install({})
    peripheral = peripheral or {}
    peripheral.find = function(name) if name == "kv_storage" then return kv end return nil end
    package.loaded["cloudstore"] = nil
    return require("cloudstore")
end

return {
    ["reports unavailable with no peripheral"] = function(assert_eq)
        local cs = fresh(nil)
        assert_eq(cs.available(), false)
        assert_eq(cs.get(cs.NS.ZONE, "1,2,3,4"), nil)
        local ok = cs.put(cs.NS.ZONE, "1,2,3,4", { a = 1 })
        assert_eq(ok, false)
    end,

    ["round-trips a table"] = function(assert_eq)
        local cs = fresh(fakeKV())
        assert_eq(cs.available(), true)
        assert_eq(cs.put(cs.NS.ZONE, "1,2,3,4", { pct = 42 }), true)
        local got = cs.get(cs.NS.ZONE, "1,2,3,4")
        assert_eq(type(got), "table")
        assert_eq(got.pct, 42)
    end,

    ["namespaces keys so subsystems cannot collide"] = function(assert_eq)
        local kv = fakeKV()
        local cs = fresh(kv)
        cs.put(cs.NS.ZONE, "dup", { which = "zone" })
        cs.put(cs.NS.INDEX, "dup", { which = "index" })
        assert_eq(cs.get(cs.NS.ZONE, "dup").which, "zone")
        assert_eq(cs.get(cs.NS.INDEX, "dup").which, "index")
        assert_eq(kv._store["z:dup"] ~= nil, true)
    end,

    ["listKeys strips the namespace and excludes others"] = function(assert_eq)
        local cs = fresh(fakeKV())
        cs.put(cs.NS.ZONE, "a", { n = 1 })
        cs.put(cs.NS.ZONE, "b", { n = 2 })
        cs.put(cs.NS.INDEX, "c", { n = 3 })
        local keys = cs.listKeys(cs.NS.ZONE)
        table.sort(keys)
        assert_eq(#keys, 2)
        assert_eq(keys[1], "a")
        assert_eq(keys[2], "b")
    end,

    ["refuses a value over the 500000 byte limit"] = function(assert_eq)
        local cs = fresh(fakeKV())
        local ok, err = cs.put(cs.NS.ZONE, "big", { blob = string.rep("x", 600000) })
        assert_eq(ok, false)
        assert_eq(type(err), "string")
        assert_eq(cs.get(cs.NS.ZONE, "big"), nil)
    end,

    ["health counts writes and failures"] = function(assert_eq)
        local cs = fresh(fakeKV())
        cs.put(cs.NS.ZONE, "a", { n = 1 })
        cs.put(cs.NS.ZONE, "big", { blob = string.rep("x", 600000) })
        local h = cs.health()
        assert_eq(h.available, true)
        assert_eq(h.writes, 1)
        assert_eq(h.failures, 1)
        assert_eq(type(h.lastError), "string")
    end,

    ["corrupt stored value reads as nil rather than erroring"] = function(assert_eq)
        local kv = fakeKV()
        local cs = fresh(kv)
        kv._store["z:bad"] = "this is not serialised lua"
        assert_eq(cs.get(cs.NS.ZONE, "bad"), nil)
    end,
}
```

Register it in `tests/run.lua` by adding `"tests.test_cloudstore",` to the `files` list, immediately after `"tests.test_stub",`.

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/run.lua`
Expected: `LOAD FAIL tests.test_cloudstore: module 'cloudstore' not found` and a non-zero failure count.

- [ ] **Step 3: Write minimal implementation**

Create `cloudstore.lua`:

```lua
-- cloudstore.lua
-- The only module that talks to the kv_storage peripheral.
--
-- KV is player-bound: every computer this player owns shares ONE key space and
-- ONE budget. Namespacing is therefore mandatory, not stylistic — an
-- un-namespaced key from one subsystem can silently overwrite another's.
--
-- Measured in-world 2026-08-25: valueLimit 500000, keyLimit 10240.

local cloudstore = {}

-- Namespace prefixes. Short on purpose: the prefix is stored on every key.
cloudstore.NS = {
    ZONE  = "z",     -- one key per mine zone
    INDEX = "ix",    -- ore coordinate index, one key per sector
    LOG   = "log",   -- shipped turtle logs, TTL'd
    JOB   = "j",     -- job state
}

-- Declared allocations against the measured 10240-key limit. A subsystem that
-- would exceed its allocation must raise it here first, so the shared pool is
-- never consumed by accident (spec §13.1, applied to keys instead of bytes).
cloudstore.BUDGET = {
    [cloudstore.NS.ZONE]  = 500,
    [cloudstore.NS.INDEX] = 6000,
    [cloudstore.NS.LOG]   = 2000,
    [cloudstore.NS.JOB]   = 200,
}

local VALUE_LIMIT = 500000

local _kv        = nil
local _resolved  = false
local _writes    = 0
local _failures  = 0
local _lastError = nil
local _lastOkAt  = 0

local function kv()
    if not _resolved then
        _resolved = true
        local ok, found = pcall(function() return peripheral.find("kv_storage") end)
        _kv = ok and found or nil
    end
    return _kv
end

function cloudstore.available()
    return kv() ~= nil
end

local function fullKey(ns, key)
    return ns .. ":" .. tostring(key)
end

function cloudstore.put(ns, key, tbl)
    local p = kv()
    if not p then
        _lastError = "no kv_storage peripheral"
        return false, _lastError
    end
    local encoded = textutils.serialise(tbl)
    if #encoded > VALUE_LIMIT then
        _failures  = _failures + 1
        _lastError = string.format("value %d bytes exceeds limit %d", #encoded, VALUE_LIMIT)
        return false, _lastError
    end
    local ok, err = pcall(function() p.put(fullKey(ns, key), encoded) end)
    if not ok then
        _failures  = _failures + 1
        _lastError = tostring(err)
        return false, _lastError
    end
    _writes   = _writes + 1
    _lastOkAt = os.epoch and os.epoch("utc") or 0
    return true
end

function cloudstore.get(ns, key)
    local p = kv()
    if not p then return nil end
    local ok, raw = pcall(function() return p.get(fullKey(ns, key)) end)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end
    -- A corrupt or foreign value must read as absent, never raise: an
    -- unreadable zone is survivable, a crashed server is not.
    local decoded = textutils.unserialise(raw)
    if type(decoded) ~= "table" then return nil end
    return decoded
end

function cloudstore.delete(ns, key)
    local p = kv()
    if not p then return false end
    local ok = pcall(function() p.delete(fullKey(ns, key)) end)
    return ok and true or false
end

function cloudstore.listKeys(ns)
    local p = kv()
    if not p then return {} end
    local ok, all = pcall(function() return p.list() end)
    if not ok or type(all) ~= "table" then return {} end
    local prefix, out = ns .. ":", {}
    for _, k in ipairs(all) do
        if type(k) == "string" and k:sub(1, #prefix) == prefix then
            out[#out + 1] = k:sub(#prefix + 1)
        end
    end
    return out
end

function cloudstore.health()
    return {
        available = cloudstore.available(),
        writes    = _writes,
        failures  = _failures,
        lastError = _lastError,
        lastOkAt  = _lastOkAt,
    }
end

-- Test seam: forces re-resolution of the peripheral.
function cloudstore._reset()
    _kv, _resolved, _writes, _failures, _lastError, _lastOkAt = nil, false, 0, 0, nil, 0
end

return cloudstore
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua tests/run.lua`
Expected: `246 passed, 0 failed` (239 baseline + 7 new).

- [ ] **Step 5: Mutation-test each new assertion**

For each of the seven tests, break the code, confirm the test fails, restore it:

| Test | Break this | Expect |
|---|---|---|
| reports unavailable | make `available()` `return true` | FAIL |
| round-trips a table | make `get` return `nil` always | FAIL |
| namespaces keys | make `fullKey` return `tostring(key)` | FAIL |
| listKeys strips | drop the prefix filter in `listKeys` | FAIL |
| refuses oversize | raise `VALUE_LIMIT` to `math.huge` | FAIL |
| health counts | stop incrementing `_failures` | FAIL |
| corrupt reads nil | `return decoded` without the type check | FAIL |

Restore the file to the working version after each. **Do not proceed until all seven have been observed failing.**

- [ ] **Step 6: Commit**

```bash
git add cloudstore.lua tests/test_cloudstore.lua tests/run.lua
git commit -m "feat: cloudstore module wrapping the kv_storage peripheral"
```

---

### Task 1b: Namespace index, so enumeration does not scale with total keys

**Files:**
- Modify: `cloudstore.lua`
- Modify: `tests/test_cloudstore.lua`

**Interfaces:**
- Consumes: Task 1's `cloudstore` module.
- Produces: no signature change. `listKeys(ns)` keeps its contract; it stops
  being O(all keys) internally.

**Why this exists.** `kv.list()` returns **every key in the shared player-bound
space** with no prefix filter, and Task 1's `listKeys` filters client-side. That
is fine at the current 10240-key limit and becomes a problem at the 32768 this
system is expected to be configured for: enumerating zones would transfer and
iterate a 32000-element table on a computer with a tick budget, on a hot path.

Each namespace therefore maintains its own index key, and `list()` becomes a
repair tool rather than normal operation. Build the seam now — retrofitting it
after Tier 2 lands means rewriting live callers.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_cloudstore.lua`, and extend `fakeKV()` to count `list` calls
by replacing its `list` field with:

```lua
        list   = function()
            store.__listCalls = (store.__listCalls or 0) + 1
            local out = {}
            for k in pairs(store) do if k ~= "__listCalls" then out[#out + 1] = k end end
            return out
        end,
```

Then add these two tests:

```lua
    ["listKeys uses the index and does not scan all keys"] = function(assert_eq)
        local kv = fakeKV()
        local cs = fresh(kv)
        cs.put(cs.NS.ZONE, "a", { n = 1 })
        cs.put(cs.NS.ZONE, "b", { n = 2 })
        kv._store.__listCalls = 0
        local keys = cs.listKeys(cs.NS.ZONE)
        table.sort(keys)
        assert_eq(#keys, 2)
        assert_eq(keys[1], "a")
        assert_eq(kv._store.__listCalls, 0)
    end,

    ["delete removes the key from the index"] = function(assert_eq)
        local cs = fresh(fakeKV())
        cs.put(cs.NS.ZONE, "a", { n = 1 })
        cs.put(cs.NS.ZONE, "b", { n = 2 })
        cs.delete(cs.NS.ZONE, "a")
        local keys = cs.listKeys(cs.NS.ZONE)
        assert_eq(#keys, 1)
        assert_eq(keys[1], "b")
    end,
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua tests/run.lua`
Expected: `FAIL  listKeys uses the index and does not scan all keys` — the count
will be 1, not 0.

- [ ] **Step 3: Implement the index**

In `cloudstore.lua`, add above `cloudstore.put`:

```lua
-- Each namespace keeps its own index of live keys. kv.list() returns the whole
-- shared key space with no prefix filter, so scanning it per enumeration costs
-- O(total keys across every subsystem) — untenable once the key limit is raised.
local function indexKey(ns) return ns .. ":__index" end

local function readIndex(p, ns)
    local ok, raw = pcall(function() return p.get(indexKey(ns)) end)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end
    local decoded = textutils.unserialise(raw)
    if type(decoded) ~= "table" then return nil end
    return decoded
end

local function writeIndex(p, ns, set)
    pcall(function() p.put(indexKey(ns), textutils.serialise(set)) end)
end

-- Rebuild from a full scan. Only called when the index is missing or corrupt,
-- which is a repair path, not a hot path.
local function rebuildIndex(p, ns)
    local set = {}
    local ok, all = pcall(function() return p.list() end)
    if ok and type(all) == "table" then
        local prefix = ns .. ":"
        for _, k in ipairs(all) do
            if type(k) == "string" and k:sub(1, #prefix) == prefix then
                local bare = k:sub(#prefix + 1)
                if bare ~= "__index" then set[bare] = true end
            end
        end
    end
    writeIndex(p, ns, set)
    return set
end
```

Then, in `cloudstore.put`, immediately before `return true`, add:

```lua
    local set = readIndex(p, ns) or rebuildIndex(p, ns)
    if not set[tostring(key)] then
        set[tostring(key)] = true
        writeIndex(p, ns, set)
    end
```

In `cloudstore.delete`, replace the body after the `if not p` guard with:

```lua
    local ok = pcall(function() p.delete(fullKey(ns, key)) end)
    if ok then
        local set = readIndex(p, ns)
        if set and set[tostring(key)] then
            set[tostring(key)] = nil
            writeIndex(p, ns, set)
        end
    end
    return ok and true or false
```

And replace `cloudstore.listKeys` entirely with:

```lua
function cloudstore.listKeys(ns)
    local p = kv()
    if not p then return {} end
    local set = readIndex(p, ns) or rebuildIndex(p, ns)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    return out
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua tests/run.lua`
Expected: `248 passed, 0 failed` (246 from Task 1 + 2 new).

- [ ] **Step 5: Mutation-test both new assertions**

| Test | Break this | Expect |
|---|---|---|
| listKeys uses the index | make `listKeys` call `rebuildIndex` unconditionally | FAIL (count becomes 1) |
| delete removes from index | drop the `writeIndex` call inside `delete` | FAIL |

Restore after each. Do not proceed until both have been observed failing.

- [ ] **Step 6: Update the key budget**

Each namespace now spends one extra key on its own index. In
`cloudstore.BUDGET`, this is within existing allocations and needs no change —
but add this comment above the table so nobody is surprised:

```lua
-- Each namespace also consumes one key for its "<ns>:__index" entry.
```

- [ ] **Step 7: Commit**

```bash
git add cloudstore.lua tests/test_cloudstore.lua
git commit -m "perf: index each cloudstore namespace so enumeration is not O(all keys)"
```

---

### Task 2: Load zones from KV, with the disk path as fallback

**Files:**
- Modify: `central_server.lua:559-578` (`loadPersistentZones`)

**Interfaces:**
- Consumes: `cloudstore.available()`, `cloudstore.listKeys(ns)`, `cloudstore.get(ns, key)`, `cloudstore.NS.ZONE` from Task 1.
- Produces: `state.persistentZones` populated identically whether the source was KV or disk.

Read is done before write deliberately: after this task the server can read what a later task writes, and a half-finished migration cannot lose data.

- [ ] **Step 1: Add the require**

Near the other requires at the top of `central_server.lua`, add:

```lua
local cloudstore = require("cloudstore")
```

- [ ] **Step 2: Replace `loadPersistentZones`**

Replace the whole function at `central_server.lua:559-578` with:

```lua
local function loadPersistentZones()
    -- Prefer KV. It is authoritative once migration has run, and it is the only
    -- store that does not compete with program text for the 1 MB disk.
    if cloudstore.available() then
        local keys = cloudstore.listKeys(cloudstore.NS.ZONE)
        if #keys > 0 then
            local loaded, n = {}, 0
            for _, zoneKey in ipairs(keys) do
                local zone = cloudstore.get(cloudstore.NS.ZONE, zoneKey)
                if zone then loaded[zoneKey] = zone; n = n + 1 end
            end
            state.persistentZones = loaded
            logInfo(string.format("Loaded %d persistent mine zone(s) from cloud", n))
            return
        end
        -- No cloud zones yet: fall through to disk so the first boot after
        -- deployment still sees existing data. Task 4 migrates it.
        logInfo("No cloud zones found — reading disk (migration pending)")
    end

    local raw = ""
    if fs.exists(ZONE_SAVE_FILE) then
        local f = fs.open(ZONE_SAVE_FILE, "r")
        if f then raw = f.readAll(); f.close() end
    elseif fs.exists(ZONE_SAVE_FILE .. ".bak") then
        logWarn("loadPersistentZones: " .. ZONE_SAVE_FILE .. " missing — loading from backup")
        local f = fs.open(ZONE_SAVE_FILE .. ".bak", "r")
        if f then raw = f.readAll(); f.close() end
    else
        return
    end
    if raw == "" then return end
    local data = textutils.unserialise(raw)
    if type(data) ~= "table" then return end
    state.persistentZones = data
    local n = 0
    for _ in pairs(data) do n = n + 1 end
    if n > 0 then logInfo(string.format("Loaded %d persistent mine zone(s) from disk", n)) end
end
```

- [ ] **Step 3: Verify the harness still passes**

Run: `lua tests/run.lua`
Expected: `248 passed, 0 failed`. `central_server.lua` is not covered by the harness, so this confirms no collateral damage rather than proving the change.

- [ ] **Step 4: Commit**

```bash
git add central_server.lua
git commit -m "feat: load mine zones from cloud KV, falling back to disk"
```

---

### Task 3: Save one key per zone

**Files:**
- Modify: `central_server.lua:543-557` (`savePersistentZones`)

**Interfaces:**
- Consumes: `cloudstore.put`, `cloudstore.delete`, `cloudstore.listKeys`, `cloudstore.NS.ZONE`.
- Produces: `savePersistentZones(changedKey)` — an optional argument. Called with a zone key, it writes only that zone. Called with no argument, it writes every zone.

This signature change is the point of the whole plan: the current function re-serialises all zones on every sector completion, which is why a 254 KB file needs 254 KB of free space to save.

- [ ] **Step 1: Replace `savePersistentZones`**

Replace `central_server.lua:543-557` with:

```lua
-- changedKey: write only that zone. Omitted: write all of them.
--
-- Granularity is the reason this exists. The previous implementation
-- re-serialised the entire zone table on every sector completion, which both
-- stalled the event loop and required free disk equal to the whole file.
local function savePersistentZones(changedKey)
    if cloudstore.available() then
        local wrote, failed = 0, 0
        if changedKey then
            local zone = state.persistentZones[changedKey]
            if zone then
                local ok, err = cloudstore.put(cloudstore.NS.ZONE, changedKey, zone)
                if ok then wrote = 1 else failed = 1; logWarn("zone save failed for " .. changedKey .. ": " .. tostring(err)) end
            else
                cloudstore.delete(cloudstore.NS.ZONE, changedKey)
            end
        else
            for zoneKey, zone in pairs(state.persistentZones) do
                local ok, err = cloudstore.put(cloudstore.NS.ZONE, zoneKey, zone)
                if ok then wrote = wrote + 1 else failed = failed + 1; logWarn("zone save failed for " .. zoneKey .. ": " .. tostring(err)) end
            end
        end
        if failed == 0 then return end
        logWarn(string.format("savePersistentZones: %d written, %d failed — falling back to disk", wrote, failed))
    end

    -- Disk fallback: unchanged behaviour for a server with no KV attached.
    local ok, err = pcall(function()
        local data = textutils.serialise(state.persistentZones)
        local f = fs.open("zones.tmp", "w")
        if not f then error("could not open zones.tmp for writing") end
        f.write(data); f.close()
        if fs.exists(ZONE_SAVE_FILE) then
            if fs.exists(ZONE_SAVE_FILE .. ".bak") then fs.delete(ZONE_SAVE_FILE .. ".bak") end
            fs.copy(ZONE_SAVE_FILE, ZONE_SAVE_FILE .. ".bak")
            fs.delete(ZONE_SAVE_FILE)
        end
        fs.move("zones.tmp", ZONE_SAVE_FILE)
    end)
    if not ok then logWarn("savePersistentZones failed: " .. tostring(err)) end
end
```

- [ ] **Step 2: Pass the changed zone key at every call site**

There are **eight** call sites, enumerated here so nobody has to hunt for them:

| Line | Action |
|---|---|
| `central_server.lua:679` | Inspect for a zone key in scope; pass it if present |
| `central_server.lua:1203` | Inspect; pass if present |
| `central_server.lua:1468` | Inspect; pass if present |
| `central_server.lua:1597` | Inspect; pass if present |
| `central_server.lua:1601` | Inspect; pass if present |
| `central_server.lua:2099` | Inspect; pass if present |
| `central_server.lua:2130` | Inspect; pass if present |
| `central_server.lua:2869` | Inspect; pass if present |

At each one, read the enclosing function and find the variable holding the zone
key being modified — commonly `zoneKey`, or the key used to index
`state.persistentZones`. Pass it: `savePersistentZones(zoneKey)`.

**Do not guess a variable name.** Where no single zone is implicated — shutdown,
bulk edits, a loop over many zones — leave the bare `savePersistentZones()`
call. It still writes everything and is correct, just slower. Note in the commit
message which sites were left bare and why.

A bare call is never wrong; a wrong key is. When unsure, leave it bare.

- [ ] **Step 3: Verify the harness still passes**

Run: `lua tests/run.lua`
Expected: `248 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add central_server.lua
git commit -m "feat: write one KV key per zone instead of re-serialising all zones"
```

---

### Task 4: One-time migration from disk to KV

**Files:**
- Modify: `central_server.lua` — add `migrateZonesToCloud()` and call it during startup, after `loadPersistentZones()`.

**Interfaces:**
- Consumes: `state.persistentZones` as populated by Task 2; `cloudstore.put`, `cloudstore.listKeys`.
- Produces: nothing new. Idempotent — safe to run on every boot.

- [ ] **Step 1: Add the migration function**

Immediately after `loadPersistentZones`, add:

```lua
-- Idempotent: copies disk-loaded zones into KV the first time a cloud-capable
-- server boots, then does nothing on subsequent boots because KV is no longer
-- empty. The disk files are deliberately NOT deleted here — a human deletes
-- them once the cloud copy has been eyeballed.
local function migrateZonesToCloud()
    if not cloudstore.available() then return end
    if #cloudstore.listKeys(cloudstore.NS.ZONE) > 0 then return end

    local total, wrote, failed = 0, 0, 0
    for zoneKey, zone in pairs(state.persistentZones) do
        total = total + 1
        local ok, err = cloudstore.put(cloudstore.NS.ZONE, zoneKey, zone)
        if ok then
            wrote = wrote + 1
        else
            failed = failed + 1
            logError("zone migration failed for " .. zoneKey .. ": " .. tostring(err))
        end
    end

    if total == 0 then return end
    if failed == 0 then
        logInfo(string.format("Migrated %d zone(s) to cloud storage", wrote))
    else
        logError(string.format("Zone migration incomplete: %d of %d written, %d FAILED — disk files retained", wrote, total, failed))
    end
end
```

- [ ] **Step 2: Call it at startup**

The startup call to `loadPersistentZones()` is at **`central_server.lua:3363`**.
Add `migrateZonesToCloud()` on the line immediately after it, at the same
indentation.

- [ ] **Step 3: Verify the harness still passes**

Run: `lua tests/run.lua`
Expected: `248 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add central_server.lua
git commit -m "feat: one-time idempotent migration of mine zones into cloud KV"
```

---

### Task 5: Expose storage health in `/state` (Invariant K)

**Files:**
- Modify: `central_server.lua` — the `/state` payload assembly near line 3070.

**Interfaces:**
- Consumes: `cloudstore.health()`.
- Produces: a `storageHealth` object in the `/state` JSON: `{ available, writes, failures, lastError, lastOkAt }`.

Without this, a KV write failing repeatedly looks exactly like everything being fine — the precise failure that ran for hours with `saveJobs`.

- [ ] **Step 1: Add the field to the payload**

Locate the payload assembly:

```bash
grep -n '"serverLog"' central_server.lua
```

In that concatenated JSON string, add a `storageHealth` entry alongside `serverLog`, using the same `js(...)` helper the neighbouring fields use:

```lua
',"storageHealth":' .. js(cloudstore.health(), "{}", "storageHealth") ..
```

Match the surrounding comma and quoting style exactly — the payload is assembled as one string and a malformed fragment blanks the whole dashboard.

- [ ] **Step 2: Verify the harness still passes**

Run: `lua tests/run.lua`
Expected: `248 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add central_server.lua
git commit -m "feat: surface cloud storage health in /state per Invariant K"
```

---

### Task 6: Deploy and verify in-world

**Files:**
- Modify: `install.lua`, `updater.lua` — add `cloudstore.lua` to the server profile
- Modify: `protocol.lua` — bump `proto.VERSION`

- [ ] **Step 1: Add `cloudstore.lua` to deployment**

In `install.lua`, add `cloudstore = "cloudstore.lua",` to the `FILES` table, and add `{ src = FILES.cloudstore, name = "cloudstore.lua" },` to the server profile's file list beside `protocol.lua`.

In `updater.lua`, add `{ src = "cloudstore.lua", dst = "cloudstore.lua" },` to the server profile list.

- [ ] **Step 2: Bump the protocol version**

In `protocol.lua`, change `proto.VERSION = "1.9.43"` to `proto.VERSION = "1.9.44"`.

- [ ] **Step 3: Commit and push**

```bash
git add install.lua updater.lua protocol.lua
git commit -m "chore: deploy cloudstore to the server profile, bump to 1.9.44"
git push origin master
```

- [ ] **Step 4: Free the disk before deploying**

**Ask the user before running anything that restarts computers.** On the dispatch computer, first recover headroom so the fallback path cannot fail mid-deploy:

```bash
fs.delete("/mine_zones.dat.bak") fs.delete("/zones.tmp") print("free",fs.getFreeSpace("/"))
```

- [ ] **Step 5: Update the server and reboot it**

With the user's explicit go-ahead, update the dispatch computer only, then reboot it.

- [ ] **Step 6: Verify migration ran**

On the dispatch computer:

```bash
local kv=peripheral.find("kv_storage") local n=0 for _,k in ipairs(kv.list()) do if k:sub(1,2)=="z:" then n=n+1 print(k,#kv.get(k)) end end print("zones in cloud",n)
```

Expected: one `z:` key per zone, each well under 500000 bytes.

- [ ] **Step 7: Verify granular writes and health**

Watch a mining job complete a sector, then confirm `savePersistentZones` no longer touches the disk and that health is clean:

```bash
curl -s -H "ngrok-skip-browser-warning: true" "https://mardi-flogging-factor.ngrok-free.dev/state" | grep -o '"storageHealth":{[^}]*}'
```

Expected: `available` true, `failures` 0, `writes` climbing as sectors complete.

- [ ] **Step 8: Retire the disk files**

Only after Steps 6 and 7 both pass, and only with the user's agreement:

```bash
fs.delete("/mine_zones.dat") print("free",fs.getFreeSpace("/"))
```

Expected: free space rises by ~254 KB, to roughly 750 KB.

---

## Out of scope

Deliberately not in this plan, each needing its own: the ore coordinate index (Tier 1 census and Tier 2 coordinates), turtle log shipping and TTL retention, job-state migration to KV, the planner's project storage, and splitting `central_server.lua`. This plan moves zones only, because zones are what is failing today.
