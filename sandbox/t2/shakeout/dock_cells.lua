-- Shakeout world builder: prints every dock of waypoints.lua as JSON, one object per dock, so the Python kit
-- (sandbox/t2/shakeout/world.py, dock_cells()) never re-types a coordinate.
--
--   <lua> sandbox/t2/shakeout/dock_cells.lua <path to waypoints.lua>
--
-- Each object: type (the typed list it is in: DELIVERY / SUPPORT / MINER), bay, row ("A" nearer the taxiway, "B"
-- further), side ("WORKER" south of the taxiway, "SUPPORT" north: read from W.WHITE_Z, not assumed), slot (dx from the
-- bay's centre column), x, y, z, facing (W.dockFacing as a name: 0 north, 1 east, 2 south, 3 west, as waypoints.lua
-- documents it), aisle_z / return_z (the departure and return aisles waypoints' own routes use for this dock), lane_z (the
-- taxiway lane next to the dock's side). Order: W.docks.DELIVERY, then SUPPORT, then MINER, each in its own list order.
local path = arg and arg[1] or "waypoints.lua"
local W = dofile(path)

local FACING = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }

local function str(s)
    local text = tostring(s):gsub("[%c\"\\]", function(c) return string.format("\\u%04x", c:byte()) end)
    return "\"" .. text .. "\""
end

local out = {}
for _, t in ipairs({ "DELIVERY", "SUPPORT", "MINER" }) do
    for _, d in ipairs(W.docks[t] or {}) do
        local dep, ret = W.departureRoute(d), W.returnRoute(d)
        out[#out + 1] = string.format('{"type":%s,"bay":%d,"row":%s,"side":%s,"slot":%d,"x":%d,"y":%d,"z":%d,"facing":%s,'
            .. '"aisle_z":%d,"return_z":%d,"lane_z":%d}',
            str(t), d.bay, str(d.row), str(d.z < W.WHITE_Z and "WORKER" or "SUPPORT"), d.x - d.junction.x, d.x, d.y, d.z,
            str(FACING[W.dockFacing(d)] or W.dockFacing(d)),
            dep[1].z,                                   -- the departure aisle: the route's first step out of the dock
            ret[#ret - 1].z,                            -- the return aisle: the step before the dock itself
            d.z < W.WHITE_Z and W.WHITE_Z or W.RED_Z)   -- the taxiway lane on this side
    end
end
io.write("[" .. table.concat(out, ",\n") .. "]\n")
