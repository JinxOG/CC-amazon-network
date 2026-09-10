-- The updater, actually run.
--
-- Written the day it bricked the fleet. On 2026-09-10 turtle_base.lua gained
-- `require("logship")` in the same release that added logship.lua to the
-- updater's COMMON list. The manifest was correct and the manifest test passed.
-- But the updater doing the work on each turtle was the PREVIOUS version,
-- running from the PREVIOUS list: it shipped the new turtle_base, did not know
-- logship.lua existed, rebooted, and fifteen turtles came up at a shell prompt
-- saying "module 'logship' not found".
--
-- Two source-ordering assertions were written first. Mutation killed both of
-- them: `if false and selfAfter ~= selfBefore` left the text in place, and so
-- did moving the `readSelf()` that produces selfAfter below the role loop. A
-- test that matches the POSITION of text cannot see whether the branch is live
-- or whether the values are in scope, and this path is too expensive to guard
-- with something that cannot see either.
--
-- So updater.lua is loaded into a fake CC environment and run for real, against
-- an in-memory disk and an in-memory GitHub. The scenario below IS the incident,
-- reproduced: old updater on disk, new everything on the remote.

package.path = "./?.lua;" .. package.path

local NL = string.char(10)

-- ─── A CC computer, in a table ───────────────────────────────────────────────

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

-- os.reboot never returns on a real computer. Raising a sentinel is the only
-- faithful way to model that, and it also stops a test hanging if the updater
-- ever loops.
local REBOOT = { "reboot" }

local function makeEnv(disk, remote, log, relaunch, fetched)
    local env

    local fs = {}
    function fs.exists(p) return disk[p] ~= nil end
    function fs.delete(p) disk[p] = nil end
    function fs.getSize(p)
        if disk[p] == nil then error("no such file " .. p) end
        return #disk[p]
    end
    function fs.getFreeSpace() return 512 * 1024 end
    function fs.move(a, b) disk[b] = disk[a]; disk[a] = nil end
    function fs.open(p, mode)
        if mode == "r" then
            if disk[p] == nil then return nil end
            local content, pos = disk[p], 1
            return {
                readAll = function() local r = content:sub(pos); pos = #content + 1; return r end,
                readLine = function()
                    if pos > #content then return nil end
                    local nl = content:find(NL, pos, true)
                    local line
                    if nl then line = content:sub(pos, nl - 1); pos = nl + 1
                    else line = content:sub(pos); pos = #content + 1 end
                    return line
                end,
                close = function() end,
            }
        end
        local buf = {}
        return {
            write     = function(s) buf[#buf + 1] = s end,
            writeLine = function(s) buf[#buf + 1] = tostring(s) .. NL end,
            close     = function() disk[p] = table.concat(buf) end,
        }
    end

    local http = {}
    function http.get(url)
        local name = url:sub(#REPO + 1)
        -- Recorded per pass. Which files a pass ASKS FOR is the only direct
        -- evidence of whether it got as far as the role loop -- see the
        -- ordering test below for why inferring it from the outcome is not
        -- enough.
        if fetched then fetched[#fetched + 1] = name end
        local body = remote[name]
        if body == nil then return nil end
        local pos = 1
        return {
            readAll = function() local r = body:sub(pos); pos = #body + 1; return r end,
            close   = function() end,
        }
    end

    local shell = {}
    function shell.run(name, ...)
        log.ran[#log.ran + 1] = name
        if name == "updater" then return relaunch() end
        return true
    end

    local osT = { date = function() return "2026-09-10 12:00:00" end,
                  reboot = function() log.rebooted = true; error(REBOOT) end }

    env = {
        fs = fs, http = http, shell = shell, os = osT,
        io = { write = function(...) end },
        sleep = function() end,
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            log.out[#log.out + 1] = table.concat(parts, " ")
        end,
        string = string, table = table, math = math,
        pcall = pcall, ipairs = ipairs, pairs = pairs, type = type,
        tostring = tostring, tonumber = tonumber, error = error,
        assert = assert, select = select, next = next,
    }
    env._G = env
    return env
end

-- Runs the updater.lua that is CURRENTLY ON THE FAKE DISK, which is the whole
-- point: a relaunch must pick up the file this run just downloaded, not the
-- source we started from.
local function runUpdater(disk, remote, log, depth)
    depth = (depth or 0) + 1
    assert(depth <= 4, "updater relaunched " .. depth .. " times — not converging")
    log.runs = depth

    local src = disk["updater.lua"]
    assert(src, "no updater.lua on the fake disk")
    local env = makeEnv(disk, remote, log, function()
        return runUpdater(disk, remote, log, depth)
    end)
    local chunk = assert(load(src, "@updater.lua", "t", env))
    local ok, err = pcall(chunk)
    if not ok and err ~= REBOOT then error(err, 0) end
end

local function readRepoFile(name)
    local f = assert(io.open(name, "r"), "cannot open " .. name)
    local s = f:read("*a")
    f:close()
    return s
end

-- ─── The incident ────────────────────────────────────────────────────────────

-- updater.lua as it stood before logship.lua existed: COMMON without it. Built
-- by editing the real current file rather than pasting an old copy, so the two
-- differ ONLY in the manifest and this test cannot rot into comparing a fossil
-- against itself.
local function previousUpdater()
    local current = readRepoFile("updater.lua")
    local old = current:gsub('%s*"logship%.lua",' .. NL, NL, 1)
    assert(old ~= current, "could not build the pre-logship updater — the "
        .. "COMMON entry for logship.lua moved or changed shape")
    return old
end

local function freshRemote()
    return {
        ["updater.lua"]       = readRepoFile("updater.lua"),
        ["protocol.lua"]      = "-- protocol",
        ["waypoints.lua"]     = "-- waypoints",
        ["logship.lua"]       = "-- logship",
        ["turtle_base.lua"]   = "-- turtle_base, requires logship",
        ["delivery_turtle.lua"] = "-- delivery",
    }
end

local suite = {}

suite["an updater that predates a new module still ships it"] = function(assert_eq)
    local disk = {
        ["role.txt"]         = "DELIVERY" .. NL,
        ["updater.lua"]      = previousUpdater(),
        ["protocol.lua"]     = "-- old protocol",
        ["waypoints.lua"]    = "-- old waypoints",
        ["turtle_base.lua"]  = "-- old turtle_base",
        ["startup.lua"]      = "-- old delivery",
    }
    local log = { out = {}, ran = {}, rebooted = false }

    runUpdater(disk, freshRemote(), log)

    -- THE assertion. Without the self-refresh this is nil, the turtle reboots
    -- into a turtle_base that requires a file it does not have, and it does not
    -- come back.
    assert_eq(disk["logship.lua"], "-- logship",
        "the updater must ship a module its own list did not know about — the "
        .. "new turtle_base requires it, and a CC computer with a missing "
        .. "module does not degrade, it refuses to boot")

    assert_eq(disk["turtle_base.lua"], "-- turtle_base, requires logship",
        "and it must still have shipped the role files")
    assert_eq(disk["updater.lua"], readRepoFile("updater.lua"),
        "and updated itself")
    assert_eq(log.rebooted, true,
        "and rebooted, because everything it set out to write is on disk")
end

suite["the relaunch happens before any role file lands"] = function(assert_eq)
    -- Ordering, observed rather than inferred.
    --
    -- The first version of this test withheld the role files from pass one and
    -- expected it to fail on them. Mutation killed it: an updater that checks
    -- itself AFTER the role loop downloads them from the stale list, relaunches
    -- anyway, and the second pass fixes everything up -- so the outcome is
    -- identical and every assertion stayed green while the bug was back.
    --
    -- What actually distinguishes the two is which files each pass ASKS FOR.
    -- A pass that reached the role loop fetched turtle_base.lua. That is not
    -- recoverable from the final state of the disk, so the transport is
    -- instrumented instead.
    local disk = {
        ["role.txt"]        = "DELIVERY" .. NL,
        ["updater.lua"]     = previousUpdater(),
        ["turtle_base.lua"] = "-- old turtle_base",
    }
    local remote = freshRemote()
    local log = { out = {}, ran = {}, rebooted = false }

    local passes = {}
    local function run()
        local mine = {}
        passes[#passes + 1] = mine
        assert(#passes <= 4, "updater is not converging")
        local env = makeEnv(disk, remote, log, run, mine)
        local chunk = assert(load(disk["updater.lua"], "@updater.lua", "t", env))
        local ok, err = pcall(chunk)
        if not ok and err ~= REBOOT then error(err, 0) end
    end
    run()

    local function fetched(pass, name)
        for _, got in ipairs(passes[pass] or {}) do
            if got == name then return true end
        end
        return false
    end

    assert_eq(#passes, 2,
        "exactly two passes: the first notices it replaced its own file list, "
        .. "the second finds them identical and finishes")

    assert_eq(fetched(1, "updater.lua"), true,
        "precondition: pass one must have downloaded the new updater, or there "
        .. "is nothing for it to have noticed")
    assert_eq(fetched(1, "turtle_base.lua"), false,
        "pass one must NOT reach the role files. Downloading them from the "
        .. "stale list is the whole fault of 2026-09-10 — a second pass "
        .. "cleaning up afterwards makes the outcome look fine and leaves the "
        .. "machine one failed download away from the same brick")
    assert_eq(fetched(2, "turtle_base.lua"), true,
        "and pass two, off the new list, must be the one that ships them")
    assert_eq(fetched(2, "logship.lua"), true,
        "along with the module the old list did not know about")

    assert_eq(log.rebooted, true, "and the run must complete")
    assert_eq(disk["turtle_base.lua"], "-- turtle_base, requires logship",
        "with the role file on disk")
end

suite["an updater that is already current does not relaunch"] = function(assert_eq)
    local disk = {
        ["role.txt"]        = "DELIVERY" .. NL,
        ["updater.lua"]     = readRepoFile("updater.lua"),
        ["turtle_base.lua"] = "-- old turtle_base",
    }
    local log = { out = {}, ran = {}, rebooted = false }

    runUpdater(disk, freshRemote(), log)

    -- Every ordinary update takes this path. A relaunch on every run would
    -- double the traffic of a fifteen-turtle rollout and double the window in
    -- which a machine is mid-update.
    assert_eq(log.runs, 1,
        "an updater whose own file did not change must NOT start over")
    assert_eq(#log.ran, 0, "and must not shell out to itself at all")
    assert_eq(log.rebooted, true, "but must still finish and reboot")
    assert_eq(disk["turtle_base.lua"], "-- turtle_base, requires logship",
        "having shipped the role files on its single pass")
end

-- The guard that stops this whole file from passing vacuously. If the fake
-- environment is wrong enough that the updater falls over immediately, every
-- assertion above about what is NOT on disk would still hold.
suite["the fake environment actually runs the real updater"] = function(assert_eq)
    local disk = {
        ["role.txt"]    = "DELIVERY" .. NL,
        ["updater.lua"] = readRepoFile("updater.lua"),
    }
    local log = { out = {}, ran = {}, rebooted = false }
    runUpdater(disk, freshRemote(), log)

    local joined = table.concat(log.out, NL)
    assert_eq(joined:find("=== Updater [DELIVERY] ===", 1, true) ~= nil, true,
        "the updater must have read role.txt and started — if it errored out "
        .. "early, every other assertion in this file is about a program that "
        .. "never ran")
    assert_eq(joined:find("All files updated successfully!", 1, true) ~= nil, true,
        "and must have reported success, or the reboot assertions above are "
        .. "measuring a different code path")
end

return suite
