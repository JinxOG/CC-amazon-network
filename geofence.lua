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

-- ─── Leases ──────────────────────────────────────────────────────────────────
--
-- The chunk anchor above answers "where is it safe to be". A LEASE answers a
-- different question: "which volume is mine alone". Sector assignment has always
-- been exclusive -- nextSector pops from zone.pending, so two miners never hold
-- the same sector -- but nothing enforced it in the world. SECTOR_STEP is 32
-- blocks while the chunk fence is radius 1, i.e. 48, so adjacent leaseholders'
-- fences overlapped by 16 blocks on every shared edge. The lease was real; the
-- wall was the wrong size and in the wrong units.
--
-- A lease is a block rectangle with a CEILING. Below the ceiling the volume is
-- exclusive; above it is shared transit, because a bedrock-to-sky column would
-- deadlock four miners on a 15-sector zone the moment the fence refused to let
-- one overfly another on the way home.
--
-- Both fences apply when both are set, and each passes when unset. A lease is a
-- strict subset of the loader's chunk footprint (sectors sit on multiples of 32,
-- so a lease spans two chunks per axis, well inside a 3x3), so requiring both is
-- a pure narrowing and can never place the miner outside loaded chunks.

local geofence = {}

local _anchor = nil   -- { cx, cz, chunkRadius } or nil when travelling on our own chunky
local _lease  = nil   -- { x1, z1, x2, z2, ceilingY } or nil when not holding one

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

-- Bounds are INCLUSIVE and must tile: the server derives them half-open from the
-- sector centre (see proto.leaseBounds) so two adjacent leases never share a
-- column. ceilingY is the highest y the holder may occupy; nil means no ceiling.
function geofence.setLease(x1, z1, x2, z2, ceilingY)
    _lease = {
        x1 = math.min(x1, x2), x2 = math.max(x1, x2),
        z1 = math.min(z1, z2), z2 = math.max(z1, z2),
        ceilingY = ceilingY,
    }
end

function geofence.clearLease() _lease = nil end
function geofence.lease()      return _lease end
function geofence.hasLease()   return _lease ~= nil end

-- Clears BOTH fences. A caller releasing its hold on the world means it, and
-- leaving half a fence armed is how a miner ends up refusing its own way home.
function geofence.clear()
    _anchor = nil
    _lease  = nil
end

function geofence.isActive() return _anchor ~= nil or _lease ~= nil end

function geofence.anchor() return _anchor end

-- y is optional: horizontal moves cannot change it, so they do not test the
-- ceiling. Vertical moves pass it and must.
function geofence.contains(x, z, y)
    -- Chebyshev distance in CHUNK space (not block space — see file header).
    if _anchor then
        local cx, cz = geofence.chunkOf(x, z)
        if math.abs(cx - _anchor.cx) > _anchor.chunkRadius
        or math.abs(cz - _anchor.cz) > _anchor.chunkRadius then return false end
    end

    if _lease then
        if x < _lease.x1 or x > _lease.x2
        or z < _lease.z1 or z > _lease.z2 then return false end
        if y ~= nil and _lease.ceilingY and y > _lease.ceilingY then return false end
    end

    return true
end

function geofence.check(x, z, y)
    if geofence.contains(x, z, y) then return true end
    return false, "geofence_breach"
end

return geofence
