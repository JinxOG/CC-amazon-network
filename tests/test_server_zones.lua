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
