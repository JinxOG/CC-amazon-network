-- android_update.lua
-- Run this to pull the latest android files from GitHub and reboot.
local BASE = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"
local files = { "protocol.lua", "android_base.lua", "android_main.lua", "android_update.lua" }

for _, name in ipairs(files) do
    print("Downloading " .. name .. "...")
    local ok, err = http.get(BASE .. name)
    if not ok then
        print("FAILED: " .. tostring(err))
    else
        local f = fs.open(name, "w")
        f.write(ok.readAll())
        f.close()
        ok.close()
        print("OK")
    end
end

print("Done. Rebooting...")
os.reboot()
