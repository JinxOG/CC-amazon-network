-- startup_server.lua
-- Runs the server loop and a command shell in parallel.
-- Type commands while the server runs in the background.

local server = require("central_server")

-- Simple command shell running alongside the server
local function shell()
    print("Server shell ready. Commands:")
    print("  job <x> <y> <z>     -- submit a test delivery")
    print("  list                -- show registered turtles")
    print("  jobs                -- show job queue")
    print("  recall              -- recall all turtles")
    print("  cancel <jobId>      -- cancel a specific job (and its paired support job)")
    print("  cancelall           -- cancel every non-finished job and clear the queue")
    print("")

    while true do
        io.write("> ")
        local input = io.read()
        if not input then break end
        local args = {}
        for word in input:gmatch("%S+") do table.insert(args, word) end
        local cmd = args[1]

        if cmd == "job" and #args == 4 then
            local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
            local id = server.submitJob("DELIVER", {
                items       = { ["minecraft:cobblestone"] = 1 },
                destination = { x=x, y=y, z=z },
            }, 1)
            print("Submitted: " .. id)

        elseif cmd == "list" then
            local state = server.getState()
            for id, t in pairs(state.registry) do
                print(string.format("  %s [%s] %s fuel=%d dock=%s",
                    id, t.role, t.online and "ONLINE" or "OFFLINE",
                    t.fuel or 0,
                    t.dock and ("bay"..t.dock.bay..t.dock.row) or "none"))
            end

        elseif cmd == "jobs" then
            local state = server.getState()
            for id, j in pairs(state.jobs) do
                print(string.format("  %s [%s] %s -> %s",
                    id, j.type, j.status, j.assignedTo or "unassigned"))
            end

        elseif cmd == "recall" then
            server.recallAll("manual")
            print("Recalled all turtles.")

        elseif cmd == "ping" and #args == 2 then
            -- Request a position update from a specific turtle
            -- Usage: ping node_70
            local targetId = args[2]
            local state    = server.getState()
            local t        = state.registry[targetId]
            if t then
                if t.position then
                    print(string.format("%s last known: %d, %d, %d (%.1fs ago)",
                        targetId,
                        t.position.x, t.position.y, t.position.z,
                        (os.epoch("utc") - t.lastSeen) / 1000))
                else
                    print(targetId .. " has no position data yet.")
                end
            else
                print("Unknown turtle: " .. targetId)
            end

        elseif cmd == "kick" and #args == 2 then
            -- Permanently remove a lost/unrecoverable turtle from the registry.
            -- Releases its dock, cancels its job, wipes it from the list.
            -- Usage: kick node_45
            local targetId = args[2]
            local state    = server.getState()
            local t        = state.registry[targetId]
            if t then
                local W        = require("waypoints")
                local dockRole = (t.role == "SUPPORT") and "SUPPORT" or "DELIVERY"
                -- Release dock slot
                W.releaseDock(dockRole, targetId)
                -- Cancel any active job
                if t.jobId then
                    server.cancelJob(t.jobId)
                end
                -- Wipe from registry entirely
                state.registry[targetId] = nil
                print("Removed " .. targetId .. " — dock released, registry cleared.")
            else
                print("Unknown turtle: " .. targetId)
            end

        elseif cmd == "cancel" and #args == 2 then
            local ok, err = server.cancelJob(args[2])
            if ok then
                print("Cancelled " .. args[2] .. " (and linked support job if any).")
            else
                print("Cannot cancel: " .. (err or "?"))
            end

        elseif cmd == "cancelall" then
            local st = server.getState()
            local cancelled = 0
            for jobId, job in pairs(st.jobs) do
                if job.status ~= "COMPLETE" and job.status ~= "FAILED" and job.status ~= "CANCELLED" then
                    server.cancelJob(jobId)
                    cancelled = cancelled + 1
                end
            end
            print(string.format("Cancelled %d jobs. Both turtles should return to dock.", cancelled))

        else
            print("Unknown command: " .. (cmd or ""))
        end
    end
end

print("Starting central server...")
parallel.waitForAny(server.run, shell)
