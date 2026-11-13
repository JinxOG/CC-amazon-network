-- The server's disk at the default limit, under shakeout load (W3, 2026-11-13; SPEC-OWNER's ruling of 2026-11-12).
--
-- T2 run shakeout-faults-a: the dispatch computer's disk ran out 75 minutes in. One 36-sector zone's survey readings
-- were 202,663 bytes of active_zones.dat, a second copy of those readings sat in sector_progress.dat, everything was
-- saved in the readable layout, and every save needs room for a full temporary copy of its file.
--
-- The bar, in bytes, at the default limits: with CC's default 1,000,000-byte disk, used space plus the temporary copy
-- of the largest file stays at or under 700,000 bytes, with three 36-sector zones open at once (the shakeout keeps at
-- least three long-running sites) and a day of job history at that run's rate.
--
-- The model, from #95's files in that run:
--   * the server's own programs (startup.lua, updater, waypoints, protocol, ...) took 214,720 bytes;
--   * a surveyed sector has about 4.8 depth readings, each about 38 of the 86 ore kinds that zone met;
--   * 150 live jobs; history at that run's rate (about 7 entries a job in 2 hours) reaches the in-memory bound of 40
--     a job within a day, so a day's worth is 40 a job;
--   * three miners a zone, each holding a sector (the readings sector_progress.dat keeps).
-- Modelled harder than measured: every sector of all three zones surveyed at 5 depths, half of them mined too.
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

local DISK = 1000000
local BAR = 700000
local PROGRAMS = 214720

local function freshServer()
    local c = stub.install({ freeSpace = DISK })
    local savedEpoch, savedPeripheral = os.epoch, peripheral
    os.epoch = function() return 1794540000000 end
    peripheral = { find = function() return nil end }
    package.loaded["cloudstore"] = nil
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"] = nil
    local server = require("central_server")
    local restore = function()
        os.epoch, peripheral = savedEpoch, savedPeripheral
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
        package.loaded["cloudstore"] = nil
    end
    return server, server._test, restore, c
end

-- Ore ids as long as this pack's (mekanism:deepslate_fluorite_ore, electrodynamics:deepslateorevanadium, ...).
local ORES = {}
for i = 1, 86 do ORES[i] = string.format("examplemodpack:deepslate_ore_kind_%02d", i) end

local function oreMap(seed, kinds, scale)
    local m = {}
    for k = 1, kinds do
        local name = ORES[(seed * 7 + k * 13) % #ORES + 1]
        m[name] = (seed * 31 + k * 17) % scale + 1
    end
    return m
end

local DEPTHS = { 16, 0, -32, -52, -60 }

local function zone(n)
    local x0, z0 = 512 + n * 1024, -2176
    local z = { phase = "MINE", total = 36, done = 18, surveyTotal = 36, surveyDone = 36, surveyOnly = false,
                startTime = 1794538991957, persistentKey = string.format("%d,%d,%d,%d", x0, z0, x0 + 192, z0 + 192),
                bounds = { x1 = x0 - 16, z1 = z0 - 16, x2 = x0 + 208, z2 = z0 + 208 },
                rawBounds = { x1 = x0, z1 = z0, x2 = x0 + 192, z2 = z0 + 192 },
                allSectors = {}, pending = {}, surveySectors = {}, doneKeys = {}, lastAssignments = {},
                sectorSeen = {}, sectorMined = {}, sectorTimes = { MINE = { n = 18, total = 64800 } },
                oreFound = oreMap(n, 86, 9000), oreMined = oreMap(n + 1, 86, 6000) }
    for i = 0, 35 do
        local sx, sz = x0 + (i % 6) * 32, z0 + math.floor(i / 6) * 32
        z.allSectors[#z.allSectors + 1] = { x = sx, z = sz }
        if i >= 18 then z.pending[#z.pending + 1] = { x = sx, z = sz } else z.doneKeys["MINE:" .. sx .. "," .. sz] = true end
        for d, y in ipairs(DEPTHS) do
            local k = string.format("%d,%d,%d", sx, sz, y)
            z.sectorSeen[k] = oreMap(i * 5 + d + n, 38, 400)
            if i < 18 then z.sectorMined[k] = oreMap(i * 5 + d + n + 3, 38, 300) end
        end
    end
    for m = 1, 3 do
        local s = z.pending[m]
        z.lastAssignments["node_" .. (n * 10 + m)] = { x = s.x, z = s.z, isSurvey = false, phase = "MINE",
            jobId = string.format("job_%04d", n * 100 + m), assignedAt = 1794541435284 }
    end
    return z
end

local DETAIL = "[WORKING] phase SCANNING — 544,-2176 Y=16 depth 2/4"

local function loadFleet(T)
    T.state.jobs, T.state.miningZones = {}, {}
    for n = 1, 3 do
        local zn = zone(n)
        for m = 1, 3 do T.state.miningZones[string.format("job_%04d", n * 100 + m)] = zn end
    end
    for i = 1, 150 do
        local id = string.format("job_%04d", i <= 9 and (math.floor((i - 1) / 3) + 1) * 100 + (i - 1) % 3 + 1 or 1000 + i)
        local job = { id = id, type = i <= 133 and "MINE" or "DELIVER", status = i <= 9 and "IN_PROGRESS" or "PENDING",
                      priority = 5, retries = 0, createdAt = 1794538176334, updatedAt = 1794538176334,
                      params = { x1 = 1184, z1 = -1728, x2 = 1344, z2 = -1568, sharedZoneKey = "1168,-1744,1360,-1552" },
                      history = {} }
        for h = 1, 40 do
            job.history[h] = { ts = 1794540675001 + h * 1000, event = "progress", detail = DETAIL }
        end
        T.state.jobs[id] = job
    end
    T.state.jobCounter = 355
    for _, zn in pairs(T.state.miningZones) do zn.progressDirty = true end
end

local function putPrograms()
    local f = fs.open("startup.lua", "w"); f.write(string.rep("x", PROGRAMS)); f.close()
end



local function saveAll(T)
    T.saveJobs()
    T.saveMiningZones()
    T.saveSectorProgress()
end

return {
    ["three 36-sector zones and a day of job history fit the default disk with room to save"] = function(assert_eq)
        local _, T, restore, c = freshServer()
        putPrograms()
        loadFleet(T)
        saveAll(T)
        local healthy = T.state.persistenceHealthy
        local used = DISK - c.freeSpace()
        -- Every file the saves wrote, whatever it is called: the largest is the one whose copy has to fit.
        local largest, which, sizes, leftovers = 0, nil, {}, 0
        local names = {}
        for name in pairs(c.files) do if name ~= "startup.lua" then names[#names + 1] = name end end
        table.sort(names)
        for _, name in ipairs(names) do
            local n = #c.files[name]
            sizes[#sizes + 1] = name .. " " .. n
            if n > largest then largest, which = n, name end
            if name:match("%.tmp$") or name:match("%.bak$") then leftovers = leftovers + 1 end
        end
        restore()
        print(string.format("  disk at the bar: used %d + largest copy %d (%s) = %d of %d [%s]", used, largest,
            tostring(which), used + largest, BAR, table.concat(sizes, ", ")))
        assert_eq(leftovers, 0, "no temporary or backup copy is left on the disk (" .. table.concat(sizes, ", ") .. ")")
        assert_eq(healthy ~= false, true, "every save succeeded")
        assert_eq(c.files["active_zones.dat"] ~= nil and c.files["jobs.dat"] ~= nil, true,
            "the saves wrote their files: the check below has something to judge")
        assert_eq(used + largest <= BAR, true, string.format(
            "used %d + a temporary copy of the largest file (%s, %d) = %d, at most %d [%s]",
            used, tostring(which), largest, used + largest, BAR, table.concat(sizes, ", ")))
    end,

    ["the saved zones come back with every survey reading and ore count"] = function(assert_eq)
        local _, T, restore, c = freshServer()
        loadFleet(T)
        saveAll(T)
        local files = {}
        for k, v in pairs(c.files) do files[k] = v end
        -- Without the progress file: its overlay recomputes the zone's totals, which is not what is checked here.
        files["sector_progress.dat"] = nil
        local before = T.state.miningZones["job_0101"]
        local jobs = T.state.jobs
        restore()

        local _, T2, restore2, c2 = freshServer()
        for k, v in pairs(files) do c2.files[k] = v end
        T2.state.jobs = jobs
        T2.loadMiningZones()
        local after = T2.state.miningZones["job_0101"]
        local shared = T2.state.miningZones["job_0102"] == after
        restore2()

        local function same(a, b)
            local diff = 0
            for k, m in pairs(a) do
                for name, n in pairs(m) do if not (b[k] and b[k][name] == n) then diff = diff + 1 end end
            end
            for k, m in pairs(b) do
                for name in pairs(m) do if not (a[k] and a[k][name]) then diff = diff + 1 end end
            end
            return diff
        end
        assert_eq(after ~= nil, true, "the zone was restored")
        assert_eq(same(before.sectorSeen, after.sectorSeen), 0, "every survey reading, exactly")
        assert_eq(same(before.sectorMined, after.sectorMined), 0, "every mined count, exactly")
        assert_eq(same({ x = before.oreFound }, { x = after.oreFound }), 0, "the zone's found totals")
        assert_eq(same({ x = before.oreMined }, { x = after.oreMined }), 0, "the zone's mined totals")
        assert_eq(shared, true, "the miners of one zone still share one zone")
        assert_eq(#after.allSectors, 36, "and the rest of the zone is as it was")
    end,

    ["the sectors in flight come back from the progress file"] = function(assert_eq)
        local _, T, restore, c = freshServer()
        loadFleet(T)
        local held = T.state.miningZones["job_0101"].lastAssignments["node_11"]
        local key = string.format("%d,%d,%d", held.x, held.z, 0)
        T.saveSectorProgress()
        local files = {}
        for k, v in pairs(c.files) do files[k] = v end
        local want = T.state.miningZones["job_0101"].sectorSeen[key]
        restore()

        local _, T2, restore2, c2 = freshServer()
        for k, v in pairs(files) do c2.files[k] = v end
        loadFleet(T2)
        local zn = T2.state.miningZones["job_0101"]
        zn.sectorSeen[key] = nil
        T2.overlaySectorProgress()
        local got = zn.sectorSeen[key]
        restore2()
        local diff = 0
        for name, n in pairs(want) do if not (got and got[name] == n) then diff = diff + 1 end end
        assert_eq(got ~= nil, true, "the held sector's reading was put back")
        assert_eq(diff, 0, "with every count")
    end,

    ["a zones file written in the old layout still loads"] = function(assert_eq)
        local _, T, restore, c = freshServer()
        loadFleet(T)
        local zn = T.state.miningZones["job_0101"]
        local f = fs.open("active_zones.dat", "w")
        f.write(textutils.serialise({ job_0101 = zn, job_0102 = { sharedWith = "job_0101" } }))
        f.close()
        local want = zn.sectorSeen
        T.state.miningZones = {}
        T.loadMiningZones()
        local got = T.state.miningZones["job_0101"]
        restore()
        local k = next(want)
        assert_eq(got ~= nil and got.sectorSeen[k] ~= nil, true, "an old file's zone loads with its readings")
    end,
}
