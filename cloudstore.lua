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
-- Each namespace also consumes one key for its "<ns>:__index" entry.
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

-- Shared by get() and readIndex(). A corrupt or foreign value must read as
-- absent, never raise: an unreadable zone is survivable, a crashed server is
-- not. Anything that does not decode to a table — a scalar, another
-- subsystem's value — counts as absent rather than being handed back.
local function decodeTable(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local decoded = textutils.unserialise(raw)
    if type(decoded) ~= "table" then return nil end
    return decoded
end

-- Each namespace keeps its own index of live keys. kv.list() returns the whole
-- shared key space with no prefix filter, so scanning it per enumeration costs
-- O(total keys across every subsystem) — untenable once the key limit is raised.
local function indexKey(ns) return ns .. ":__index" end

local function readIndex(p, ns)
    local ok, raw = pcall(function() return p.get(indexKey(ns)) end)
    if not ok then return nil end
    return decodeTable(raw)
end

local function writeIndex(p, ns, set)
    local ok, err = pcall(function() p.put(indexKey(ns), textutils.serialise(set)) end)
    if not ok then
        -- Invariant K. A lost index write is worse than a lost value: listKeys
        -- then under-reports, so the next load comes back short and looks like a
        -- clean load of fewer zones. Count it like any other write failure so it
        -- reaches health() and /state rather than dying inside the pcall.
        _failures  = _failures + 1
        _lastError = "index write failed for " .. tostring(ns) .. ": " .. tostring(err)
    end
    return ok
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
    local set = readIndex(p, ns) or rebuildIndex(p, ns)
    if not set[tostring(key)] then
        set[tostring(key)] = true
        writeIndex(p, ns, set)
    end
    return true
end

function cloudstore.get(ns, key)
    local p = kv()
    if not p then return nil end
    local ok, raw = pcall(function() return p.get(fullKey(ns, key)) end)
    if not ok then return nil end
    return decodeTable(raw)
end

function cloudstore.delete(ns, key)
    local p = kv()
    if not p then return false end
    local ok = pcall(function() p.delete(fullKey(ns, key)) end)
    if ok then
        local set = readIndex(p, ns)
        if set and set[tostring(key)] then
            set[tostring(key)] = nil
            writeIndex(p, ns, set)
        end
    end
    return ok and true or false
end

function cloudstore.listKeys(ns)
    local p = kv()
    if not p then return {} end
    local set = readIndex(p, ns) or rebuildIndex(p, ns)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
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
