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
