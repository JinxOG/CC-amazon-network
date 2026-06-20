-- android_update.lua
-- Run this to pull the latest android files from GitHub and reboot.
local BASE  = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"
local files = { "protocol.lua", "android_base.lua", "android_main.lua", "android_update.lua" }

for _, name in ipairs(files) do
    print("Downloading " .. name .. "...")
    local res, err = http.get(BASE .. name)
    if not res then
        print("FAILED: " .. tostring(err))
    else
        local f = fs.open(name, "w")
        f.write(res.readAll())
        f.close()
        res.close()
        print("OK")
    end
end

-- Write startup.lua so android_main runs automatically on boot
local s = fs.open("startup.lua", "w")
s.write('shell.run("android_main")\n')
s.close()
print("startup.lua written")

-- Print installed version
local ok, src = pcall(loadfile, "android_base.lua")
if ok and src then
    local env = { }
    local ver = "unknown"
    local chunk = src
    -- extract version line directly
    local f2 = fs.open("android_base.lua", "r")
    local content = f2.readAll()
    f2.close()
    ver = content:match('ANDROID_VERSION = "([^"]+)"') or "unknown"
    print("Installed version: " .. ver)
end

print("Done. Rebooting...")
os.reboot()
