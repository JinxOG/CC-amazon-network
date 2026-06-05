-- setup.lua
-- One-command bootstrap for a brand-new turtle or computer.
-- Downloads a fresh updater.lua then runs it with the given role.
--
-- Usage (from any CC terminal with HTTP enabled):
--   wget run https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/setup.lua DELIVERY
--   wget run https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/setup.lua SUPPORT
--   wget run https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/setup.lua SERVER
--
-- Valid roles: DELIVERY  SUPPORT  WAREHOUSE  SERVER  ADMIN

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

local role = ...
if not role then
    print("Usage: setup <ROLE>")
    print("Roles: DELIVERY  SUPPORT  WAREHOUSE  SERVER  ADMIN")
    return
end

print("=== Setup [" .. role:upper() .. "] ===")
print("Downloading updater...")

local url = REPO .. "updater.lua?cb=" .. tostring(os.epoch("utc"))
local r = http.get(url)
if not r then
    print("ERROR: HTTP request failed.")
    print("Make sure HTTP is enabled in the CC config.")
    return
end

local f = fs.open("updater.lua", "w")
f.write(r.readAll())
f.close()
r.close()

print("Running updater...")
shell.run("updater", role)
