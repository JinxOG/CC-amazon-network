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
