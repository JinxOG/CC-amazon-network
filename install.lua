-- install.lua
-- Usage (from any CC computer with internet access):
--   pastebin run <install_id> server
--   pastebin run <install_id> delivery
--   pastebin run <install_id> support
--   pastebin run <install_id> miner
--
-- Or copy install.lua to the computer and run:
--   install server | install delivery | install support | install miner

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

local FILES = {
    protocol        = "protocol.lua",
    updater         = "updater.lua",
    central_server  = "central_server.lua",
    turtle_base     = "turtle_base.lua",
    waypoints       = "waypoints.lua",
    startup_server  = "startup_server.lua",
    delivery_turtle = "delivery_turtle.lua",
    support_turtle  = "support_turtle.lua",
    ore_turtle      = "ore_turtle.lua",
    admin_ui        = "admin_ui.lua",
    warehouse       = "warehouse.lua",
    warehouse_test  = "warehouse_test.lua",
}

local PROFILES = {
    server = {
        { src = FILES.protocol,       name = "protocol.lua"       },
        { src = FILES.updater,        name = "updater.lua"        },
        { src = FILES.waypoints,      name = "waypoints.lua"      },
        { src = FILES.central_server, name = "central_server.lua" },
        { src = FILES.startup_server, name = "startup.lua"        },
    },
    admin = {
        { src = FILES.protocol, name = "protocol.lua" },
        { src = FILES.updater,  name = "updater.lua"  },
        { src = FILES.admin_ui, name = "startup.lua"  },
    },
    warehouse = {
        { src = FILES.protocol,       name = "protocol.lua"        },
        { src = FILES.updater,        name = "updater.lua"         },
        { src = FILES.warehouse,      name = "startup.lua"         },
        { src = FILES.warehouse_test, name = "warehouse_test.lua"  },
    },
    delivery = {
        { src = FILES.protocol,        name = "protocol.lua"    },
        { src = FILES.updater,         name = "updater.lua"     },
        { src = FILES.waypoints,       name = "waypoints.lua"   },
        { src = FILES.turtle_base,     name = "turtle_base.lua" },
        { src = FILES.delivery_turtle, name = "startup.lua"     },
    },
    support = {
        { src = FILES.protocol,       name = "protocol.lua"    },
        { src = FILES.updater,        name = "updater.lua"     },
        { src = FILES.waypoints,      name = "waypoints.lua"   },
        { src = FILES.turtle_base,    name = "turtle_base.lua" },
        { src = FILES.support_turtle, name = "startup.lua"     },
    },
    miner = {
        { src = FILES.protocol,    name = "protocol.lua"    },
        { src = FILES.updater,     name = "updater.lua"     },
        { src = FILES.waypoints,   name = "waypoints.lua"   },
        { src = FILES.turtle_base, name = "turtle_base.lua" },
        { src = FILES.ore_turtle,  name = "startup.lua"     },
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
    io.write("Install as [server/delivery/support/miner]: ")
    role = io.read()
end
role = role:lower():gsub("%s+", "")

local files = PROFILES[role]
if not files then
    print("Unknown role '" .. role .. "'. Use: server, delivery, support, or miner")
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
    -- Save role for both update mechanisms:
    --   .role   → used by update.lua (manual)
    --   role.txt → used by updater.lua (OTA via UPDATE_ALL)
    local f = fs.open(".role", "w")
    f.write(role)
    f.close()
    local f2 = fs.open("role.txt", "w")
    f2.writeLine(role:upper())
    f2.close()
    print("Done! Reboot to apply (Ctrl+R).")
end
