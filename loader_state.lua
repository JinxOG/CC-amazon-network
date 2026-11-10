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
-- `label` is the placed loader's label, read off the item before it left the
-- inventory. It is what later proves a CARRIED turtle is the one we placed:
-- every advanced turtle shares one item id, so possession alone stopped being
-- proof once a dug-up miner could sit in the pack. An in-world probe
-- (2026-08-22) established that a label replaces the upgrade-derived
-- displayName, survives place -> break on the item, and is readable from Lua.
-- Optional: records written before this existed have none, and must stay
-- readable.
function loader_state.record(x, y, z, sector, radius, label)
    local rec = {
        x = x, y = y, z = z,
        sector = sector,
        radius = radius,
        label = label,
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

-- Correct WHERE the recorded loader is, without restating WHAT it is.
--
-- Boot recovery believes the loader's own beacon over the record when the two
-- disagree, and one-block mismatches are real (node_182, 2026-10-06:
-- "ahead=1767 recorded=1768"). That correction used to call record() again and
-- pass no label, so the label was dropped by the one path that only runs during
-- reboot recovery -- which is the exact case the label exists for. A rescued
-- loader was then refused all over again. Found by W3, 2026-10-08.
--
-- Everything but the position is carried over deliberately, placedAt included:
-- this is the same loader, placed at the same time, seen more accurately.
-- Refuses rather than inventing a record, because a correction with nothing to
-- correct means the caller's own state is wrong and writing one would hide it.
function loader_state.correctPosition(x, y, z)
    local rec = load()
    if not rec then return false, "no_loader_recorded" end
    local updated = {}
    for k, v in pairs(rec) do updated[k] = v end
    updated.x, updated.y, updated.z = x, y, z
    local f = fs.open(PATH, "w")
    if not f then return false, "loader_state_write_failed" end
    f.write(textutils.serialise(updated))
    f.close()
    _cache  = updated
    _loaded = true
    return true
end

-- Call this only AFTER retrieval is confirmed (the loader is back in
-- inventory). Clearing early would erase the only record of a loader that
-- turned out still to be standing in the world.
-- WHAT THE MINER WAS DOING WHEN IT PLACED THIS LOADER.
--
-- Written as a second step rather than as more arguments to record(), because
-- mine_flow.placeLoader does not know the mining sector -- it knows the chunk
-- to anchor the fence on, which is the `sector` field above and a different
-- thing. ore_turtle knows the order, so ore_turtle records it, and
-- placeLoader's signature stays as it is.
--
-- WHY IT IS PERSISTED AT ALL. A miner that reboots mid-job loses its order with
-- the job coroutine, and the server will not re-send it: on re-registration it
-- withholds the sector whenever the turtle is not awaiting one, logging
-- "mid-sector, it already has its order". For a RE_REGISTER (coroutine intact)
-- that is true. For a reboot it is not -- the order died with the coroutine --
-- and SECTOR_REQUEST would not recover it either, because the held sector was
-- removed from the zone's list when it was assigned and lives only in the
-- server's lastAssignments. So the turtle writes its order down, which makes
-- the server's assumption true instead of arguing with it.
--
-- The lifetime is exactly right without any extra bookkeeping: this record
-- exists while a loader is placed, and a loader is placed exactly while the
-- miner is working a sector. clear() takes the order with it on retrieval.
function loader_state.setOrder(order)
    local rec = load()
    if not rec then return false, "no_loader_recorded" end
    if type(order) ~= "table" or not order.jobId then return false, "no_order" end
    local updated = {}
    for k, v in pairs(rec) do updated[k] = v end
    updated.order = { jobId = order.jobId, sx = order.sx, sz = order.sz,
                      surveyMode = order.surveyMode == true,
                      -- WHICH SCAN LEVEL, so a resume does not redo the ones
                      -- already finished. Without it the sector restarts at
                      -- level 1 and the re-scan is most of the time a resume
                      -- still costs: measured 10 minutes from boot to mining
                      -- again, against the card's bar of 5, with only 2 of
                      -- those minutes being the loader.
                      level = tonumber(order.level) or 1 }
    local f = fs.open(PATH, "w")
    if not f then return false, "loader_state_write_failed" end
    f.write(textutils.serialise(updated))
    f.close()
    _cache  = updated
    _loaded = true
    return true
end

-- The recorded order, or nil. Records written before this existed have none,
-- and a miner with no order simply has nothing to resume -- which is the same
-- answer as "between sectors", and correct in both cases.
function loader_state.order()
    local rec = load()
    local o = rec and rec.order
    if type(o) == "table" and o.jobId and o.sx and o.sz then
        o.level = tonumber(o.level) or 1   -- records written before levels existed
        return o
    end
    return nil
end

function loader_state.clear()
    _cache = nil
    _loaded = true
    if fs.exists(PATH) then fs.delete(PATH) end
end

function loader_state.get() return load() end

function loader_state.hasPlaced() return load() ~= nil end

return loader_state
