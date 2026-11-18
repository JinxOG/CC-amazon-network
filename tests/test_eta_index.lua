-- The zone ETA, priced from a one-pass index (W3, 2026-11-18). T2 shakeout-payload-b (160 turtles) still had 29 LOOP
-- STALLs in one bridge slice, up to 3846 ms: one zone's ETA.forJob. For every pending sector it scanned every key of
-- sectorSeen and sectorMined, and an unscanned one also took ETA.meanOre, which scans them again for every sector --
-- cubic in the zone's size. forJob now indexes the zone once; the answer must be the same.
package.path = "./?.lua;" .. package.path
local stub = require("tests.stub_cc")

local function freshServer()
    stub.install({})
    local savedEpoch, savedPeripheral = os.epoch, peripheral
    os.epoch = function() return 1000000 end
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
    return server, server._test, restore
end

-- A 36-sector zone, 5 depths scanned in all but the last 6 sectors, some ore mined; the survey not finished.
local function bigZone()
    local z = { pending = {}, allSectors = {}, sectorSeen = {}, sectorMined = {}, surveyDone = 30, surveyTotal = 36,
                rescanSectors = {}, surveySectors = {}, phase = "MINE", lastAssignments = {} }
    for i = 0, 35 do
        local x, zz = 1024 + (i % 6) * 32, -2048 + math.floor(i / 6) * 32
        z.allSectors[#z.allSectors + 1] = { x = x, z = zz }
        z.pending[#z.pending + 1] = { x = x, z = zz }
        if i < 30 then
            for _, y in ipairs({ 16, 0, -16, -32, -48 }) do
                local k = string.format("%d,%d,%d", x, zz, y)
                z.sectorSeen[k] = { ["minecraft:iron_ore"] = 10 + i, ["minecraft:coal_ore"] = 5 + y % 7 }
                if i % 3 == 0 then z.sectorMined[k] = { ["minecraft:iron_ore"] = 4 } end
            end
        end
    end
    return z
end

return {
    ["the zone ETA from the index is the one the full scan gives"] = function(assert_eq)
        local _, T, restore = freshServer()
        local ETA = T.ETA
        local z = bigZone()
        local slow = ETA._forJob(z, 3)               -- no index: the original scans
        local fast = ETA.forJob(z, 3)                -- indexed once
        local again = ETA._forJob(z, 3)              -- and the index is gone afterwards
        restore()
        assert_eq(type(slow), "number", "the scan prices the zone (" .. tostring(slow) .. ")")
        assert_eq(fast, slow, "the index gives the same answer")
        assert_eq(again, slow, "and leaves nothing behind")
    end,
}
