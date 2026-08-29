-- The server's job-recovery sweep: does a miner that finished its job ever get
-- freed when the JOB_COMPLETE that says so is lost?
--
-- Observed 2026-08-22 (W1): node_118 mined all 15 sectors of job_0726, flew
-- home, docked, and then sat at its own bay for FOUR HOURS -- full tank,
-- heartbeating normally, status stuck at RETURNING, job still IN_PROGRESS --
-- while the log repeated "Dispatch hold: job_0723 needs MINER (idle=0)" once a
-- minute. Two /state snapshots 991 seconds apart were byte-identical. A stable
-- deadlock, not slow recovery.
--
-- sendComplete is fire-and-forget, so losing it is expected and survivable by
-- design: jobQueue.checkGhosts' idle-stuck arm exists for exactly this. It never
-- fired, because registry.update's stale-IDLE guard erases the IDLE the arm is
-- waiting to see -- the recovery condition is destroyed before the recovery code
-- can read it.
--
-- This is the first suite to load central_server.lua at all. See the test seam
-- at the bottom of that file for why it could not be done before.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

-- A server with one MINER registered and one MINE job IN_PROGRESS assigned to
-- it -- the state node_118 was in the moment its JOB_COMPLETE went missing.
local function serverWithMinerOnJob(stubOpts)
    local c = stub.install(stubOpts or {})
    local savedEpoch = os.epoch
    local clock = 1000000            -- ms; advanced by the tests
    os.epoch = function() return clock end

    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local server = require("central_server")
    local T = server._test

    -- server.run() would normally find this. Handlers that reply -- SECTOR_DONE
    -- dispatches the next sector -- reach proto.send, which indexes the modem,
    -- so without one the test fails inside the transport rather than on its
    -- assertion. Transmissions are recorded so a test can assert on them.
    T.sent = {}
    T.state.modem = {
        isOpen   = function() return true end,
        open     = function() end,
        transmit = function(ch, reply, body)
            T.sent[#T.sent + 1] = { channel = ch, body = body }
        end,
    }

    T.state.registry["node_118"] = {
        id       = "node_118",
        role     = proto.ROLE.MINER,
        status   = proto.STATUS.WORKING,
        jobId    = "job_0726",
        fuel     = 100000,
        online   = true,
        lastSeen = clock,
        position = { x = 158, y = 67, z = -2810 },
    }
    -- Shape mirrors what jobQueue.add builds, history included: jobQueue._hist
    -- does table.insert(job.history, ...) with no guard, so a fixture missing it
    -- fails inside the code under test rather than in the assertion.
    T.state.jobs["job_0726"] = {
        id         = "job_0726",
        type       = proto.JOB.MINE,
        status     = "IN_PROGRESS",
        assignedTo = "node_118",
        params     = {},
        priority   = 5,
        history    = {},
        createdAt  = clock,
        retries    = 0,
    }

    local restore = function()
        os.epoch = savedEpoch
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
    end
    -- advance(sec) moves the clock so the sweep's debounce windows can elapse.
    local advance = function(sec) clock = clock + (sec * 1000) end
    return server, T, advance, restore, c
end

-- One heartbeat exactly as a finished miner sends it: its own state, which is
-- IDLE with no job, because from its point of view the work is done.
local function heartbeatAsFinished(T)
    T.registry.update("node_118", proto.STATUS.IDLE, 100000,
                      { x = 158, y = 67, z = -2810 }, nil, proto.VERSION)
end

return {
    -- The precondition, asserted so the test below cannot pass for the wrong
    -- reason. The guard is deliberate and stays: it is what stops a stale IDLE
    -- (sent before JOB_ASSIGN lands) re-opening a turtle for a second dispatch.
    ["the stale-IDLE guard keeps the server's own view of an active job"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        heartbeatAsFinished(T)
        local t = T.state.registry["node_118"]
        local status, jobId = t.status, t.jobId
        restore()
        assert_eq(status ~= proto.STATUS.IDLE, true,
            "the guard must still suppress IDLE while the job is IN_PROGRESS")
        assert_eq(jobId, "job_0726", "and must keep the job pinned to the turtle")
    end,

    -- The defect. A miner that has been reporting IDLE for four hours is done,
    -- whatever the job table still says, and the sweep must eventually act on it.
    ["a finished miner whose JOB_COMPLETE was lost is recovered, not stranded"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()

        -- Heartbeat, wait past the 60s idle-stuck debounce, heartbeat again --
        -- exactly what node_118 did for four hours.
        heartbeatAsFinished(T)
        jobQueue.checkGhosts()
        advance(120)
        heartbeatAsFinished(T)
        jobQueue.checkGhosts()

        local job = T.state.jobs["job_0726"]
        local status = job and job.status
        restore()

        assert_eq(status ~= "IN_PROGRESS", true,
            "the job must not still be IN_PROGRESS after two minutes of IDLE "
            .. "heartbeats -- this is the four-hour deadlock")
    end,

    -- ─── Terminal job outcomes (Invariant P7) ───────────────────────────────
    --
    -- /state carries only PENDING/ASSIGNED/IN_PROGRESS jobs, and that filter is
    -- right -- serialising every past job grows O(n) with mining cycles and
    -- stalls the event loop. Its side effect was that a FAILED job vanished
    -- entirely, taking the reason with it, leaving "no jobs running" as the only
    -- visible symptom. Three incidents were read as "dispatch is broken" when one
    -- turtle was refusing work.
    ["a permanently failed job keeps its reason"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local job = T.state.jobs["job_0726"]
        job.retries = 99                       -- past MAX_JOB_RETRIES: terminal
        jobQueue.fail("job_0726", "loader_outstanding", false)

        local ring   = T.state.recentFailures
        local last   = ring[#ring]
        local onJob  = job.failReason
        restore()

        assert_eq(job.status, "FAILED", "precondition: the job must be terminal")
        assert_eq(onJob, "loader_outstanding", "the reason must survive on the job")
        assert_eq(last ~= nil and last.reason, "loader_outstanding",
            "and reach /state through the failure ring")
        assert_eq(last.jobId, "job_0726")
        assert_eq(last.outcome, "FAILED")
    end,

    -- The bound is what lets this coexist with the filter it works around. An
    -- unbounded list would reintroduce exactly the O(n) growth that made
    -- serialising all jobs stall the event loop in the first place.
    ["the failure ring stays bounded however long the server runs"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        for i = 1, 60 do
            T.state.jobs["j" .. i] = {
                id = "j" .. i, type = proto.JOB.MINE, status = "IN_PROGRESS",
                params = {}, priority = 5, history = {}, retries = 99,
            }
            jobQueue.fail("j" .. i, "reason_" .. i, false)
        end
        local n     = #T.state.recentFailures
        local newest = T.state.recentFailures[n]
        restore()

        assert_eq(n <= 20, true,
            string.format("the ring must stay bounded, got %d entries", n))
        assert_eq(newest.reason, "reason_60",
            "and it must keep the NEWEST failures, not the first twenty")
    end,

    -- ─── Ore accounting ─────────────────────────────────────────────────────
    --
    -- surveyMode gates only the digging, so every depth level is scanned and
    -- reported twice. oreFound accumulated both, came out at ~2x reality, and
    -- every zone read as "mined about half of what it found" however well the
    -- mining had gone. The operator saw 50% and reasonably concluded the miners
    -- were losing half the ore.
    ["a sector scanned in both passes is not counted twice"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = { oreFound = {}, oreMined = {}, phase = "MINE" }
        T.state.miningZones["job_0726"] = zone

        local function scan(sy, found, mined)
            T.handlers[proto.MSG.SECTOR_SCAN]({ from = "node_118", payload = {
                jobId = "job_0726", sectorX = 100, sectorZ = 200, scanY = sy,
                foundOres = found, minedOres = mined,
            } })
        end

        -- SURVEY sees 100 iron at one depth and mines nothing.
        scan(56, { ["minecraft:iron_ore"] = 100 }, nil)
        local afterSurvey = zone.oreFound["minecraft:iron_ore"]

        -- MINE revisits the same depth, reports the same find, and takes it all.
        scan(56, { ["minecraft:iron_ore"] = 100 }, { ["minecraft:iron_ore"] = 100 })
        restore()

        assert_eq(afterSurvey, 100, "precondition: the survey pass must be counted once")
        assert_eq(zone.oreFound["minecraft:iron_ore"], 100,
            "the second report of the same depth is a fresher view, not more ore")
        assert_eq(zone.oreMined["minecraft:iron_ore"], 100, "and all of it was mined")
    end,

    -- The case W1 flagged as the discriminator, and they are right that a naive
    -- fix gets it wrong: plain replacement gives 60, plain accumulation gives 160.
    ["a retried sector counts what was there, not what is left"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = { oreFound = {}, oreMined = {}, phase = "MINE" }
        T.state.miningZones["job_0726"] = zone
        local function scan(found, mined)
            T.handlers[proto.MSG.SECTOR_SCAN]({ from = "node_118", payload = {
                jobId = "job_0726", sectorX = 1, sectorZ = 2, scanY = 40,
                foundOres = found, minedOres = mined,
            } })
        end

        scan({ ["minecraft:gold_ore"] = 100 }, { ["minecraft:gold_ore"] = 40 })
        scan({ ["minecraft:gold_ore"] = 60 },  { ["minecraft:gold_ore"] = 60 })
        restore()

        assert_eq(zone.oreFound["minecraft:gold_ore"], 100,
            "100 were there: 40 taken on the first attempt, 60 on the second")
        assert_eq(zone.oreMined["minecraft:gold_ore"], 100, "and 100 were mined")
    end,

    -- The rescan case, which used to need a wholesale rewrite of oreFound and now
    -- falls out of the same rule. A level held 100, the miner took 40 and left 60,
    -- and the rescan pass sees those 60 still in the ground: 40 + 60 = 100 were
    -- there. This is the only figure the old accounting got right, and only
    -- because RESCAN was special-cased.
    ["a rescan of a partly mined level still reports what was there"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = { oreFound = {}, oreMined = {}, phase = "MINE" }
        T.state.miningZones["job_0726"] = zone
        local function scan(found, mined)
            T.handlers[proto.MSG.SECTOR_SCAN]({ from = "node_118", payload = {
                jobId = "job_0726", sectorX = 9, sectorZ = 9, scanY = 12,
                foundOres = found, minedOres = mined,
            } })
        end

        scan({ ["minecraft:redstone_ore"] = 100 }, { ["minecraft:redstone_ore"] = 40 })
        zone.phase = "RESCAN"
        scan({ ["minecraft:redstone_ore"] = 60 }, nil)   -- 60 still in the ground
        restore()

        assert_eq(zone.oreFound["minecraft:redstone_ore"], 100,
            "40 taken plus 60 left is 100 that were there")
        assert_eq(zone.oreMined["minecraft:redstone_ore"], 40,
            "and a rescan mines nothing, so mined is unchanged")
    end,

    -- The correction to the design's own keying. foundOres is reported once per
    -- DEPTH LEVEL, so keying by sector alone would keep only the last level's
    -- find -- turning a double count into a large undercount.
    ["depth levels within one sector each count"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = { oreFound = {}, oreMined = {}, phase = "MINE" }
        T.state.miningZones["job_0726"] = zone
        for _, sy in ipairs({ 56, 40, 24 }) do
            T.handlers[proto.MSG.SECTOR_SCAN]({ from = "node_118", payload = {
                jobId = "job_0726", sectorX = 7, sectorZ = 7, scanY = sy,
                foundOres = { ["minecraft:diamond_ore"] = 10 },
            } })
        end
        restore()
        assert_eq(zone.oreFound["minecraft:diamond_ore"], 30,
            "three depth levels of one sector are three finds, not one")
    end,

    -- minedOres arrives in batches of 25 within a single depth level
    -- (ore_turtle's SCAN_BATCH), so mined must accumulate where seen replaces.
    ["batched mined reports for one depth accumulate"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = { oreFound = {}, oreMined = {}, phase = "MINE" }
        T.state.miningZones["job_0726"] = zone
        T.handlers[proto.MSG.SECTOR_SCAN]({ from = "node_118", payload = {
            jobId = "job_0726", sectorX = 3, sectorZ = 3, scanY = 30,
            foundOres = { ["minecraft:coal_ore"] = 50 },
        } })
        for _ = 1, 2 do
            T.handlers[proto.MSG.SECTOR_SCAN]({ from = "node_118", payload = {
                jobId = "job_0726", sectorX = 3, sectorZ = 3, scanY = 30,
                minedOres = { ["minecraft:coal_ore"] = 25 },
            } })
        end
        restore()
        assert_eq(zone.oreMined["minecraft:coal_ore"], 50,
            "two batches of 25 are 50 mined, not 25")
        assert_eq(zone.oreFound["minecraft:coal_ore"], 50,
            "and the find is still 50, not 50 + the batches")
    end,

    -- ─── Phase ETA ──────────────────────────────────────────────────────────
    --
    -- The old estimate divided remaining work by a rate averaged over a period
    -- that included the entire SURVEY phase, where nothing is mined -- and its
    -- numerator used the doubled `found`. Wrong twice, both the same direction.
    --
    -- A sector's duration is assignment -> SECTOR_DONE. This drives the real
    -- handlers so the assignedAt stamp and the fold are exercised together; a
    -- test that called recordSectorTime directly would not prove the stamp is
    -- ever written.
    ["the phase ETA is measured from real sector durations"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = {
            oreFound = {}, oreMined = {}, phase = "MINE",
            total = 10, done = 0, doneKeys = {},
            pending = {}, lastAssignments = {},
        }
        T.state.miningZones["job_0726"] = zone

        -- Two sectors, 100 s each, one miner. Eight left at 100 s => 800.
        for i = 1, 2 do
            zone.lastAssignments["node_118"] =
                { x = i, z = 0, isSurvey = false, assignedAt = 1000000 + (i - 1) * 100000 }
            advance(100)
            T.handlers[proto.MSG.SECTOR_DONE]({ from = "node_118", payload = {
                jobId = "job_0726", sectorX = i, sectorZ = 0,
            } })
        end

        local samples = zone.sectorTimes and zone.sectorTimes["MINE"]
        zone.done = 2
        local eta = T.phaseEta(zone, 1)
        restore()

        assert_eq(samples ~= nil and samples.n, 2,
            "precondition: two durations must actually have been folded in")
        assert_eq(eta, 800, "8 sectors left at a 100s mean, one miner")
    end,

    -- Four miners share a zone; throughput is fleet-wide sectors-per-second, so
    -- a per-miner mean overstates by 4x.
    ["the ETA divides remaining work across the active miners"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = {
            phase = "MINE", total = 10, done = 2,
            sectorTimes = { MINE = { n = 2, total = 200 } },
        }
        local one  = T.phaseEta(zone, 1)
        local four = T.phaseEta(zone, 4)
        restore()
        assert_eq(one, 800)
        assert_eq(four, 200, "four miners finish the same eight sectors in a quarter the time")
    end,

    -- A wrong number is worse than no number: that is the failure being fixed,
    -- and a one-sample mean would be the same mistake in a smaller form.
    ["no ETA is reported below two samples"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local none = T.phaseEta({ phase = "MINE", total = 10, done = 0 }, 1)
        local one  = T.phaseEta({ phase = "MINE", total = 10, done = 1,
                                  sectorTimes = { MINE = { n = 1, total = 100 } } }, 1)
        restore()
        assert_eq(none, nil, "no samples means no estimate")
        assert_eq(one,  nil, "and one sample is still not an estimate")
    end,

    -- MINE timings say nothing about RESCAN. A phase change starts with no
    -- samples, so the ETA is correctly nil until two land in the new phase.
    ["a phase change does not inherit the previous phase's mean"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = {
            phase = "MINE", total = 10, done = 2,
            sectorTimes = { MINE = { n = 5, total = 500 } },
        }
        local during = T.phaseEta(zone, 1)
        zone.phase = "RESCAN"
        local after = T.phaseEta(zone, 1)
        restore()
        assert_eq(during, 800, "precondition: the MINE phase has a usable mean")
        assert_eq(after, nil, "RESCAN must not borrow it")
    end,

    -- A sector assigned before this shipped, or after a restart that lost the
    -- ledger, carries no assignedAt. Counting it as zero would drag the mean
    -- toward an ETA that is confidently too short.
    ["a sector with no assignedAt is skipped, not counted as zero"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        local zone = {
            oreFound = {}, oreMined = {}, phase = "MINE",
            total = 10, done = 0, doneKeys = {}, pending = {},
            lastAssignments = { node_118 = { x = 1, z = 0 } },   -- no assignedAt
        }
        T.state.miningZones["job_0726"] = zone
        advance(100)
        T.handlers[proto.MSG.SECTOR_DONE]({ from = "node_118", payload = {
            jobId = "job_0726", sectorX = 1, sectorZ = 0,
        } })
        local samples = zone.sectorTimes and zone.sectorTimes["MINE"]
        restore()
        assert_eq(samples, nil, "an unstamped sector contributes no sample at all")
    end,

    -- ─── Persistence ────────────────────────────────────────────────────────
    --
    -- saveJobs kept a backup so "a crash between delete and move can't destroy
    -- both copies simultaneously". On a full disk the sequence did precisely
    -- what the backup was written to prevent: the .bak was DELETED, the fs.copy
    -- meant to recreate it needed room for a second full copy and failed, and
    -- nothing after it ran. Every save then left jobs.dat stale, no .bak at all,
    -- and the data stranded in jobs.tmp.
    --
    -- The invariant is not "the save succeeds" -- on a full disk it cannot. It is
    -- that a failed save NEVER leaves the server with neither copy, because
    -- loadJobs falls back to .bak only when jobs.dat is missing.
    -- The invariant, stated on the state the operator actually cares about: after
    -- a save that cannot complete, there must still be a backup to fall back to.
    -- loadJobs consults .bak ONLY when jobs.dat is missing, and the old sequence
    -- deleted .bak first and then failed to recreate it -- so the safety net was
    -- destroyed by the exact failure it was written to survive.
    ["a failing save leaves the backup intact"] = function(assert_eq)
        local server, T, advance, restore, c = serverWithMinerOnJob({ freeSpace = 200000 })

        -- First save writes jobs.dat while there is no backup yet, so the backup
        -- ends up holding a SMALL early snapshot. That asymmetry is what makes
        -- the fs.copy reachable: refunding a small .bak does not free enough to
        -- copy a much larger jobs.dat.
        pcall(jobQueue.add, proto.JOB.MINE, { note = "first" }, 5)
        for i = 1, 30 do
            pcall(jobQueue.add, proto.JOB.MINE, { note = string.rep("x", 200) }, 5)
        end
        local hadBackup = fs.exists("jobs.dat.bak")
        local liveSize  = #c.files["jobs.dat"]

        -- Leave room for the temp write and nothing more, so the sequence gets
        -- past writing jobs.tmp, deletes the backup, and then cannot copy.
        -- The window is narrow and real: free must be at least the new temp
        -- file, yet less than that plus what refunding the small backup returns.
        -- Below it the temp write fails first and nothing is damaged; above it
        -- the copy fits. 600 bytes clears one more job's worth of growth while
        -- staying inside the gap between the small backup and the large live file.
        local pad = fs.open("ballast", "w")
        pad.write(string.rep("b", fs.getFreeSpace() - liveSize - 600))
        pcall(pad.close)

        pcall(jobQueue.add, proto.JOB.MINE, { note = "final" }, 5)

        local stillHaveBackup = fs.exists("jobs.dat.bak")
        local stillHaveLive   = fs.exists("jobs.dat")
        restore()

        assert_eq(hadBackup, true, "precondition: a backup must have been established")
        assert_eq(stillHaveBackup or stillHaveLive, true,
            "a failed save must leave something to restore from")
        assert_eq(stillHaveBackup, true,
            "and specifically the BACKUP must survive — it is deleted before its "
            .. "replacement is secured, so a failure here destroys the safety net")
    end,

    -- A disk too full to write anything at all is not recoverable by reordering,
    -- so the requirement there is that it stops being SILENT. The server ran for
    -- hours with no durability and the only signal was one repeated log line,
    -- found by accident while chasing a different bug.
    ["a save that cannot complete marks persistence unhealthy"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob({ freeSpace = 120 })

        pcall(jobQueue.add, proto.JOB.MINE, { note = string.rep("x", 400) }, 5)

        local healthy = T.state.persistenceHealthy
        restore()

        assert_eq(healthy, false,
            "a disk too full to save must be reported, not swallowed by the pcall")
    end,

    -- The third and last instance of the backup-destroying save. saveJobs and
    -- savePersistentZones were fixed; saveMiningZones still deleted its backup
    -- and then tried to fs.copy a replacement, which needs room for a second
    -- full file. active_zones.dat was one of the two files truncated to
    -- near-zero in the original disk incident, so this was the exact mechanism
    -- that produced it, still live.
    --
    -- Source-level: saveMiningZones is a local with no seam, and the whole point
    -- is which fs call is used. Weaker than a behavioural test and labelled so.
    ["no disk save destroys its backup before securing one (SOURCE-ONLY)"] =
    function(assert_eq)
        local f = io.open("central_server.lua", "r")
        local src = f:read("*a"); f:close()

        local calls = 0
        for line in src:gmatch("[^\n]+") do
            -- Ignore comments; several explain why fs.copy is NOT used.
            if not line:match("^%s*%-%-") and line:find("fs%.copy%(") then
                calls = calls + 1
            end
        end
        assert_eq(calls, 0,
            "fs.copy needs room for a second full file and every use here runs "
            .. "AFTER the only backup has been deleted — use fs.move")
    end,

    -- ─── Sector leases ──────────────────────────────────────────────────────
    --
    -- A holder that dies must give its sector back. Assignment was always
    -- exclusive -- nextSector POPS from pending, so a held sector cannot be
    -- issued twice -- but nothing ever put one BACK, so a dead miner took its
    -- sector out of the world with it and the zone could never finish.
    --
    -- The shared-zone case is the one that matters and the one reassign misses:
    -- with sharedZoneKey several jobs hold ONE table by reference, so nilling
    -- state.miningZones[jobId] removes a reference and leaves the table, and the
    -- popped sector, exactly as they were.
    ["a dead holder's sector returns to the pool, even on a shared zone"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()

        -- Two jobs sharing one zone table by reference, as ensureMineZone builds
        -- them for a multi-miner order.
        local shared = {
            persistentKey   = "zone_test",
            pending         = { { x = 1152, z = -2800 } },
            lastAssignments = { node_118 = { x = 1120, z = -2800, isSurvey = false } },
            done = 0, total = 2,
        }
        T.state.miningZones["job_0726"] = shared
        T.state.miningZones["job_0727"] = shared      -- the surviving miner's job

        -- The holder goes dark and stays dark past the 5-minute absent window.
        T.state.registry["node_118"].online = false
        jobQueue.checkGhosts()
        advance(400)
        jobQueue.checkGhosts()

        local stillShared = T.state.miningZones["job_0727"]
        local returned, claim = false, nil
        for _, s in ipairs(stillShared.pending) do
            if s.x == 1120 and s.z == -2800 then returned = true end
        end
        claim = stillShared.lastAssignments["node_118"]
        restore()

        assert_eq(returned, true,
            "the dead holder's sector must be back in the shared pool — reassign "
            .. "only drops one reference and would leave it popped forever")
        assert_eq(claim, nil, "and its claim on that sector must be gone")
    end,

    -- Release must not hand back a sector that has already failed three times,
    -- for the same reason the failure path refuses to: it would be reissued
    -- immediately and fail again.
    ["a blacklisted sector is released but not requeued"] = function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()

        T.state.persistentZones["zone_test"] = {
            sectorFailCount = { ["1120,-2800"] = 3 },
        }
        -- Held directly. reassign nils state.miningZones[jobId], so reading the
        -- zone back through the state table afterwards yields nil whether the
        -- blacklist was honoured or not -- an assertion that cannot fail.
        local zone = {
            persistentKey   = "zone_test",
            pending         = {},
            lastAssignments = { node_118 = { x = 1120, z = -2800 } },
            done = 0, total = 1,
        }
        T.state.miningZones["job_0726"] = zone

        T.state.registry["node_118"].online = false
        jobQueue.checkGhosts()
        advance(400)
        jobQueue.checkGhosts()

        local pendingCount = #zone.pending
        local claim        = zone.lastAssignments["node_118"]
        restore()

        assert_eq(claim, nil, "the claim must still be dropped — release happened")

        assert_eq(pendingCount, 0,
            "a thrice-failed sector must not be handed straight back out")
    end,

    -- The guard's stated rationale is the ASSIGNED window: an IDLE sent before
    -- JOB_ASSIGN arrives must not re-open the turtle. Recovery must not undo
    -- that, or one dropped packet becomes a double dispatch.
    ["a single stale IDLE during the assign window does not free the job"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        T.state.jobs["job_0726"].status = "ASSIGNED"

        heartbeatAsFinished(T)
        jobQueue.checkGhosts()
        advance(10)                      -- well inside the 60s debounce
        jobQueue.checkGhosts()

        local status = T.state.jobs["job_0726"].status
        restore()
        assert_eq(status, "ASSIGNED",
            "a brief stale IDLE must not cancel a job that was just assigned")
    end,
}
