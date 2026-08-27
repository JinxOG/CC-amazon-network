-- Zone persistence: where does the server read its mine zones from, and what
-- happens on the way to KV being authoritative?
--
-- The plan for this work assumed central_server.lua could not be required under
-- the harness and treated `lua tests/run.lua` as a collateral-damage check only.
-- The test seam added in a9ab20b makes it testable, so these cover the paths
-- rather than merely confirming nothing else broke.
--
-- The properties that matter are the rollout ones. A missing peripheral must
-- behave exactly as today (mods add capability, never replace it), and a cloud
-- store that exists but is empty must still find existing disk data -- otherwise
-- the first boot after deployment looks like total zone loss.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

local function fakeKV(seed)
    local store = {}
    for k, v in pairs(seed or {}) do store[k] = v end
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

-- kv = a fake peripheral, or nil for "no kv_storage attached".
-- diskZones = a table to write to the on-disk zone file, or nil for no file.
local function freshServer(kv, diskZones)
    local c = stub.install({})
    local savedEpoch, savedPeripheral = os.epoch, peripheral
    os.epoch = function() return 1000000 end
    peripheral = { find = function(n) if n == "kv_storage" then return kv end return nil end }

    if diskZones then
        local f = fs.open("mine_zones.dat", "w")
        f.write(textutils.serialise(diskZones))
        f.close()
    end

    package.loaded["cloudstore"] = nil
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local server = require("central_server")

    local restore = function()
        os.epoch, peripheral = savedEpoch, savedPeripheral
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
        package.loaded["cloudstore"]     = nil
    end
    return server, server._test, restore, c
end

local ZONE = { bounds = { x1 = 0, z1 = 0, x2 = 32, z2 = 32 }, surveyed = true, total = 4 }

return {
    -- The constraint the whole rollout rests on: a server with no kv_storage
    -- attached must be indistinguishable from today's. A missing peripheral is
    -- not an error.
    ["with no kv peripheral, zones still load from disk"] = function(assert_eq)
        local server, T, restore = freshServer(nil, { ["0,0,32,32"] = ZONE })
        T.state.persistentZones = {}
        T.loadPersistentZones()
        local z = T.state.persistentZones["0,0,32,32"]
        restore()
        assert_eq(z ~= nil, true, "the disk path must still work with no peripheral")
        assert_eq(z and z.total, 4)
    end,

    ["cloud zones are preferred once they exist"] = function(assert_eq)
        local server, T, restore = freshServer(
            fakeKV({ ["z:9,9,41,41"] = textutils.serialise({ total = 7, surveyed = true }) }),
            { ["0,0,32,32"] = ZONE })
        T.state.persistentZones = {}
        T.loadPersistentZones()
        local fromCloud = T.state.persistentZones["9,9,41,41"]
        local fromDisk  = T.state.persistentZones["0,0,32,32"]
        restore()
        assert_eq(fromCloud ~= nil and fromCloud.total, 7,
            "KV is authoritative once it holds anything")
        assert_eq(fromDisk, nil,
            "and the disk copy must not be merged in behind it — that would "
            .. "resurrect zones a migration deliberately left behind")
    end,

    -- The first boot after deployment. KV is attached and empty; the disk still
    -- holds everything. Reading only KV here would look like total zone loss.
    ["an empty cloud store falls back to disk rather than reporting nothing"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), { ["0,0,32,32"] = ZONE })
        T.state.persistentZones = {}
        T.loadPersistentZones()
        local z = T.state.persistentZones["0,0,32,32"]
        restore()
        assert_eq(z ~= nil, true,
            "an attached-but-empty KV must not shadow existing disk data")
        assert_eq(z and z.total, 4)
    end,

    -- ─── Per-zone writes ────────────────────────────────────────────────────
    --
    -- The point of the whole plan. The old function re-serialised EVERY zone on
    -- every sector completion, which both stalled the event loop and meant a
    -- 254 KB file needed 254 KB free to save.
    ["a keyed save writes only that zone"] = function(assert_eq)
        local kv = fakeKV({})
        local server, T, restore = freshServer(kv, nil)
        T.state.persistentZones = {
            ["a"] = { total = 1 },
            ["b"] = { total = 2 },
        }
        T.savePersistentZones("a")
        local wroteA = kv._store["z:a"] ~= nil
        local wroteB = kv._store["z:b"] ~= nil
        restore()
        assert_eq(wroteA, true, "the named zone must be written")
        assert_eq(wroteB, false,
            "and the others must NOT be — re-serialising all of them is the cost "
            .. "this change exists to remove")
    end,

    -- A bare call is never wrong, just slower. Shutdown and bulk edits use it.
    ["a bare save still writes every zone"] = function(assert_eq)
        local kv = fakeKV({})
        local server, T, restore = freshServer(kv, nil)
        T.state.persistentZones = { ["a"] = { total = 1 }, ["b"] = { total = 2 } }
        T.savePersistentZones()
        local a, b = kv._store["z:a"] ~= nil, kv._store["z:b"] ~= nil
        restore()
        assert_eq(a and b, true, "an unkeyed save must still persist everything")
    end,

    -- A zone deleted from memory must be removed from the store, not left as a
    -- stale copy that the next load would resurrect. DELETE_MINE_ZONE passes its
    -- key after nilling the entry, which is exactly this path.
    ["a keyed save for a removed zone deletes it from the store"] = function(assert_eq)
        local kv = fakeKV({ ["z:gone"] = textutils.serialise({ total = 3 }) })
        local server, T, restore = freshServer(kv, nil)
        T.state.persistentZones = {}
        T.savePersistentZones("gone")
        local still = kv._store["z:gone"] ~= nil
        restore()
        assert_eq(still, false,
            "a zone removed from memory must not survive in the store")
    end,

    -- Invariant K: a write path exposes a health signal reachable from /state.
    ["a failing zone write is reported, not swallowed"] = function(assert_eq)
        local kv = fakeKV({})
        kv.put = function() error("kv exploded", 0) end
        local server, T, restore = freshServer(kv, nil)
        T.state.persistentZones = { ["a"] = { total = 1 } }
        T.savePersistentZones("a")
        local healthy = T.state.zoneStoreHealthy
        restore()
        assert_eq(healthy, false,
            "a pcall is error handling, not error reporting — the failure must surface")
    end,

    -- Nothing anywhere is a clean start, not a crash.
    ["no cloud and no disk is an empty start"] = function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        T.state.persistentZones = {}
        T.loadPersistentZones()
        local n = 0
        for _ in pairs(T.state.persistentZones) do n = n + 1 end
        restore()
        assert_eq(n, 0, "no zones anywhere must load cleanly, not raise")
    end,
}
