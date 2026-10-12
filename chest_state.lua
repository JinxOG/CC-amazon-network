-- chest_state.lua
-- Persists the fact that this miner has its ore ender chest placed in the world.
--
-- The chest is placed and dug back up on every dump, dozens of times a sector.
-- In memory that fact dies with a reboot, and a reboot mid-dump leaves the chest
-- standing in the world with nothing recording where: the miner then boots with
-- an empty chest slot, refuses work for missing hardware, and waits for a person
-- to hand it a new one.
--
-- Observed 2026-10-08: node_181 was DUMPING at 22:48:33, the reboot at 22:52
-- left its chest near 2048,16,-3392, and it stayed benched until the user
-- replaced the chest.
--
-- Same ordering contract as loader_state.lua, and for the same reason: the
-- record is written BEFORE the place and cleared only AFTER the chest is
-- confirmed back aboard, so a crash at any instant errs toward "we may have one
-- out there", which is the recoverable direction.
--
-- File handle convention: real CC:Tweaked handles are called dot-style, with no
-- implicit self (`h.write(text)`, not `h:write(text)`). The stub's fs matches
-- that, so this module does too.

local chest_state = {}

local PATH = "chest_state.dat"
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
    -- A truncated write (power loss mid-save) must not brick the miner on boot.
    -- textutils.unserialise already returns nil rather than raising on malformed
    -- input; this pcall is the belt-and-braces guard in case that ever changes.
    local ok, data = pcall(textutils.unserialise, raw)
    if ok and type(data) == "table" and data.x ~= nil then
        _cache = data
    end
    return _cache
end

-- Call this immediately BEFORE the chest is placed, with the absolute block it
-- is going into. The face is chosen at runtime (bankPayload tries down, then
-- forward, then up), so the caller resolves it to a block and this module only
-- ever stores a position.
--
-- Returns true once the record is on disk, or false, reason if it could not be
-- written (a full disk makes fs.open return nil). The caller MUST NOT place the
-- chest on a false return: without the record, a crash after placement strands
-- it with nothing recording why -- the exact failure this module prevents.
function chest_state.record(x, y, z)
    local rec = { x = x, y = y, z = z, placedAt = os.epoch("utc") }
    local f = fs.open(PATH, "w")
    if not f then
        -- Leave _cache/_loaded alone: claiming a placement we could not persist
        -- would be a lie in memory as well as on disk.
        return false, "chest_state_write_failed"
    end
    f.write(textutils.serialise(rec))
    f.close()
    _cache  = rec
    _loaded = true
    return true
end

-- Call this only AFTER the chest is confirmed back in its slot. Clearing early
-- would erase the only record of a chest still standing in the world.
function chest_state.clear()
    _cache = nil
    _loaded = true
    if fs.exists(PATH) then fs.delete(PATH) end
end

function chest_state.get() return load() end

function chest_state.hasPlaced() return load() ~= nil end

return chest_state
