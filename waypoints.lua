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
local DOCK_SAVE_FILE = "dock_assignments.dat"

local function saveDockAssignments()
    local f = fs.open(DOCK_SAVE_FILE, "w")
    if f then f.write(textutils.serialise(_assigned)); f.close() end
end

function W.loadDockAssignments()
    if not fs.exists(DOCK_SAVE_FILE) then return end
    local f = fs.open(DOCK_SAVE_FILE, "r")
    if not f then return end
    local data = textutils.unserialise(f.readAll())
    f.close()
    if type(data) ~= "table" then return end
    -- textutils.serialise converts number table keys to strings.
    -- Convert them back so dock index lookups (which use ipairs numbers) work.
    local fixed = {}
    for role, slots in pairs(data) do
        fixed[role] = {}
        for k, v in pairs(slots) do
            fixed[role][tonumber(k) or k] = v
        end
    end
    _assigned = fixed
end

function W.assignDock(role, turtleId)
    if not _assigned[role] then _assigned[role] = {} end
    local docks = W.docks[role]
    for i, dock in ipairs(docks) do
        if not _assigned[role][i] then
            _assigned[role][i] = turtleId
            saveDockAssignments()
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
            saveDockAssignments()
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
--   Every row exits AWAY from the taxiway into a back aisle (2 blocks
--   behind the row). No dock slots exist there. The bay centre column
--   (junction.x, offset 0 — always empty) is then used to travel all
--   the way from the back aisle to the taxiway without crossing any row.
--
--   Departure:  slot → back aisle (perpendicular, away from taxiway)
--               → back aisle to centre column
--               → centre column all the way to taxiway
--               → taxiway to hole
--   Return:     reverse of above

-- Returns the DEPARTURE aisle Z for a dock: 2 blocks AWAY from the taxiway.
-- Departing turtles use this lane.
local function aisleZ(dock)
    local dir = W.WHITE_Z > dock.z and 1 or -1
    return dock.z - dir * 2   -- opposite direction to taxiway
end

-- Returns the RETURN aisle Z for a dock: 3 blocks AWAY from the taxiway.
-- One block further back than the departure lane so returning and departing
-- turtles never share the same corridor and cannot deadlock.
local function returnAisleZ(dock)
    local dir = W.WHITE_Z > dock.z and 1 or -1
    return dock.z - dir * 3
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

-- Return: arrivals hole → red taxiway → centre column → return aisle → slot.
-- Uses returnAisleZ (3 blocks back) so returning turtles never share a lane
-- with departing turtles (which use aisleZ, 2 blocks back).
function W.returnRoute(dock)
    local az = returnAisleZ(dock)
    return {
        -- 1. Get onto red taxiway from arrivals hole
        { x = W.ARRIVALS_HOLE.x, y = CFG.FLOOR_Y, z = W.RED_Z },
        -- 2. Travel along red taxiway to bay centre column X
        { x = dock.junction.x,   y = CFG.FLOOR_Y, z = W.RED_Z },
        -- 3. Drop from taxiway to return aisle via centre column (always clear)
        { x = dock.junction.x,   y = CFG.FLOOR_Y, z = az       },
        -- 4. Move along return aisle to dock's column X
        { x = dock.x,            y = CFG.FLOOR_Y, z = az       },
        -- 5. Enter dock slot perpendicular (back into row)
        { x = dock.x,            y = CFG.FLOOR_Y, z = dock.z   },
    }
end

-- Internal return from a KNOWN inside position (fromX, fromZ).
-- Every waypoint changes only one axis so move.to never crosses a dock row
-- sideways (move.to does X before Z, which would cut through occupied slots
-- if both axes change in the same call).
--
-- Route: current col → red taxiway (Z only)
--      → junction col  (X only, along clear taxiway)
--      → return aisle  (Z only)
--      → dock col      (X only, along clear aisle)
--      → dock slot     (Z only)
--
-- Use this for RECALL homing and boot-time position correction.
-- Never call from underground.
function W.internalReturnRouteFrom(dock, fromX, fromZ)
    local az = returnAisleZ(dock)
    return {
        -- 1. Move to red taxiway at CURRENT column (Z-only — never crosses rows)
        { x = fromX,           y = CFG.FLOOR_Y, z = W.RED_Z  },
        -- 2. Travel along red taxiway to dock's junction column (X-only, clear lane)
        { x = dock.junction.x, y = CFG.FLOOR_Y, z = W.RED_Z  },
        -- 3. Drop from taxiway into return aisle (Z-only via clear centre column)
        { x = dock.junction.x, y = CFG.FLOOR_Y, z = az       },
        -- 4. Move along return aisle to dock's X column (X-only, clear aisle)
        { x = dock.x,          y = CFG.FLOOR_Y, z = az       },
        -- 5. Enter dock slot (Z-only)
        { x = dock.x,          y = CFG.FLOOR_Y, z = dock.z   },
    }
end

-- Compatibility wrapper (turtle already at junction on red taxiway).
-- Prefer internalReturnRouteFrom for general use.
function W.internalReturnRoute(dock)
    return W.internalReturnRouteFrom(dock, dock.junction.x, W.RED_Z)
end

-- Returns the facing direction a turtle should hold while at its dock.
-- "Toward the taxiway" — the direction of the first departure move is then
-- consistently the OPPOSITE (into the back aisle), which move.face() handles.
-- Facing values: 0=north(-Z) 1=east(+X) 2=south(+Z) 3=west(-X)
function W.dockFacing(dock)
    -- WHITE_Z is the outbound taxiway. Face toward it from the dock.
    return W.WHITE_Z > dock.z and 2 or 0   -- south if taxiway is in +Z, north otherwise
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
