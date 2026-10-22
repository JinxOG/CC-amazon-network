# GPS 3: recover position and facing after a crash (fuel journal and saved facing)

**Card:** GPS 3 (community-programs report, 2026-10-22). **Owner:** W3. **Status:** design, awaiting a ruling (section 6) before any code.

## 1. What the card asks

- **Before** each move, save the position, facing, fuel level and the intended move.
- Every move costs exactly 1 fuel. After a reboot, a fuel level 1 lower than the journal's means the move happened.
- Save the facing at every turn.
- **New rule:** a turtle with a recent good fix may navigate on the restored position for a bounded number of moves, enough to get home. When GPS returns, the two must agree, or it parks.

## 2. What the code does today (read 2026-10-22, turtle_base.lua)

- **Position:** `_self.pos` is set by `gpsSync` (`posFixed = true`) and updated by `applyMove(dir)` after each successful move. Nothing is saved to disk.
- **Facing:** `detectFacing` steps one block between two GPS fixes. It is not saved. `move.turnLeft/turnRight` update `_self.facing` after the turn.
- **The boot guard** (`tryMove`, release 2): no move until `posFixed and facingKnown`; `base.waitForPositionFix` retries GPS every 10 s and reports `stuck_no_fix` once a minute. Since 2026-10-05 this is what has stopped "flew off blind" losses, and it is the rule GPS 3 must loosen without breaking.
- **Moves that bypass `tryMove`:** about ten direct `turtle.forward/back/up/down` calls, each followed by `applyMove`:
  - `detectFacing`;
  - the turtle-blocked bypass (`bypassForward`, at lines ~1055-1175);
  - the facing dig-out;
  - sky-return helpers (around line 1272).
- **Turns that bypass `move.turn*`:** `detectFacing` and the bypass call `turtle.turnRight` directly.

## 3. Design

### 3.1 One choke point for every physical move and turn

Every `turtle.forward/back/up/down/turnLeft/turnRight` call in turtle_base, `tryMove` included, goes through two wrappers:

```lua
local function jMove(dir)   -- journal the intent, then move; applyMove on success, as today
local function jTurn(dir)   -- journal the intent, then turn; update facing on success
```

A source-pin test fails if any raw `turtle.(forward|back|up|down|turnLeft|turnRight)%(` appears outside the wrappers. That makes "a new call site bypasses the journal" a test failure, not a code-review hope.

**Checked 2026-10-22:** `turtle.(forward|back|up|down|turnLeft|turnRight)(` appears 17 times in turtle_base.lua and **0 times** in ore_turtle.lua, delivery_turtle.lua and support_turtle.lua. Every role moves through turtle_base, so the wrappers cover the whole fleet and no other engineer's file changes.

### 3.2 The journal (one small file, `journal.dat`, rewritten in place)

    { x, y, z, facing, facingKnown, fuel, posFixed, movesSinceFix, pending = "forward"|"up"|...|"turnRight"|nil, t }

**Writes:**
- before every move or turn: `pending` = the intent;
- after it succeeds: the new state, with `pending = nil`;
- after every refuel: the new fuel level;
- after every `gpsSync`: `posFixed`, with `movesSinceFix = 0`.

That is two small writes per move. A file write in CC is synchronous and fast. The cost will be **measured** at layer 2 before it ships, because miners make thousands of moves a job. If it costs too much, the "after" write can be dropped: it is redundant with the next "before" write, at the price of one more ambiguous case.

### 3.3 Restore at boot (before `initPosition` gives up)

- **No journal, or the journal says `posFixed = false`:** today's behaviour (wait for GPS).
- **`pending` is nil:** the position and facing are the journal's.
- **`pending` is a move:**
  - fuel = journal.fuel − 1: the move happened, so apply it;
  - fuel = journal.fuel: it did not;
  - fuel greater than journal.fuel (a refuel landed after the write, which only happens standing still): it did not;
  - anything else: unknown, so wait for GPS as today.
- **`pending` is a turn:** facing is **unknown** (turns cost no fuel, so there is nothing to tell). Position stays restored, facing is re-measured. Without GPS the turtle parks, as today; the card's "save facing before every turn" cannot settle a crash *mid*-turn, and guessing is the 10-06 node_182 loss.

The restored state is `posRestored = true`, **not** `posFixed`.

### 3.4 The new movement rule (the part that loosens the boot guard)

A turtle may move on a restored position only if all of these hold:

1. facing was restored, not unknown;
2. the journal's `movesSinceFix` is at most `RESTORE_MAX_DRIFT` (proposed 2,000);
3. it is heading home (`returnToDock*` or the miner's boot-recovery flight), not starting work;
4. it stops after `RESTORE_MOVE_BUDGET` moves (proposed 1.5 x the distance home, plus 64) without a fix;
5. it tries `gpsSync` every 32 moves. On the first fix, the fix and the restored position must agree within 1 block. Agreement: `posFixed = true`, carry on. Disagreement: park, `stuck_no_fix`-style report "restored position disagrees with GPS by N", and needs-hands.

Otherwise the boot guard is as today.

## 4. Tests (layer 0, unit; written first)

- A reboot after a journaled move intent:
  - fuel −1 restores the moved position;
  - fuel equal restores the old one;
  - fuel greater (refuel) restores the old one;
  - fuel −2 (impossible) gives no restore.
- A reboot with a pending turn: position restored, facing unknown, no move without GPS.
- `movesSinceFix` over the cap: no restore.
- Restored and heading home: moves without GPS. Starting a job on a restored position: refused.
- The budget is exhausted: parks and reports.
- GPS returns and agrees: carries on, `posFixed`. GPS returns and disagrees by 2: parks, needs hands, and **never moves again on the restored position**.
- Source pin: no raw `turtle.<move>(` outside `jMove` / `jTurn`.
- Fuel accounting with the fuel ender chest (the card's caution): one refuel between two moves still gives exactly −1 per move after it.

## 5. Layers 1 and 2

- **Simulator:** reboot a miner mid-flight at many points (`turtle_reboot` at random times), with GPS up, with `gps_down`, and both. Must never move on a wrong position (checked against the simulator's true position after every move). It must get home in the GPS-down case where today it parks.
- **Test server:** the t2control M4 shutdown-mid-move, with `gps_down`, plus the journal-write cost (move rate with and without the journal).

## 6. Questions before coding (for SPEC-OWNER)

1. **Loosening the boot guard (3.4)** is the riskiest change since the guard went in on 10-06. Is "home-bound only, capped budget, park on disagreement" the right scope? Or should GPS 3 first ship only the restore (3.3) and keep today's "no move without GPS", which is safe and still saves the facing-detection step when GPS is up?
2. **Turns:** agreed that a crash mid-turn leaves facing unknown (3.3)? The card's wording, "save facing before every turn", can't by itself tell whether the turn happened.
3. ~~ore_turtle.lua's own direct moves~~: none (17 raw calls, all in turtle_base). W1 is not needed.

## 7. Rulings (SPEC-OWNER, 2026-10-22) and the Release A build

**Ruled:**
- **Two releases.** A = journal + restore, with "no move without GPS" **unchanged**. B (the bounded blind homing of 3.4) comes only after A is live-validated and B passes T1 and T2 under every fault that can be staged, with "any failed or blocked move without GPS = park at once". B's go-ahead is the user's call.
- **Turns:** a crash mid-turn leaves facing unknown. No guessing.
- **Source pin across every fleet file**, not only turtle_base.
- **Atomic journal write** (temp file + fs.move). An unreadable journal counts as no journal.
- **Job-time cost ≤ 2%** at T2 1x.
- A VALIDATION block on the card.

### 7.1 What Release A changes for a turtle

Only one thing: after a reboot, **if GPS agrees with the journal, the turtle takes its facing from the journal instead of stepping out and back to measure it.** Every other rule, the boot guard included, is as today. A turtle with no GPS still waits, exactly as now.

### 7.2 Code (all in turtle_base.lua; a new module cannot ship in its own first OTA)

- **`jMove(dir)` / `jTurn(dir)`** are the only places that call `turtle.forward/back/up/down/turnLeft/turnRight`.
  - Each journals the intent, then makes the raw call (`turtle[dir]()`).
  - On a failure it settles the journal (`pending = nil`).
- **`applyMove`** and **`move.turnLeft/turnRight`** write the settled state after they update `_self`.
- **The other call sites:**
  - `tryMove` loses its `moveFn` argument and calls `jMove(dir)`.
  - The ~15 raw sites in detectFacing, the dig-out, the bypasses and the sidestep call `jMove`/`jTurn`. Their own `applyMove` calls stay where they are.
- **`detectFacing`** sets `_self.facingKnown = false` before its first step. While it turns around to measure, the facing really is unknown, so a crash in the middle leaves a journal that restores nothing.
- **The journal record:** `{ v=1, x, y, z, facing, facingKnown, posFixed, fuel, pending, t }`.
  - It is written to `journal.tmp`, then `journal.dat` is deleted and `journal.tmp` moved onto it.
  - **Read:** `journal.dat`. If it is missing, use `journal.tmp`: a crash between the delete and the move leaves a complete temp file. If it is present, `.dat` wins: a crash *during* the temp write leaves a partial temp file and a `.dat` that is still exact, because the move had not started.
  - Anything that does not unserialise to a well-formed record means no journal.
  - Every journal call is in a pcall. A journal fault never stops a move; it logs once.
- **Restore** (`restoreFacingFromJournal(fix)`): called right after a successful `gpsSync` at boot (initPosition) and in waitForPositionFix, where `detectFacing` would run.
  - It needs a journal with `posFixed` and `facingKnown`, and `pending` nil or a move. A pending turn means no restore.
  - **Pending move:**
    - fuel = journal − 1: the move happened;
    - fuel ≥ journal: it did not;
    - anything else, `"unlimited"` included: no restore.
  - The resulting position must **equal** the GPS fix for the facing to be restored. Otherwise `detectFacing` runs as today, which is the safe fallback. Every boot with a journal and a fix logs one line, which is the evidence for the VALIDATION block:
    - `Journal: restored facing east at x,y,z (agrees with GPS)`;
    - `Journal: 1 block from GPS (...) -- measuring facing`;
    - the loud case the ruling asks for, a disagreement of **more than 1 block**: `JOURNAL DISAGREES WITH GPS by N (...)`. The VALIDATION block's *Failed if* is any line of this kind.
- **First-step check (added; not in the card).** A restored facing is provisional until the turtle's first horizontal move, which then takes one `gps.locate`.
  - The fix agrees: the facing is confirmed.
  - The fix disagrees: the real facing is taken from that one-block step, the position is corrected to GPS, and a loud warning `RESTORED FACING WAS WRONG` is logged.
  - No fix: `facingKnown = false`, so the boot guard holds the next move.
  - **Why:** the journal cannot tell a crash-reboot from the user picking a turtle up and putting it back **in the same block, turned**. The position agrees, the facing does not, and that is node_182's 10-06 loss. The check costs one GPS call per reboot, and the worst case is one block in the wrong direction (detectFacing itself steps a block).

### 7.3 Tests, written first (layer 0)

**Journal file:**
- a round trip;
- a partial temp file with `.dat` present uses `.dat`;
- `.dat` missing with a complete temp file uses the temp file;
- garbage, a wrong type or a missing field: no journal;
- a write that raises does not stop the move.

**Restore (`initPosition` with a journal on disk and a GPS stub):**
- pending nil and agrees: facing restored, **no forward/back step** (the facing detection is skipped);
- disagrees by 1: detectFacing runs;
- pending forward with fuel −1: the moved position;
- fuel equal: the old position;
- fuel +N (refuel): the old position;
- fuel −2: no restore;
- fuel "unlimited": no restore;
- a pending turn: no restore and detectFacing runs;
- `facingKnown = false` or `posFixed = false` in the journal: no restore;
- no GPS: no restore, the boot guard waits as today (unchanged; the existing boot-guard tests still pass untouched).

**First step:**
- agrees: confirmed and no further locate;
- disagrees: facing corrected from the delta, position set to GPS, warning logged;
- no fix: facingKnown false, so the next tryMove waits.

**Writes:**
- an intent is on disk **before** the raw call (the stub raw move asserts it);
- after success the record has `pending = nil` and the new position or facing;
- a failed move settles to `pending = nil` and the old position;
- detectFacing writes `facingKnown = false` before its first step.

**Source pin across every fleet file:**
- every `*.lua` in the repo root, except central_server.lua and the tests;
- no `turtle.(forward|back|up|down|turnLeft|turnRight)` and no `turtle[` outside the bodies of `jMove`/`jTurn`;
- it carries its own self-test: the pin must find a planted raw call in a string.

**Mutants for tests/mutate_logship.py:**
- the restore skips the GPS comparison;
- the fuel rule is inverted;
- a pending turn restores;
- the first-step check is skipped;
- `.tmp` is preferred over `.dat`;
- the intent is written after the move;
- detectFacing does not clear facingKnown.

### 7.4 Layers 1 and 2

- **Simulator** (scenario `w3_gps3_journal_restore`):
  - a miner and a delivery turtle are rebooted at random points mid-job, with GPS up. After each reboot:
    - the journal line agrees;
    - no facing-detection step;
    - the simulator's true position equals the turtle's after every later move.
  - One turtle is also teleported into the same block, rotated, then rebooted: `RESTORED FACING WAS WRONG` is logged, it corrects, and it never takes a second wrong step.
  - The old code (1.9.151) is the control: it measures facing on every reboot.
- **Test server:**
  - shutdown mid-move (M4) with GPS up: restore lines appear and nothing is lost;
  - the cost, as ruled: the three-sector job at 1x, with and without the journal. Job time may grow by **at most 2%**. If it grows more, drop the "after" write for moves and measure again.
- **Live** (the watcher, after the deploy): reboots during normal work give `Journal: restored` lines and no `RESTORED FACING WAS WRONG`. Any disagreement line is read before the card moves.

## 8. Revised after layer 1 (2026-10-22): the journal is CHECKED, never trusted for facing

**This section supersedes 7.1, the restore in 7.2, and 7.3's restore and first-step tests.** The decision is with the spec owner (mail `2026-10-22-W3-to-SPEC-OWNER-gps-3-release-a-the-sandbox-says-never-trust...`).

### Why

Scenario `w3_gps3_journal_restore`, run on 4f557e7 (restore plus the first-step check):
- **Random reboots:** all 5 restored and agreed.
- **A field put-back, same block, turned:** the miner took the journal's facing.
  1. Boot recovery then turned it to "face" its loader. It logged `loader_not_in_front` and left the loader behind.
  2. It then climbed to y=200 with its modem swapped out for the chunk loader.
  3. The first-step check had no GPS, so it parked for good.

There are two lessons:
- **Facing is used before any move.** Facing a loader, and placing or digging in a direction, all depend on it.
- **A miner's first step often has no GPS.** In travel mode the modem is swapped out for the chunk loader.

A journal cannot tell a crash from a hand put-back.

### What Release A is now

- The journal, the wrappers, the atomic write and the source pin are unchanged.
- **At boot:**
  1. `journalClaim()` reads the journal **before anything moves or burns fuel**. A pending move is settled by fuel; a pending turn keeps the position and drops the facing.
  2. GPS fix.
  3. `detectFacing()`, exactly as today.
  4. `checkJournal()` logs one line: `Journal: agrees with GPS ...`, `Journal: 1 block from GPS`, `JOURNAL DISAGREES WITH GPS by N` (more than 1 block), `JOURNAL FACING DIFFERS: journal X, measured Y`, or `Journal: nothing to check (why)`.
- With no GPS at boot there is no check, and the boot guard waits as before.
- **The turtle never uses the journal's position or facing.**

### For Release B

The put-back case means a journal's facing cannot be trusted after a reboot without a measurement. B, as it was shaped, would fly a turned turtle its whole budget the wrong way. That needs a new answer before B is designed further.
