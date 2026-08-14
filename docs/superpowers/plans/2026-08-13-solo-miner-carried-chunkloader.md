# Solo Miner with Carried Chunk Loader — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the paired miner+support mining architecture with a single miner that carries a chunk-loader turtle as cargo, places it at each sector to hold the chunk, and swaps its own equipped upgrades to mine — eliminating all turtle-to-turtle coordination from mining.

**Architecture:** The miner equips `[ender modem + chunky]` while travelling, self-loading its own chunk. On reaching a sector it *places* the carried chunk-loader turtle (no tool required), then swaps `chunky → pickaxe` and mines strictly inside the placed loader's chunk footprint. To retrieve, it swaps `modem → chunky` so pickaxe and chunky are equipped simultaneously, digs up the loader, then swaps `pickaxe → modem`. Chunk loading is never absent while the miner is outside the base-loaded area; comms drop only inside a short, deliberate, logged window. Delivery keeps the existing pair system untouched.

**Tech Stack:** CC:Tweaked 1.116.0 (Lua 5.2 subset) on Minecraft 1.21.x; Advanced Peripherals geo scanner; chunky turtle upgrade; existing `central_server.lua` job queue and ngrok bridge `/state` dashboard feed.

## Global Constraints

Every task's requirements implicitly include this section.

- **Delivery must not change behaviourally.** `delivery_turtle.lua` is not modified. `support_turtle.lua` keeps its delivery branch byte-for-byte equivalent in behaviour. `proto.JOB.SUPPORT_FOLLOW`, `HOLE_READY`, `SUPPORT_STAGED`, `POSITION_UPDATE`, `RETURN_TO_DOCK`, `ASCENDING`, `DESCENDED` all remain in the protocol and keep working for DELIVER jobs.
- **`proto.VERSION` MUST be bumped and pushed to remote after every change that alters server or protocol behaviour.**
- **Never trigger `/self-update` or `UPDATE_ALL` without asking the user first.** These restart all turtles and interrupt active miners.
- **Invariant A — chunk safety:** the miner must never be outside the base-loaded area with neither its own chunky equipped nor a placed loader within footprint. Any code path that could violate this is a defect regardless of how unlikely.
- **Invariant B — modem recoverability:** the miner must be able to recover a missing modem on boot from its own inventory. A reboot inside the swap window must not brick it.
- **Invariant C — geofence:** while the pickaxe is equipped (chunky in inventory), the miner must not move outside the placed loader's guaranteed-loaded footprint. Enforced at the movement primitive, not at call sites.
- **Invariant D — no abandoned loaders:** a placed loader must always be recoverable. The miner persists its placement to disk before placing and clears it only after confirmed retrieval, so a reboot or server crash at any instant errs toward "we may have one out there" rather than silently losing it. An abandoned loader is a turtle lost from the fleet plus a permanently force-loaded chunk.
- **Invariant E — server independence for return:** the miner must be able to retrieve its loader and reach its dock with no server contact at all. A server outage may pause work; it must never strand a turtle in the field.
- Slot numbers, item names, and altitudes are given as exact values in each task. Use them verbatim.
- Existing style: 4-space indent, `--` comments explaining *why*, `logInfo`/`logWarn`/`logError` for base-level messages, `print("[MINER] ...")` for role-level.

---

## Verification Gate (Task 1) — do not skip

Three assumptions carry the entire design. If any fails, stop and re-plan rather than working around it.

1. A **placed, idle turtle** with a chunky upgrade loads chunks with no program running.
2. A chunky upgrade **survives place → break → re-place** in item NBT.
3. `turtle.equipLeft()`/`equipRight()` can swap the chunky upgrade at runtime, and holding pickaxe+chunky simultaneously works.

---

## File Structure

| File | Responsibility |
|---|---|
| `equipment.lua` **(new)** | Equipment state model. Finds modem/pickaxe/chunky regardless of side, validates the full inventory contract, performs the two swap sequences atomically. No movement, no comms — pure inventory/peripheral logic so it is unit-testable. |
| `geofence.lua` **(new)** | Chunk-footprint maths and the movement guard. Given a loader anchor and a target, answers "is this inside the loaded footprint". Pure functions. |
| `loader_state.lua` **(new)** | Disk-persisted record of a placed loader, so a reboot never abandons one. Survives crashes on either side of the wire. |
| `tests/stub_cc.lua` **(new)** | Stubs `turtle`, `peripheral`, `os.pullEvent`, `fs`, `textutils` so turtle modules load and run headless. |
| `tests/run.lua` **(new)** | Test runner: discovers `tests/test_*.lua`, reports pass/fail, non-zero exit on failure. |
| `tests/test_equipment.lua` **(new)** | Unit tests for `equipment.lua`. |
| `tests/test_geofence.lua` **(new)** | Unit tests for `geofence.lua`. |
| `tests/test_mine_flow.lua` **(new)** | End-to-end simulated mining job against a fake server. |
| `ore_turtle.lua` | New sector loop: place loader → swap → mine in fence → swap → retrieve. Loses all partner logic. |
| `support_turtle.lua` | Mining branch deleted. Delivery branch untouched. |
| `central_server.lua` | MINE jobs stop creating a paired support job. Tracks `phase` and `chunk` per turtle; exposes both in `/state`. |
| `protocol.lua` | Adds `MINE_PHASE`; adds `phase`/`chunk`/`commsGap` to heartbeat payload. Removes nothing. |
| `turtle_base.lua` | Boot-time equipment reconciliation; geofence hook in `tryMove`. |

---

### Task 1: In-world verification gate

**Files:** none (manual, in-game)

- [ ] **Step 1: Confirm a placed idle turtle loads chunks**

Place a turtle with only a chunky upgrade equipped, no program, at a location well outside your base-loaded area. Place a second turtle 5 blocks away running:

```lua
local n = 0
while true do
    n = n + 1
    local f = fs.open("tick.txt", "w")
    f.write(tostring(n) .. " " .. tostring(os.epoch("utc")))
    f.close()
    sleep(5)
end
```

Fly away until the area is well outside render/loaded distance. Wait **at least 12
minutes** (amended: see below). Return and read `tick.txt`.
Expected: the counter advanced by roughly 144 (12 min ÷ 5 s). If it stalled, **assumption 1 fails — stop.**

**The 12-minute window is not padding.** The pack sets `chunkLoadValidTime = 600`,
so the chunk ticket may expire after 10 minutes without a "touch". A 3-minute
observation cannot detect that, and an expiry mid-sector freezes the miner. If the
counter advances for 3 minutes but stalls before 12, assumption 1 fails in the
form that matters: idle loaders decay, and only a running loader program (Task 5c)
keeps them alive.

- [ ] **Step 2: Confirm the upgrade survives place → break → re-place**

With a mining turtle, `turtle.place()` the chunky turtle, then break it and check the recovered item:

```lua
turtle.select(1)          -- slot 1 holds the chunky turtle item
print(textutils.serialise(turtle.getItemDetail(1, true)))
turtle.place()
sleep(1)
turtle.dig()
print(textutils.serialise(turtle.getItemDetail(1, true)))
```

Expected: both prints show the same item with upgrade NBT intact. If the second print shows a bare turtle, **assumption 2 fails — stop.**

- [ ] **Step 3: Confirm the runtime equip swap**

On a turtle with modem on left and pickaxe on right, chunky item in slot 2:

```lua
print("L:", peripheral.getType("left"), " R:", peripheral.getType("right"))
turtle.select(2)
print("equipRight ->", turtle.equipRight())
print("L:", peripheral.getType("left"), " R:", peripheral.getType("right"))
print("slot2 now:", textutils.serialise(turtle.getItemDetail(2)))
turtle.select(2)
print("equipRight back ->", turtle.equipRight())
```

Expected: `equipRight()` returns true both times; after the first the pickaxe is in slot 2; after the second it is back on the right. If it returns false, **assumption 3 fails — stop.**

- [x] **Step 4: Measure the geofence radius** — RESOLVED FROM CONFIG

Not measured empirically; read directly from the pack's Advanced Peripherals
config, which is authoritative:

```
chunkyTurtleRadius = 2     # was 0; loads 5x5 chunks = 80x80 blocks
```

Recorded in `docs/superpowers/specs/chunkloader-footprint.md`. The fence is
**1 chunk** (3×3 = 48×48), one below the loaded radius, so there is a full chunk
of slack. Tasks 5 and 8 consume the chunk radius, not a block radius — see the
amendment note on Task 5.

- [ ] **Step 4b: Probe the equipment-detection surface** (added after Task 1)

The chunky upgrade turned out to be `advancedperipherals:chunk_controller`, not
the `chunkloaders` item the plan assumed. Task 3 identifies upgrades by peripheral
type and infers the pickaxe by elimination, which only works if exactly one
equipped upgrade reports `nil`. Run at the turtle's Lua prompt, with the modem
left and the chunk controller right:

```lua
print("L:", peripheral.getType("left"), " R:", peripheral.getType("right"))
print(textutils.serialise(
    turtle.getEquippedRight and turtle.getEquippedRight() or "absent"))
```

Two answers needed:
1. What `peripheral.getType` reports for the chunk-controller side. If it is
   `nil`, both it and the pickaxe are invisible to the plan's detection scheme
   and `equipment.lua` must be rewritten.
2. Whether `turtle.getEquippedRight()` exists (believed added ~CC:Tweaked 1.109;
   this pack is 1.116). If it does, it returns the equipped item's detail and
   upgrades can be identified by registry name directly — strictly better than
   inference, and the whole `PERIPHERAL_TYPE`/elimination scheme in Task 3 should
   be deleted in favour of it.

- [ ] **Step 5: Commit the findings**

```bash
git add docs/superpowers/specs/chunkloader-footprint.md
git commit -m "docs: record verified chunk-loader footprint and equip-swap behaviour"
```

---

### Task 2: Headless test harness

**Files:**
- Create: `tests/stub_cc.lua`
- Create: `tests/run.lua`
- Test: `tests/test_stub.lua`

**Interfaces:**
- Produces: `require("tests.stub_cc").install(opts)` → installs globals `turtle`, `peripheral`, `os.pullEvent`, `fs`, `textutils`; returns a control table `{ inv, equipped, world, events, pos }` for assertions.
- Produces: `tests/run.lua` runnable via `lua tests/run.lua`, exit 0 all-pass / 1 any-fail.

- [ ] **Step 1: Write the failing test**

Create `tests/test_stub.lua`:

```lua
local stub = require("tests.stub_cc")

return {
    ["stub tracks selected slot and inventory"] = function(assert_eq)
        local c = stub.install({ inv = { [1] = { name = "minecraft:coal", count = 5 } } })
        turtle.select(1)
        assert_eq(turtle.getItemCount(1), 5)
        assert_eq(turtle.getItemDetail(1).name, "minecraft:coal")
        assert_eq(c.selected, 1)
    end,

    ["stub models equipped sides"] = function(assert_eq)
        local c = stub.install({
            equipped = { left = "modem", right = "pickaxe" },
        })
        assert_eq(peripheral.getType("left"), "modem")
        assert_eq(c.equipped.right, "pickaxe")
    end,
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua tests/run.lua`
Expected: FAIL — `module 'tests.stub_cc' not found`

- [ ] **Step 3: Implement the stub**

Create `tests/stub_cc.lua`:

```lua
-- Minimal CC:Tweaked stand-ins so turtle modules can be loaded and driven
-- headlessly. Only models what the mining code actually touches; anything
-- unimplemented raises so gaps surface as test errors rather than silence.
local M = {}

function M.install(opts)
    opts = opts or {}
    local c = {
        inv      = opts.inv or {},
        equipped = opts.equipped or { left = nil, right = nil },
        pos      = opts.pos or { x = 0, y = 64, z = 0, facing = 0 },
        world    = opts.world or {},        -- "x,y,z" -> block name
        events   = opts.events or {},       -- queue of {name, ...}
        selected = 1,
        fuel     = opts.fuel or 100000,
        log      = {},
    }

    local function key(x, y, z) return x .. "," .. y .. "," .. z end
    local function below() return key(c.pos.x, c.pos.y - 1, c.pos.z) end
    local function ahead()
        local dx, dz = 0, 0
        if     c.facing == 0 then dz = -1
        elseif c.facing == 1 then dx =  1
        elseif c.facing == 2 then dz =  1
        else                      dx = -1 end
        return key(c.pos.x + dx, c.pos.y, c.pos.z + dz)
    end

    local function firstEmpty()
        for s = 1, 16 do if not c.inv[s] then return s end end
        return nil
    end

    turtle = {
        select        = function(s) c.selected = s; return true end,
        getSelectedSlot = function() return c.selected end,
        getItemCount  = function(s) local i = c.inv[s or c.selected]; return i and i.count or 0 end,
        getItemDetail = function(s) return c.inv[s or c.selected] end,
        getItemSpace  = function(s) local i = c.inv[s or c.selected]; return 64 - (i and i.count or 0) end,
        getFuelLevel  = function() return c.fuel end,
        getFuelLimit  = function() return 100000 end,
        refuel        = function() return true end,

        detect     = function() return c.world[ahead()] ~= nil end,
        detectDown = function() return c.world[below()] ~= nil end,
        inspect    = function()
            local b = c.world[ahead()]
            if b then return true, { name = b, tags = {} } end
            return false
        end,
        inspectDown = function()
            local b = c.world[below()]
            if b then return true, { name = b, tags = {} } end
            return false
        end,

        place = function()
            local i = c.inv[c.selected]
            if not i then return false, "Nothing to place" end
            if c.world[ahead()] then return false, "Cannot place block here" end
            c.world[ahead()] = i.name
            i.count = i.count - 1
            if i.count <= 0 then c.inv[c.selected] = nil end
            return true
        end,
        dig = function()
            if c.equipped.left ~= "pickaxe" and c.equipped.right ~= "pickaxe" then
                return false, "No tool to dig with"
            end
            local b = c.world[ahead()]
            if not b then return false, "Nothing to dig here" end
            c.world[ahead()] = nil
            local s = c.selected
            if c.inv[s] and c.inv[s].name == b then c.inv[s].count = c.inv[s].count + 1
            else
                s = c.inv[s] and firstEmpty() or s
                if s then c.inv[s] = { name = b, count = 1 } end
            end
            return true
        end,
        digDown = function()
            if c.equipped.left ~= "pickaxe" and c.equipped.right ~= "pickaxe" then
                return false, "No tool to dig with"
            end
            c.world[below()] = nil
            return true
        end,

        equipLeft  = function() return M._equip(c, "left")  end,
        equipRight = function() return M._equip(c, "right") end,

        forward = function() return M._move(c, "forward") end,
        back    = function() return M._move(c, "back")    end,
        up      = function() return M._move(c, "up")      end,
        down    = function() return M._move(c, "down")    end,
        turnLeft  = function() c.facing = (c.facing - 1) % 4; return true end,
        turnRight = function() c.facing = (c.facing + 1) % 4; return true end,

        transferTo = function(dest, n)
            local src = c.inv[c.selected]
            if not src then return false end
            n = n or src.count
            local d = c.inv[dest]
            if d and d.name ~= src.name then return false end
            c.inv[dest] = { name = src.name, count = (d and d.count or 0) + n }
            src.count = src.count - n
            if src.count <= 0 then c.inv[c.selected] = nil end
            return true
        end,
        dropDown = function() c.inv[c.selected] = nil; return true end,
        drop     = function() c.inv[c.selected] = nil; return true end,
        suckDown = function() return false end,
    }

    peripheral = {
        getType = function(side)
            local e = c.equipped[side]
            if e == "modem" then return "modem" end
            return e
        end,
        find = function(kind)
            for _, side in ipairs({ "left", "right" }) do
                if c.equipped[side] == kind then
                    return { transmit = function() end, open = function() end,
                             isOpen = function() return true end }
                end
            end
            return nil
        end,
        wrap = function() return nil end,
    }

    c.facing = c.pos.facing or 0
    M._ctl = c
    return c
end

-- Swap the selected inventory slot with the upgrade on `side`, matching
-- CC:Tweaked semantics: empty slot unequips into it, occupied slot swaps.
function M._equip(c, side)
    local item = c.inv[c.selected]
    local cur  = c.equipped[side]
    local UPGRADES = { ["pickaxe"] = true, ["modem"] = true, ["chunky"] = true }

    if item and not UPGRADES[item.name] then
        return false, "Not a valid upgrade"
    end
    c.equipped[side] = item and item.name or nil
    c.inv[c.selected] = cur and { name = cur, count = 1 } or nil
    return true
end

function M._move(c, dir)
    if dir == "up"   then c.pos.y = c.pos.y + 1; return true end
    if dir == "down" then c.pos.y = c.pos.y - 1; return true end
    local dx, dz = 0, 0
    if     c.facing == 0 then dz = -1
    elseif c.facing == 1 then dx =  1
    elseif c.facing == 2 then dz =  1
    else                      dx = -1 end
    if dir == "back" then dx, dz = -dx, -dz end
    c.pos.x = c.pos.x + dx
    c.pos.z = c.pos.z + dz
    return true
end

return M
```

- [ ] **Step 4: Implement the runner**

Create `tests/run.lua`:

```lua
-- Discovers tests/test_*.lua, each returning { ["name"] = function(assert_eq) end }.
-- Every test gets a fresh stub install, so ordering cannot leak state.
package.path = "./?.lua;" .. package.path

local files = {
    "tests.test_stub",
}

local passed, failed = 0, 0

local function assert_eq(got, want, msg)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            msg or "assertion", tostring(want), tostring(got)), 2)
    end
end

for _, mod in ipairs(files) do
    local ok, suite = pcall(require, mod)
    if not ok then
        print(string.format("LOAD FAIL %s: %s", mod, suite))
        failed = failed + 1
    else
        for name, fn in pairs(suite) do
            local ran, err = pcall(fn, assert_eq)
            if ran then
                passed = passed + 1
                print("PASS  " .. name)
            else
                failed = failed + 1
                print("FAIL  " .. name .. "\n      " .. tostring(err))
            end
        end
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 5: Run to verify it passes**

Run: `lua tests/run.lua`
Expected: `2 passed, 0 failed`, exit 0

- [ ] **Step 6: Commit**

```bash
git add tests/stub_cc.lua tests/run.lua tests/test_stub.lua
git commit -m "test: add headless CC:Tweaked stub and test runner"
```

---

### Task 3: `equipment.lua` — state model, validation, safe swaps

This is the module that prevents stranding. It owns every equip transition.

**Files:**
- Create: `equipment.lua`
- Test: `tests/test_equipment.lua`

**Interfaces:**
- Consumes: nothing from earlier tasks except the Task 2 stub for testing.
- Produces:
  - `equipment.SLOTS = { SCANNER=1, LOADER=2, TOOL=3, MODEM=4, COAL=14, FUEL_EC=15, ORE_EC=16 }`
  - `equipment.ITEMS = { PICKAXE=..., CHUNKY=..., MODEM=..., LOADER_TURTLE=... }` (names set in Step 3)
  - `equipment.sideOf(itemKind) → "left"|"right"|nil`
  - `equipment.state() → { left=kind, right=kind, invLoader=bool, invFuelEC=bool, invOreEC=bool, invScanner=bool }`
  - `equipment.validate(mode) → ok, reason` where `mode` is `"travel"` or `"mine"`
  - `equipment.toMineMode() → ok, reason` (chunky → pickaxe)
  - `equipment.toTravelMode() → ok, reason` (pickaxe → chunky)
  - `equipment.retrievalSwapIn() → ok, reason` (modem → chunky; pickaxe stays)
  - `equipment.retrievalSwapOut() → ok, reason` (pickaxe → modem)
  - `equipment.reconcile() → ok, reason` (boot self-heal)

- [ ] **Step 1: Write the failing tests**

Create `tests/test_equipment.lua`:

```lua
local stub = require("tests.stub_cc")

local function fresh(equipped, inv)
    stub.install({ equipped = equipped, inv = inv })
    package.loaded["equipment"] = nil
    return require("equipment")
end

local E_TRAVEL = { left = "modem", right = "chunky" }
local E_MINE   = { left = "modem", right = "pickaxe" }

local function fullInv(extra)
    local inv = {
        [1]  = { name = "advancedperipherals:geo_scanner", count = 1 },
        [2]  = { name = "computercraft:turtle_advanced",  count = 1 },
        [14] = { name = "minecraft:coal",                 count = 32 },
        [15] = { name = "enderstorage:ender_chest",       count = 1 },
        [16] = { name = "enderstorage:ender_chest",       count = 1 },
    }
    for k, v in pairs(extra or {}) do inv[k] = v end
    return inv
end

return {
    ["travel mode validates when modem+chunky equipped and cargo present"] = function(assert_eq)
        local eq = fresh(E_TRAVEL, fullInv({ [3] = { name = "pickaxe", count = 1 } }))
        local ok, reason = eq.validate("travel")
        assert_eq(ok, true, reason or "should validate")
    end,

    ["travel mode fails when the loader turtle is missing"] = function(assert_eq)
        local inv = fullInv({ [3] = { name = "pickaxe", count = 1 } })
        inv[2] = nil
        local eq = fresh(E_TRAVEL, inv)
        local ok, reason = eq.validate("travel")
        assert_eq(ok, false)
        assert_eq(reason, "loader_turtle_missing")
    end,

    ["travel mode fails when chunky is not equipped"] = function(assert_eq)
        local eq = fresh(E_MINE, fullInv({ [3] = { name = "chunky", count = 1 } }))
        local ok, reason = eq.validate("travel")
        assert_eq(ok, false)
        assert_eq(reason, "chunky_not_equipped")
    end,

    ["mine mode fails when an ender chest is missing"] = function(assert_eq)
        local inv = fullInv({ [3] = { name = "chunky", count = 1 } })
        inv[16] = nil
        local eq = fresh(E_MINE, inv)
        local ok, reason = eq.validate("mine")
        assert_eq(ok, false)
        assert_eq(reason, "ore_ec_missing")
    end,

    ["toMineMode swaps chunky out for pickaxe"] = function(assert_eq)
        local eq = fresh(E_TRAVEL, fullInv({ [3] = { name = "pickaxe", count = 1 } }))
        local ok, reason = eq.toMineMode()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("pickaxe") ~= nil, true, "pickaxe should be equipped")
        assert_eq(eq.sideOf("chunky"), nil, "chunky should be stowed")
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem must stay equipped")
    end,

    ["toMineMode refuses when no pickaxe is carried"] = function(assert_eq)
        local eq = fresh(E_TRAVEL, fullInv())
        local ok, reason = eq.toMineMode()
        assert_eq(ok, false)
        assert_eq(reason, "pickaxe_missing")
    end,

    ["retrieval keeps chunky and pickaxe on simultaneously"] = function(assert_eq)
        local eq = fresh(E_MINE, fullInv({ [3] = { name = "chunky", count = 1 } }))
        local ok, reason = eq.retrievalSwapIn()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must be on")
        assert_eq(eq.sideOf("pickaxe") ~= nil, true, "pickaxe must stay on")
        assert_eq(eq.sideOf("modem"), nil, "modem is the one sacrificed")
    end,

    ["retrievalSwapOut restores the modem and keeps chunky"] = function(assert_eq)
        local eq = fresh(E_MINE, fullInv({ [3] = { name = "chunky", count = 1 } }))
        assert_eq(eq.retrievalSwapIn(), true)
        local ok, reason = eq.retrievalSwapOut()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem restored")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky retained")
        assert_eq(eq.sideOf("pickaxe"), nil, "pickaxe stowed")
    end,

    ["reconcile re-equips a modem left in inventory"] = function(assert_eq)
        local eq = fresh({ left = nil, right = "chunky" },
                         fullInv({ [4] = { name = "modem", count = 1 } }))
        local ok, reason = eq.reconcile()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem must be re-equipped")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must be retained")
    end,

    ["reconcile prefers chunky over pickaxe when both are stowed"] = function(assert_eq)
        local eq = fresh({ left = "modem", right = nil },
                         fullInv({ [3] = { name = "pickaxe", count = 1 },
                                   [5] = { name = "chunky",  count = 1 } }))
        local ok = eq.reconcile()
        assert_eq(ok, true)
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunk safety outranks digging when recovering")
    end,
}
```

- [ ] **Step 2: Run to verify they fail**

Add `"tests.test_equipment"` to the `files` list in `tests/run.lua`, then run: `lua tests/run.lua`
Expected: all 10 equipment tests FAIL with `module 'equipment' not found`

- [ ] **Step 3: Implement `equipment.lua`**

Replace the four `ITEMS` values with the exact registry names from your pack before running — get them from Task 1 Step 2's `getItemDetail` output.

```lua
-- equipment.lua
-- Owns every equipped-upgrade transition on the miner.
--
-- The miner has two upgrade slots and three things it needs: an ender modem for
-- comms, a chunky upgrade for chunk loading, and a pickaxe for digging. It never
-- needs all three at once, so each phase sacrifices exactly one:
--
--   travel : modem + chunky    (self-loading, cannot dig)
--   mine   : modem + pickaxe   (placed loader holds the chunk)
--   retrieve: chunky + pickaxe (comms down; can dig AND stay loaded)
--
-- Losing comms is self-correcting. Losing chunk loading outside the base-loaded
-- area is an unrecoverable freeze. So retrieval always sacrifices the modem.

local equipment = {}

equipment.SLOTS = {
    SCANNER = 1,   -- geo scanner (placed and picked up per scan)
    LOADER  = 2,   -- the chunk-loader turtle carried as cargo
    TOOL    = 3,   -- whichever of pickaxe/chunky is currently stowed
    MODEM   = 4,   -- holds the modem only during the retrieval window
    COAL    = 14,
    FUEL_EC = 15,
    ORE_EC  = 16,
}

-- Registry names, verified in-world 2026-08-13. See
-- docs/superpowers/specs/chunkloader-footprint.md.
-- The chunky upgrade is Advanced Peripherals' Chunky Turtle, not the
-- `chunkloaders` mod — that mod is not in this pack.
equipment.ITEMS = {
    PICKAXE       = "minecraft:diamond_pickaxe",
    CHUNKY        = "advancedperipherals:chunk_controller",
    MODEM         = "computercraft:wireless_modem_advanced",
    LOADER_TURTLE = "computercraft:turtle_advanced",
    SCANNER       = "advancedperipherals:geo_scanner",
}

local S, I = equipment.SLOTS, equipment.ITEMS

-- Peripheral type reported for each upgrade. A pickaxe is a tool, not a
-- peripheral, so getType returns nil for it and we must infer it instead.
local PERIPHERAL_TYPE = {
    [I.MODEM]  = "modem",
    [I.CHUNKY] = "chunky",
}

-- Which kind is on a given side, or nil. Sides are never assumed: the swap
-- dance flips them every cycle, so everything here is side-agnostic.
local function kindOnSide(side)
    local t = peripheral.getType(side)
    if t == "modem"  then return "modem"  end
    if t == "chunky" then return "chunky" end
    -- No peripheral: either empty or a tool. Tools are not introspectable, so
    -- treat a non-empty, non-peripheral side as the pickaxe.
    if t == nil then return nil end
    return t
end

function equipment.sideOf(kind)
    for _, side in ipairs({ "left", "right" }) do
        if kindOnSide(side) == kind then return side end
    end
    return nil
end

-- A side that reports no peripheral may still hold the pickaxe. We track that
-- by elimination: if the pickaxe is not in inventory it must be equipped.
local function pickaxeStowedSlot()
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name == I.PICKAXE then return s end
    end
    return nil
end

local function findSlot(itemName)
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name == itemName then return s end
    end
    return nil
end
equipment.findSlot = findSlot

local function emptySide()
    for _, side in ipairs({ "left", "right" }) do
        if kindOnSide(side) == nil and peripheral.getType(side) == nil then
            return side
        end
    end
    return nil
end

function equipment.state()
    return {
        left        = kindOnSide("left"),
        right       = kindOnSide("right"),
        pickaxeOn   = pickaxeStowedSlot() == nil,
        invLoader   = findSlot(I.LOADER_TURTLE) ~= nil,
        invScanner  = findSlot(I.SCANNER)       ~= nil,
        invFuelEC   = turtle.getItemDetail(S.FUEL_EC) ~= nil,
        invOreEC    = turtle.getItemDetail(S.ORE_EC)  ~= nil,
    }
end

-- Cargo the miner must never be without, whatever phase it is in.
local function validateCargo()
    if not equipment.state().invScanner then return false, "scanner_missing" end
    local fe = turtle.getItemDetail(S.FUEL_EC)
    if not fe then return false, "fuel_ec_missing" end
    local oe = turtle.getItemDetail(S.ORE_EC)
    if not oe then return false, "ore_ec_missing" end
    return true
end

-- mode: "travel" (modem+chunky, loader in cargo) or "mine" (modem+pickaxe)
function equipment.validate(mode)
    if not equipment.sideOf("modem") then return false, "modem_not_equipped" end

    if mode == "travel" then
        if not equipment.sideOf("chunky") then return false, "chunky_not_equipped" end
        if not equipment.state().invLoader then return false, "loader_turtle_missing" end
    elseif mode == "mine" then
        if equipment.sideOf("chunky") then return false, "chunky_still_equipped" end
        if pickaxeStowedSlot() ~= nil then return false, "pickaxe_not_equipped" end
    else
        return false, "unknown_mode"
    end

    return validateCargo()
end

-- Swap the item in `slot` onto `side`. Returns ok, reason.
local function swap(slot, side)
    turtle.select(slot)
    local ok, err = (side == "left") and turtle.equipLeft() or turtle.equipRight()
    if not ok then return false, "equip_failed:" .. tostring(err) end
    return true
end

-- chunky -> pickaxe. Called only once the placed loader is confirmed holding
-- the chunk; the caller owns that ordering.
function equipment.toMineMode()
    local pSlot = pickaxeStowedSlot()
    if not pSlot then
        if equipment.sideOf("chunky") then return false, "pickaxe_missing" end
        return true   -- already in mine mode
    end
    local chunkySide = equipment.sideOf("chunky")
    if not chunkySide then return false, "chunky_not_equipped" end
    local ok, reason = swap(pSlot, chunkySide)
    if not ok then return false, reason end
    return equipment.validate("mine")
end

-- pickaxe -> chunky. Safe to call while the placed loader still holds the
-- chunk; do it before retrieving so travel mode is restored first.
function equipment.toTravelMode()
    local cSlot = findSlot(I.CHUNKY)
    if not cSlot then
        if equipment.sideOf("chunky") then return true end
        return false, "chunky_missing"
    end
    -- The pickaxe occupies whichever side is not the modem.
    local modemSide = equipment.sideOf("modem")
    if not modemSide then return false, "modem_not_equipped" end
    local toolSide = (modemSide == "left") and "right" or "left"
    local ok, reason = swap(cSlot, toolSide)
    if not ok then return false, reason end
    return true
end

-- Retrieval step 1: modem -> chunky, so pickaxe AND chunky are both on.
-- Comms go down here. This is deliberate and must be reported before calling.
function equipment.retrievalSwapIn()
    local cSlot = findSlot(I.CHUNKY)
    if not cSlot then return false, "chunky_missing" end
    local modemSide = equipment.sideOf("modem")
    if not modemSide then return false, "modem_not_equipped" end
    local ok, reason = swap(cSlot, modemSide)
    if not ok then return false, reason end
    if not equipment.sideOf("chunky") then return false, "chunky_equip_verify_failed" end
    return true
end

-- Retrieval step 2: pickaxe -> modem. Chunky stays on throughout.
function equipment.retrievalSwapOut()
    local mSlot = findSlot(I.MODEM)
    if not mSlot then return false, "modem_item_missing" end
    local chunkySide = equipment.sideOf("chunky")
    if not chunkySide then return false, "chunky_not_equipped" end
    local toolSide = (chunkySide == "left") and "right" or "left"
    local ok, reason = swap(mSlot, toolSide)
    if not ok then return false, reason end
    if not equipment.sideOf("modem") then return false, "modem_equip_verify_failed" end
    if not equipment.sideOf("chunky") then return false, "chunky_lost_during_swap" end
    return true
end

-- Boot self-heal. A reboot inside the retrieval window leaves the modem in
-- inventory and no comms; without this the turtle is stranded until a player
-- intervenes. Chunk safety is restored before comms, because being unloaded is
-- unrecoverable while being offline is not.
function equipment.reconcile()
    if not equipment.sideOf("chunky") then
        local cSlot = findSlot(I.CHUNKY)
        local side  = emptySide()
        if cSlot and side then swap(cSlot, side) end
    end
    if not equipment.sideOf("modem") then
        local mSlot = findSlot(I.MODEM)
        local side  = emptySide()
        if mSlot and side then
            swap(mSlot, side)
        elseif mSlot then
            -- Both sides full and no modem on either: displace the pickaxe,
            -- which is the only upgrade safe to stow while outside.
            local pSlot = pickaxeStowedSlot()
            if pSlot == nil then
                local chunkySide = equipment.sideOf("chunky")
                local toolSide   = (chunkySide == "left") and "right" or "left"
                swap(mSlot, toolSide)
            end
        end
    end
    if not equipment.sideOf("modem") then return false, "modem_unrecoverable" end
    return true
end

return equipment
```

- [ ] **Step 4: Run to verify they pass**

Run: `lua tests/run.lua`
Expected: `12 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add equipment.lua tests/test_equipment.lua tests/run.lua
git commit -m "feat: add equipment module owning all miner upgrade transitions"
```

---

### Task 4: Boot-time reconciliation in `turtle_base.lua`

**Files:**
- Modify: `turtle_base.lua` — `comms.init()` (around line 98) and `base.init()` (around line 1263)

**Interfaces:**
- Consumes: `equipment.reconcile()` from Task 3.
- Produces: a miner that boots successfully with the modem stowed in inventory.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_equipment.lua`:

```lua
["comms.init recovers a stowed modem instead of erroring"] = function(assert_eq)
    stub.install({
        equipped = { left = nil, right = "chunky" },
        inv = { [4] = { name = "modem", count = 1 } },
    })
    package.loaded["equipment"] = nil
    local eq = require("equipment")
    assert_eq(peripheral.find("modem"), nil, "precondition: no modem equipped")
    assert_eq(eq.reconcile(), true)
    assert_eq(peripheral.find("modem") ~= nil, true, "modem now findable")
end,
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua tests/run.lua`
Expected: FAIL — `precondition: no modem equipped` passes but reconcile returns false, because `stub_cc`'s `ITEMS.MODEM` name is `"modem"` while `equipment.ITEMS.MODEM` is the registry name. Align the stub fixture to use `equipment.ITEMS.MODEM`.

- [ ] **Step 3: Make `comms.init` self-heal**

In `turtle_base.lua`, replace the body of `comms.init()`:

```lua
function comms.init()
    _self.modem = peripheral.find("modem")
    if not _self.modem then
        -- A miner rebooted inside the retrieval swap window has its modem in
        -- inventory, not equipped. Recover it rather than erroring out, which
        -- would strand the turtle in the field until a player intervened.
        local ok, equipment = pcall(require, "equipment")
        if ok and equipment then
            logWarn("No modem equipped — attempting equipment reconciliation")
            local healed, reason = equipment.reconcile()
            if healed then
                _self.modem = peripheral.find("modem")
                logInfo("Modem recovered from inventory.")
            else
                logError("Equipment reconciliation failed: " .. tostring(reason))
            end
        end
    end
    if not _self.modem then
        error("No modem found. Attach a wireless or ender modem.")
    end
    proto.openChannels(_self.modem, {
        proto.CH_BROADCAST, proto.CH_PRIVATE, proto.CH_LOCAL, proto.CH_WAREHOUSE,
    })
end
```

Preserve the exact channel list already present in the file — copy it from the current implementation rather than the line above if it differs.

- [ ] **Step 4: Run to verify it passes**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add turtle_base.lua tests/test_equipment.lua
git commit -m "fix: recover a stowed modem on boot instead of erroring out"
```

---

### Task 5: `geofence.lua` — loaded-area bounds and movement guard

**AMENDED after Task 1.** The fence works in **chunk space**, not block space.
Advanced Peripherals' chunky turtle loads a grid-aligned square of chunks around
the chunk it occupies — not a square centred on the turtle. A block-radius
Chebyshev fence cannot express that: near a chunk edge the two disagree by up to
15 blocks, every one of them unloaded. Uses `FENCE_CHUNK_RADIUS = 1` (3×3 chunks)
against a configured `chunkyTurtleRadius = 2` (5×5 loaded), per
`docs/superpowers/specs/chunkloader-footprint.md`.

**Files:**
- Create: `geofence.lua`
- Test: `tests/test_geofence.lua`

**Interfaces:**
- Produces:
  - `geofence.setAnchorChunk(cx, cz, chunkRadius)` / `geofence.clear()`
  - `geofence.setAnchorBlock(x, z, chunkRadius)` — anchors on the chunk containing that block
  - `geofence.isActive() → bool`
  - `geofence.contains(x, z) → bool`
  - `geofence.check(x, z) → ok, reason`
  - `geofence.anchor() → { cx=, cz=, chunkRadius= } | nil`
  - `geofence.chunkOf(x, z) → cx, cz`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_geofence.lua`:

```lua
local function fresh()
    package.loaded["geofence"] = nil
    return require("geofence")
end

return {
    ["inactive fence permits everything"] = function(assert_eq)
        local g = fresh()
        assert_eq(g.isActive(), false)
        assert_eq(g.contains(99999, -99999), true)
    end,

    ["anchor confines movement to the chunk block"] = function(assert_eq)
        local g = fresh()
        g.setAnchorChunk(0, 0, 1)          -- chunks -1..1 => blocks -16..31
        assert_eq(g.isActive(), true)
        assert_eq(g.contains(0, 0), true)
        assert_eq(g.contains(-16, -16), true, "far corner of chunk -1")
        assert_eq(g.contains(31, 31), true, "far corner of chunk 1")
        assert_eq(g.contains(-17, 0), false, "chunk -2 is outside")
        assert_eq(g.contains(32, 0), false, "chunk 2 is outside")
        assert_eq(g.contains(0, 32), false)
    end,

    ["the fence is grid-aligned, not centred on the anchor block"] = function(assert_eq)
        -- The bug this whole redesign exists to prevent: a loader placed at the
        -- high edge of its chunk loads the SAME chunks as one at the low edge.
        local g = fresh()
        g.setAnchorBlock(15, 15, 1)        -- block 15,15 is still chunk 0,0
        assert_eq(g.contains(31, 31), true)
        assert_eq(g.contains(32, 32), false,
            "a block-radius fence would wrongly allow this")
        assert_eq(g.contains(-16, -16), true,
            "a block-radius fence would wrongly forbid this")
    end,

    ["a sector's 33x33 work area fits a radius-1 fence exactly"] = function(assert_eq)
        -- SECTOR_STEP=32, SCAN_RADIUS=16 => centre c, area [c-16, c+16].
        -- Sector centres are multiples of 32, so they land on chunk boundaries.
        local g = fresh()
        g.setAnchorBlock(0, 0, 1)          -- loader in the sector's anchor chunk
        assert_eq(g.contains(-16, -16), true, "sector min corner")
        assert_eq(g.contains(16, 16), true,  "sector max corner")
    end,

    ["check reports the reason on breach"] = function(assert_eq)
        local g = fresh()
        g.setAnchorChunk(0, 0, 1)
        local ok, reason = g.check(400, 0)
        assert_eq(ok, false)
        assert_eq(reason, "geofence_breach")
    end,

    ["clear releases the fence"] = function(assert_eq)
        local g = fresh()
        g.setAnchorChunk(0, 0, 1)
        g.clear()
        assert_eq(g.isActive(), false)
        assert_eq(g.contains(9999, 9999), true)
    end,

    ["chunkOf floors to 16-block chunks including negatives"] = function(assert_eq)
        local g = fresh()
        local cx, cz = g.chunkOf(0, 0)
        assert_eq(cx, 0); assert_eq(cz, 0)
        cx, cz = g.chunkOf(15, 15)
        assert_eq(cx, 0); assert_eq(cz, 0)
        cx, cz = g.chunkOf(16, -1)
        assert_eq(cx, 1); assert_eq(cz, -1)
        cx, cz = g.chunkOf(-1, -17)
        assert_eq(cx, -1); assert_eq(cz, -2)
    end,
}
```

- [ ] **Step 2: Run to verify they fail**

Add `"tests.test_geofence"` to `tests/run.lua`, then run: `lua tests/run.lua`
Expected: 5 geofence tests FAIL — `module 'geofence' not found`

- [ ] **Step 3: Implement `geofence.lua`**

```lua
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

-- Chebyshev distance in chunk space.
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 5: Enforce it in `tryMove`**

In `turtle_base.lua`, at the top of `tryMove` (around line 365, immediately after the `serverDown` hold loop), add:

```lua
    -- Geofence: refuse any move that would leave the placed loader's footprint.
    -- Enforced here, at the single choke point every move passes through, so a
    -- new call site cannot bypass it.
    if _geofence and _geofence.isActive() then
        local nx, nz = _self.pos.x, _self.pos.z
        if dir == "forward" or dir == "back" then
            local sign = (dir == "forward") and 1 or -1
            if     _self.facing == 0 then nz = nz - sign
            elseif _self.facing == 1 then nx = nx + sign
            elseif _self.facing == 2 then nz = nz + sign
            else                          nx = nx - sign end
        end
        if not _geofence.contains(nx, nz) then
            local a = _geofence.anchor()
            logWarn(string.format(
                "Geofence: refusing move to %d,%d (anchor chunk %d,%d r%d)",
                nx, nz, a.cx, a.cz, a.chunkRadius))
            return false, "geofence_breach"
        end
    end
```

Near the top of `turtle_base.lua`, beside the other requires, add:

```lua
local ok_gf, _geofence = pcall(require, "geofence")
if not ok_gf then _geofence = nil end
```

Expose it so the miner can set the anchor:

```lua
base.geofence = _geofence
```

- [ ] **Step 6: Run the suite again**

Run: `lua tests/run.lua`
Expected: all pass (no regression)

- [ ] **Step 7: Commit**

```bash
git add geofence.lua turtle_base.lua tests/test_geofence.lua tests/run.lua
git commit -m "feat: add geofence and enforce it in the movement primitive"
```

---

### Task 5b: Crash recovery — persistent loader state and autonomous return

**Implement before Task 8.** Task 8's flow depends on the functions defined here.

A placed loader is a physical object the miner is responsible for. In-memory
state does not survive a reboot, so without this a rebooted miner abandons its
loader: the turtle is lost from the fleet and the chunk stays force-loaded
forever with nothing recording why. A server crash must also never leave a miner
parked in the field indefinitely.

**Files:**
- Create: `loader_state.lua`
- Modify: `turtle_base.lua` — `tryMove` serverDown hold; add `base.setAutonomousReturn()`
- Modify: `ore_turtle.lua` — boot recovery before accepting work
- Test: `tests/test_loader_state.lua`

**Interfaces:**
- Consumes: `equipment` (Task 3), `geofence` (Task 5).
- Produces:
  - `loader_state.record(x, y, z, sector, radius)` — persist before placing
  - `loader_state.clear()` — after confirmed retrieval
  - `loader_state.get() → { x, y, z, sector, radius } | nil`
  - `loader_state.hasPlaced() → bool`
  - `base.setAutonomousReturn(bool)` — exempts movement from the serverDown hold

- [ ] **Step 1: Write the failing tests**

Create `tests/test_loader_state.lua`:

```lua
local stub = require("tests.stub_cc")

local function fresh()
    stub.install({})
    package.loaded["loader_state"] = nil
    local ls = require("loader_state")
    ls.clear()
    return ls
end

return {
    ["no loader recorded on a clean start"] = function(assert_eq)
        local ls = fresh()
        assert_eq(ls.hasPlaced(), false)
        assert_eq(ls.get(), nil)
    end,

    ["record survives a simulated reboot"] = function(assert_eq)
        local ls = fresh()
        ls.record(100, 64, -200, { sx = 96, sz = -208 }, 24)
        package.loaded["loader_state"] = nil          -- simulate reboot
        local ls2 = require("loader_state")
        assert_eq(ls2.hasPlaced(), true)
        local s = ls2.get()
        assert_eq(s.x, 100); assert_eq(s.y, 64); assert_eq(s.z, -200)
        assert_eq(s.sector.sx, 96); assert_eq(s.radius, 24)
    end,

    ["clear removes the record"] = function(assert_eq)
        local ls = fresh()
        ls.record(1, 2, 3, { sx = 0, sz = 0 }, 24)
        ls.clear()
        assert_eq(ls.hasPlaced(), false)
    end,

    ["corrupt state file is treated as no loader, not a crash"] = function(assert_eq)
        local ls = fresh()
        local f = fs.open("loader_state.dat", "w")
        f.write("{ this is not valid lua")
        f.close()
        package.loaded["loader_state"] = nil
        local ls2 = require("loader_state")
        assert_eq(ls2.hasPlaced(), false,
            "a corrupt file must not brick the miner on boot")
    end,
}
```

Extend `tests/stub_cc.lua` with an in-memory `fs` so these run headless:

```lua
    local files = {}
    fs = {
        open = function(path, mode)
            if mode == "r" then
                if not files[path] then return nil end
                local content, done = files[path], false
                return {
                    readAll = function() return content end,
                    close   = function() end,
                }
            end
            local buf = {}
            return {
                write = function(_, s) buf[#buf + 1] = s end,
                writeLine = function(_, s) buf[#buf + 1] = s .. "\n" end,
                close = function() files[path] = table.concat(buf) end,
            }
        end,
        exists = function(path) return files[path] ~= nil end,
        delete = function(path) files[path] = nil end,
    }
    c.files = files
```

Note the `write` signature: the stub is called as `f.write(s)` in `loader_state.lua`,
so drop the leading `_` parameter if you call it without a colon. Keep the call
style consistent between stub and implementation.

- [ ] **Step 2: Run to verify they fail**

Add `"tests.test_loader_state"` to `tests/run.lua`, then run: `lua tests/run.lua`
Expected: 4 tests FAIL — `module 'loader_state' not found`

- [ ] **Step 3: Implement `loader_state.lua`**

```lua
-- loader_state.lua
-- Persists the fact that this miner has a chunk loader placed in the world.
--
-- The loader is a physical turtle the miner is responsible for retrieving. In
-- memory that fact dies with a reboot, and an abandoned loader means a turtle
-- lost from the fleet plus a chunk force-loaded forever with nothing recording
-- why. So the record is written to disk BEFORE placing and cleared only AFTER a
-- confirmed retrieval — that ordering means a crash at any instant errs toward
-- "we may have one out there", which is the recoverable direction.

local loader_state = {}

local PATH = "loader_state.dat"
local _cache = nil
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
    -- A truncated write (power loss mid-save) must not brick the miner on boot.
    local ok, data = pcall(textutils.unserialise, raw)
    if ok and type(data) == "table" and data.x then
        _cache = data
    end
    return _cache
end

function loader_state.record(x, y, z, sector, radius)
    _cache = { x = x, y = y, z = z, sector = sector, radius = radius,
               placedAt = os.epoch("utc") }
    _loaded = true
    local f = fs.open(PATH, "w")
    f.write(textutils.serialise(_cache))
    f.close()
end

function loader_state.clear()
    _cache = nil
    _loaded = true
    if fs.exists(PATH) then fs.delete(PATH) end
end

function loader_state.get() return load() end

function loader_state.hasPlaced() return load() ~= nil end

return loader_state
```

- [ ] **Step 4: Run to verify they pass**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 5: Wire the record into the flow**

In `mine_flow.lua` (Task 8), `placeLoader` must call `loader_state.record(...)`
immediately **before** `turtle.place()`, and `retrieveLoader` must call
`loader_state.clear()` only **after** `retrievalSwapOut()` succeeds. Add
`local loader_state = require("loader_state")` at the top of that module.

- [ ] **Step 6: Exempt the autonomous return from the serverDown hold**

In `turtle_base.lua`, the hold at the top of `tryMove` currently reads:

```lua
    while _self.serverDown and not _self.inSkyReturn do sleep(2) end
```

Replace with:

```lua
    -- Hold position while the server is unreachable so it does not lose track of
    -- us — except during a fixed-path sky return, or an autonomous return, where
    -- the whole point is to get home WITHOUT the server. Blocking there would
    -- strand the miner in the field for as long as the server stays down, and
    -- leave its placed loader force-loading a chunk indefinitely.
    while _self.serverDown
          and not _self.inSkyReturn
          and not _self.autonomousReturn do
        sleep(2)
    end
```

Add beside the other accessors:

```lua
function base.setAutonomousReturn(v) _self.autonomousReturn = v end
function base.isAutonomousReturn()   return _self.autonomousReturn end
```

and initialise `autonomousReturn = false` in the `_self` table.

- [ ] **Step 7: Boot recovery in `ore_turtle.lua`**

Before `base.run(mineJob)` is reached — immediately after `initProtectedSlots()`
— recover any abandoned loader:

```lua
-- Boot recovery. A reboot with a loader still placed would otherwise abandon it:
-- the turtle is lost and its chunk stays force-loaded with nothing recording it.
-- This runs before any job is accepted, so recovery always precedes new work.
local function recoverPlacedLoader()
    if not loader_state.hasPlaced() then return end
    local s = loader_state.get()
    print(string.format("[MINER] Boot: loader recorded at %d,%d,%d — recovering",
        s.x, s.y, s.z))
    base.sendProgress(string.format("recovering abandoned loader at %d,%d", s.x, s.z))

    equipment.reconcile()
    base.setAutonomousReturn(true)

    -- Approach at sky altitude, then drop onto the loader's own level so the
    -- fence stays valid for the descent. s.radius is a CHUNK radius and s.x/s.z
    -- are the loader's own block coords, so anchor on its chunk.
    geofence.setAnchorBlock(s.x, s.z, s.radius)
    base.move.to(s.x, SKY_Y, s.z)
    base.move.to(s.x, s.y, s.z)

    local ok, reason = mine_flow.retrieveLoader()
    if ok then
        print("[MINER] Loader recovered.")
        loader_state.clear()
    else
        -- Report loudly and leave the record in place: an operator needs to know
        -- a loader is standing out there, and the next boot will retry.
        print("[MINER] Loader recovery FAILED: " .. tostring(reason))
        base.sendProgress("loader_recovery_failed: " .. tostring(reason))
    end

    geofence.clear()
    base.setAutonomousReturn(false)
end

recoverPlacedLoader()
```

- [ ] **Step 8: Autonomous return on prolonged server loss**

Inside the miner's sector loop, check elapsed server-down time each iteration:

```lua
        -- A server outage must not leave the miner parked in the field with a
        -- loader force-loading a chunk. After 5 minutes, take ourselves home:
        -- retrieve the loader, restore travel mode, dock, and wait for the
        -- server there. GPS comes from beacons, not the server, so navigation
        -- is unaffected by the outage.
        if base.isServerDown() then
            _serverDownSince = _serverDownSince or os.epoch("utc")
            if os.epoch("utc") - _serverDownSince > 300000 then
                print("[MINER] Server unreachable 5min — autonomous return")
                base.setAutonomousReturn(true)
                soloReturn()
                base.setAutonomousReturn(false)
                return base.sendFailed("server_unreachable_autonomous_return", true)
            end
        else
            _serverDownSince = nil
        end
```

Declare `local _serverDownSince = nil` beside the other job-scope locals.

- [ ] **Step 9: Report placed loaders to the server**

So an operator can find orphans. In `mine_flow.placeLoader`, after the record is
written, include the coordinates in the phase report:

```lua
    report("PLACING_LOADER", string.format("%d,%d,%d", p.x, p.y, p.z))
```

In `central_server.lua`'s `handleMinePhase`, capture it:

```lua
    -- Track placed loaders so orphans are findable after a crash on either side.
    if p.phase == proto.PHASE.PLACING_LOADER and p.detail then
        t.placedLoader = p.detail
    elseif p.phase == proto.PHASE.TRAVELLING or p.phase == proto.PHASE.RETURNING then
        t.placedLoader = nil
    end
```

Expose `placedLoader` in `/state` beside `chunk`, and surface it in the dashboard
(Task 10) as an explicit warning row when a turtle is offline while holding one.

- [ ] **Step 10: Run the suite**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 11: Commit**

```bash
git add loader_state.lua turtle_base.lua ore_turtle.lua mine_flow.lua central_server.lua tests/test_loader_state.lua tests/stub_cc.lua tests/run.lua
git commit -m "feat: persist placed-loader state and add autonomous return on server loss"
```

---

### Task 5c: Loader beacon — modem on the carried chunk loader

**AMENDED after Task 1: this task is mandatory and load-bearing, not telemetry.**
The pack sets `chunkLoadValidTime = 600` — "time in seconds while a loaded chunk
can be considered valid without touch". If a placed, idle turtle running no
program does not constitute a touch, chunk loading expires **10 minutes into a
sector** and the miner freezes: Invariant A failing on a timer. A loader running
`loader_turtle.lua` ticks continuously, which is the most plausible "touch", so
the beacon program is what keeps the ticket alive. It must ship before any long
sector run, not after. Raising `chunkLoadValidTime` (range is open above 60) is
recommended belt-and-braces, not a substitute.

The loader turtle has two upgrade slots and uses one for chunky. Putting an ender
modem in the other turns it from a silent object into one that reports itself.

This does **not** close the retrieval comms gap — radio needs a modem at both
ends, and the miner has none during the swap. What it buys is bigger:

- **Invariant A becomes verified rather than assumed.** Today the miner places the
  loader, sees a block standing, and trusts it is loading. If that upgrade fails
  or something breaks the loader, the miner mines on until it silently unloads.
  A beacon makes loss detectable in seconds.
- **Orphans self-report.** Task 5b infers orphans from the miner's disk state plus
  server bookkeeping. A beacon just announces itself, and keeps announcing even
  if the miner that placed it is permanently gone.

The loader program is the simplest turtle program in the fleet: register, beacon,
nothing else. It never moves, never touches inventory, never coordinates, and
needs no fuel.

**Files:**
- Create: `loader_turtle.lua` (renamed to `startup.lua` on each loader)
- Modify: `protocol.lua` — `ROLE.LOADER`, `MSG.LOADER_BEACON`
- Modify: `central_server.lua` — register loaders, never dispatch to them, expose in `/state`
- Modify: `mine_flow.lua` — verify the beacon before removing chunky; monitor it while mining
- Test: `tests/test_loader_beacon.lua`

**Interfaces:**
- Produces: `LOADER_BEACON` broadcast on `CH_LOCAL` and `CH_SERVER` every 5s carrying `{ loaderId, position, deployedBy }`.
- Produces: `mine_flow.beaconSeenWithin(seconds) → bool`

- [ ] **Step 1: Add the role and message**

In `protocol.lua`:

```lua
    LOADER   = "LOADER",     -- in proto.ROLE: placed chunk loader, never dispatched
```

```lua
    -- Placed chunk loader liveness (loader → server + CH_LOCAL to any miner).
    -- Proves the chunk is actually held, and makes an abandoned loader
    -- self-reporting rather than something the server has to infer.
    LOADER_BEACON = "LOADER_BEACON",
```

```lua
function proto.payloadLoaderBeacon(position, deployedBy)
    return { position = position, deployedBy = deployedBy, ts = os.epoch("utc") }
end
```

- [ ] **Step 2: Write the loader program**

Create `loader_turtle.lua`:

```lua
-- loader_turtle.lua
-- Rename to startup.lua on any turtle used as a placed chunk loader.
--
-- Equipped: chunky upgrade + ender modem. Never moves, never digs, holds no
-- cargo, needs no fuel. Its entire job is to hold a chunk and say so.
--
-- The beacon is what makes chunk loading verifiable: a miner that stops hearing
-- it re-equips its own chunky immediately rather than mining on inside a chunk
-- that may no longer be loaded.

local proto = require("protocol")

local BEACON_INTERVAL = 5

local modem = peripheral.find("modem")
if not modem then
    -- Nothing useful can be done without comms, but the chunky upgrade still
    -- works, so keep holding the chunk rather than halting.
    print("[LOADER] No modem — holding chunk silently.")
    while true do sleep(60) end
end

proto.openChannels(modem, { proto.CH_SERVER, proto.CH_BROADCAST,
                            proto.CH_PRIVATE, proto.CH_LOCAL })

local selfId = proto.selfId()
local deployedBy = nil
if fs.exists("deployed_by.txt") then
    local f = fs.open("deployed_by.txt", "r")
    deployedBy = f.readAll()
    f.close()
end

local function position()
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z } end
    return nil
end

print("[LOADER] " .. selfId .. " holding chunk. Beaconing every "
      .. BEACON_INTERVAL .. "s.")

while true do
    local pos = position()
    local payload = proto.payloadLoaderBeacon(pos, deployedBy)
    -- CH_LOCAL so a nearby miner can verify directly without a server round
    -- trip; CH_SERVER so the fleet view knows this loader exists at all.
    proto.send(modem, proto.CH_LOCAL,
        proto.encode(proto.MSG.LOADER_BEACON, selfId, "broadcast", payload))
    proto.send(modem, proto.CH_SERVER,
        proto.encode(proto.MSG.LOADER_BEACON, selfId, "server", payload))
    sleep(BEACON_INTERVAL)
end
```

- [ ] **Step 3: Gate the chunky swap on a live beacon**

In `mine_flow.lua`, add beacon tracking and require it before giving up chunky:

```lua
local _lastBeacon = 0
local _beaconId   = nil

-- Called by ore_turtle whenever a LOADER_BEACON arrives.
function mine_flow.noteBeacon(msg)
    _lastBeacon = os.epoch("utc")
    _beaconId   = msg.from
end

function mine_flow.beaconSeenWithin(seconds)
    return (os.epoch("utc") - _lastBeacon) < (seconds * 1000)
end
```

In `placeLoader`, between confirming the block is standing and swapping:

```lua
    -- Wait for the placed loader to announce itself before giving up our own
    -- chunk loading. Without this we would be trusting that a block we can see
    -- is actually holding the chunk.
    _lastBeacon = 0
    local beaconDeadline = os.epoch("utc") + 15000
    while os.epoch("utc") < beaconDeadline do
        if mine_flow.beaconSeenWithin(10) then break end
        _hooks.pump(1)   -- let ore_turtle drain messages into noteBeacon
    end
    if not mine_flow.beaconSeenWithin(10) then
        -- Never remove chunky on an unverified loader. Take it back and fail
        -- the sector; a loader that cannot beacon may not be loading either.
        log("Loader placed but never beaconed — recovering it")
        return false, "loader_no_beacon"
    end
```

Add `pump` to the injected hooks in Task 8, implemented in `ore_turtle.lua` as a
short `base.receive`-style drain that routes `LOADER_BEACON` to
`mine_flow.noteBeacon` and ignores everything else.

- [ ] **Step 4: Monitor the beacon while mining**

In the miner's ore loop, beside the existing periodic fuel check:

```lua
            -- If the loader stops beaconing we may no longer be in a loaded
            -- chunk. Re-equip our own chunky immediately — mining can wait,
            -- being unloaded outside the base area cannot be undone.
            if mined % 10 == 0 and geofence.isActive()
                    and not mine_flow.beaconSeenWithin(30) then
                print("[MINER] Loader beacon lost — restoring own chunk loading")
                base.sendProgress("loader_beacon_lost")
                equipment.toTravelMode()
                geofence.clear()
                break
            end
```

- [ ] **Step 5: Record the deployer on placement**

In `placeLoader`, before `turtle.place()`, the miner cannot write to the loader's
filesystem, so record the pairing server-side instead: include the miner's own ID
in the `PLACING_LOADER` phase detail (Task 5b Step 9 already sends coordinates —
extend it to `"x,y,z by <selfId>"`). The server joins beacon reports to that
record so the dashboard can show which miner owns which loader.

- [ ] **Step 6: Server — register loaders, never dispatch to them**

In `central_server.lua`, handle `LOADER_BEACON`:

```lua
-- Loaders are inventory, not workers. They register so the fleet view can show
-- them and flag orphans, but the dispatcher must never assign them a job.
local function handleLoaderBeacon(msg)
    local p = msg.payload
    local t = state.registry[msg.from] or {}
    t.role       = proto.ROLE.LOADER
    t.online     = true
    t.lastSeen   = os.epoch("utc")
    t.position   = p.position or t.position
    t.deployedBy = p.deployedBy or t.deployedBy
    state.registry[msg.from] = t
end
```

Confirm `registry.getIdle(role)` can never return a LOADER — the dispatcher asks
for `MINER`, `DELIVERY` and `SUPPORT` roles specifically, so verify by inspection
that no code path requests an idle turtle without naming a role.

- [ ] **Step 7: Dashboard — orphan warning**

A loader beaconing with no active mine job owning it is an orphan. Surface it as
a warning row with its coordinates so it can be collected by hand. This is the
case that would otherwise silently force-load a chunk indefinitely.

- [ ] **Step 8: Write the tests**

Create `tests/test_loader_beacon.lua` covering:
- `beaconSeenWithin` returns false before any beacon and true immediately after `noteBeacon`
- `placeLoader` returns `loader_no_beacon` and **leaves chunky equipped** when no beacon arrives
- the mining loop's beacon-lost path restores travel mode and clears the fence

The second is the important one: it is the guard that stops the miner giving up
chunk loading to a loader that may not be working.

- [ ] **Step 9: Run the suite**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 10: Prepare the loader turtles**

On each turtle intended as a loader: equip chunky and an ender modem, copy
`loader_turtle.lua` to `startup.lua`, and label it (`label set loader_1`) so it
has a stable identity. A turtle keeps its computer ID and filesystem through
place → break → re-place, so this is a one-time setup per loader.

- [ ] **Step 11: Commit and push**

```lua
proto.VERSION = "1.9.3"
```

```bash
git add protocol.lua loader_turtle.lua mine_flow.lua ore_turtle.lua central_server.lua tests/test_loader_beacon.lua tests/run.lua
git commit -m "feat: loader beacon verifies chunk loading and self-reports orphans (v1.9.3)"
git push origin master
```

---

### Task 6: Protocol additions

Additive only. Nothing is removed, so delivery is unaffected.

**Files:**
- Modify: `protocol.lua`

**Interfaces:**
- Produces: `proto.MSG.MINE_PHASE`; `proto.payloadMinePhase(jobId, phase, detail)`; `phase`, `chunk`, `commsGap` fields on the heartbeat payload.

- [ ] **Step 1: Add the message type**

In `protocol.lua`, inside `proto.MSG`, immediately after the `MINE_COMPLETE` line:

```lua
    -- Solo-miner phase reporting (miner → server). Drives the dashboard's
    -- per-node process view and distinguishes a deliberate comms gap during the
    -- loader-retrieval swap from an actual turtle failure.
    MINE_PHASE     = "MINE_PHASE",
```

- [ ] **Step 2: Add the phase constants**

After the `proto.STATUS` table:

```lua
-- ─── Solo Miner Phases ───────────────────────────────────────────────────────
-- Ordered lifecycle of one sector. Reported on entry to each phase so the
-- dashboard can show exactly where a node is, and so a stall is attributable.
proto.PHASE = {
    DEPARTING       = "DEPARTING",        -- leaving the depot, modem+chunky
    TRAVELLING      = "TRAVELLING",       -- flying to sector, self-loading
    PLACING_LOADER  = "PLACING_LOADER",   -- placing the carried chunk loader
    SWAP_TO_PICKAXE = "SWAP_TO_PICKAXE",  -- chunky → pickaxe
    SCANNING        = "SCANNING",          -- geo scan at a depth level
    MINING          = "MINING",            -- working ores inside the fence
    DUMPING         = "DUMPING",           -- emptying to the ore ender chest
    SWAP_TO_CHUNKY  = "SWAP_TO_CHUNKY",   -- pickaxe → chunky, loader still down
    RETRIEVING      = "RETRIEVING",        -- comms-gap window: digging loader up
    RETURNING       = "RETURNING",         -- flying home, modem+chunky
    DOCKED          = "DOCKED",
}
```

- [ ] **Step 3: Add the payload builder**

Beside the other mining payload builders:

```lua
-- detail is free-form context for the dashboard: a reason, a sector, a count.
function proto.payloadMinePhase(jobId, phase, detail)
    return {
        jobId  = jobId,
        phase  = phase,
        detail = detail,
        ts     = os.epoch("utc"),
    }
end
```

- [ ] **Step 4: Extend the heartbeat payload**

Replace `proto.payloadHeartbeat` with:

```lua
-- phase/chunk/commsGap are optional and nil for every non-miner role, so
-- delivery and support heartbeats are unchanged on the wire.
function proto.payloadHeartbeat(status, fuelLevel, position, jobId, extra)
    extra = extra or {}
    return {
        status   = status,
        fuel     = fuelLevel,
        position = position,
        jobId    = jobId,
        version  = proto.VERSION,
        phase    = extra.phase,
        chunk    = extra.chunk,      -- { cx=, cz= } the miner is working in
        commsGap = extra.commsGap,   -- true while a deliberate gap is expected
    }
end
```

Every existing 4-argument call site keeps working because `extra` defaults to `{}`.

- [ ] **Step 5: Bump the version**

```lua
proto.VERSION = "1.9.0"
```

- [ ] **Step 6: Verify no call site broke**

Run: `grep -rn "payloadHeartbeat" *.lua`
Expected: every hit passes 4 args or fewer, or 5 with a table as the 5th.

- [ ] **Step 7: Commit**

```bash
git add protocol.lua
git commit -m "feat: add MINE_PHASE, phase constants, and heartbeat phase/chunk fields (v1.9.0)"
git push origin master
```

---

### Task 7: Server — stop pairing MINE jobs, track phase and chunk

**Files:**
- Modify: `central_server.lua` — dispatcher (around line 1234–1310), heartbeat handler, `/state` serialisation (around line 2675), and add a `MINE_PHASE` handler.

**Interfaces:**
- Consumes: `proto.MSG.MINE_PHASE`, `proto.PHASE`, heartbeat `extra` fields from Task 6.
- Produces: `registry[id].phase`, `.chunk`, `.commsGap`, `.phaseAt`; both present in `/state`.

- [ ] **Step 1: Stop creating a support job for MINE**

In `dispatcher.tick()`, the block that builds `supportParams` and calls `jobQueue.add(proto.JOB.SUPPORT_FOLLOW, ...)` currently runs for both DELIVER and MINE. Guard it so it runs for DELIVER only:

```lua
            -- MINE jobs are solo since v1.9.0: the miner carries its own chunk
            -- loader. DELIVER keeps the pair system unchanged — a delivery
            -- turtle moves continuously to its destination, so a stationary
            -- loader cannot cover it.
            if not isMine then
                local supportParams = {
                    partnerId      = worker.id,
                    masterJobId    = job.id,
                    fuelManage     = false,
                    destination    = job.params.destination,
                    travelYOffset  = workerParams.travelYOffset or 0,
                }
                local supportJobId = jobQueue.add(proto.JOB.SUPPORT_FOLLOW, supportParams, job.priority)
                job.linkedJob = supportJobId
                jobQueue.assign(supportJobId, support.id)
                sendTo(support.id, proto.MSG.JOB_ASSIGN,
                    proto.payloadJobAssign(supportJobId, proto.JOB.SUPPORT_FOLLOW, supportParams))
            end
```

Then remove the `workerParams.partnerId = support.id` assignment for mine jobs — a solo miner has no partner:

```lua
            if not isMine then workerParams.partnerId = support.id end
```

Also remove the MINE-only support-availability precondition so a mine job dispatches with zero idle supports. Find where the dispatcher requires both a worker and a support and make the support requirement conditional on `not isMine`.

- [ ] **Step 2: Record phase and chunk from heartbeats**

In the heartbeat handler, after the existing fields are stored:

```lua
    -- Solo-miner telemetry. nil for every other role, so this is a no-op for them.
    if p.phase then
        if t.phase ~= p.phase then t.phaseAt = os.epoch("utc") end
        t.phase = p.phase
    end
    if p.chunk    then t.chunk    = p.chunk    end
    if p.commsGap ~= nil then t.commsGap = p.commsGap end
```

- [ ] **Step 3: Handle `MINE_PHASE`**

Beside the other mining handlers, add:

```lua
-- Phase transitions arrive as their own message as well as on heartbeats, so a
-- short-lived phase between two heartbeats is not missed by the dashboard.
local function handleMinePhase(msg)
    local p = msg.payload
    local t = state.registry[msg.from]
    if not t then return end
    if t.phase ~= p.phase then t.phaseAt = p.ts or os.epoch("utc") end
    t.phase = p.phase
    -- RETRIEVING is the deliberate comms-gap window: the miner sacrifices its
    -- modem so pickaxe and chunky can be equipped together. Mark it so a
    -- missed heartbeat during it is not misread as a failure.
    t.commsGap = (p.phase == proto.PHASE.RETRIEVING)
    jobQueue.progress(p.jobId, proto.STATUS.WORKING,
        string.format("phase %s%s", p.phase, p.detail and (" — " .. p.detail) or ""))
    logInfo(string.format("%s phase: %s%s", msg.from, p.phase,
        p.detail and (" (" .. p.detail .. ")") or ""))
end
```

Register it in the message dispatch table alongside `SECTOR_DONE` and friends.

- [ ] **Step 4: Suppress ghost detection during a planned comms gap**

In `checkGhosts()` and the offline-detection pass, skip turtles whose gap is expected:

```lua
        -- A miner in RETRIEVING has deliberately unequipped its modem; missed
        -- heartbeats there are expected, not evidence of a failure. Allow a
        -- generous 60s before treating it as real.
        if t.commsGap and t.phaseAt and (now - t.phaseAt) < 60000 then
            goto continue_turtle
        end
```

Use whatever skip mechanism the surrounding loop already uses rather than introducing `goto` if the loop is structured differently.

- [ ] **Step 5: Expose phase and chunk in `/state`**

In the `/state` JSON serialisation for each turtle, alongside `version`:

```lua
                        ',"phase":'    .. js(t.phase,    'null', "phase") ..
                        ',"phaseAt":'  .. tostring(t.phaseAt or 0) ..
                        ',"commsGap":' .. tostring(t.commsGap and true or false) ..
                        ',"chunk":'    .. (t.chunk
                            and string.format('{"cx":%d,"cz":%d}', t.chunk.cx, t.chunk.cz)
                            or 'null') ..
```

Match the existing `js()` helper's calling convention exactly — copy the pattern from the adjacent `version` field.

- [ ] **Step 6: Bump and push**

```lua
proto.VERSION = "1.9.1"
```

```bash
git add protocol.lua central_server.lua
git commit -m "feat: solo MINE dispatch, phase/chunk telemetry, comms-gap aware ghost detection (v1.9.1)"
git push origin master
```

---

### Task 8: `ore_turtle.lua` — the solo sector flow

The largest task. Replaces every partner interaction with the place/swap/mine/swap/retrieve cycle.

**Files:**
- Modify: `ore_turtle.lua`
- Test: `tests/test_mine_flow.lua`

**Interfaces:**
- Consumes: `equipment` (Task 3), `geofence` (Task 5), `proto.PHASE` and `proto.payloadMinePhase` (Task 6).
- Produces: `minerFlow.placeLoader()`, `minerFlow.retrieveLoader()`, `minerFlow.sectorCycle(sector)` — extracted as testable functions rather than inlined in the job loop.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_mine_flow.lua`:

```lua
local stub = require("tests.stub_cc")

local function loadFlow(equipped, inv, world)
    stub.install({ equipped = equipped, inv = inv, world = world or {},
                   pos = { x = 0, y = 80, z = 0, facing = 0 } })
    package.loaded["equipment"]  = nil
    package.loaded["geofence"]   = nil
    package.loaded["mine_flow"]  = nil
    return require("mine_flow"), require("equipment"), require("geofence")
end

local function travelInv()
    local eq = require("equipment")
    return {
        [1]  = { name = "advancedperipherals:geo_scanner", count = 1 },
        [2]  = { name = eq.ITEMS.LOADER_TURTLE, count = 1 },
        [3]  = { name = eq.ITEMS.PICKAXE,       count = 1 },
        [14] = { name = "minecraft:coal",       count = 32 },
        [15] = { name = "enderstorage:ender_chest", count = 1 },
        [16] = { name = "enderstorage:ender_chest", count = 1 },
    }
end

return {
    ["placeLoader places, then swaps to pickaxe, then arms the fence"] = function(assert_eq)
        package.loaded["equipment"] = nil
        local eqm = require("equipment")
        local flow, eq, gf = loadFlow(
            { left = "modem", right = "chunky" }, travelInv())
        -- Miner at 0,0 facing north => loader lands at 0,-1, which is chunk 0,-1.
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky"), nil, "chunky must be stowed after the swap")
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem stays on")
        assert_eq(gf.isActive(), true, "fence must be armed once the pickaxe is on")
        local a = gf.anchor()
        assert_eq(a.cx, 0);  assert_eq(a.cz, -1,
            "fence anchors on the LOADER's chunk, not the miner's position")
    end,

    ["placeLoader refuses a target outside the sector's anchor chunk"] = function(assert_eq)
        package.loaded["equipment"] = nil
        local eqm = require("equipment")
        local flow, eq, gf = loadFlow(
            { left = "modem", right = "chunky" }, travelInv())
        -- Demand a chunk the placement cannot reach from here.
        local ok, reason = flow.placeLoader(1, { cx = 5, cz = 5 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_target_wrong_chunk")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must NOT be removed when placement is refused")
        assert_eq(gf.isActive(), false)
        assert_eq(eq.findSlot(eqm.ITEMS.LOADER_TURTLE) ~= nil, true,
            "loader must still be carried, not dropped in the wrong chunk")
    end,

    ["placeLoader refuses when the loader turtle is not carried"] = function(assert_eq)
        package.loaded["equipment"] = nil
        local eqm = require("equipment")
        local inv = travelInv(); inv[2] = nil
        local flow, eq, gf = loadFlow({ left = "modem", right = "chunky" }, inv)
        local ok, reason = flow.placeLoader(1, { cx = 0, cz = -1 })
        assert_eq(ok, false)
        assert_eq(reason, "loader_turtle_missing")
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunky must NOT be removed when placement fails")
        assert_eq(gf.isActive(), false)
    end,

    ["retrieveLoader keeps chunky on across the dig"] = function(assert_eq)
        package.loaded["equipment"] = nil
        local eqm = require("equipment")
        local inv = travelInv()
        inv[2] = nil                                  -- loader is placed, not carried
        inv[3] = { name = eqm.ITEMS.CHUNKY, count = 1 }
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf = loadFlow({ left = "modem", right = "pickaxe" }, inv, world)
        gf.setAnchorChunk(0, 0, 1)
        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky on at the end")
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem restored at the end")
        assert_eq(gf.isActive(), false, "fence released once self-loading again")
    end,

    ["retrieveLoader aborts before digging if chunky is not carried"] = function(assert_eq)
        package.loaded["equipment"] = nil
        local eqm = require("equipment")
        local inv = travelInv(); inv[2] = nil; inv[3] = nil
        local world = { ["0,80,-1"] = eqm.ITEMS.LOADER_TURTLE }
        local flow, eq, gf = loadFlow({ left = "modem", right = "pickaxe" }, inv, world)
        local ok, reason = flow.retrieveLoader()
        assert_eq(ok, false)
        assert_eq(reason, "chunky_missing")
        assert_eq(world["0,80,-1"], eqm.ITEMS.LOADER_TURTLE,
            "loader must still be standing — never dig it up without chunky in hand")
    end,
}
```

- [ ] **Step 2: Run to verify they fail**

Add `"tests.test_mine_flow"` to `tests/run.lua`, then run: `lua tests/run.lua`
Expected: 4 tests FAIL — `module 'mine_flow' not found`

- [ ] **Step 3: Implement `mine_flow.lua`**

Extracting these into their own module keeps them testable and keeps `ore_turtle.lua` readable.

```lua
-- mine_flow.lua
-- The place / swap / mine / swap / retrieve cycle for a solo miner.
--
-- Ordering is the whole safety argument, so it lives in one place:
--
--   placeLoader:    place loader  →  verify standing  →  chunky→pickaxe  →  arm fence
--   retrieveLoader: verify chunky carried  →  modem→chunky  →  dig  →  pickaxe→modem
--                   →  release fence
--
-- Placement removes chunky only AFTER the loader is confirmed down. Retrieval
-- equips chunky BEFORE the loader comes up. At no instant is the miner both
-- unloaded and outside the base-loaded area.

local equipment = require("equipment")
local geofence  = require("geofence")

local mine_flow = {}

-- Injected by ore_turtle so this module stays free of comms and movement.
-- reportPhase(phase, detail); log(msg); pos() → {x,y,z}
local _hooks = { reportPhase = function() end, log = print, pos = nil }
function mine_flow.setHooks(h)
    for k, v in pairs(h) do _hooks[k] = v end
end

local function report(phase, detail) _hooks.reportPhase(phase, detail) end
local function log(msg) _hooks.log(msg) end

-- One block ahead of the miner — where turtle.place() will put the loader.
local function aheadBlock(p)
    local dx, dz = 0, 0
    if     p.facing == 0 then dz = -1
    elseif p.facing == 1 then dx =  1
    elseif p.facing == 2 then dz =  1
    else                      dx = -1 end
    return p.x + dx, p.z + dz
end

-- Place the carried loader turtle ahead, confirm it is standing, then hand
-- chunk duty over to it and arm the fence around it.
--
-- anchorChunk is the chunk the sector requires the loader to occupy: with
-- SECTOR_STEP=32 and SCAN_RADIUS=16 the work area is exactly the 3x3 chunks
-- centred on chunkOf(sectorCentre). Placing one chunk off leaves the sector's
-- far edge unloaded, so this is checked BEFORE the loader leaves the inventory.
function mine_flow.placeLoader(chunkRadius, anchorChunk)
    report("PLACING_LOADER")

    local ok, reason = equipment.validate("travel")
    if not ok then return false, reason end

    local slot = equipment.findSlot(equipment.ITEMS.LOADER_TURTLE)
    if not slot then return false, "loader_turtle_missing" end

    -- turtle.place() puts the loader one block AHEAD, which can be in a
    -- different chunk than the miner. The fence must describe the LOADER's
    -- chunk, since that is the thing doing the loading — anchoring on the
    -- miner's own position is wrong wherever the two straddle a boundary.
    local p = _hooks.pos()
    local tx, tz = aheadBlock(p)
    local lcx, lcz = geofence.chunkOf(tx, tz)

    if anchorChunk and (lcx ~= anchorChunk.cx or lcz ~= anchorChunk.cz) then
        -- Caller must reposition; never place a loader that cannot cover the
        -- sector. Recovering it would need a pickaxe we are not holding.
        return false, "loader_target_wrong_chunk"
    end

    turtle.select(slot)
    if turtle.detect() then
        return false, "placement_blocked"
    end
    if not turtle.place() then
        return false, "loader_place_failed"
    end

    -- Confirm it is actually standing before giving up our own chunk loading.
    if not turtle.detect() then
        return false, "loader_not_detected_after_place"
    end
    log("Loader placed and confirmed standing.")

    report("SWAP_TO_PICKAXE")
    local swapped, why = equipment.toMineMode()
    if not swapped then
        -- We still hold chunky, so we are safe; the loader is down and will be
        -- retrieved by the caller's failure path.
        return false, why
    end

    -- Anchor on the loader's chunk, not the miner's position.
    geofence.setAnchorBlock(tx, tz, chunkRadius)
    log(string.format("Fence armed on chunk %d,%d radius %d (loader at %d,%d)",
        lcx, lcz, chunkRadius, tx, tz))
    return true
end

-- Restore self-loading, then take the loader back. Never dig it up first.
function mine_flow.retrieveLoader()
    -- Refuse before touching anything if we cannot restore our own loading.
    if not equipment.findSlot(equipment.ITEMS.CHUNKY) then
        return false, "chunky_missing"
    end
    if not turtle.detect() then
        return false, "loader_not_in_front"
    end

    report("RETRIEVING", "comms gap expected")

    -- Sacrifice the modem, not chunk loading: offline is recoverable, unloaded
    -- is not. Comms are down from here until the swap-out below.
    local ok, reason = equipment.retrievalSwapIn()
    if not ok then return false, reason end

    local dug = turtle.dig()
    if not dug then
        -- Put comms back before reporting the failure.
        equipment.retrievalSwapOut()
        return false, "loader_dig_failed"
    end

    local restored, why = equipment.retrievalSwapOut()
    if not restored then return false, why end

    geofence.clear()
    log("Loader retrieved; self-loading restored.")
    return true
end

return mine_flow
```

- [ ] **Step 4: Run to verify they pass**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 5: Rewrite the miner's job flow**

In `ore_turtle.lua`:

Add near the other requires:

```lua
local equipment = require("equipment")
local geofence  = require("geofence")
local mine_flow = require("mine_flow")

-- Footprint from docs/superpowers/specs/chunkloader-footprint.md. Measured in
-- CHUNKS: 1 => the 3x3 chunks around the loader's own chunk, which is exactly a
-- 33x33 sector. The pack loads 5x5 (chunkyTurtleRadius=2), so this leaves one
-- chunk of slack on every side.
--
-- This is the only thing keeping the miner inside loaded chunks while its own
-- chunky upgrade is stowed. Do NOT raise it without raising chunkyTurtleRadius
-- in the Advanced Peripherals config first — nothing checks that they agree,
-- and a mismatch does not error, it freezes the turtle in an unloaded chunk.
local FENCE_CHUNK_RADIUS = 1
```

Add a phase reporter and wire the hooks:

```lua
local _phase = nil
local function reportPhase(phase, detail)
    _phase = phase
    local cx, cz = geofence.chunkOf(base.getPos().x, base.getPos().z)
    base.setPhase(phase, { cx = cx, cz = cz })
    base.sendToServer(proto.MSG.MINE_PHASE,
        proto.payloadMinePhase(base.getJobId(), phase, detail))
    print(string.format("[MINER] phase %s%s", phase, detail and (" — " .. detail) or ""))
end

mine_flow.setHooks({
    reportPhase = reportPhase,
    log         = function(m) print("[MINER] " .. m) end,
    pos         = function() return base.getPos() end,
})
```

Delete these entirely — no partner exists any more:
- the `base.setPartnerId(job.params.partnerId)` call
- the `JOB_ABORT`-from-partner branch in `waitMsg`
- `coordinatedSkyReturn`'s support-online query loop, `MINE_RECALL` retry loop, and every `signalPartner` call
- the near-surface `RETURN_TO_DOCK` signal

Replace `coordinatedSkyReturn` with:

```lua
    -- Solo return. No partner to coordinate with, so this is just: make sure we
    -- are self-loading, then fly home. If a loader is still placed we must take
    -- it with us — leaving it behind loses a turtle and permanently loads a chunk.
    local function soloReturn()
        report_or_print("RETURNING")
        dumpOres()
        if geofence.isActive() then
            local ok, reason = mine_flow.retrieveLoader()
            if not ok then
                print("[MINER] WARNING: could not retrieve loader: " .. tostring(reason))
                base.sendProgress("loader_left_behind: " .. tostring(reason))
                -- Restore our own loading regardless so we can still get home.
                equipment.toTravelMode()
                geofence.clear()
            end
        else
            equipment.toTravelMode()
        end
        checkFuel(jobId)
        local p = base.getPos()
        base.setSkyReturn(true)
        base.move.to(p.x, SKY_Y, p.z)
        base.move.to(W.ARRIVALS_HOLE.x, SKY_Y, W.ARRIVALS_HOLE.z)
        base.returnToDockFromSky()
        base.setSkyReturn(false)
    end
```

Wrap each sector's work with the place/retrieve pair:

```lua
        -- Fly to the sector while self-loading, then hand chunk duty to the
        -- placed loader before removing our own.
        reportPhase(proto.PHASE.TRAVELLING, string.format("sector %d,%d", sx, sz))

        -- Stand at the middle of the sector's anchor chunk, not at the sector
        -- centre. Sector centres are multiples of 32 and so land exactly ON a
        -- chunk boundary: placing from there would drop the loader into
        -- whichever neighbouring chunk we happened to be facing, and the fence
        -- would then cover the wrong 3x3. From 8 blocks in, every facing keeps
        -- both miner and loader inside the anchor chunk.
        local acx, acz = geofence.chunkOf(sx, sz)
        base.move.to(sx + 8, travelY, sz + 8)

        local placed, placeErr =
            mine_flow.placeLoader(FENCE_CHUNK_RADIUS, { cx = acx, cz = acz })
        if not placed then
            print("[MINER] Cannot start sector: " .. tostring(placeErr))
            base.sendProgress("sector_setup_failed: " .. tostring(placeErr))
            soloReturn()
            return base.sendFailed("sector_setup_failed: " .. tostring(placeErr), true)
        end

        -- ... existing scan + mine loop, unchanged except that every
        -- base.move.to inside it may now return false with "geofence_breach" ...

        local got, retErr = mine_flow.retrieveLoader()
        if not got then
            print("[MINER] Cannot retrieve loader: " .. tostring(retErr))
            base.sendProgress("loader_retrieve_failed: " .. tostring(retErr))
            return base.sendFailed("loader_retrieve_failed: " .. tostring(retErr), false)
        end
```

Handle geofence refusals inside the ore loop — treat a fenced-out ore as unreachable rather than an error:

```lua
        local reached = navToOre(ore, jobId)
        if not reached then
            -- Includes geofence refusals: an ore outside the loader footprint is
            -- simply not minable this sector. Skipping it is correct; chasing it
            -- would strand the turtle.
            skipped = skipped + 1
        end
```

- [ ] **Step 6: Validate equipment at each phase boundary**

Immediately after `base.depart(...)` succeeds, and again before each `base.move.to` to a new sector:

```lua
    local eqOk, eqReason = equipment.validate("travel")
    if not eqOk then
        print("[MINER] Equipment check failed: " .. tostring(eqReason))
        base.sendProgress("equipment_invalid: " .. tostring(eqReason))
        return base.sendFailed("equipment_invalid: " .. tostring(eqReason), false)
    end
```

- [ ] **Step 7: Run the suite**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 8: Commit**

```bash
git add ore_turtle.lua mine_flow.lua tests/test_mine_flow.lua tests/run.lua
git commit -m "feat: solo miner place/swap/mine/retrieve cycle with fence and phase reporting"
```

---

### Task 9: Remove the mining branch from `support_turtle.lua`

**Files:**
- Modify: `support_turtle.lua`
- Test: `tests/test_delivery_support.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: a support turtle that serves DELIVER pairs only.

- [ ] **Step 1: Write the regression test first**

The point of this test is to prove delivery did not change. Create `tests/test_delivery_support.lua`:

```lua
-- Guards the constraint that delivery behaviour is untouched by the mining
-- rework. Asserts on the delivery-relevant protocol surface, which is what
-- support_turtle's delivery branch and delivery_turtle both depend on.
local proto = require("protocol")

return {
    ["delivery coordination messages still exist"] = function(assert_eq)
        for _, t in ipairs({ "HOLE_READY", "SUPPORT_STAGED", "POSITION_UPDATE",
                            "RETURN_TO_DOCK", "ASCENDING", "DESCENDED",
                            "JOB_ABORT" }) do
            assert_eq(proto.MSG[t], t, "delivery message " .. t .. " must remain")
        end
    end,

    ["SUPPORT_FOLLOW job type still exists"] = function(assert_eq)
        assert_eq(proto.JOB.SUPPORT_FOLLOW, "SUPPORT_FOLLOW")
    end,

    ["heartbeat stays backward compatible with 4 args"] = function(assert_eq)
        local p = proto.payloadHeartbeat("IDLE", 100, { x = 1, y = 2, z = 3 }, "job_1")
        assert_eq(p.status, "IDLE")
        assert_eq(p.jobId, "job_1")
        assert_eq(p.phase, nil, "phase must be nil for non-miners")
        assert_eq(p.chunk, nil)
    end,
}
```

- [ ] **Step 2: Run to verify it passes already**

Add `"tests.test_delivery_support"` to `tests/run.lua`, then run: `lua tests/run.lua`
Expected: 3 tests PASS — they encode a constraint that must hold before and after.

- [ ] **Step 3: Delete the mining branch**

In `support_turtle.lua`, remove the entire `if params.fuelManage then ... end` block — from the `local SUPPORT_FUEL_WARN = 800` line through the `return` that closes it, including `::mine_done::`. Leave everything after it untouched.

Replace it with a guard that fails loudly if a mining support job somehow still arrives:

```lua
    -- Mining no longer uses a support turtle: since v1.9.0 the miner carries its
    -- own chunk loader and places it at each sector. A SUPPORT_FOLLOW job with
    -- fuelManage set means a stale job survived the upgrade — fail it rather
    -- than fly out to shadow a miner that is not expecting a partner.
    if params.fuelManage then
        print("[SUPPORT] Stale mining-support job — mining is solo since v1.9.0")
        return base.sendFailed("mining_support_deprecated", false)
    end
```

Update the file header comment to say it serves delivery pairs only.

- [ ] **Step 4: Remove the now-dead coal helpers**

`fuel.dockFillCoal()` and `fuel.selfRefuel()` in `turtle_base.lua` existed only for the mining support. Confirm no remaining callers:

Run: `grep -rn "dockFillCoal\|selfRefuel" *.lua`
Expected: no hits outside `turtle_base.lua` itself. If clean, delete both functions and the `COAL_SLOTS`/`COAL_ITEM_NAMES` config.

- [ ] **Step 5: Run the suite**

Run: `lua tests/run.lua`
Expected: all pass

- [ ] **Step 6: Commit and push**

```lua
proto.VERSION = "1.9.2"
```

```bash
git add protocol.lua support_turtle.lua turtle_base.lua tests/test_delivery_support.lua tests/run.lua
git commit -m "refactor: remove mining support branch, keep delivery pair intact (v1.9.2)"
git push origin master
```

---

### Task 10: Dashboard — phase, chunk, and disconnect attribution

**Files:**
- Modify: the dashboard renderer that consumes the bridge `/state` feed

**Interfaces:**
- Consumes: `phase`, `phaseAt`, `commsGap`, `chunk` from `/state` (Task 7 Step 5).

- [ ] **Step 1: Locate the renderer**

The dashboard reads the bridge's `/state`. Find where it renders an existing per-turtle field:

Run: `grep -rln "fuel" --include=*.html --include=*.js --include=*.jsx --include=*.ts --include=*.tsx --include=*.lua .`

The file that renders `fuel` and `status` per turtle is the one to modify. Confirm it also reads `version`, which is the field `phase` sits beside in the JSON.

- [ ] **Step 2: Verify the new fields arrive**

With the server running:

```bash
curl -s http://localhost:8080/state | head -c 2000
```

Expected: each miner object contains `"phase"`, `"phaseAt"`, `"commsGap"`, and `"chunk"`. If `phase` is `null` for an active miner, Task 7 is incomplete — fix that before continuing.

- [ ] **Step 3: Render phase and chunk per node**

Add two columns to the fleet table: **Phase** and **Chunk**. Phase shows `phase` with the elapsed time since `phaseAt`; Chunk shows `cx,cz` or `—`.

- [ ] **Step 4: Attribute disconnects**

Offline turtles currently render identically whatever the cause. Distinguish them:

- `commsGap === true` and less than 60s since `phaseAt` → **"Swapping loader (expected)"**, neutral styling, not an alert
- `commsGap === true` and more than 60s → **"Stuck in loader swap"**, critical — the swap should take under a second, so this means it failed mid-dance and may need manual recovery
- offline with `phase` set and `commsGap` false → **"Lost during <phase>"**, critical
- offline with no phase → **"Offline"**, the existing treatment

This is the requirement that a dropped connection is attributable rather than ambiguous.

- [ ] **Step 5: Show the fence**

Where a miner's `chunk` is present, render the geofence anchor beside it so it is visible whether the miner is working inside its loaded footprint.

- [ ] **Step 6: Verify in the browser**

Load the dashboard with a miner mid-job. Confirm phase advances through `TRAVELLING → PLACING_LOADER → SWAP_TO_PICKAXE → SCANNING → MINING`, and that the chunk column matches the sector.

- [ ] **Step 7: Commit**

```bash
git add <dashboard files>
git commit -m "feat: dashboard shows miner phase, working chunk, and disconnect attribution"
```

---

### Task 11: End-to-end harness run

**Files:**
- Create: `tests/test_full_job.lua`

- [ ] **Step 1: Write the test**

Drive a full simulated job: depart → travel → place → swap → scan → mine → dump → retrieve → return. Assert at every step that either the miner's own chunky is equipped **or** a loader is standing inside the fence — the mechanised form of Invariant A.

```lua
["invariant A holds at every step of a full sector cycle"] = function(assert_eq)
    -- After each simulated step, exactly one of these must be true:
    --   own chunky equipped, or a placed loader within the armed fence.
    -- Anything else means the miner could freeze in the field.
    local function assertLoaded(eq, gf, world, label)
        local selfLoaded = eq.sideOf("chunky") ~= nil
        local loaderDown = false
        for k, v in pairs(world) do
            if v == eq.ITEMS.LOADER_TURTLE then
                local x, _, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
                if gf.contains(tonumber(x), tonumber(z)) then loaderDown = true end
            end
        end
        assert_eq(selfLoaded or loaderDown, true,
            "Invariant A breached at: " .. label)
    end
    -- ... drive the cycle, calling assertLoaded after each transition ...
end,
```

- [ ] **Step 2: Run and fix until green**

Run: `lua tests/run.lua`
Expected: all pass. Any Invariant A breach is a blocking defect — fix the flow, not the test.

- [ ] **Step 3: Commit**

```bash
git add tests/test_full_job.lua tests/run.lua
git commit -m "test: end-to-end solo mining cycle asserting chunk-safety invariant"
```

---

### Task 12: Staged deployment

- [ ] **Step 1: Confirm the suite is green**

Run: `lua tests/run.lua`
Expected: `0 failed`

- [ ] **Step 2: Ask the user before updating the fleet**

**Do not send `UPDATE_ALL` or `/self-update` without explicit approval.** Report what will change: mining turtles get new equipment handling and lose their support partners; delivery is unaffected; existing mine jobs should be allowed to finish or be cancelled first.

- [ ] **Step 3: Prepare one miner manually**

Before the fleet update, set up a single miner by hand: modem + chunky equipped, and slots 1/2/3/14/15/16 loaded per `equipment.SLOTS`. Confirm `equipment.validate("travel")` returns true from its Lua prompt.

- [ ] **Step 4: Single-pair trial**

Dispatch one mine job to that miner with a small radius. Watch the dashboard through a full sector: phase advances, chunk populates, the `RETRIEVING` gap shows as expected rather than as an alert.

- [ ] **Step 5: Verify a survey-phase job**

The survey phase regressed once already under untested changes. Run a survey-only job start to finish before trusting the build.

- [ ] **Step 6: Cancel-mid-job trial**

Cancel the job from the dashboard mid-sector. The miner must retrieve its loader, restore travel mode, and fly home solo. Confirm no loader is left standing in the world.

- [ ] **Step 6b: Crash-recovery trial**

Two failures to force deliberately, since they are the ones that lose hardware:

1. **Miner reboot mid-sector.** With a loader placed and the miner mining, reboot
   the miner (`os.reboot()` from its terminal). Expected: on boot it announces
   `Boot: loader recorded at x,y,z — recovering`, flies back, retrieves the
   loader, and only then accepts work. Confirm no loader is left standing.
2. **Server crash mid-sector.** Kill the server process while a miner is mining.
   Expected: the miner keeps working, then after 5 minutes reports
   `Server unreachable 5min — autonomous return`, retrieves its loader, and docks
   unaided. Restart the server and confirm it re-registers cleanly.

Both must pass before rollout — they are the two cases where a failure costs a
turtle and leaves a chunk force-loaded with no record of why.

- [ ] **Step 7: Fleet rollout**

Only after steps 4–6 pass, and only with the user's approval, `UPDATE_ALL`.

---

## Rollback

`4523d2c` is the working v1.8.0 state. To abandon this work:

```bash
git checkout 4523d2c -- protocol.lua turtle_base.lua ore_turtle.lua support_turtle.lua central_server.lua delivery_turtle.lua
git commit -m "Roll back to v1.8.0"
git push origin master
```

Then `UPDATE_ALL` with approval. Any loader turtles left standing in the world must be collected by hand.

---

## Notes carried in from the previous session

- **The survey regression in 1.8.1–1.8.7 was never explained.** Prime suspect is the `waitMsg` / shared-inbox rewrite in v1.8.1. This plan does not reintroduce that inbox. If survey misbehaves again on v1.9.x, that suspicion is wrong and the real cause is still out there.
- **Every failure in that session was pair coordination.** None was in scanning, sector assignment, ore mining, or delivery. This plan deletes the pair from mining and leaves those subsystems alone.
- **The reliability change is Task 2.** Every bug in that session was a message-routing or state-machine bug — exactly what a harness catches and code review does not.
