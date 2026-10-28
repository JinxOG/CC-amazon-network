-- A zone's ore record (W3 card "Mid-sector ore progress is only saved when a
-- sector finishes; an outage loses it", found 2026-09-30).
--
-- Two faults, one record:
--
--   * HISTORY. A zone built again from the store (a new order on the same
--     ground, a requeue, a restart without its working copy) inherited the
--     store's totals -- and the first scan report threw them away, because the
--     totals were recomputed from this run's scans alone. The next finished
--     sector then wrote the smaller figure over the store. On 2026-09-30 the
--     zone read 1,384 ore found after the requeue where it read 21,250 before.
--     The store now keeps each finished sector's ore, and a rebuilt zone counts
--     those as well as its own scans, once each.
--
--   * IN FLIGHT. A sector's mined ore lived only in memory until the sector
--     finished, and a sector can take two hours. The sectors in flight are now
--     written to a small local file at most once a minute, and put back on a
--     restart. Local, not the cloud store: a cloud write is a peripheral call,
--     and a peripheral call eats the radio messages that arrive during it.
--
-- These drive the real SECTOR_SCAN and SECTOR_DONE handlers.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

local A        = "node_138"
local J1, J2   = "job_0300", "job_0301"
local COAL     = "minecraft:coal_ore"
local PARAMS   = { x1 = 2048, z1 = -3104, x2 = 2080, z2 = -3104 }

local function server()
    stub.install({})
    local savedEpoch = os.epoch
    local clock = 1000000
    os.epoch = function() return clock end
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local T = require("central_server")._test
    T.sent = {}
    T.state.modem = {
        isOpen = function() return true end, open = function() end,
        transmit = function(_, _, body) T.sent[#T.sent + 1] = body end,
    }
    T.state.registry[A] = {
        id = A, role = proto.ROLE.MINER, status = proto.STATUS.WORKING,
        fuel = 100000, online = true, lastSeen = clock, position = { x = 0, y = 60, z = 0 },
    }
    local function restore()
        os.epoch = savedEpoch
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
    end
    return T, restore, function(ms) clock = clock + ms end
end

local function job(T, id)
    T.state.jobs[id] = {
        id = id, type = proto.JOB.MINE, status = "IN_PROGRESS", assignedTo = A,
        params = PARAMS, priority = 5, history = {}, createdAt = 0, retries = 0,
    }
    T.state.registry[A].jobId = id
end

-- A zone for `id` on PARAMS, in its mine phase, and two of its sectors.
local function zoneFor(T, id)
    job(T, id)
    T.ensureMineZone(id, PARAMS)
    local z = T.state.miningZones[id]
    z.phase = "MINE"
    return z, z.allSectors[1], z.allSectors[2]
end

local function hold(z, s)
    z.lastAssignments[A] = { x = s.x, z = s.z, isSurvey = false }
end

local function scan(T, id, s, found, mined)
    T.handlers[proto.MSG.SECTOR_SCAN]({ from = A, payload = {
        jobId = id, sectorX = s.x, sectorZ = s.z, scanY = -40,
        foundOres = found, minedOres = mined } })
end

local function finish(T, id, s)
    hold(T.state.miningZones[id], s)
    T.handlers[proto.MSG.SECTOR_DONE]({ from = A, payload = {
        jobId = id, sectorX = s.x, sectorZ = s.z, oreCount = 0 } })
end

-- The job ends; the zone's working copy goes with it.
local function drop(T, id) T.state.miningZones[id] = nil end

local function restart(T) T.state.miningZones = {} end

return {
    ["a zone built again keeps the ore of the sectors finished before it"] = function(assert_eq)
        local T, restore = server()
        local z, s1, s2 = zoneFor(T, J1)
        scan(T, J1, s1, { [COAL] = 100 }, nil)
        scan(T, J1, s1, nil, { [COAL] = 90 })
        finish(T, J1, s1)
        drop(T, J1)
        local z2 = zoneFor(T, J2)                       -- a new order on the same ground
        local key = z2.persistentKey
        scan(T, J2, s2, { [COAL] = 10 }, nil)
        local found, mined = z2.oreFound[COAL], z2.oreMined[COAL]
        finish(T, J2, s2)
        local pz = T.state.persistentZones[key]
        restore()
        assert_eq(mined, 90, "the 90 mined before are still counted after a scan of the new run")
        assert_eq(found, 110, "100 found before and 10 now")
        assert_eq(pz.oreMined[COAL], 90, "and the store is not overwritten with this run's figure")
        assert_eq(pz.oreFound[COAL], 110)
    end,

    ["a rescan of a sector finished before the rebuild does not count it twice"] = function(assert_eq)
        local T, restore = server()
        local z, s1 = zoneFor(T, J1)
        scan(T, J1, s1, { [COAL] = 100 }, nil)
        scan(T, J1, s1, nil, { [COAL] = 90 })
        finish(T, J1, s1)
        drop(T, J1)
        local z2 = zoneFor(T, J2)
        scan(T, J2, s1, { [COAL] = 10 }, nil)           -- the rescan sees the 10 left
        scan(T, J2, s1, nil, { [COAL] = 10 })           -- and the re-mine takes them
        local found, mined = z2.oreFound[COAL], z2.oreMined[COAL]
        finish(T, J2, s1)
        local pz = T.state.persistentZones[z2.persistentKey]
        restore()
        assert_eq(found, 100, "the sector held 100, not 100 + 10")
        assert_eq(mined, 100, "90 before and 10 now")
        assert_eq(pz.oreMined[COAL], 100, "a re-mined sector's ore reaches the store")
    end,

    ["a zone stored before per-sector ore keeps its totals"] = function(assert_eq)
        local T, restore = server()
        local z, s1, s2 = zoneFor(T, J1)
        local pz = T.state.persistentZones[z.persistentKey]
        pz.doneSectors = { { x = s1.x, z = s1.z } }
        pz.oreFound, pz.oreMined, pz.sectorOre = { [COAL] = 50 }, { [COAL] = 40 }, nil
        drop(T, J1)
        local z2 = zoneFor(T, J2)
        scan(T, J2, s2, { [COAL] = 5 }, nil)
        local found, mined = z2.oreFound[COAL], z2.oreMined[COAL]
        restore()
        assert_eq(found, 55, "50 before and 5 now")
        assert_eq(mined, 40)
    end,

    ["a sector's mined ore survives a restart before the sector finishes"] = function(assert_eq)
        local T, restore, advance = server()
        local z, s1 = zoneFor(T, J1)
        hold(z, s1)
        T.saveMiningZones()                             -- the last sector boundary
        scan(T, J1, s1, { [COAL] = 100 }, nil)
        scan(T, J1, s1, nil, { [COAL] = 30 })
        advance(61000)
        local wrote = T.saveSectorProgress()
        restart(T)
        T.loadMiningZones()
        local back = T.state.miningZones[J1]
        restore()
        assert_eq(wrote, true, "the sector in flight was written")
        assert_eq(back and back.oreMined[COAL], 30, "the 30 mined since the boundary are back")
        assert_eq(back and back.oreFound[COAL], 100)
    end,

    ["progress is written only when there is something new"] = function(assert_eq)
        local T, restore = server()
        local z, s1 = zoneFor(T, J1)
        hold(z, s1)
        scan(T, J1, s1, nil, { [COAL] = 30 })
        local first  = T.saveSectorProgress()
        local second = T.saveSectorProgress()
        restore()
        assert_eq(first, true)
        assert_eq(second, false, "nothing reported since the last write")
    end,

    ["a finished sector left in the progress file is not counted again"] = function(assert_eq)
        local T, restore = server()
        local z, s1 = zoneFor(T, J1)
        hold(z, s1)
        scan(T, J1, s1, { [COAL] = 100 }, nil)
        scan(T, J1, s1, nil, { [COAL] = 30 })
        T.saveSectorProgress()                          -- then it finishes, inside the minute
        finish(T, J1, s1)
        drop(T, J1)
        restart(T)
        local z2 = zoneFor(T, J2)                       -- its 30 are in the store now
        local mined = z2.oreMined[COAL]
        restore()
        assert_eq(mined, 30, "counted once, from the store, not again from the file")
    end,
}
