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
    -- The dock type of each bay, by bay number (shakeout stress test, 2026-11-09).
    -- DELIVERY / SUPPORT bays hold only that role; MINER bays hold miners. The
    -- worker side (south of the taxiway) and support side (north) are separate lists.
    BAY_TYPES = {
        WORKER  = { "DELIVERY", "MINER", "MINER", "MINER", "MINER" },
        SUPPORT = { "SUPPORT",  "MINER", "MINER", "MINER", "MINER" },
    },
}
W.BAY_TYPES = CFG.BAY_TYPES

-- ─── Taxiways ────────────────────────────────────────────────────────────────

W.WHITE_Z = -2803   -- outbound dispatch lane
W.RED_Z   = -2801   -- inbound return lane

-- ─── Holes ───────────────────────────────────────────────────────────────────

W.DISPATCH_HOLE    = { x = 143, y = CFG.FLOOR_Y,      z = -2813 }  -- go DOWN to leave
W.DISPATCH_STAGING = { x = 143, y = CFG.FLOOR_Y,      z = -2812 }  -- 1 block before hole (support waits here)
W.ARRIVALS_HOLE    = { x = 228, y = CFG.FLOOR_Y,      z = -2782 }  -- come UP to return
W.WORLD_EXIT       = { x = W.DISPATCH_HOLE.x, y = CFG.BELOW_HOLE_Y, z = W.DISPATCH_HOLE.z }  -- below dispatch hole
W.WORLD_ENTRY      = { x = W.ARRIVALS_HOLE.x, y = CFG.BELOW_HOLE_Y, z = W.ARRIVALS_HOLE.z }  -- below arrivals hole

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
    MINER    = {},
}

-- side: "WORKER" or "SUPPORT" -- which list of CFG.BAY_TYPES gives each bay's type.
local function generateBays(side, numBays, rowAZ, rowBZ)
    for bay = 1, numBays do
        local role = CFG.BAY_TYPES[side][bay]
        local docks = W.docks[role]
        assert(docks, "unknown bay type " .. tostring(role) .. " for " .. side .. " bay " .. bay)
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

generateBays("WORKER",  CFG.NUM_WORKER_BAYS,  WORKER_ROW_A_Z,  WORKER_ROW_B_Z)
generateBays("SUPPORT", CFG.NUM_SUPPORT_BAYS, SUPPORT_ROW_A_Z, SUPPORT_ROW_B_Z)

-- The dock type a turtle role uses, or nil for a role that has no dock (LOADER).
-- Callers pass this to assignDock / getDockFor / freeDocks / totalDocks.
function W.dockTypeFor(role)
    if role == "SUPPORT" then return "SUPPORT" end
    if role == "MINER" then return "MINER" end
    if role == "LOADER" then return nil end
    return "DELIVERY"
end

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

-- Release current dock and assign the turtle to the first free slot at targetBay.
-- Returns the new dock, or nil if that bay has no free slots.
function W.assignDockAt(role, turtleId, targetBay)
    W.releaseDock(role, turtleId)
    if not _assigned[role] then _assigned[role] = {} end
    local docks = W.docks[role]
    for i, dock in ipairs(docks) do
        if dock.bay == targetBay and not _assigned[role][i] then
            _assigned[role][i] = turtleId
            saveDockAssignments()
            return dock
        end
    end
    return nil  -- bay full or does not exist
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
    -- FROM A DOCK, LEAVE IT THE WAY A DEPARTURE DOES (2026-11-03). Z first from a
    -- back-row dock drove straight into the parked turtle in the front row and
    -- stayed there: node_4070, homing from support dock 211,-2793, blocked at
    -- 211,-2796 for good when ~147 turtles changed docks at boot (w3_atc_base150).
    -- So: back into that dock's own departure aisle, along it to the bay's centre
    -- column -- which no dock occupies -- and on from there.
    for _, role in ipairs({ "DELIVERY", "SUPPORT", "MINER" }) do
        for _, d in ipairs(W.docks[role]) do
            if d.x == fromX and d.z == fromZ and not (d.x == dock.x and d.z == dock.z) then
                local out = { { x = fromX, y = CFG.FLOOR_Y, z = aisleZ(d) }, { x = d.junction.x, y = CFG.FLOOR_Y, z = aisleZ(d) } }
                for _, wp in ipairs(W.internalReturnRouteFrom(dock, d.junction.x, aisleZ(d))) do out[#out + 1] = wp end
                return out
            end
        end
    end
    -- ANYWHERE ELSE IN A BAY SIDE, off its centre column: along the row it is on to
    -- the centre column first. Only the dock rows hold docks, and a turtle on one of
    -- those is on a dock (above), so this row is clear. node_3069 rebooted in an
    -- aisle behind its dock and drove Z first into the parked front row (world
    -- restart, sim, 2026-11-03).
    for b = 1, CFG.NUM_WORKER_BAYS do
        local cx = CFG.BAY_CENTER_X + (b - 1) * CFG.BAY_SPACING
        local inSide = (fromZ < W.WHITE_Z and fromZ >= WORKER_ROW_B_Z - 3) or (fromZ > W.RED_Z and fromZ <= SUPPORT_ROW_B_Z + 3)
        if fromX ~= cx and math.abs(fromX - cx) <= 4 and inSide then
            local out = { { x = cx, y = CFG.FLOOR_Y, z = fromZ } }
            for _, wp in ipairs(W.internalReturnRouteFrom(dock, cx, fromZ)) do out[#out + 1] = wp end
            return out
        end
    end
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

-- ─── Air-traffic control sections (2026-11-03, atc.lua) ─────────────────────
-- The base is cut into short sections; the ATC computer lets one turtle into a
-- section at a time (docs/superpowers/specs/2026-11-03-base-atc-design.md).
-- Docks and the holding line are in NO section: they are where a turtle waits.
--
--   S<b> / N<b>  worker (south) / support (north) side of bay b: its centre
--                column, its aisles, everything between the taxiway and the
--                back aisle -- dock cells excluded
--   J<b>         the crossing at bay b's centre column (red, middle, white)
--   W<b>         the white lane between crossing b-1 and crossing b (W1 starts
--                at the dispatch corner; W6 east of bay 5, which nothing uses)
--   R<b>         the red lane between crossing b and b+1 (R5 runs to the
--                arrivals run; R0 west of bay 1, which nothing uses)
--   DH           the dispatch corner and its shaft down to the tunnel
--   ARR          the arrivals shaft, the floor run from it to the red lane, the
--                column above it, and the taxi row in the tunnel under it

local BAY_X = {}
for b = 1, CFG.NUM_WORKER_BAYS do BAY_X[b] = CFG.BAY_CENTER_X + (b - 1) * CFG.BAY_SPACING end

W.ATC = {
    -- Holding-line slots east of the arrivals hole, at x 230, 232, ... THE LINE MUST
    -- LIE IN THE LOADED BASE: a turtle sent to a slot in an unloaded chunk freezes
    -- there. 40 reached x 308, and with slots handed out in turn 23 turtles froze past
    -- the sim's loaded edge at x 260 (2026-11-03). 14 ends at x 256.
    HOLD_SLOTS  = 14,
    HOLD_STEP   = 2,       -- x between slots, so a turtle called up passes nobody
    HOLD_Z      = W.ARRIVALS_HOLE.z + 2,   -- the slots (z -2780)
    TAXI_Z      = W.ARRIVALS_HOLE.z + 4,   -- the taxi row, NORTH of the slots (z -2778): a turtle reaches its
                                           -- slot from the south and leaves it northwards, so the support that
                                           -- followed it in, one block behind, is never in its way out
    SKY_MIN_Y   = 100,                     -- the sky line and its taxi row are above this
    BAY_X       = BAY_X,
}

local function isDockCell(x, z)
    for _, row in ipairs({ WORKER_ROW_A_Z, WORKER_ROW_B_Z, SUPPORT_ROW_A_Z, SUPPORT_ROW_B_Z }) do
        if z == row then
            for b = 1, #BAY_X do
                local dx = x - BAY_X[b]
                if dx ~= 0 and dx >= -4 and dx <= 4 then return true end
            end
        end
    end
    return false
end

-- The section a cell belongs to, or nil (a dock, the holding line, the world).
function W.atcSection(x, y, z)
    local A, ax, az = W.ATC, W.ARRIVALS_HOLE.x, W.ARRIVALS_HOLE.z
    -- the arrivals side: shaft, sky column, floor run, tunnel taxi row
    if x == ax and z == az and y >= CFG.BELOW_HOLE_Y then return "ARR" end
    if y == CFG.FLOOR_Y and x == ax and z <= az and z >= W.RED_Z then return "ARR" end
    if (y == CFG.BELOW_HOLE_Y or y >= A.SKY_MIN_Y) then
        if z == A.TAXI_Z and x >= ax and x <= ax + A.HOLD_STEP * A.HOLD_SLOTS then return "ARR" end
        if x == ax and z > az and z < A.TAXI_Z then return "ARR" end   -- from the taxi row to the column
    end
    -- the dispatch corner and its shaft
    local dx, dz = W.DISPATCH_HOLE.x, W.DISPATCH_HOLE.z
    if x == dx and z == dz and y >= CFG.BELOW_HOLE_Y and y <= CFG.FLOOR_Y then return "DH" end
    if y ~= CFG.FLOOR_Y then return nil end
    if x == dx and z <= W.WHITE_Z and z >= dz then return "DH" end
    -- the taxiway strip: crossings and lanes
    if z >= W.WHITE_Z and z <= W.RED_Z then
        for b = 1, #BAY_X do if x == BAY_X[b] then return "J" .. b end end
        if x < dx or x > ax then return nil end
        local b = 0
        while b < #BAY_X and x > BAY_X[b + 1] do b = b + 1 end   -- x lies between BAY_X[b] and BAY_X[b+1]
        if z == W.RED_Z then return "R" .. b end
        return "W" .. (b + 1)
    end
    -- the bay sides
    if isDockCell(x, z) then return nil end
    for b = 1, #BAY_X do
        if x >= BAY_X[b] - 4 and x <= BAY_X[b] + 4 then
            if z < W.WHITE_Z and z >= WORKER_ROW_B_Z - 3 then return "S" .. b end
            if z > W.RED_Z and z <= SUPPORT_ROW_B_Z + 3 then return "N" .. b end
        end
    end
    return nil
end

-- Holding-line slot k (1-based) east of the arrivals hole: in the tunnel, or at
-- height y for the sky line (miners come home from the sky; ATC card, addition A).
function W.holdingSlot(k, y)
    return { x = W.ARRIVALS_HOLE.x + W.ATC.HOLD_STEP * k, y = y or CFG.BELOW_HOLE_Y, z = W.ATC.HOLD_Z }
end

-- From anywhere at the line's height to slot k: along the row it is on to the
-- slot's column, then up the column into the slot. Not along the column it came
-- down (the destination's own, which outbound turtles use), and from the south no
-- crossing at all: the taxi row is beyond the slots.
function W.holdingApproach(from, k, y)
    local s = W.holdingSlot(k, y)
    return {
        { x = s.x, y = s.y, z = from.z },
        { x = s.x, y = s.y, z = s.z },
    }
end

-- Out of slot k to the arrivals column: onto the taxi row, along it to the
-- column -- then up the shaft to the floor (tunnel), or nothing more (the sky:
-- the descent is the caller's).
function W.holdingExitRoute(k, y)
    local s = W.holdingSlot(k, y)
    local route = {
        { x = s.x,               y = s.y, z = W.ATC.TAXI_Z },
        { x = W.ARRIVALS_HOLE.x, y = s.y, z = W.ATC.TAXI_Z },
        { x = W.ARRIVALS_HOLE.x, y = s.y, z = W.ARRIVALS_HOLE.z },
    }
    if s.y < CFG.FLOOR_Y then
        route[#route + 1] = { x = W.ARRIVALS_HOLE.x, y = CFG.FLOOR_Y, z = W.ARRIVALS_HOLE.z }
    end
    return route
end

-- The sections a route passes through, in order, walking its cells the way
-- move.to does (vertical, then x, then z) from `from`. Each section once, at its
-- first visit. `from`'s own section comes first when it has one: a turtle that
-- is standing in a section holds it.
function W.routeSections(from, waypoints)
    local out, seen = {}, {}
    local function add(x, y, z)
        local s = W.atcSection(x, y, z)
        if s and not seen[s] then seen[s] = true; out[#out + 1] = s end
    end
    local x, y, z = from.x, from.y, from.z
    add(x, y, z)
    for _, wp in ipairs(waypoints) do
        while y ~= wp.y do y = y + (wp.y > y and 1 or -1); add(x, y, z) end
        while x ~= wp.x do x = x + (wp.x > x and 1 or -1); add(x, y, z) end
        while z ~= wp.z do z = z + (wp.z > z and 1 or -1); add(x, y, z) end
    end
    return out
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
