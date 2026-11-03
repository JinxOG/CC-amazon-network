-- install.lua
-- Usage (from any CC computer with internet access):
--   pastebin run <install_id> server
--   pastebin run <install_id> delivery
--   pastebin run <install_id> support
--   pastebin run <install_id> miner
--   pastebin run <install_id> loader
--
-- Or copy install.lua to the computer and run:
--   install server | install delivery | install support | install miner | install loader

local REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"

local FILES = {
    protocol        = "protocol.lua",
    updater         = "updater.lua",
    central_server  = "central_server.lua",
    turtle_base     = "turtle_base.lua",
    logship         = "logship.lua",
    waypoints       = "waypoints.lua",
    startup_server  = "startup_server.lua",
    delivery_turtle = "delivery_turtle.lua",
    support_turtle  = "support_turtle.lua",
    ore_turtle      = "ore_turtle.lua",
    admin_ui        = "admin_ui.lua",
    warehouse       = "warehouse.lua",
    warehouse_test  = "warehouse_test.lua",
    equipment       = "equipment.lua",
    geofence        = "geofence.lua",
    loader_state    = "loader_state.lua",
    mine_flow       = "mine_flow.lua",
    loader_turtle   = "loader_turtle.lua",
    cloudstore      = "cloudstore.lua",
}

local PROFILES = {
    server = {
        { src = FILES.protocol,       name = "protocol.lua"       },
        { src = FILES.updater,        name = "updater.lua"        },
        -- Ships to every role: turtle_base requires it at load, and the
        -- warehouse and admin computers are next. A require that lands before
        -- its file does not degrade, it refuses to boot.
        { src = FILES.logship,        name = "logship.lua"        },
        { src = FILES.waypoints,      name = "waypoints.lua"      },
        -- central_server requires this at load. Without it the server does not
        -- start at all -- observed 2026-08-27, "module 'cloudstore' not found"
        -- on boot, because the require shipped before the deployment entry did.
        { src = FILES.cloudstore,     name = "cloudstore.lua"     },
        -- The server IS startup.lua, as every update writes it (updater.lua). Installing
        -- it as central_server.lua beside a startup_server.lua launcher left, after
        -- the first update, a 346 KB copy nothing ran (2026-11-02, W3's disk card).
        { src = FILES.central_server, name = "startup.lua"        },
    },
    admin = {
        { src = FILES.protocol, name = "protocol.lua" },
        { src = FILES.updater,  name = "updater.lua"  },
        { src = FILES.logship,  name = "logship.lua"  },
        { src = FILES.admin_ui, name = "startup.lua"  },
    },
    warehouse = {
        { src = FILES.protocol,       name = "protocol.lua"        },
        { src = FILES.updater,        name = "updater.lua"         },
        { src = FILES.logship,        name = "logship.lua"         },
        { src = FILES.warehouse,      name = "startup.lua"         },
        { src = FILES.warehouse_test, name = "warehouse_test.lua"  },
    },
    delivery = {
        { src = FILES.protocol,        name = "protocol.lua"    },
        { src = FILES.updater,         name = "updater.lua"     },
        { src = FILES.logship,         name = "logship.lua"     },
        { src = FILES.waypoints,       name = "waypoints.lua"   },
        { src = FILES.turtle_base,     name = "turtle_base.lua" },
        { src = FILES.delivery_turtle, name = "startup.lua"     },
    },
    support = {
        { src = FILES.protocol,       name = "protocol.lua"    },
        { src = FILES.updater,        name = "updater.lua"     },
        { src = FILES.logship,        name = "logship.lua"     },
        { src = FILES.waypoints,      name = "waypoints.lua"   },
        { src = FILES.turtle_base,    name = "turtle_base.lua" },
        { src = FILES.support_turtle, name = "startup.lua"     },
    },
    miner = {
        { src = FILES.protocol,     name = "protocol.lua"     },
        { src = FILES.updater,      name = "updater.lua"      },
        { src = FILES.logship,      name = "logship.lua"      },
        { src = FILES.waypoints,    name = "waypoints.lua"    },
        { src = FILES.turtle_base,  name = "turtle_base.lua"  },
        { src = FILES.equipment,    name = "equipment.lua"    },
        { src = FILES.geofence,     name = "geofence.lua"     },
        { src = FILES.loader_state, name = "loader_state.lua" },
        { src = FILES.mine_flow,    name = "mine_flow.lua"    },
        { src = FILES.ore_turtle,   name = "startup.lua"      },
    },
    loader = {
        { src = FILES.protocol,      name = "protocol.lua" },
        { src = FILES.updater,       name = "updater.lua"  },
        { src = FILES.logship,       name = "logship.lua"  },
        { src = FILES.loader_turtle, name = "startup.lua"  },
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
    io.write("Install as [server/delivery/support/miner/loader]: ")
    role = io.read()
end
role = role:lower():gsub("%s+", "")

local files = PROFILES[role]
if not files then
    print("Unknown role '" .. role .. "'. Use: server, delivery, support, miner, or loader")
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

-- Lua goes to disk without its comments and indentation, line breaks kept --
-- the same strip the updater applies to every update (minify, in updater.lua,
-- which is installed first). A file that cannot be stripped is left as it came.
if not failed then
    _G.__UPDATER_MINIFY_ONLY = true
    local okM, minify = pcall(function()
        local h = fs.open("updater.lua", "r")
        local text = h and h.readAll()
        if h then h.close() end
        local chunk = text and load(text, "@updater.lua", "t", _ENV)
        return chunk and chunk()
    end)
    _G.__UPDATER_MINIFY_ONLY = nil
    if okM and type(minify) == "function" then
        for _, f in ipairs(files) do
            if f.name:match("%.lua$") and fs.exists(f.name) then
                local h = fs.open(f.name, "r")
                local text = h and h.readAll() or ""
                if h then h.close() end
                local okS, small = pcall(minify, text)
                if okS and type(small) == "string" and #small > 0 and #small < #text then
                    local w = fs.open(f.name, "w")
                    if w then w.write(small); w.close() end
                end
            end
        end
    end
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
