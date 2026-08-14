-- geofence.lua
-- Bounds the miner to the area a placed chunk loader guarantees is loaded.
--
-- While the pickaxe is equipped the miner has no chunky upgrade of its own, so
-- stepping outside the placed loader's footprint unloads it mid-move and it
-- freezes with no way to recover. The fence is enforced inside the movement
-- primitive rather than at call sites, so no future caller can forget it.
--
-- The fence is measured in CHUNKS, not blocks. Advanced Peripherals' chunky
-- turtle loads a grid-aligned square of chunks around the chunk it occupies —
-- it is not a square centred on the turtle. A block radius cannot express that:
-- a loader at the high edge of its chunk loads exactly the same chunks as one at
-- the low edge, and a block-centred fence would be wrong by up to 15 blocks in
-- both directions, every one of them unloaded.
--
-- chunkRadius comes from docs/superpowers/specs/chunkloader-footprint.md and
-- MUST stay at least one below the pack's chunkyTurtleRadius. Nothing checks
-- that at runtime — the config is server-side and unreadable from here.

local geofence = {}

local _anchor = nil   -- { cx, cz, chunkRadius } or nil when travelling on our own chunky

function geofence.chunkOf(x, z)
    return math.floor(x / 16), math.floor(z / 16)
end

function geofence.setAnchorChunk(cx, cz, chunkRadius)
    _anchor = { cx = cx, cz = cz, chunkRadius = chunkRadius }
end

-- Anchor on the chunk CONTAINING this block. Callers hold block coords, and
-- doing the conversion here means no call site can forget it.
function geofence.setAnchorBlock(x, z, chunkRadius)
    local cx, cz = geofence.chunkOf(x, z)
    geofence.setAnchorChunk(cx, cz, chunkRadius)
end

function geofence.clear() _anchor = nil end

function geofence.isActive() return _anchor ~= nil end

function geofence.anchor() return _anchor end

-- Chebyshev distance in CHUNK space (not block space — see file header).
function geofence.contains(x, z)
    if not _anchor then return true end
    local cx, cz = geofence.chunkOf(x, z)
    return math.abs(cx - _anchor.cx) <= _anchor.chunkRadius
       and math.abs(cz - _anchor.cz) <= _anchor.chunkRadius
end

function geofence.check(x, z)
    if geofence.contains(x, z) then return true end
    return false, "geofence_breach"
end

return geofence
