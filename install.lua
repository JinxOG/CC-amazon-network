-- install.lua
-- Usage (from any CC computer with internet access):
--   pastebin run <install_id> server
--   pastebin run <install_id> delivery
--   pastebin run <install_id> support
--
-- Or copy install.lua to the computer and run:
--   install server | install delivery | install support

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

local FILES = {
    protocol        = "protocol.lua",
    central_server  = "central_server.lua",
    turtle_base     = "turtle_base.lua",
    waypoints       = "waypoints.lua",
    startup_server  = "startup_server.lua",
    delivery_turtle = "delivery_turtle.lua",
    support_turtle  = "support_turtle.lua",
}

local PROFILES = {
    server = {
        { src = FILES.protocol,       name = "protocol.lua"       },
        { src = FILES.waypoints,      name = "waypoints.lua"      },
        { src = FILES.central_server, name = "central_server.lua" },
        { src = FILES.startup_server, name = "startup.lua"        },
    },
    delivery = {
        { src = FILES.protocol,        name = "protocol.lua"    },
        { src = FILES.waypoints,       name = "waypoints.lua"   },
        { src = FILES.turtle_base,     name = "turtle_base.lua" },
        { src = FILES.delivery_turtle, name = "startup.lua"     },
    },
    support = {
        { src = FILES.protocol,       name = "protocol.lua"    },
        { src = FILES.waypoints,      name = "waypoints.lua"   },
        { src = FILES.turtle_base,    name = "turtle_base.lua" },
        { src = FILES.support_turtle, name = "startup.lua"     },
    },
}

-- ─── helpers ─────────────────────────────────────────────────────────────────

local function download(url, dest)
    if fs.exists(dest) then fs.delete(dest) end
    local ok = shell.run("wget", url, dest)
    return ok
end

-- ─── main ────────────────────────────────────────────────────────────────────

local role = arg and arg[1]
if not role then
    io.write("Install as [server/delivery/support]: ")
    role = io.read()
end
role = role:lower():gsub("%s+", "")

local files = PROFILES[role]
if not files then
    print("Unknown role '" .. role .. "'. Use: server, delivery, or support")
    return
end

print("Installing: " .. role)
print("Repo: " .. REPO)
print("")

local failed = false
for _, f in ipairs(files) do
    io.write("  " .. f.name .. "... ")
    local url = REPO .. f.src
    local ok  = download(url, f.name)
    print(ok and "OK" or "FAILED")
    if not ok then failed = true end
end

print("")
if failed then
    print("Some files failed. Check internet access or run again.")
else
    -- Save role so update.lua can re-install without asking
    local f = fs.open(".role", "w")
    f.write(role)
    f.close()
    print("Done! Reboot to apply (Ctrl+R).")
end
