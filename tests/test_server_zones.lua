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

    -- Auto-respawn: a zone with sectors left must not stop being worked because
    -- the job covering it failed.
    --
    -- This crashed in-world on 2026-09-04, caught during an 8-minute watch:
    -- "Handler [JOB_FAILED]: attempt to index global 'server' (a nil value)".
    -- jobQueue.fail calls server.submitJob roughly a thousand lines above where
    -- `local server` was declared, so the name compiled to a global lookup and
    -- the call threw. The handler is pcall'd, so it was caught and logged --
    -- and everything after that line was skipped: the finished zone was never
    -- cleared from state.miningZones and saveJobs() never ran.
    --
    -- Drives the real handler rather than jobQueue.fail directly, so the pcall
    -- that hid this in production is in the path the test exercises too.
    ["a failed mine job respawns a replacement for its unfinished zone"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)

        T.state.jobs["job_0100"] = {
            id       = "job_0100",
            type     = proto.JOB.MINE,
            status   = "IN_PROGRESS",
            assignedTo = "node_1",
            priority = 5,
            params   = { x1 = 0, z1 = 0, x2 = 32, z2 = 32 },
            -- jobQueue._hist appends to this on every transition; a job built
            -- without it fails inside the history write, before reaching
            -- anything this test is about.
            history  = {},
        }
        T.state.miningZones["job_0100"] = {
            persistentKey = "0,0,32,32",
            pending = { { 0, 0 }, { 32, 0 } },   -- two sectors still to mine
        }
        local before = 0
        for _ in pairs(T.state.jobs) do before = before + 1 end

        -- Non-recoverable, so the job lands in FAILED rather than back in
        -- PENDING -- the auto-respawn only runs on a permanent failure.
        T.handlers[proto.MSG.JOB_FAILED]({
            from = "node_1", type = proto.MSG.JOB_FAILED,
            payload = { jobId = "job_0100", reason = "test", recoverable = false },
        })

        local after, replacement = 0, nil
        for id, j in pairs(T.state.jobs) do
            after = after + 1
            if id ~= "job_0100" and j.type == proto.JOB.MINE
               and j.params and j.params.sharedZoneKey == "0,0,32,32" then
                replacement = j
            end
        end
        local zoneCleared = T.state.miningZones["job_0100"] == nil
        local failedStatus = T.state.jobs["job_0100"].status
        restore()

        assert_eq(failedStatus, "FAILED",
            "precondition: the job must actually have failed permanently")
        assert_eq(before, 1, "precondition: exactly one job before the failure")
        assert_eq(replacement ~= nil, true,
            "a zone with sectors remaining must get a replacement job, or it "
            .. "silently stops being mined")
        assert_eq(after, 2, "exactly one replacement, not several")
        -- The tail of jobQueue.fail. Before the fix the throw skipped both of
        -- these, which is the damage the caught-and-logged error concealed.
        assert_eq(zoneCleared, true,
            "the finished zone must be cleared -- if this fails, the respawn "
            .. "threw and everything after it was skipped")
    end,

    -- A bare re-registration must NOT clear a dispatch hold.
    --
    -- Observed 2026-09-04: every turtle re-registered roughly every 24 seconds
    -- without rebooting (heartbeat ACKs are being lost somewhere). node_119 was
    -- benched for 600s for holding an outstanding chunk loader, cleared its own
    -- bench on the next re-registration, and -- being full of fuel, which sorts
    -- it first for dispatch -- was offered work ahead of every healthy miner. It
    -- destroyed two of the operator's four mine jobs, four seconds apart each.
    ["a re-registration from a turtle the server still sees does not clear its bench"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        local id = "node_777"

        T.registry.register(id, proto.ROLE.MINER, 100000, 100000, { x = 0, y = 64, z = 0 }, false)
        local t = T.state.registry[id]
        t.dispatchBlockedUntil = 9999999999999
        t.dispatchBlockReason  = "loader_outstanding at 1,2,3"

        assert_eq(t.online, true, "precondition: the turtle is online after registering")

        -- The storm case: it never went anywhere, it just said hello again.
        T.registry.register(id, proto.ROLE.MINER, 100000, 100000, { x = 0, y = 64, z = 0 }, false)
        local heldAfterStorm = T.state.registry[id].dispatchBlockedUntil

        -- The real-reboot case: the server had lost it first.
        T.state.registry[id].online = false
        T.registry.register(id, proto.ROLE.MINER, 100000, 100000, { x = 0, y = 64, z = 0 }, false)
        local heldAfterReboot = T.state.registry[id].dispatchBlockedUntil
        restore()

        assert_eq(heldAfterStorm ~= nil, true,
            "a re-registration from a turtle that never went offline must not "
            .. "clear the hold — that is what let one broken miner eat the queue")
        assert_eq(heldAfterReboot, nil,
            "but a turtle the server had actually lost must come back "
            .. "dispatchable, or a hand-fixed reboot waits out the full 600s")
    end,

    -- Disk exhaustion, observed live 2026-09-06: the server's 1 MB disk down to
    -- 36,081 bytes free after a mining job. jobs.dat.bak was 326,661 bytes -- a
    -- third of the disk -- while jobs.dat was 35. Two causes, both here.
    ["job history is bounded so a long job cannot fill the disk"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        T.state.jobs["job_0200"] = {
            id = "job_0200", type = proto.JOB.MINE, status = "IN_PROGRESS",
            priority = 5, params = {}, history = {},
        }
        -- A miner working a 20-sector zone sends this many STATUS_UPDATEs and
        -- more; every one appended an entry that was never trimmed.
        for i = 1, 300 do
            T.jobQueue._hist("job_0200", "progress", "sector " .. i)
        end
        local h = T.state.jobs["job_0200"].history
        local n, newest, oldest = #h, h[#h].detail, h[1].detail
        restore()

        assert_eq(n <= 40, true,
            "history must be capped, or jobs.dat grows for as long as the job "
            .. "runs — got " .. n .. " entries")
        assert_eq(newest, "sector 300",
            "the most recent entry must survive: it is what explains where the "
            .. "job is now")
        assert_eq(oldest ~= "sector 1", true,
            "and the OLDEST must be the one dropped, not the newest")
    end,

    ["a completed save drops its backup instead of keeping a second full copy"] =
    function(assert_eq)
        local server, T, restore, c = freshServer(fakeKV({}), nil)
        T.state.jobs["job_0201"] = {
            id = "job_0201", type = proto.JOB.MINE, status = "IN_PROGRESS",
            priority = 5, params = { x1 = 0, z1 = 0, x2 = 32, z2 = 32 },
            history = {},
        }
        -- Twice: the first write creates jobs.dat, the second moves it aside to
        -- jobs.dat.bak and writes a new one. Only after the second does a backup
        -- exist to be dropped, so one save would pass without testing anything.
        T.saveJobs()
        local afterFirst = c.files["jobs.dat"] ~= nil
        T.saveJobs()
        local live = c.files["jobs.dat"]
        local bak  = c.files["jobs.dat.bak"]
        restore()

        assert_eq(afterFirst, true, "precondition: the first save must land")
        assert_eq(live ~= nil, true, "the live file must exist after the save")
        assert_eq(bak, nil,
            "the backup protects the write, not the file — keeping it costs a "
            .. "second full copy for as long as the file exists, which is how "
            .. "one file took 37% of the disk")
    end,

    -- The other half of the same change: the backup must SURVIVE when the
    -- replacement did not land, which is the only case it exists for.
    ["a save whose replacement never lands keeps its backup"] =
    function(assert_eq)
        local server, T, restore, c = freshServer(fakeKV({}), nil)
        c.files["jobs.dat"]     = "live"
        c.files["jobs.dat.bak"] = "previous"
        T.dropBackupAfterVerify("jobs.dat")
        local keptWhenPresent = c.files["jobs.dat.bak"]

        c.files["jobs.dat"] = nil          -- the move did not land
        c.files["jobs.dat.bak"] = "previous"
        T.dropBackupAfterVerify("jobs.dat")
        local keptWhenMissing = c.files["jobs.dat.bak"]
        restore()

        assert_eq(keptWhenPresent, nil,
            "precondition: a verified file does drop its backup")
        assert_eq(keptWhenMissing, "previous",
            "but a missing replacement must keep it — that crash window is the "
            .. "entire reason the backup exists")
    end,

    -- The same leak in the third save, which nothing covered. saveMiningZones
    -- moved active_zones.dat aside and never dropped it, so live zones cost the
    -- disk twice: 183 KB of backup behind 183 KB of zones. The job-backup test
    -- above could not catch it -- it only ever drives saveJobs.
    ["a live-zone save drops its backup too"] =
    function(assert_eq)
        local server, T, restore, c = freshServer(fakeKV({}), nil)
        T.state.miningZones["job_0300"] = {
            total = 12, done = 3, oreFound = { iron = 40 }, oreMined = { iron = 10 },
        }
        -- Twice, for the same reason as the job test: only the second save has
        -- a previous file to move aside, so one save proves nothing.
        T.saveMiningZones()
        local afterFirst = c.files["active_zones.dat"] ~= nil
        T.saveMiningZones()
        local live = c.files["active_zones.dat"]
        local bak  = c.files["active_zones.dat.bak"]
        restore()

        assert_eq(afterFirst, true, "precondition: the first save must land")
        assert_eq(live ~= nil, true, "the live file must exist after the save")
        assert_eq(bak, nil,
            "the backup must be dropped once the replacement is in place -- "
            .. "keeping it is a permanent second copy of every live zone, which "
            .. "is what filled the server disk after the 4-miner job")
    end,

    -- Knowing what is actually running.
    --
    -- Twice now a machine has run different code from the source being read: an
    -- OTA where protocol.lua landed and the 211 KB server did not, and a fleet
    -- updated while the server was not. Both were diagnosed for hours against
    -- the wrong source. A node's reported proto.VERSION is the only evidence
    -- available, and nothing was looking at it.
    ["a node reporting a different version is counted, not just stored"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        T.registry.register("node_a", proto.ROLE.MINER, 100, 100, { x=0, y=64, z=0 }, false)
        T.registry.register("node_b", proto.ROLE.MINER, 100, 100, { x=0, y=64, z=0 }, false)

        T.registry.update("node_a", proto.STATUS.IDLE, 100, nil, nil, proto.VERSION)
        local agreeing = T.registry.versionMismatchCount()

        T.registry.update("node_b", proto.STATUS.IDLE, 100, nil, nil, "1.0.0-ancient")
        local mismatched = T.registry.versionMismatchCount()

        -- A node that has never reported one is unknown, not mismatched --
        -- counting it would make the number meaningless at every boot.
        T.state.registry["node_a"].version = nil
        local silentNotCounted = T.registry.versionMismatchCount()
        restore()

        assert_eq(agreeing, 0, "a node on the server's own version is not a mismatch")
        assert_eq(mismatched, 1, "a node on different code must be counted")
        assert_eq(silentNotCounted, 1,
            "a node that has not reported a version yet is unknown, not wrong")
    end,

    -- SOURCE-ONLY, weaker: the guard lives inside server.run's event loop, which
    -- the harness cannot enter.
    ["a failed update must not reboot the server (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = assert(io.open("central_server.lua", "r"))
        local src = f:read("*a")
        f:close()

        local runAt = src:find("if fs%.exists%(\"updater%.lua\"%) then shell%.run%(\"updater\"%) end")
        assert_eq(runAt ~= nil, true, "the server's updater invocation moved or vanished")

        -- Bound the window to the update block so a reboot elsewhere in the file
        -- cannot satisfy this.
        -- 3000, not 2200: the explanatory comment between the two is ~1500
        -- characters, so a tighter window ended before the reboot and the
        -- ordering assertion failed on the window rather than on the code.
        local tail = src:sub(runAt, runAt + 3000)
        local guardAt  = tail:find("if fs%.exists%(\"update_failed%.txt\"%) then")
        local rebootAt = guardAt and tail:find("os%.reboot%(%)", guardAt)
        assert_eq(guardAt ~= nil, true,
            "the reboot must be gated on the updater's own failure marker — the "
            .. "updater already decides not to reboot, and this caller used to "
            .. "override it and boot into a half-applied update")
        assert_eq(rebootAt ~= nil and guardAt < rebootAt, true,
            "the guard must come BEFORE the reboot, or it does nothing")
    end,

    -- ─── Continuous fleet log: the delta push (Phase 2) ─────────────────────
    --
    -- The server used to ship a fixed window every 3s -- the last 100 of its own
    -- lines and the last 10 per node -- whether or not the bridge had already
    -- written them. Two costs: a turtle printing more than 10 lines between
    -- pushes lost the rest before the bridge ever saw them, and the same lines
    -- were re-serialised for ever. That serialisation time is exactly how long
    -- the server is deaf to the radio.
    ["an acknowledged source contributes nothing to the next push"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        local ring = {
            { ts = 1, msg = "a", seq = 1, bootId = 100 },
            { ts = 2, msg = "b", seq = 2, bootId = 100 },
            { ts = 3, msg = "c", seq = 3, bootId = 100 },
        }
        local before = #T.logSelect(ring, "node_1", 10)
        T.state.logAck["node_1"] = { bootId = 100, seq = 3 }
        local after = T.logSelect(ring, "node_1", 10)
        T.state.logAck["node_1"] = { bootId = 100, seq = 1 }
        local partial = T.logSelect(ring, "node_1", 10)
        restore()

        assert_eq(before, 3, "precondition: with no ack, everything is unsent")
        assert_eq(#after, 0,
            "a fully acknowledged source must cost nothing — an idle fleet "
            .. "re-sending its window is the payload that made the server deaf")
        assert_eq(#partial, 2, "only entries past the ack may be sent")
        assert_eq(partial[1].msg, "b", "and they must start just after it")
    end,

    ["a later boot outranks a higher sequence from an earlier one"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        -- A turtle ring lives on the SERVER and survives the turtle rebooting,
        -- so one window legitimately straddles two boots: high seq from the old
        -- boot, then seq restarting at 1 under a new bootId. Comparing seq alone
        -- would discard everything the turtle has said since it came back.
        local ring = {
            { ts = 1, msg = "old-900", seq = 900, bootId = 100 },
            { ts = 2, msg = "new-1",   seq = 1,   bootId = 200 },
            { ts = 3, msg = "new-2",   seq = 2,   bootId = 200 },
        }
        T.state.logAck["node_1"] = { bootId = 100, seq = 900 }
        local out = T.logSelect(ring, "node_1", 10)
        restore()

        assert_eq(#out, 2, "the new boot's lines must survive a stale ack")
        assert_eq(out[1].msg, "new-1", "and start at the new boot's first line")
    end,

    ["a source with no sequence numbers keeps the old fixed window"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        -- The fleet runs mixed versions during every rollout. An entry with no
        -- seq can never be acknowledged, so treating "no seq" as "unsent" would
        -- re-send that node's whole window on every push, for ever.
        local ring = {}
        for i = 1, 25 do ring[i] = { ts = i, msg = "line " .. i } end
        local out = T.logSelect(ring, "node_old", 10)
        T.state.logAck["node_old"] = { bootId = 0, seq = 999 }
        local stillWindowed = T.logSelect(ring, "node_old", 10)
        restore()

        assert_eq(#out, 10, "a pre-1.9.84 source must keep the fixed window")
        assert_eq(out[1].msg, "line 16", "and it must be the NEWEST 10, not the oldest")
        assert_eq(#stillWindowed, 10,
            "an ack it can never satisfy must not silence it either")
    end,

    ["a backlog is capped so recovery cannot cost more than the outage"] =
    function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        -- The bridge being down for a while leaves everything unacknowledged.
        -- Uncapped, the first push after it returns would be the whole ring --
        -- and buildBridgePayload is synchronous, so that is dead air on the
        -- radio at exactly the moment the fleet needs to be heard.
        local ring = {}
        for i = 1, 500 do ring[i] = { ts = i, msg = "line " .. i, seq = i, bootId = 100 } end
        local out = T.logSelect(ring, "server", 100)
        restore()

        assert_eq(#out, 40, "a backlog must be capped at LOG_PUSH_MAX")
        assert_eq(out[1].msg, "line 1",
            "and drain oldest-first, so nothing is skipped — the rest follow on "
            .. "the next push 3 seconds later")
    end,

    -- A bridge restart must replay, or its log panel stays blank.
    --
    -- The bridge's display buffers die with the process; this server's logAck
    -- does not. Without noticing the restart, the server keeps sending only what
    -- is new and the panel shows nothing until the fleet next speaks -- which on
    -- an idle fleet is a long time. Observed 2026-09-08.
    ["a restarted bridge gets the rings replayed"] = function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)

        -- First sighting: a server that booted alongside a bridge that did not.
        -- Clearing acks we never set would be a no-op with a misleading warning.
        local firstSighting = T.noteBridgeBoot(1000)
        T.state.logAck["server"]  = { bootId = 5, seq = 42 }
        T.state.logAck["node_1"]  = { bootId = 5, seq = 7 }

        local sameBoot = T.noteBridgeBoot(1000)
        local keptAcks = T.state.logAck["server"] ~= nil

        local restarted = T.noteBridgeBoot(2000)
        local clearedAcks = next(T.state.logAck) == nil
        restore()

        assert_eq(firstSighting, false,
            "a first sighting is not a restart — there is nothing to replay")
        assert_eq(sameBoot, false, "an unchanged boot id is a quiet bridge, not a new one")
        assert_eq(keptAcks, true,
            "and must not throw away acks that are still good — that would "
            .. "replay the rings on every single push")
        assert_eq(restarted, true, "a changed boot id is a restart")
        assert_eq(clearedAcks, true,
            "which must clear every ack, so the rings are re-sent and the "
            .. "bridge's panel refills instead of waiting for new activity")
    end,

    ["a malformed bridge boot id is ignored rather than trusted"] = function(assert_eq)
        local server, T, restore = freshServer(fakeKV({}), nil)
        T.noteBridgeBoot(1000)
        T.state.logAck["server"] = { bootId = 5, seq = 42 }
        -- An old bridge sends no bridgeBootId at all, and tonumber(nil) is nil.
        -- Treating that as a change would replay the rings on every push for
        -- ever -- the exact payload cost the delta exists to remove.
        local a = T.noteBridgeBoot(nil)
        local b = T.noteBridgeBoot("not a number")
        local stillAcked = T.state.logAck["server"] ~= nil
        restore()
        assert_eq(a, false, "a missing boot id is not a restart")
        assert_eq(b, false, "nor is a non-numeric one")
        assert_eq(stillAcked, true,
            "an old bridge that never sends one must not trigger a replay every "
            .. "3 seconds for ever")
    end,

    -- The server must report its own stalls (SOURCE-ONLY, weaker).
    --
    -- Until 1.9.90 the fleet reported an outage fifteen times and this server
    -- reported it zero times. W1 spent an afternoon on 2026-09-09
    -- reconstructing one from two log sources because of that asymmetry: the
    -- server was the only party that knew and the only one not talking.
    --
    -- The loop lives inside server.run and cannot be entered under this harness,
    -- so what is pinned here is the shape rather than the behaviour.
    ["the server measures and reports its own deaf windows (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = assert(io.open("central_server.lua", "r"))
        local src = f:read("*a")
        f:close()

        local pullAt = src:find("local event, p1, p2, p3, p4 = os%.pullEventRaw%(%)")
        assert_eq(pullAt ~= nil, true, "the event loop moved or vanished")

        -- The window must OPEN after the pull returns. Opening it at the top of
        -- the loop body would include the time blocked in pullEventRaw, which is
        -- time the server is listening -- the opposite of the thing measured.
        local openAt = src:find("local busyStart = os%.epoch", pullAt)
        assert_eq(openAt ~= nil and openAt - pullAt < 400, true,
            "the busy window must open immediately after the event is pulled, "
            .. "or it measures time spent listening as though it were deafness")

        -- And close at the bottom, after the work, before blocking again.
        local closeAt = src:find("local busy = os%.epoch%(\"utc\"%) %- busyStart", openAt)
        assert_eq(closeAt ~= nil and closeAt > openAt, true,
            "the busy window must be closed after the iteration's work")

        assert_eq(src:find("LOOP STALL") ~= nil, true,
            "a stall must produce a line naming itself")
        assert_eq(src:find("slowest step %%s") ~= nil, true,
            "and name the step that caused it — a duration with no attribution "
            .. "is what made the last one take an afternoon")
        -- The message SAYING it names a step is not the same as anything
        -- recording one. Deleting the recorder left the format string intact and
        -- this test green, reporting "-" for every stall for ever.
        assert_eq(src:find("stepMs, stepName = ms, name", 1, true) ~= nil, true,
            "something must actually record the slowest step, or the attribution "
            .. "is a placeholder that never fills in")

        -- A step name is not a cause. W6 found on 2026-09-10 that the
        -- refreshStorage span covers a yielding mod call AND a flat rebuild, and
        -- that rsPollMs measured only the first -- so an idle figure from one
        -- span was compared against a loaded figure from the other. The two
        -- halves behave differently under load, so only a split can be reasoned
        -- about.
        -- Both the format string AND the branch that fills it. Asserting the
        -- literal alone passed with the condition stubbed to false: the text
        -- stayed in the source and no stall ever carried it. Third time this
        -- session an assertion matched a string instead of the logic behind it.
        assert_eq(src:find("listItems %%dms %+ rebuild %%dms") ~= nil, true,
            "a stall naming refreshStorage must break out the yielding call from "
            .. "the flat rebuild — the function name alone cannot say which")
        assert_eq(src:find('stepName == "refreshStorage"', 1, true) ~= nil, true,
            "and the branch that appends it must actually be reachable")
        assert_eq(src:find("lastRsBuildMs = storageTs - buildStart", 1, true) ~= nil, true,
            "and something must measure the rebuild half, or the split is a "
            .. "format string with nothing behind it")
        assert_eq(src:find('rsBuildWorstMs":', 1, true) ~= nil, true,
            "the split must reach /state too, not only the stall line — a number "
            .. "that appears once an hour cannot be compared against anything")
        -- And each step must be wrapped, or there is nothing to record.
        local wrapped = 0
        local at = src:find('timed("', 1, true)
        while at do wrapped = wrapped + 1; at = src:find('timed("', at + 1, true) end
        assert_eq(wrapped >= 8, true,
            "the loop's expensive steps must be wrapped for timing — got "
            .. wrapped .. " call sites")

        -- Emitted unconditionally, for the reason that is now four-for-four in
        -- this project: an absent stall line means either "nothing stalled" or
        -- "the instrument broke", and those must not look alike.
        -- Emitted unconditionally, for the reason that is now four-for-four in
        -- this project: an absent stall line means either "nothing stalled" or
        -- "the instrument broke", and those must not look alike.
        --
        -- Plain finds and offsets throughout: no patterns, no escapes. Two
        -- earlier attempts put a newline escape inside a Lua pattern here
        -- and it collapsed into a real line break, breaking the suite.
        local rollupAt = src:find("loop rollup: iters=", 1, true)
        assert_eq(rollupAt ~= nil, true, "a periodic rollup must exist")
        local before = src:sub(math.max(1, rollupAt - 160), rollupAt)
        assert_eq(before:find("logInfo", 1, true) ~= nil, true,
            "the rollup must be logged unconditionally as INFO, not raised only "
            .. "when something was slow")
        -- It carries its denominator: "slow=0" alone is a shrug, "slow=0
        -- iters=4200" is a result.
        local rollupLine = src:sub(rollupAt, rollupAt + 200)
        assert_eq(rollupLine:find("slow=", 1, true) ~= nil, true,
            "the rollup must carry the slow count alongside the iteration count")
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
