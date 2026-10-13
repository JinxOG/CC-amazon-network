# Recovery Layer, Release 2: Placed-Item Ledger, Fuel Chest, Boot Guard

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a reboot, no turtle of any role moves on a guessed position, and a fuel ender chest left in the world by a reboot mid-refuel is recovered automatically, through a generic placed-item ledger that later releases extend to the ore chest and builder placements.

**Architecture:** Everything lives in `turtle_base.lua`, the code every role runs, and in `central_server.lua`. Both files are W3's. The ledger is a table on `base` (`base.ledger`) and not a new module, because a new module and its first `require` can't ship in one OTA (see memory: OTA Predates the Module). Storage is W1's `chest_state.lua` logic generalised to one file per kind. Recovery is a single generic routine driven by two fields per kind. The boot guard is lazy: it sits at the top of `tryMove`, so a turtle only waits for GPS and facing when it actually tries to move. Heartbeats keep running while it waits.

**Tech Stack:** Lua 5.x on CC:Tweaked. Tests use `lua tests/run.lua` with `tests/stub_cc.lua`. Mutation checks use `python tests/mutate_logship.py`.

**Spec:**
- Ruling: `docs/mail/2026-10-08-SPEC-OWNER-to-W3-W1-one-recovery-layer-approved-w3-builds-it-the-fuel-chest-is-e.md`
- Contract: `docs/mail/2026-10-12-W3-to-W1-SPEC-OWNER-the-placed-item-ledger-contract-build-the-ore-chest-recovery.md`
- W1's requirements: `git show a8a1516:docs/mail/2026-10-08-W1-to-W3-SPEC-OWNER-stopped-before-building-it-twice-what-the-generic-ledger-nee.md`

## Global Constraints

- Lua's limit is 200 locals per function. New state goes in fields (`base.*`, `_self.*`, `fuel.*`, `registry.*`), never new file-level `local`s, unless one table holds many.
- No new module file in this release. Its first `require` cannot ship in the same OTA.
- Touch only `turtle_base.lua`, `central_server.lua`, tests and the mutation harness. **`ore_turtle.lua` (W1's) and `delivery_turtle.lua`/`support_turtle.lua` (frozen; their hooks are release 4) are not edited.**
- Record before place. Roll back a clean `place()` failure. Clear only once the item is confirmed in its home slot. A failed recovery **keeps** the record and raises NEEDS HANDS with coordinates. Never drop items to make room.
- The loader stays in `loader_state`, outside the ledger.
- Every behaviour change gets a test that fails first, and mutants that `tests/mutate_logship.py` kills. Run the full mutation suite before release. Never edit sources while it runs.
- Deploy only with the fleet idle. Pin to the commit: `UPDATE_ALL {"ref": "<sha>"}`.

## Review Focus

1. **A reboot mid-refuel at the dock.** The turtle never left. Recovery must dig back only the recorded block, after an identity check, and never anything else near the depot. *Pinned in Task 3: "a fuel chest stranded at the dock is recovered and nothing else is dug".*
2. **Two kinds out at once.** A dump can start while the fuel chest is down, so the ledger must keep both records independently. *Pinned in Task 1: "two kinds out at once are kept separately".*
3. **A corrupt or truncated ledger file.** It must read as "no record" and boot normally, with a log line, never a crash. *Pinned in Task 1.*
4. **Facing can't be measured at recovery** (boxed in, no pickaxe). The turtle must not dig on a guess: it waits in `waitForPositionFix`, which already reports itself stuck. *Pinned in Task 2: "forward recovery waits for a measured facing".*
5. **The turtle isn't standing where it placed the item.** No dig; the record is kept; NEEDS HANDS names the item's block. *Pinned in Task 2.*

---

### Task 1: Ledger storage in turtle_base

**Files:**
- Modify: `turtle_base.lua`, adding a `base.ledger` table after the `fuel` table's definitions (near `fuel.returnLeftover`)
- Test: `tests/test_ledger.lua` (new)

**Interfaces:**
- Produces:
  - `base.ledger.record(kind, entry) -> true | false, reason`. `entry` = `{x,y,z, face, facing, turtleAt={x,y,z}}`; `placedAt` is added.
  - `base.ledger.rollback(kind)`
  - `base.ledger.clear(kind)`
  - `base.ledger.get(kind) -> entry|nil`
  - `base.ledger.all() -> { [kind]=entry }`
  - File per kind: `ledger_<kind>.dat`

- [ ] **Step 1: Write the failing tests**

```lua
-- tests/test_ledger.lua
package.path = "./?.lua;" .. package.path
local stub = require("tests.stub_cc")
os.epoch = os.epoch or function() return os.time() * 1000 end

local function fresh()
    stub.install({})
    gps = { locate = function() return 0, 64, 0 end }
    for _, m in ipairs({ "turtle_base", "logship", "geofence" }) do package.loaded[m] = nil end
    return require("turtle_base")
end
local E = { x = 10, y = 63, z = 0, face = "down", turtleAt = { x = 10, y = 64, z = 0 } }

return {
    ["nothing recorded on a clean start"] = function(assert_eq)
        local base = fresh()
        assert_eq(base.ledger.get("fuel_chest"), nil)
        assert_eq(next(base.ledger.all()), nil)
    end,
    ["a record survives a reboot"] = function(assert_eq)
        local base = fresh()
        assert_eq(base.ledger.record("fuel_chest", E), true)
        for _, m in ipairs({ "turtle_base", "logship", "geofence" }) do package.loaded[m] = nil end
        local base2 = require("turtle_base")
        local r = base2.ledger.get("fuel_chest")
        assert_eq(r and r.x, 10); assert_eq(r and r.face, "down")
        assert_eq(r and r.turtleAt.y, 64)
    end,
    ["two kinds out at once are kept separately"] = function(assert_eq)
        local base = fresh()
        base.ledger.record("fuel_chest", E)
        base.ledger.record("ore_chest", { x = 11, y = 64, z = 0, face = "forward", facing = 1,
                                          turtleAt = { x = 10, y = 64, z = 0 } })
        base.ledger.clear("fuel_chest")
        assert_eq(base.ledger.get("fuel_chest"), nil)
        assert_eq(base.ledger.get("ore_chest").x, 11, "clearing one never touches the other")
    end,
    ["a rollback leaves no record"] = function(assert_eq)
        local base = fresh()
        base.ledger.record("fuel_chest", E)
        base.ledger.rollback("fuel_chest")
        assert_eq(base.ledger.get("fuel_chest"), nil)
    end,
    ["an unwritable disk is reported, never assumed"] = function(assert_eq)
        local base = fresh()
        local open = fs.open
        fs.open = function(p, m) if m == "w" then return nil end return open(p, m) end
        local ok, why = base.ledger.record("fuel_chest", E)
        fs.open = open
        assert_eq(ok, false); assert_eq(why, "ledger_write_failed")
        assert_eq(base.ledger.get("fuel_chest"), nil, "no claim in memory either")
    end,
    ["a truncated file reads as no record and boots"] = function(assert_eq)
        local base = fresh()
        local f = fs.open("ledger_fuel_chest.dat", "w"); f.write("{ x = 10, y ="); f.close()
        for _, m in ipairs({ "turtle_base", "logship", "geofence" }) do package.loaded[m] = nil end
        local base2 = require("turtle_base")
        assert_eq(base2.ledger.get("fuel_chest"), nil)
    end,
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `lua tests/run.lua 2>&1 | grep -E "^FAIL|passed"`
Expected: the six new tests FAIL (`base.ledger` is nil).

- [ ] **Step 3: Implement**

```lua
-- In turtle_base.lua, after fuel.returnLeftover.
-- PLACED-ITEM LEDGER (2026-10-12, recovery layer release 2). Whatever a turtle
-- places in the world and means to take back is recorded here first ...
base.ledger = { _cache = {}, _loaded = {} }
local function ledgerPath(kind) return "ledger_" .. kind .. ".dat" end
```

`ledgerPath` adds one file-level local; if the 200-local limit is close, make it `base.ledger.path`. The functions:
- `record`: build the record with `placedAt`; `fs.open(path, "w")`; nil → `return false, "ledger_write_failed"`, cache untouched; write `textutils.serialise`; set the cache.
- `rollback` and `clear`: drop the cache and delete the file. `rollback` also logs.
- `get`: lazy load, using `pcall(textutils.unserialise)`, and requiring `x ~= nil`. If invalid, return nil and `logWarn("Ledger file for <kind> unreadable -- treated as no record")`.
- `all`: `fs.list("")` filtered by `^ledger_(.+)%.dat$`, plus the cache.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `lua tests/run.lua 2>&1 | grep -E "^FAIL|passed"`. Expected: 0 failed.

- [ ] **Step 5: Add mutants and commit**

Add these to `tests/mutate_logship.py`:
- record ignores a nil handle;
- clear removes every kind;
- rollback keeps the file;
- a truncated read raises.

Each must be KILLED. Commit `feat: a placed-item ledger in turtle_base, one record per kind`.

---

### Task 2: Kinds and the generic recovery

**Files:**
- Modify: `turtle_base.lua`, after `base.ledger`
- Test: `tests/test_ledger.lua`

**Interfaces:**
- Consumes: Task 1's `base.ledger.*`; existing `digGuarded(dir)`, `_digToolWrapper`, `base.makeRoomBeforeDig()`, `base.waitForPositionFix(why)`, `move.turnRight()`, `base.sendProgress(detail)`.
- Produces:
  - `base.ledger.registerKind(kind, { blockName = string, homeSlot = number|function })`
  - `base.ledger.recover(kind) -> true | false, reason`
  - `base.ledger.recoverAll() -> number recovered`
  - On failure, sends progress detail `"needs_hands: <kind> at x,y,z -- <reason>"` and keeps the record.

- [ ] **Step 1: Write the failing tests** (in `tests/test_ledger.lua`). The world has the chest at the recorded block and the turtle standing at `turtleAt`.

Test names, each with arrange, act and assert in full:
1. `"a chest below is dug back into its home slot and the record cleared"`: kind registered with `blockName = "enderstorage:ender_chest", homeSlot = 16`; world has the chest at `(10,63,0)`; pickaxe equipped. Expect `recover` → true; `c.inv[16].name` is the chest; `ledger.get` is nil; the block is gone.
2. `"a chest in front is dug after turning to the recorded facing"`: record `face="forward", facing=1`, turtle facing 3. Expect a turn to facing 1, then dig `(11,64,0)`.
3. `"a different block where the chest was is never dug"`: the world has `minecraft:stone` at the spot. Expect false, the stone still there, the record kept, and a progress detail beginning `needs_hands: fuel_chest at 10,63,0`.
4. `"a turtle not where it stood is not trusted"`: GPS says `(12,64,0)`. Expect false, nothing dug, the record kept, needs_hands.
5. `"a full pack is never emptied onto the ground"`: all 16 slots full, no dig-room hook. Expect false, the record kept, nothing dropped (count the items), needs_hands.
6. `"a stowed pickaxe is borrowed"`: no pickaxe equipped; a wrapper is installed that swaps one in (as in `test_shaft_sidestep`'s stowed test). Expect true.
7. `"forward recovery waits for a measured facing"`: `facingKnown` false, boxed in, canDig false. Stub `sleep` to unbox after 2 naps. Expect `recover` to have called `waitForPositionFix` (a stuck report was sent) before digging, and no dig before the facing was known.

- [ ] **Step 2: Run them; expect FAIL** (`registerKind` is nil).

- [ ] **Step 3: Implement `registerKind`, `recover`, `recoverAll`** following the contract's rule 5, in order:
  1. `waitForPositionFix`
  2. position equals `turtleAt`
  3. aim (up and down directly; forward via `move.turnRight` until `_self.facing == entry.facing`)
  4. identity via `INSPECT[dir]`
  5. a free slot, else `makeRoomBeforeDig`, else fail
  6. dig via `digGuarded`, inside `_digToolWrapper` when present
  7. find `blockName` aboard, `transferTo(home, 1)` if needed
  8. `clear`

  Every failure goes through `needsHands(kind, entry, reason)`, which sends the progress detail and logs once.

- [ ] **Step 4: Run; expect 0 failed.**

- [ ] **Step 5: Add mutants and commit**

Mutants:
- skip the identity check;
- skip the position check;
- clear on failure;
- drop items for room;
- dig without the wrapper;
- no turn to facing.

All KILLED. Commit `feat: generic ledger recovery - identity, position, room, borrowed pickaxe`.

---

### Task 3: The fuel chest is entry one

**Files:**
- Modify: `turtle_base.lua`, `fuel.refuelFromChest` (around line 2013)
- Test: `tests/test_dock_refuel.lua` (harness `refuelAtDock`) and `tests/test_ledger.lua`

**Interfaces:**
- Consumes: Tasks 1 and 2; existing `findFreeSpace()` returning `placeFn, digFn, suckFn`; `CHEST_SLOT`; `CHEST_ITEM`.
- Produces:
  - kind `"fuel_chest"`, registered in `base.init` once `CHEST_SLOT` is final (`homeSlot = function() return CHEST_SLOT end`);
  - `fuel.blockFor(placeFn) -> face, x, y, z`.

- [ ] **Step 1: Failing tests**
1. `"a refuel records the fuel chest before placing it"`: wrap `turtle.placeUp` to snapshot `base.ledger.get("fuel_chest")` at the moment of placement. Expect a record with the block above.
2. `"a placement that fails leaves no record"`: make the place function return false. Expect no record, and the refuel returns false.
3. `"a finished refuel leaves no record"`: the normal path. Expect nil afterwards.
4. `"a reboot mid-refuel leaves the record for boot"`: make the dig function return false (the chest stays). Expect the record kept.
5. `"a fuel chest stranded at the dock is recovered and nothing else is dug"`: dock world with the station chest below, the fuel chest above, recorded. Expect `recoverAll() == 1`, the chest in `CHEST_SLOT`, and the station chest still there.

- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.** In `refuelFromChest`, before `placeFn()`:
  - `fuel.blockFor(placeFn)` resolves the face and block (`placeDown` → y−1; `placeUp` → y+1; `place` → `projectStep`-style using `_self.facing`);
  - `local ok, why = base.ledger.record("fuel_chest", {...})`; on false, `logWarn` and `return false`;
  - if `placeFn()` fails → `base.ledger.rollback("fuel_chest")`;
  - after the chest is back in `CHEST_SLOT` (`chestAt(CHEST_SLOT)`) → `base.ledger.clear("fuel_chest")`.
- [ ] **Step 4: Run; expect 0 failed.** `test_field_refuel` and `test_dock_refuel` must stay green.
- [ ] **Step 5: Add mutants and commit**

Mutants:
- no record before place;
- no rollback;
- clear before the chest is aboard;
- never clear.

KILLED. Commit `feat: the fuel chest is the ledger's first entry`.

---

### Task 4: Recovery runs at boot, for every role

**Files:**
- Modify: `turtle_base.lua`, top of `base.run` (line ~3022)
- Test: `tests/test_ledger.lua`

**Interfaces:**
- Consumes: Task 2's `recoverAll`.
- Produces: `base.recoverLedger()` (idempotent; a no-op when the ledger is empty), called once at the top of `base.run`. Exported so that W1 can call it from ore_turtle **before** `recoverPlacedLoader`. That line is W1's to add, in release 1 or right after; mail W1.

- [ ] Step 1: Failing test `"base.run recovers the ledger before its first job"`. Use the `test_control_loop` pattern: a record exists; stub the job handler; drive one loop iteration. Expect the record cleared before the handler is called.
- [ ] Step 2: FAIL. Step 3: `pcall(base.recoverLedger)` at the top of `base.run`, logging any error. Step 4: PASS.
- [ ] Step 5: Mutant (the call removed) KILLED. Commit `feat: every role recovers its ledger at boot`.

---

### Task 5: The boot guard for every role

**Files:**
- Modify: `turtle_base.lua`: `base.init` sets `_self.bootGuard = true` before `initPosition()`; the top of `tryMove` (line ~1276) waits when `_self.bootGuard and not (_self.posFixed and _self.facingKnown)`.
- Test: `tests/test_shaft_sidestep.lua`

**Interfaces:**
- Consumes: existing `base.waitForPositionFix`, `_self.posFixed`, `_self.facingKnown`.
- Produces: `base.setBootGuardForTest(on)`, so tests can arm it without a full `init`.

- [ ] Step 1: Failing tests:
  - `"a booted turtle with no GPS fix does not move"`: guard armed; GPS returns nil for 3 calls, then a fix. Expect `move.forward()` to wait (stuck reports sent) and the turtle to move only after the fix, to the right place.
  - `"a turtle with a measured fix moves at once"`: no extra GPS calls.
  - `"the guard is off until init arms it"`: tests that never call init keep today's behaviour.
- [ ] Step 2: FAIL. Step 3: implement (two lines plus the comment). Step 4: PASS. The full suite must stay green; any test that moves after init with no fix must give it one.
- [ ] Step 5: Mutants (guard removed; guard ignores facing) KILLED. Commit `feat: no turtle of any role moves after boot until it knows where it is`.

---

### Task 6: The server shows a ledger failure

**Files:**
- Modify: `central_server.lua`, `handlers[STATUS_UPDATE]` and a new `registry.flagNeedsHands`
- Test: `tests/test_zone_phase.lua`

- [ ] Step 1: Failing test `"a needs_hands report is shown once, with where"`. Three identical STATUS_UPDATEs with detail `needs_hands: fuel_chest at 10,63,0 -- not_the_item`. Expect `registry[A].needsHands` = the detail, exactly one `NEEDS HANDS:` log line, and the turtle **not** held (a ledger failure at the dock leaves it dispatchable unless its hardware check fails).
- [ ] Step 2: FAIL. Step 3: implement (the `^needs_hands` prefix → `registry.flagNeedsHands(id, detail)`; set, log once). Step 4: PASS.
- [ ] Step 5: Mutants (ignored; logged every time) KILLED. Commit `feat: a ledger failure raises NEEDS HANDS with the item's block`.

---

### Task 7: Release 1.9.141 and the standing restart test

- [ ] **Step 1:** full suite, then the full mutation run. Fix MALFORMED anchors: every mutant KILLED, 0 SURVIVED.
- [ ] **Step 2:** bump `proto.VERSION` to the next free number (master is 1.9.140; W1's release 1 may take 1.9.141, so check first). Commit, push, and verify raw file bytes at the SHA.
- [ ] **Step 3:** mail W1 asking them to add `base.recoverLedger()` before `recoverPlacedLoader` in ore_turtle. Mail the spec owner the release note.
- [ ] **Step 4:** deploy pinned, **fleet idle only**. Confirm all 19 on the new version.
- [ ] **Step 5:** the standing double-reboot test, for every role, with the user and operator. Arm `restart_watch.py` and record per role:
  - position and facing measured before the first move;
  - any `needs_hands` raised;
  - any ledger recovered.

  Board card moves to Needs measuring, with the evidence.
