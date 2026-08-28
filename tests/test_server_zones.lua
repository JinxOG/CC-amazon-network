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

    -- ─── Migration ──────────────────────────────────────────────────────────
    --
    -- This is what makes the per-zone write safe to deploy. Without it, the
    -- FIRST zone saved after deployment leaves KV holding one key -- and
    -- loadPersistentZones treats any non-empty KV as authoritative, so the next
    -- restart loads that one zone and silently drops every zone that had not
    -- happened to change.
    ["migration seeds every disk zone into an empty cloud store"] = function(assert_eq)
        local kv = fakeKV({})
        local server, T, restore = freshServer(kv, nil)
        T.state.persistentZones = {
            ["a"] = { total = 1 }, ["b"] = { total = 2 }, ["c"] = { total = 3 },
        }
        T.migrateZonesToCloud()
        local n = 0
        -- Skip the namespace index. Task 1b gave each namespace a "<ns>:__index"
        -- key so listKeys stops scanning the whole shared key space; it is
        -- bookkeeping, not a zone. Counted here it would read as a fourth zone.
        for k in pairs(kv._store) do if k ~= "z:__index" then n = n + 1 end end
        restore()
        assert_eq(n, 3, "every zone must be seeded, not just the ones that later change")
    end,

    -- Idempotent: it runs on every boot and must do nothing once KV is populated,
    -- or a later boot would overwrite live cloud state with whatever the disk
    -- fallback happened to hold.
    ["migration does nothing once the cloud store is populated"] = function(assert_eq)
        local kv = fakeKV({ ["z:a"] = textutils.serialise({ total = 99 }) })
        local server, T, restore = freshServer(kv, nil)
        T.state.persistentZones = { ["a"] = { total = 1 }, ["b"] = { total = 2 } }
        T.migrateZonesToCloud()
        local a = textutils.unserialise(kv._store["z:a"])
        local addedB = kv._store["z:b"] ~= nil
        restore()
        assert_eq(a.total, 99, "an existing cloud zone must not be overwritten on reboot")
        assert_eq(addedB, false, "and migration must not run at all once KV is non-empty")
    end,

    -- A partial migration is the dangerous state: KV is now non-empty, so the
    -- next boot reads it as authoritative while some zones exist only on disk.
    -- It must be loud, and the disk files must stay.
    ["a partial migration reports unhealthy rather than passing quietly"] =
    function(assert_eq)
        local kv = fakeKV({})
        local calls = 0
        kv.put = function(k, v)
            calls = calls + 1
            if calls == 2 then error("kv full", 0) end
            kv._store[k] = v
        end
        local server, T, restore = freshServer(kv, nil)
        T.state.zoneStoreHealthy = true
        T.state.persistentZones = { ["a"] = { total = 1 }, ["b"] = { total = 2 } }
        T.migrateZonesToCloud()
        local healthy = T.state.zoneStoreHealthy
        restore()
        assert_eq(healthy, false,
            "a half-migrated store must surface — the next boot trusts KV over disk")
    end,

    ["migration is a no-op with no kv peripheral"] = function(assert_eq)
        local server, T, restore = freshServer(nil, nil)
        T.state.persistentZones = { ["a"] = { total = 1 } }
        local ok = pcall(T.migrateZonesToCloud)
        restore()
        assert_eq(ok, true, "no peripheral is not an error")
    end,

    -- Invariant K for the cloud path. /state carries cloudstore.health() through
    -- the js() helper, which pcalls serialiseJSON and falls back to "{}" -- so a
    -- bad shape degrades one field rather than blanking the dashboard. What it
    -- cannot survive is health() returning something serialiseJSON rejects on
    -- every call, which would make the signal permanently empty and silent.
    --
    -- buildBridgePayload is a local inside server.run and is not reachable from
    -- the seam, so this covers the input rather than the assembly.
    ["storage health serialises for /state"] = function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        local cs = require("cloudstore")
        local h  = cs.health()
        local ok, encoded = pcall(textutils.serialiseJSON, h)
        restore()
        assert_eq(type(h), "table", "health() must return a table")
        assert_eq(ok and type(encoded) == "string", true,
            "and it must survive serialiseJSON, or the /state signal is silently empty")
    end,

    -- The boot failure of 2026-08-27. central_server hard-required cloudstore
    -- while the installer did not ship it, so the server did not start at all:
    -- "module 'cloudstore' not found" at startup.lua:10, dispatch down entirely.
    --
    -- Deployment order must not be load-bearing. A missing MODULE degrades the
    -- same way a missing peripheral does -- capability is added, never required
    -- -- so the server boots and uses the disk path it always had.
    ["a missing cloudstore module does not stop the server loading"] =
    function(assert_eq)
        local c = stub.install({})
        local savedEpoch, savedPeripheral = os.epoch, peripheral
        os.epoch = function() return 1000000 end
        peripheral = { find = function() return nil end }

        local f = fs.open("mine_zones.dat", "w")
        f.write(textutils.serialise({ ["0,0,32,32"] = ZONE })); f.close()

        -- Force the require to fail exactly as a missing file does.
        package.loaded["cloudstore"] = nil
        package.preload["cloudstore"] = function() error("module not found", 0) end

        _G.__CC_SERVER_TEST = true
        package.loaded["central_server"] = nil
        package.loaded["waypoints"]      = nil
        local ok, server = pcall(require, "central_server")

        local loaded, zones = false, 0
        if ok and server and server._test then
            server._test.state.persistentZones = {}
            server._test.loadPersistentZones()
            for _ in pairs(server._test.state.persistentZones) do zones = zones + 1 end
            loaded = true
        end

        package.preload["cloudstore"] = nil
        package.loaded["cloudstore"]  = nil
        package.loaded["central_server"] = nil
        _G.__CC_SERVER_TEST = nil
        os.epoch, peripheral = savedEpoch, savedPeripheral

        assert_eq(ok, true,
            "the server must load without cloudstore — a hard require bricked the "
            .. "boot when the installer had not shipped it yet")
        assert_eq(loaded, true, "and the seam must still be usable")
        assert_eq(zones, 1, "and zones must still load from disk")
    end,

    -- Invariant K, one layer in from where W5 guarded it. They seed
    -- persistenceHealthy and zoneStoreHealthy to null on a cold bridge, because
    -- "we have not heard from the server" must not render as "healthy". A server
    -- that has never attempted a write knows exactly as little, so it must not
    -- assert true either -- doing so would overwrite their null on the first push
    -- and rebuild the confusion one hop earlier.
    --
    -- The payload builder is a local inside server.run and is not reachable, so
    -- this covers the rule the field is emitted by rather than the assembly.
    ["an unwritten health flag is unknown, not healthy"] = function(assert_eq)
        local server, T, restore = freshServer(nil, nil)
        local unset = T.state.zoneStoreHealthy
        restore()

        assert_eq(unset, nil, "precondition: nothing has been written yet")
        -- The rule the payload applies. Emitting `x ~= false` for a nil value
        -- yields true, which is the bug this replaced.
        assert_eq(unset ~= false, true,
            "documents the trap: the old expression reported an untouched server "
            .. "as healthy, which is why the field is now omitted while nil")
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

    -- Wall-clock scheduling for periodic work.
    --
    -- Timers that re-arm only inside their own handler are a single point of
    -- failure: CC drops events once the 256-slot queue overflows, and one lost
    -- tick kills that task until reboot. That is how RS storage sync died
    -- minutes after every server start -- measured live at 3.8 hours stale
    -- while the server was otherwise pushing normally.
    --
    -- The run loop's callers are inside a closure and unreachable, so what is
    -- pinned here is the seconds-vs-milliseconds boundary: `now`/`lastRun` are
    -- epoch ms, `intervalSec` is seconds. Dropping the *1000 turns a 30-second
    -- poll into a 30-millisecond one, which looks like working code.
    ["isDue treats the interval as seconds against millisecond clocks"] = function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        local isDue = T.isDue
        restore()

        assert_eq(isDue(1000000, 1000000, 30), false, "no time passed: not due")
        assert_eq(isDue(1029999, 1000000, 30), false,
            "29.999s after the last run a 30s task is not due -- if this passes, "
            .. "the interval is being read as milliseconds and the task runs ~1000x too often")
        assert_eq(isDue(1030000, 1000000, 30), true,  "exactly 30s is due")
        assert_eq(isDue(1030001, 1000000, 30), true,  "past 30s is due")
    end,

    -- The fallback exists precisely for the case where the timer never fires
    -- again, so a task that has never run must become due on its own.
    ["a task whose timer never fired still becomes due"] = function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        local isDue = T.isDue
        restore()

        -- lastRun still at its init value, clock well past the interval.
        assert_eq(isDue(500000, 0, 30), true,
            "a periodic task must not depend on its timer event ever arriving")
    end,
}
