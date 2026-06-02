-- waypoints.lua
-- Physical layout of the turtle depot.
-- Defines every dock, taxiway, hole, and route in the building.
-- Installed on: server computer + all turtles.

local W = {}

-- ─── Adjust These If Layout Changes ─────────────────────────────────────────

local CFG = {
    FLOOR_Y          = 67,
    NUM_WORKER_BAYS  = 5,
    NUM_SUPPORT_BAYS = 5,
    BAY_CENTER_X     = 157,     -- Bay 1 center X (pillar column)
    BAY_SPACING      = 14,      -- X blocks between bay centers (confirmed: 157→171)
    BELOW_HOLE_Y     = 60,      -- Y level for underground travel (above lava/caves)
}

-- ─── Taxiways ────────────────────────────────────────────────────────────────

W.WHITE_Z = -2803   -- outbound dispatch lane
W.RED_Z   = -2801   -- inbound return lane

-- ─── Holes ───────────────────────────────────────────────────────────────────

W.DISPATCH_HOLE    = { x = 143, y = CFG.FLOOR_Y,      z = -2813 }  -- go DOWN to leave
W.DISPATCH_STAGING = { x = 143, y = CFG.FLOOR_Y,      z = -2812 }  -- 1 block before hole (support waits here)
W.ARRIVALS_HOLE    = { x = 228, y = CFG.FLOOR_Y,      z = -2782 }  -- come UP to return
W.WORLD_EXIT       = { x = 143, y = CFG.BELOW_HOLE_Y, z = -2813 }  -- below dispatch hole
W.WORLD_ENTRY      = { x = 228, y = CFG.BELOW_HOLE_Y, z = -2782 }  -- below arrivals hole

-- ─── Bay Slot Layout ─────────────────────────────────────────────────────────
-- Each bay has 2 rows of 8 slots. Pillar sits at center X so slots
-- are offset ±1 to ±4 from center (skipping 0).

local SLOT_OFFSETS = { -4, -3, -2, -1, 1, 2, 3, 4 }  -- dx from bay center X

-- Worker bays: south of taxiway
local WORKER_ROW_A_Z = -2806   -- closer to taxiway
local WORKER_ROW_B_Z = -2810   -- further from taxiway

-- Support/chunky bays: north of taxiway
local SUPPORT_ROW_A_Z = -2797  -- closer to taxiway
local SUPPORT_ROW_B_Z = -2793  -- further from taxiway (confirmed back corner)

-- ─── Dock Generation ─────────────────────────────────────────────────────────

W.docks = {
    DELIVERY = {},
    SUPPORT  = {},
}

local function generateBays(role, numBays, rowAZ, rowBZ)
    local docks = W.docks[role]
    for bay = 1, numBays do
        local centerX  = CFG.BAY_CENTER_X + (bay - 1) * CFG.BAY_SPACING
        local junction = { x = centerX, y = CFG.FLOOR_Y, z = W.WHITE_Z }

        for _, dx in ipairs(SLOT_OFFSETS) do
            -- Row A
            table.insert(docks, {
                role     = role,
                bay      = bay,
                x        = centerX + dx,
                y        = CFG.FLOOR_Y,
                z        = rowAZ,
                row      = "A",
                junction = junction,
            })
            -- Row B
            table.insert(docks, {
                role     = role,
                bay      = bay,
                x        = centerX + dx,
                y        = CFG.FLOOR_Y,
                z        = rowBZ,
                row      = "B",
                junction = junction,
            })
        end
    end
end

generateBays("DELIVERY", CFG.NUM_WORKER_BAYS,  WORKER_ROW_A_Z,  WORKER_ROW_B_Z)
generateBays("SUPPORT",  CFG.NUM_SUPPORT_BAYS, SUPPORT_ROW_A_Z, SUPPORT_ROW_B_Z)

-- ─── Dock Assignment (server-side) ───────────────────────────────────────────

local _assigned = {}  -- [role][dockIndex] = turtleId

function W.assignDock(role, turtleId)
    if not _assigned[role] then _assigned[role] = {} end
    local docks = W.docks[role]
    for i, dock in ipairs(docks) do
        if not _assigned[role][i] then
            _assigned[role][i] = turtleId
            return dock
        end
    end
    return nil  -- depot full
end

function W.releaseDock(role, turtleId)
    if not _assigned[role] then return end
    for i, id in pairs(_assigned[role]) do
        if id == turtleId then
            _assigned[role][i] = nil
            return
        end
    end
end

function W.getDockFor(role, turtleId)
    if not _assigned[role] then return nil end
    local docks = W.docks[role]
    for i, id in pairs(_assigned[role]) do
        if id == turtleId then return docks[i] end
    end
    return nil
end

-- ─── Route Builders (turtle-side) ────────────────────────────────────────────
-- Each route is an ordered list of {x, y, z} waypoints.
-- Turtles call move.to() on each in sequence.
--
-- AISLE SYSTEM — avoids crossing occupied dock positions:
--   Every row has a dedicated aisle Z that is 2 blocks toward the taxiway.
--   No dock slots exist in the aisle lanes; only the bay centre column
--   (junction.x, offset 0 — always empty) is used to cross between rows.
--
--   Departure:  slot → aisle (perpendicular, no docks) → centre column →
--               taxiway → hole
--   Return:     taxiway → centre column → aisle → slot column →
--               slot (perpendicular back in)

-- Returns the aisle Z for a dock: 2 blocks from the dock row toward WHITE_Z.
local function aisleZ(dock)
    local dir = W.WHITE_Z > dock.z and 1 or -1
    return dock.z + dir * 2
end

-- Departure: worker turtle leaves slot without crossing any occupied row.
function W.departureRoute(dock)
    local az = aisleZ(dock)
    return {
        -- 1. Exit slot perpendicular (toward taxiway) into clear aisle lane
        { x = dock.x,            y = CFG.FLOOR_Y, z = az                  },
        -- 2. Travel along aisle to bay centre column (always unoccupied)
        { x = dock.junction.x,   y = CFG.FLOOR_Y, z = az                  },
        -- 3. Merge onto white taxiway at centre column
        { x = dock.junction.x,   y = CFG.FLOOR_Y, z = W.WHITE_Z           },
        -- 4. Travel along taxiway to dispatch hole
        { x = W.DISPATCH_HOLE.x, y = CFG.FLOOR_Y, z = W.WHITE_Z           },
        { x = W.DISPATCH_HOLE.x, y = CFG.FLOOR_Y, z = W.DISPATCH_HOLE.z  },
    }
end

-- Support departure: identical aisle logic, stops at staging block before hole.
function W.supportDepartureRoute(dock)
    local az = aisleZ(dock)
    return {
        { x = dock.x,               y = CFG.FLOOR_Y, z = az                    },
        { x = dock.junction.x,      y = CFG.FLOOR_Y, z = az                    },
        { x = dock.junction.x,      y = CFG.FLOOR_Y, z = W.WHITE_Z             },
        { x = W.DISPATCH_HOLE.x,    y = CFG.FLOOR_Y, z = W.WHITE_Z             },
        { x = W.DISPATCH_STAGING.x, y = CFG.FLOOR_Y, z = W.DISPATCH_STAGING.z },
    }
end

-- Return: arrivals hole → red taxiway → centre column → aisle → slot.
function W.returnRoute(dock)
    local az = aisleZ(dock)
    return {
        -- 1. Get onto red taxiway from arrivals hole
        { x = W.ARRIVALS_HOLE.x, y = CFG.FLOOR_Y, z = W.RED_Z },
        -- 2. Travel along red taxiway to bay centre column X
        { x = dock.junction.x,   y = CFG.FLOOR_Y, z = W.RED_Z },
        -- 3. Drop from taxiway to aisle via centre column (always clear)
        { x = dock.junction.x,   y = CFG.FLOOR_Y, z = az       },
        -- 4. Move along aisle to dock's column X
        { x = dock.x,            y = CFG.FLOOR_Y, z = az       },
        -- 5. Enter dock slot perpendicular (back into row)
        { x = dock.x,            y = CFG.FLOOR_Y, z = dock.z   },
    }
end

-- ─── Utility ─────────────────────────────────────────────────────────────────

function W.totalDocks(role)
    return #W.docks[role]
end

function W.freeDocks(role)
    if not _assigned[role] then return W.totalDocks(role) end
    local used = 0
    for _ in pairs(_assigned[role]) do used = used + 1 end
    return W.totalDocks(role) - used
end

return W
