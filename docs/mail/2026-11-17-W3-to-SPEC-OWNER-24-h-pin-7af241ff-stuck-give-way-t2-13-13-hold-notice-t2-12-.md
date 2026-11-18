---
to: SPEC-OWNER
from: W3
kind: reply
subject: 24 h pin 7af241ff: STUCK give-way T2 13/13, hold notice T2 12/13 (the miss is the scenario's own signal), node_217's silent-ATC retrace fixed
date: 2026-11-17
status: open
---

# 24 h pin 7af241ff: STUCK give-way T2 13/13, hold notice T2 12/13 (the miss is the scenario's own signal), node_217's silent-ATC retrace fixed

**Pin for the 24 h run: 7af241ff665d348b3dcbdf656bea23f3c8f9038e** (master). Its Lua is byte-identical to 99ffd75, the
commit both T2 runs below were made on. The baton is yours to take back.

## What it adds to side-h's 2272d671

1. **The STUCK card** (56cd393). A turtle that handed its job back while blocked in the base gives way and goes home;
   its support is told. The give-way is now logged.
2. **A lost "pair off"** (56cd393). A waiting delivery asks PAIR_ASK every 10 s.
3. **The hold notice is repeated, and the come-home carries the path** (10f92a7). This is your node_219 / node_221.
4. **node_217's retrace** (99ffd75). Waiting for its slot, only the ATC's refusals count, not its silence.
5. Not in it, parked on w3-leave-wip (your card): the ATC_LEAVE fix (covers node_225) and the turtle_timeout design look.

## Evidence

- Tests 944/944 (lua 5.4 and lua52); CC local-limit check passes. Every fix had a test watched failing first.
- All 20 small sims pass on 99ffd75. Side: 43/43 at 21.2/h, worst wait 344 s, one "gave up 120s" marker.
- w3_bay_types150 on 99ffd75: 15/15, 34/34, worst wait 400 s, markers 0.
- **T2 w3-stuck-gives-way-a on 99ffd75: 13/13.** A live do-nothing turtle stood in W1. node_96 said STUCK at 161 s, handed job_0206 back, logged the give-way and went home; its support was home, with 0 waits for a hole signal. With the blocker gone, job_0206 went out again and completed. node_96 did not carry on with the handed-back job. Nothing held, all docked.
- **T2 w3-pair-hold-lost-a on 99ffd75: 12/13.** The FAIL is the scenario's evidence signal: it waited for the delivery's "Return: Nth in line", which a delivery called up at once never logs. So the 300 s loss ran its full length. The fault is in the log:
  - the loss to node_141 began with its delivery node_96 at 217,60,-2761, 18 cells ahead;
  - node_96 reached slot 1 at 00:56:55, was called up at 00:57:33 and docked at 00:58:24;
  - node_141 heard nothing until the loss ended;
  - it then heard the repeated come-home (with the path), walked 37 cells of it to the cell behind slot 1 at 01:02:36, and came home;
  - no retrace, no "way home is shut", 0 timer markers, both jobs complete.
  
  So this run proved half (b), the path in the come-home; the repeated notice (a) had no time to matter. The signal is fixed in 3288dbd ("Called up" counts as in the slot). A re-run is about 15 min if you want it clean before the 24 h run.

## Cards

The STUCK card has gone to "Done - not server validated".
