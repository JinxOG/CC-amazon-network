-- delivery_turtle.lua
-- Rename to startup.lua on any delivery/worker turtle.
-- Route: dock → dispatch hole → underground travel → ascend at destination
--        → drop items → descend → arrivals hole → dock

local base  = require("turtle_base")
local proto = require("protocol")

local UNDERGROUND_Y = 60   -- Y level for all underground travel

base.init(proto.ROLE.DELIVERY)

base.run(function(job)
    local params = job.params
    local d      = params.destination
    base.setPartnerId(params.partnerId)

    -- ── Step 1: Load items ────────────────────────────────────────────────────

    base.setStatus(proto.STATUS.LOADING, job.id)
    base.sendProgress("Requesting items from warehouse")

    local loaded = base.requestItems(params.items, nil, 90)
    if not loaded then
        return base.sendFailed("warehouse_timeout", true)
    end

    -- ── Step 2: Depart depot via dispatch hole ────────────────────────────────
    -- Exits building and descends to UNDERGROUND_Y

    local ok, err = base.depart()
    if not ok then
        return base.sendFailed("departure_failed: " .. (err or "?"), true)
    end

    -- ── Step 3: Travel underground to destination X,Z ─────────────────────────
    -- Stay at UNDERGROUND_Y the entire journey to avoid surface structures

    base.setStatus(proto.STATUS.TRAVELLING, job.id)
    base.sendProgress(string.format("Underground travel to %d,%d", d.x, d.z))

    ok, err = base.move.to(d.x, UNDERGROUND_Y, d.z)
    if not ok then
        return base.sendFailed("underground nav failed: " .. (err or "?"), true)
    end

    -- ── Step 4: Ascend to delivery Y at destination ───────────────────────────

    base.sendProgress(string.format("Ascending to delivery point Y=%d", d.y))
    ok, err = base.move.to(d.x, d.y, d.z)
    if not ok then
        return base.sendFailed("ascent failed: " .. (err or "?"), true)
    end

    -- ── Step 5: Drop items ────────────────────────────────────────────────────

    base.setStatus(proto.STATUS.WORKING, job.id)
    base.sendProgress("Delivering items")

    for slot = 1, 15 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if not turtle.dropDown() then
                if not turtle.drop() then
                    turtle.dropUp()
                end
            end
        end
    end
    turtle.select(1)

    -- ── Step 6: Descend back to underground travel level ─────────────────────

    base.sendProgress("Descending to underground level")
    ok, err = base.move.to(d.x, UNDERGROUND_Y, d.z)
    if not ok then
        logWarn("Could not fully descend — attempting return anyway")
    end

    -- ── Step 7: Return via arrivals hole ─────────────────────────────────────

    ok, err = base.returnToDock()
    if not ok then
        print("Warning: return route issue: " .. (err or "?"))
    end

    base.sendComplete({ destination = d })
end)
