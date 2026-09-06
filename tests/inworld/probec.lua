-- probec.lua — Probe C / V1: which block states can a TURTLE actually place?
--
-- Answers the highest-decision-weight open question in the system spec
-- (2026-08-18-system-integration-design.md §17, V1). That question gates the
-- builder class, which in turn gates W4's BUILDER role and W5's .litematic
-- parser. Nothing in either stream should be written against a specific builder
-- class until this has run.
--
-- The question it answers precisely: for each block a build might need, which
-- of its blockstates can a turtle reach using nothing but rotation and
-- place/placeUp/placeDown? Whatever a turtle cannot reach is the exact and
-- entire case for keeping Androids.
--
-- ── Setup ───────────────────────────────────────────────────────────────────
--
--   1. Equip a diamond pickaxe (needed to remove each test block).
--   2. Put the blocks you want tested loose in the inventory — one of each is
--      enough. Suggested spread, covering every state family a build hits:
--        stairs, slab, log/pillar, furnace or dispenser, observer,
--        trapdoor, fence, chest, plus a stateless control like dirt.
--   3. Place the turtle FLOATING IN AIR with one block of clearance on all six
--      sides. Standing on the ground is fine but silently costs you the `down`
--      row, and a wall costs you one heading.
--   4. `probec`, then read `probec.log`.
--
-- No fuel is required and the turtle never moves: it only rotates, places, and
-- digs. It ends on its starting heading.
--
-- ── Reading the output ──────────────────────────────────────────────────────
--
-- One line per (block, direction). `fwd@0..3` are the four headings, relative
-- to wherever the turtle started.
--
--   minecraft:oak_stairs  [facing=north,half=bottom,shape=straight]
--
-- The interesting column is the state. Collect the distinct states a block
-- reached across all six rows: that set is what a turtle can build. A property
-- that never varies across all six rows (`half=bottom` on every stairs line) is
-- a state a turtle CANNOT reach, and therefore a block a turtle cannot place
-- correctly.
--
-- ── Known limitation, stated so results are not over-read ────────────────────
--
-- Every placement here goes into open air. Real builds usually place against an
-- existing block, and vanilla derives some states (notably stairs `half`) from
-- where on a face the click lands — something a turtle has no analogue for.
-- CC:Tweaked synthesises its own placement context, so this most likely makes no
-- difference, but it is an assumption and not a measurement. If results look
-- suspiciously uniform, re-run with the turtle placing against a solid neighbour
-- before concluding a state is unreachable.

local LOG = "probec.log"

-- ── Output ──────────────────────────────────────────────────────────────────

-- Reopened per line rather than held open: this is a short run, and a crash
-- partway through should still leave every result gathered so far on disk.
local function out(line)
    print(line)
    local f = fs.open(LOG, "a")
    if f then
        f.writeLine(line)
        f.close()
    end
end

-- Blockstate table -> stable, sorted, one-line string. Sorted so two runs are
-- diffable, and so a property appearing/disappearing is visible at a glance.
local function stateStr(state)
    if type(state) ~= "table" then return "-" end
    local keys = {}
    for k in pairs(state) do keys[#keys + 1] = k end
    if #keys == 0 then return "-" end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(state[k])
    end
    return table.concat(parts, ",")
end

-- ── Inventory ───────────────────────────────────────────────────────────────

-- Digging returns the test block to whichever slot is free, which is not
-- necessarily the slot it came from. So every placement re-finds its item by
-- registry name instead of trusting a slot index captured earlier.
local function findSlot(name)
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name == name then return s end
    end
    return nil
end

-- Checked one getter at a time rather than through a list: if
-- turtle.getEquippedLeft were absent, a { nil, fn } table would terminate
-- ipairs immediately and report "no pickaxe" without ever testing the right
-- side. Both getters are confirmed present in this pack (chunkloader-footprint
-- .md §"Equipment detection"), but a warning that lies is worse than no warning.
local function equippedIsPickaxe(get)
    if not get then return false end
    local ok, e = pcall(get)
    return ok and type(e) == "table" and type(e.name) == "string"
           and e.name:find("pickaxe") ~= nil
end

local function hasPickaxe()
    return equippedIsPickaxe(turtle.getEquippedLeft)
        or equippedIsPickaxe(turtle.getEquippedRight)
end

-- ── One placement attempt ───────────────────────────────────────────────────

local function attempt(name, label, place, inspect, dig, detect)
    if detect() then
        out(string.format("  %-7s SKIP      obstructed — no clearance this way", label))
        return
    end

    local slot = findSlot(name)
    if not slot then
        out(string.format("  %-7s SKIP      item no longer in inventory", label))
        return
    end
    turtle.select(slot)

    local placed, placeErr = place()
    if not placed then
        -- Expected and informative for non-placeable items (tools, food): it
        -- tells us the probe saw them and rejected them, rather than silently
        -- skipping.
        out(string.format("  %-7s NOPLACE   %s", label, tostring(placeErr)))
        return
    end

    local found, data = inspect()
    if found and type(data) == "table" then
        out(string.format("  %-7s %s  [%s]", label, tostring(data.name), stateStr(data.state)))
    else
        out(string.format("  %-7s PLACED    but inspect failed: %s", label, tostring(data)))
    end

    -- Clean up, or the next placement in this direction has nowhere to go.
    local dug, digErr = dig()
    if not dug then
        out(string.format("  %-7s WARN      could not remove test block: %s "
                          .. "— clear it by hand before re-running", label, tostring(digErr)))
    end
end

-- ── Run ─────────────────────────────────────────────────────────────────────

out("")
out("=== Probe C — turtle placement matrix — " .. tostring(os.epoch("utc")) .. " ===")

if not hasPickaxe() then
    out("WARN: no pickaxe detected on either side. Test blocks cannot be removed,")
    out("      so every direction after the first will report as obstructed.")
end

-- Snapshot the item list BEFORE any placing, deduplicated by registry name.
-- Taken up front because placing and digging reshuffles slots underneath us,
-- and deduplicated so two stacks of the same block are not tested twice.
local items, seen = {}, {}
for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and not seen[d.name] then
        seen[d.name] = true
        items[#items + 1] = d.name
    end
end

if #items == 0 then
    out("No items in inventory — nothing to test. Load the blocks listed in the")
    out("setup notes at the top of this file and re-run.")
    return
end

out(string.format("Testing %d distinct item(s).", #items))

for _, name in ipairs(items) do
    out("")
    out("=== " .. name .. " ===")

    -- Four headings. Four turnRights returns the turtle to its start heading,
    -- so the probe leaves it exactly as it found it.
    for h = 0, 3 do
        attempt(name, "fwd@" .. h, turtle.place, turtle.inspect, turtle.dig, turtle.detect)
        turtle.turnRight()
    end

    attempt(name, "up",   turtle.placeUp,   turtle.inspectUp,   turtle.digUp,   turtle.detectUp)
    attempt(name, "down", turtle.placeDown, turtle.inspectDown, turtle.digDown, turtle.detectDown)
end

out("")
out("=== done — full results in " .. LOG .. " ===")
out("For each block, collect the distinct states across its six rows. A property")
out("that never varies is one a turtle cannot reach — that set, and only that")
out("set, is the case for Androids.")
