-- updater.lua
-- Downloads the latest version of all system files from GitHub.
-- Triggered automatically when the server sends UPDATE_ALL, or run manually.
--
-- FIRST-TIME SETUP: create a role.txt on each computer with one line:
--   DELIVERY   (delivery turtle)
--   SUPPORT    (support/chunk-loader turtle)
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
    WAREHOUSE = {
        { src = "warehouse.lua", dst = "startup.lua" },
    },
    SERVER    = {
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
    print("Valid roles: DELIVERY SUPPORT WAREHOUSE SERVER ADMIN")
    return
end

if not ROLE_FILES[role] then
    print("ERROR: Unknown role '" .. tostring(role) .. "'")
    print("Valid roles: DELIVERY SUPPORT WAREHOUSE SERVER ADMIN")
    return
end

print("=== Updater [" .. role .. "] ===")

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

    -- Write to temp, then atomic rename
    local tmp = dst .. ".tmp"
    local f = fs.open(tmp, "w")
    if not f then
        print("FAILED (can't open " .. tmp .. " for writing)")
        return false
    end
    f.write(content)
    f.close()

    if fs.exists(dst) then fs.delete(dst) end
    fs.move(tmp, dst)
    print("OK")
    return true
end

-- ─── Download files ───────────────────────────────────────────────────────────

local failed = 0

print("Downloading common files...")
for _, file in ipairs(COMMON) do
    if not download(file) then failed = failed + 1 end
end

print("Downloading " .. role .. " files...")
for _, entry in ipairs(ROLE_FILES[role]) do
    local ok
    if type(entry) == "string" then
        ok = download(entry)
    else
        ok = download(entry.src, entry.dst)
    end
    if not ok then failed = failed + 1 end
end

-- ─── Done ────────────────────────────────────────────────────────────────────

if failed > 0 then
    print(string.format("\nUpdate finished with %d failure(s).", failed))
    print("Check that HTTP APIs are enabled in ComputerCraft config.")
    print("NOT rebooting — fix errors first, then reboot manually.")
else
    print("\nAll files updated successfully!")
    print("Rebooting in 3 seconds...")
    sleep(3)
    os.reboot()
end
