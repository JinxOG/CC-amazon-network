-- The server's own disk (W3 card "The server keeps its own disk tidy, and reports
-- it (no in-game visits)", 2026-11-02). The live dispatch computer fell from
-- 574 KB free to 289 KB in eleven days and nobody could say which file grew
-- without walking to the computer in the game. Part 1: /state carries the free
-- space and the five largest files, measured at most once a minute.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")

-- cloud: nil for "no cloud store", or a table of zone keys the store holds.
local function server(opts, cloud)
    local c = stub.install(opts or {})
    package.loaded["cloudstore"] = nil
    if cloud then
        local keys = {}
        for k in pairs(cloud) do keys[#keys + 1] = k end
        package.loaded["cloudstore"] = {
            NS = { ZONE = "z", INDEX = "ix", LOG = "log", JOB = "j", SECTOR = "sp" },
            available = function() return true end,
            listKeys = function(ns) return ns == "z" and keys or {} end,
            get = function(ns, k) return ns == "z" and cloud[k] or nil end,
            put = function() return true end, delete = function() return true end,
            health = function() return { available = true } end,
        }
    end
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
        package.loaded["cloudstore"] = nil
    end
    return T, c, restore, function(ms) clock = clock + ms end
end

local function put(name, bytes)
    local f = fs.open(name, "w"); f.write(string.rep("x", bytes)); f.close()
end

local function write(name, text)
    local f = fs.open(name, "w"); f.write(text); f.close()
end

local function read(name)
    local f = fs.open(name, "r"); if not f then return nil end
    local s = f.readAll(); f.close(); return s
end

local function logged(T, text)
    for _, e in ipairs(T.state.log) do
        if e.msg:find(text, 1, true) then return e.msg end
    end
end

-- Every file the server keeps live state in. The tidy must leave each exactly as it was.
local LIVE = { "jobs.dat", "active_zones.dat", "sector_progress.dat", "operator_holds.dat", "ore_thresholds.dat",
               "deploy_ref.txt", "gps_home.dat", "alive.stamp", "update_fanout.pending", "dock_assignments.dat",
               "role.txt", "protocol.lua", "cloudstore.lua", "updater.lua", "logship.lua", "waypoints.lua" }

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
        assert_eq(src:find([[',"disk":'%s*%.%.%s*js%(disk%.report%(]]) ~= nil, true, "the push carries a disk field")
    end,

    -- PART 2: the tidy. It deletes only from a named list, logs bytes freed, and
    -- never touches a file a running job needs.

    ["an installer's unused central_server.lua goes once startup.lua is the server itself"] = function(assert_eq)
        local T, c, restore = server()
        write("startup.lua", "local x = 1 -- the server")
        put("central_server.lua", 300000)
        local freed = T.tidyDisk()
        local gone = not fs.exists("central_server.lua")
        local said = logged(T, "central_server.lua")
        restore()
        assert_eq(gone, true)
        assert_eq(freed >= 300000, true, "its bytes counted as freed (" .. tostring(freed) .. ")")
        assert_eq(said ~= nil and said:find("300000", 1, true) ~= nil, true, "and logged with its size")
    end,

    ["central_server.lua stays while startup.lua still loads it"] = function(assert_eq)
        local T, c, restore = server()
        write("startup.lua", 'local server = require("central_server")\nserver.run()')
        put("central_server.lua", 300000)
        T.tidyDisk()
        local kept = fs.exists("central_server.lua")
        restore()
        assert_eq(kept, true, "a never-updated server runs it")
    end,

    ["a temp file left by an interrupted save goes"] = function(assert_eq)
        local T, c, restore = server()
        put("jobs.tmp", 5000); put("active_zones.tmp", 4000)
        T.tidyDisk()
        local left = fs.exists("jobs.tmp") or fs.exists("active_zones.tmp")
        restore()
        assert_eq(left, false)
    end,

    ["a backup goes only when its own file is there"] = function(assert_eq)
        local T, c, restore = server()
        put("jobs.dat", 100); put("jobs.dat.bak", 9000)
        put("active_zones.dat.bak", 9000)                             -- its main file is missing: the backup is the copy
        write("mine_zones.dat", ""); put("mine_zones.dat.bak", 9000)  -- main file empty: keep the backup
        T.tidyDisk()
        local a, b, z = fs.exists("jobs.dat.bak"), fs.exists("active_zones.dat.bak"), fs.exists("mine_zones.dat.bak")
        restore()
        assert_eq(a, false, "jobs.dat is there, so its backup goes")
        assert_eq(b, true, "active_zones.dat is missing, so its backup stays")
        assert_eq(z, true, "mine_zones.dat is empty, so its backup stays")
    end,

    ["the crash log keeps its newest 8 KB"] = function(assert_eq)
        local T, c, restore = server()
        local lines = {}
        for i = 1, 2000 do lines[#lines + 1] = string.format("[%04d] crash line %d", i, i) end
        write("crash.log", table.concat(lines, "\n") .. "\n")
        T.tidyDisk()
        local s = read("crash.log") or ""
        restore()
        assert_eq(#s <= 8192, true, "trimmed (" .. #s .. " bytes)")
        assert_eq(s:find("crash line 2000", 1, true) ~= nil, true, "the newest line kept")
        assert_eq(s:find("crash line 1\n", 1, true) == nil, true, "the oldest gone")
        assert_eq(s:sub(1, 1), "[", "cut at a line, not mid-line")
    end,

    ["the disk copy of the zones goes when the cloud store holds every one of them"] = function(assert_eq)
        local T, c, restore = server(nil, { zA = { key = "zA" }, zB = { key = "zB" } })
        write("mine_zones.dat", textutils.serialise({ zA = { key = "zA" }, zB = { key = "zB" } }))
        T.state.zoneStoreHealthy = true
        T.tidyDisk()
        local gone = not fs.exists("mine_zones.dat")
        restore()
        assert_eq(gone, true)
    end,

    ["the disk copy of the zones stays when the cloud is missing one, is not healthy, or is absent"] = function(assert_eq)
        local T, c, restore = server(nil, { zA = { key = "zA" } })
        write("mine_zones.dat", textutils.serialise({ zA = { key = "zA" }, zB = { key = "zB" } }))
        T.state.zoneStoreHealthy = true
        T.tidyDisk()
        local kept1 = fs.exists("mine_zones.dat")
        restore()
        local T2, c2, restore2 = server(nil, { zA = { key = "zA" } })
        write("mine_zones.dat", textutils.serialise({ zA = { key = "zA" } }))
        T2.state.zoneStoreHealthy = false
        T2.tidyDisk()
        local kept2 = fs.exists("mine_zones.dat")
        restore2()
        local T3, c3, restore3 = server()                             -- no cloud store: the disk copy IS the store
        write("mine_zones.dat", textutils.serialise({ zA = { key = "zA" } }))
        T3.tidyDisk()
        local kept3 = fs.exists("mine_zones.dat")
        restore3()
        assert_eq(kept1, true, "zB exists only on disk")
        assert_eq(kept2, true, "the cloud store is not healthy")
        assert_eq(kept3, true, "there is no cloud store")
    end,

    ["the tidy never touches a live state file"] = function(assert_eq)
        local T, c, restore = server()
        local before = {}
        for i, name in ipairs(LIVE) do
            write(name, string.rep(string.char(65 + i % 26), 500 + i)); before[name] = read(name)
        end
        write("startup.lua", "-- the server itself")
        put("central_server.lua", 1000); put("x.tmp", 10); put("crash.log", 20000)
        T.tidyDisk()
        local changed = {}
        for _, name in ipairs(LIVE) do if read(name) ~= before[name] then changed[#changed + 1] = name end end
        restore()
        assert_eq(table.concat(changed, ","), "", "every live file byte-identical")
    end,

    ["the tidy runs at boot and once an hour (SOURCE-ONLY, weaker)"] = function(assert_eq)
        local f = io.open("central_server.lua", "rb"); local src = f:read("*a"); f:close()
        assert_eq(src:find("pcall(disk.tidy)", 1, true) ~= nil, true, "called, protected")
        assert_eq(src:find("CFG.DISK_TIDY_INTERVAL", 1, true) ~= nil, true, "on its own interval")
        assert_eq(src:find("\n%s*disk%.tidyIfDue%(wc%)") ~= nil, true, "from the main loop")
    end,
}
