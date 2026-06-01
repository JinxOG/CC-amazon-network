-- update.lua
-- Re-downloads all files for this computer's role from GitHub, then reboots.
-- Run with: update
-- Role is saved automatically by install.lua in .role

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

-- Read saved role
local role
if fs.exists(".role") then
    local f = fs.open(".role", "r")
    role = f.readAll():gsub("%s+", "")
    f.close()
end

if not role or role == "" then
    print("No role found. Run 'install <role>' first.")
    return
end

print("Updating role: " .. role)
print("Fetching latest install.lua...")

-- Always re-download install.lua itself first so we get any new file list
if fs.exists("install.lua") then fs.delete("install.lua") end
local ok = shell.run("wget", REPO .. "install.lua", "install.lua")
if not ok then
    print("Failed to download install.lua. Check internet access.")
    return
end

-- Run install for saved role (it will save .role again)
print("Running install...")
shell.run("install", role)

print("")
print("Update complete! Rebooting in 3 seconds...")
sleep(3)
os.reboot()
