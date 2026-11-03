-- The server's own disk (W3 card "The server keeps its own disk tidy, and reports
-- it (no in-game visits)", 2026-11-02). The live dispatch computer fell from
-- 574 KB free to 289 KB in eleven days and nobody could say which file grew
-- without walking to the computer in the game. Part 1: /state carries the free
-- space and the five largest files, measured at most once a minute.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")

local function server(opts)
    local c = stub.install(opts or {})
    local savedEpoch = os.epoch
    local clock = 1000000
    os.epoch = function() return clock end
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local T = require("central_server")._test
    local function restore()
        os.epoch = savedEpoch
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
    end
    return T, c, restore, function(ms) clock = clock + ms end
end

local function put(name, bytes)
    local f = fs.open(name, "w"); f.write(string.rep("x", bytes)); f.close()
end

return {
    ["the disk report names the five largest files, largest first"] = function(assert_eq)
        local T, c, restore = server()
        for name, n in pairs({ ["startup.lua"] = 9000, ["jobs.dat"] = 4000, ["active_zones.dat"] = 7000,
                               ["crash.log"] = 3000, ["alive.stamp"] = 10, ["a.dat"] = 2000, ["b.dat"] = 1000 }) do
            put(name, n)
        end
        local r = T.diskReport(true)
        local free = fs.getFreeSpace("/")
        restore()
        assert_eq(#r.largest, 5)
        assert_eq(r.largest[1].name, "startup.lua")
        assert_eq(r.largest[1].size, 9000)
        assert_eq(r.largest[2].name, "active_zones.dat")
        assert_eq(r.largest[5].name, "a.dat")
        assert_eq(r.free, free, "free space as CC reports it")
        assert_eq(r.files, 7, "every file counted")
        assert_eq(r.bytes, 26010, "and their total")
    end,

    ["the disk is measured at most once a minute"] = function(assert_eq)
        local T, c, restore, advance = server()
        put("jobs.dat", 100)
        local first = T.diskReport()
        put("jobs.dat", 5000)
        local cached = T.diskReport()
        advance(61000)
        local fresh = T.diskReport()
        restore()
        assert_eq(cached.bytes, first.bytes, "the same reading within the minute")
        assert_eq(fresh.bytes > first.bytes, true, "a new reading after it")
    end,

    ["the disk report goes to /state (SOURCE-ONLY, weaker)"] = function(assert_eq)
        local f = io.open("central_server.lua", "rb"); local src = f:read("*a"); f:close()
        assert_eq(src:find([[',"disk":'%s*%.%.%s*js%(diskReport]]) ~= nil, true, "the push carries a disk field")
    end,
}
