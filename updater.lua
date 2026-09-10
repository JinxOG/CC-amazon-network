-- updater.lua
-- Downloads the latest version of all system files from GitHub.
-- Triggered automatically when the server sends UPDATE_ALL, or run manually.
--
-- FIRST-TIME SETUP: create a role.txt on each computer with one line:
--   DELIVERY   (delivery turtle)
--   SUPPORT    (support/chunk-loader turtle)
--   MINER      (ore mining turtle)
--   LOADER     (placed chunk-loader turtle, solo-mining sector flow)
--   WAREHOUSE  (warehouse computer)
--   SERVER     (central server computer)
--   ADMIN      (admin UI monitor computer)
--
-- Example:  echo DELIVERY > role.txt

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

-- Files every computer needs
local COMMON = {
    "protocol.lua",
    "waypoints.lua",
    "updater.lua",
    -- The fleet log's outbox. COMMON rather than per-role on purpose: the
    -- warehouse and admin computers are about to start requiring it, and the
    -- file has to be on disk BEFORE the code that requires it arrives. That
    -- ordering is not theoretical -- see the cloudstore note under SERVER, and
    -- 2026-08-27, when an OTA shipped a require ahead of its file and the
    -- server would not boot.
    "logship.lua",
}

-- Role-specific files: string = download as-is, table = {src, dst}
local ROLE_FILES = {
    DELIVERY  = {
        "turtle_base.lua",
        { src = "delivery_turtle.lua", dst = "startup.lua" },
    },
    SUPPORT   = {
        "turtle_base.lua",
        { src = "support_turtle.lua", dst = "startup.lua" },
    },
    MINER     = {
        "turtle_base.lua",
        "equipment.lua",
        "geofence.lua",
        "loader_state.lua",
        "mine_flow.lua",
        { src = "ore_turtle.lua", dst = "startup.lua" },
    },
    LOADER    = {
        { src = "loader_turtle.lua", dst = "startup.lua" },
    },
    WAREHOUSE = {
        { src = "warehouse.lua", dst = "startup.lua" },
    },
    SERVER    = {
        -- Must precede central_server: it requires cloudstore at load, and an
        -- OTA that ships the server without it bricks the boot.
        "cloudstore.lua",
        { src = "central_server.lua", dst = "startup.lua" },
        "stress_test.lua",
    },
    ADMIN     = {
        { src = "admin_ui.lua", dst = "startup.lua" },
    },
}

-- ─── Read role ───────────────────────────────────────────────────────────────

local role
local roleFile = fs.open("role.txt", "r")
if roleFile then
    role = roleFile.readLine()
    roleFile.close()
    role = role and role:match("^%s*(.-)%s*$"):upper()
else
    -- Accept role as command-line argument for first-time setup
    local arg = ...
    if arg then
        role = arg:match("^%s*(.-)%s*$"):upper()
        local f = fs.open("role.txt", "w")
        f.writeLine(role)
        f.close()
        print("Created role.txt: " .. role)
    end
end

if not role then
    print("ERROR: No role.txt found!")
    print("Usage: updater <ROLE>  or create role.txt manually")
    print("Valid roles: DELIVERY SUPPORT MINER LOADER WAREHOUSE SERVER ADMIN")
    return
end

if not ROLE_FILES[role] then
    print("ERROR: Unknown role '" .. tostring(role) .. "'")
    print("Valid roles: DELIVERY SUPPORT MINER LOADER WAREHOUSE SERVER ADMIN")
    return
end

print("=== Updater [" .. role .. "] ===")
-- Print free space up front. A full disk is the one failure that used to be
-- invisible: it killed this script mid-run and the reboot that followed erased
-- the evidence. Seeing the number before and after makes it self-evident.
local freeBefore = fs.getFreeSpace(".")
print("Free space: " .. tostring(freeBefore) .. "B")

-- ─── Download helper ─────────────────────────────────────────────────────────

local NO_CACHE = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }

local function download(src, dst)
    dst = dst or src
    local url = REPO .. src
    io.write("  " .. src)
    if dst ~= src then io.write(" -> " .. dst) end
    io.write("... ")

    local response = http.get(url, NO_CACHE)
    if not response then
        print("FAILED (no response)")
        return false
    end

    local content = response.readAll()
    response.close()

    if not content or #content == 0 then
        print("FAILED (empty response)")
        return false
    end

    -- Every write below is pcall'd. An unprotected fs write throws "Out of space"
    -- on a full disk, and because this is a plain script that error propagates out
    -- of the whole updater -- past the failure counter, past the summary, past the
    -- "NOT rebooting" guard. That is exactly how a dispatch computer ended up
    -- running an old server while advertising a new version: the small files
    -- landed, the 185 KB one threw, and the caller rebooted into the mixture.
    local function writeFile(path, data)
        local f = fs.open(path, "w")
        if not f then return false, "cannot open " .. path end
        local ok, err = pcall(function() f.write(data) end)
        pcall(function() f.close() end)
        if not ok then
            pcall(function() fs.delete(path) end)   -- never leave a partial file
            return false, tostring(err)
        end
        return true
    end

    -- Write to temp, then atomic rename.
    local tmp = dst .. ".tmp"
    local ok, err = writeFile(tmp, content)

    if not ok then
        -- The temp copy needs the file's own size free *alongside* the existing
        -- one, so updating a 185 KB file on a 1 MB disk needs 185 KB spare. When
        -- that is what failed, the safe recovery is to drop the old file and write
        -- in place: the content is already fully in memory, so the network is no
        -- longer involved and nothing else can fail in between.
        local free = fs.getFreeSpace(".")
        print("FAILED (" .. err .. ")")
        if fs.exists(dst) then
            print("    retrying in place: need " .. #content .. "B, free " .. tostring(free))
            local ok2, err2 = writeFile(dst, content)
            if ok2 then
                print("    OK (in place)")
                return true
            end
            print("    STILL FAILED (" .. err2 .. ") -- " .. dst .. " is now MISSING, re-run once space is free")
        end
        return false
    end

    if fs.exists(dst) then fs.delete(dst) end
    local okMove = pcall(function() fs.move(tmp, dst) end)
    if not okMove then
        print("FAILED (could not move " .. tmp .. " into place)")
        return false
    end
    print("OK")
    return true
end

-- ─── Download files ───────────────────────────────────────────────────────────

local failed = 0
-- Every destination this run is supposed to produce, and how big the content we
-- downloaded for it was. Checked against the disk at the end.
local expected = {}

local function record(dst, size) expected[#expected + 1] = { dst = dst, size = size } end

-- Our own file list is the thing in this script most likely to be out of date.
--
-- 2026-09-10, and it cost the whole fleet: turtle_base.lua gained a require on a
-- NEW module in the same release that added that module to COMMON. The updater
-- doing the work was the PREVIOUS version, running from the PREVIOUS list, so it
-- shipped the new turtle_base without the file it requires. Every turtle came
-- back from the reboot unable to start -- "module 'logship' not found", dropped
-- to a shell prompt, fifteen of them, in the world.
--
-- The manifest test added alongside that change verified the manifest was
-- self-consistent, which it was. A manifest cannot make the RUNNING program read
-- it. That is this function's job.
--
-- So: if this run replaced updater.lua with different bytes, the list above is
-- stale by definition and the only correct thing to do is start over with the
-- new one. It terminates after exactly one relaunch, because the second run
-- reads the file BEFORE downloading it and finds the two identical.
--
-- update.lua has always done this -- it re-downloads install.lua before running
-- it -- and this is the same idea for the over-the-air path.
local function readSelf()
    local f = fs.open("updater.lua", "r")
    if not f then return nil end
    local ok, content = pcall(function() return f.readAll() end)
    pcall(function() f.close() end)
    if not ok then return nil end
    return content
end

local selfBefore = readSelf()

print("Downloading common files...")
for _, file in ipairs(COMMON) do
    if download(file) then record(file) else failed = failed + 1 end
end

local selfAfter = readSelf()
if selfBefore and selfAfter and selfAfter ~= selfBefore then
    print("")
    print("updater.lua changed in this run.")
    print("Restarting with the new file list before touching role files --")
    print("an updater cannot ship a module it does not know about yet.")
    print("")
    shell.run("updater")
    return
end

print("Downloading " .. role .. " files...")
for _, entry in ipairs(ROLE_FILES[role]) do
    local ok, dst
    if type(entry) == "string" then
        ok, dst = download(entry), entry
    else
        ok, dst = download(entry.src, entry.dst), entry.dst
    end
    if ok then record(dst) else failed = failed + 1 end
end

-- ─── Verify what is actually on disk ─────────────────────────────────────────
--
-- Every step above reports success from what it did, not from what survived.
-- A write can report OK and leave nothing usable: the disk fills between the
-- write and the close, the move lands on a full volume, or a later file in the
-- same run consumes the space the earlier one is sitting in.
--
-- This is the check the whole "verify before you reboot" idea rests on, and
-- without it "all files updated successfully" is a statement about intentions.
-- A dispatch computer once came up running an old 211 KB server while
-- advertising a new proto.VERSION, because the small file landed and the big
-- one did not -- and everything reported success on the way past.
print("Verifying...")
for _, e in ipairs(expected) do
    local ok, size = pcall(fs.getSize, e.dst)
    if not fs.exists(e.dst) then
        print("  MISSING: " .. e.dst)
        failed = failed + 1
    elseif not ok or type(size) ~= "number" or size == 0 then
        print("  EMPTY: " .. e.dst)
        failed = failed + 1
    end
end
if failed == 0 then print("  all " .. #expected .. " files present and non-empty") end

-- ─── Done ────────────────────────────────────────────────────────────────────

if failed > 0 then
    print(string.format("\nUpdate finished with %d failure(s).", failed))
    print("Free space: " .. tostring(fs.getFreeSpace(".")) .. "B")
    print("Check HTTP APIs are enabled, and that the disk is not full.")
    print("NOT rebooting — fix errors first, then reboot manually.")
    -- Persisted because the caller reboots regardless of what we return, and the
    -- reboot wipes the terminal. Without this the only record of a failed update
    -- is a machine quietly running the wrong code.
    pcall(function()
        local f = fs.open("update_failed.txt", "w")
        if f then
            f.write(string.format("%d file(s) failed at %s, free=%sB\n",
                failed, tostring(os.date and os.date("%Y-%m-%d %H:%M:%S") or "?"),
                tostring(fs.getFreeSpace("."))))
            f.close()
        end
    end)
else
    -- Clear any marker from a previous failed run, so the server does not report
    -- a stale failure after a successful update.
    pcall(function() if fs.exists("update_failed.txt") then fs.delete("update_failed.txt") end end)
    print("\nAll files updated successfully!")
    print("Free space: " .. tostring(fs.getFreeSpace(".")) .. "B")
    print("Rebooting in 3 seconds...")
    sleep(3)
    os.reboot()
end
