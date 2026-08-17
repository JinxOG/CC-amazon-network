-- loader_state.lua
-- Persists the fact that this miner has a chunk loader placed in the world.
--
-- The loader is a physical turtle the miner is responsible for retrieving. In
-- memory that fact dies with a reboot, and an abandoned loader means a turtle
-- lost from the fleet plus a chunk force-loaded forever with nothing recording
-- why. So the record is written to disk BEFORE placing and cleared only AFTER a
-- confirmed retrieval -- that ordering means a crash at any instant errs toward
-- "we may have one out there", which is the recoverable direction.
--
-- File handle convention: real CC:Tweaked handles are called dot-style, with
-- no implicit self (`h.write(text)`, not `h:write(text)`). The stub's fs
-- matches that, so this module does too.

local loader_state = {}

local PATH = "loader_state.dat"
local _cache  = nil
local _loaded = false

local function load()
    if _loaded then return _cache end
    _loaded = true
    _cache = nil
    if not fs.exists(PATH) then return nil end
    local f = fs.open(PATH, "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    if type(raw) ~= "string" or raw == "" then return nil end
    -- A truncated write (power loss mid-save) must not brick the miner on
    -- boot. textutils.unserialise already returns nil rather than raising on
    -- malformed input, but this pcall is the belt-and-suspenders guard in
    -- case that ever changes -- this file being unreadable must never be
    -- fatal at boot.
    local ok, data = pcall(textutils.unserialise, raw)
    if ok and type(data) == "table" and data.x ~= nil then
        _cache = data
    end
    return _cache
end

-- Call this immediately BEFORE turtle.place() puts the loader down. Persisting
-- first means a crash between record() and the actual placement just leaves a
-- record for a loader that was never placed -- recovery will find nothing at
-- those coordinates and can clear it. The opposite ordering (place, then
-- record) would let a crash right after placement lose the loader with no
-- record at all, which is the failure this module exists to prevent.
-- Returns true once the record is on disk, or false, reason if it could not be
-- written (a full disk makes fs.open return nil). The caller MUST NOT place the
-- loader on a false return: without the record on disk, a crash after placement
-- abandons the loader with nothing recording why -- the exact failure this
-- module exists to prevent. Raising here instead would abort placeLoader from
-- inside, which is survivable, but only by luck of where the pcall happens to
-- sit; a checked return makes the contract explicit.
function loader_state.record(x, y, z, sector, radius)
    local rec = {
        x = x, y = y, z = z,
        sector = sector,
        radius = radius,
        placedAt = os.epoch("utc"),
    }
    local f = fs.open(PATH, "w")
    if not f then
        -- Leave _cache/_loaded alone: claiming a placement we could not persist
        -- would be a lie in memory as well as on disk.
        return false, "loader_state_write_failed"
    end
    f.write(textutils.serialise(rec))
    f.close()
    _cache  = rec
    _loaded = true
    return true
end

-- Call this only AFTER retrieval is confirmed (the loader is back in
-- inventory). Clearing early would erase the only record of a loader that
-- turned out still to be standing in the world.
function loader_state.clear()
    _cache = nil
    _loaded = true
    if fs.exists(PATH) then fs.delete(PATH) end
end

function loader_state.get() return load() end

function loader_state.hasPlaced() return load() ~= nil end

return loader_state
