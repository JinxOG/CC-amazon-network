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
            store.__listCalls = (store.__listCalls or 0) + 1
            local out = {}
            for k in pairs(store) do if k ~= "__listCalls" then out[#out + 1] = k end end
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
        -- Two distinct corruptions, because they fail through different paths.
        -- Unparseable text makes unserialise itself return nil, so it proves
        -- only that get() does not raise. A value that parses to a NON-TABLE is
        -- what actually exercises the type check -- without it, get() would hand
        -- the caller a number where it promised a table or nil. The plan shipped
        -- only the first fixture, which made this assertion unable to fail.
        kv._store["z:bad"]    = "this is not serialised lua"
        kv._store["z:scalar"] = "42"
        assert_eq(cs.get(cs.NS.ZONE, "bad"), nil)
        assert_eq(cs.get(cs.NS.ZONE, "scalar"), nil)
    end,

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

    -- Invariant K: a pcall is error handling, not error reporting. If the index
    -- write fails, listKeys silently under-reports and a zone load quietly comes
    -- back short -- the exact class of loss this plan exists to stop. The plan's
    -- writeIndex discarded that failure, so it had to become visible somewhere.
    ["a failed index write is reported in health"] = function(assert_eq)
        local kv = fakeKV()
        local cs = fresh(kv)
        -- Seed a valid index first, so this exercises the incremental index
        -- update rather than the rebuild path.
        cs.put(cs.NS.ZONE, "a", { n = 1 })
        local realPut = kv.put
        kv.put = function(k, v)
            if k == "z:__index" then error("kv full", 0) end
            realPut(k, v)
        end
        local ok = cs.put(cs.NS.ZONE, "b", { n = 2 })
        assert_eq(ok, true)              -- the value itself was written
        local h = cs.health()
        assert_eq(h.failures, 1)         -- but the index write was not silent
        assert_eq(type(h.lastError), "string")
    end,
}
