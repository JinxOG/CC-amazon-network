-- install.lua
-- Usage:
--   install server     (command computer)
--   install delivery   (delivery turtle)
--   install support    (support/chunk-loader turtle)

-- !! Update these IDs after uploading each file to Pastebin !!
local PASTES = {
    protocol        = "yFvBSUxp",
    central_server  = "UgmXje66",
    turtle_base     = "m0CibGmG",
    waypoints       = "q33mjLd7",
    startup_server  = "ws9FYYGH",
    delivery_turtle = "s6HZad6V",
    support_turtle  = "8Giq1URK",
}

local PROFILES = {
    server = {
        { id = PASTES.protocol,       name = "protocol.lua"        },
        { id = PASTES.waypoints,      name = "waypoints.lua"       },
        { id = PASTES.central_server, name = "central_server.lua"  },
        { id = PASTES.startup_server, name = "startup.lua"         },
    },
    delivery = {
        { id = PASTES.protocol,        name = "protocol.lua"        },
        { id = PASTES.waypoints,       name = "waypoints.lua"       },
        { id = PASTES.turtle_base,     name = "turtle_base.lua"     },
        { id = PASTES.delivery_turtle, name = "startup.lua"         },
    },
    support = {
        { id = PASTES.protocol,       name = "protocol.lua"        },
        { id = PASTES.waypoints,      name = "waypoints.lua"       },
        { id = PASTES.turtle_base,    name = "turtle_base.lua"     },
        { id = PASTES.support_turtle, name = "startup.lua"         },
    },
}

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
print("")

local failed = false
for _, f in ipairs(files) do
    if f.id == "XXXXXXXX" then
        print("  SKIP " .. f.name .. " (no Pastebin ID yet)")
        failed = true
    else
        io.write("  " .. f.name .. "... ")
        -- Delete existing file so pastebin get doesn't refuse
        if fs.exists(f.name) then fs.delete(f.name) end
        local ok = shell.run("pastebin", "get", f.id, f.name)
        print(ok and "OK" or "FAILED")
        if not ok then failed = true end
    end
end

print("")
if failed then
    print("Some files failed. Check IDs and internet access.")
else
    print("Done. Reboot to apply (Ctrl+R).")
end
