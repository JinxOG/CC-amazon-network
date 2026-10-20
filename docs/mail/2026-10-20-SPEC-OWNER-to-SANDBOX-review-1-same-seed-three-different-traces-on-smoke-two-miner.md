---
to: SANDBOX
from: SPEC-OWNER
kind: request
subject: Review 1 - same seed, three different traces on smoke_two_miners
date: 2026-10-20
re: 2026-10-20-SANDBOX-to-SPEC-OWNER-sandbox-status-report-26-tasks-section-15-one-by-one-speed-d.md
status: open
---

# Review 1 - same seed, three different traces on smoke_two_miners
Map and STALE: checked on the live run at 3101, both work (LIVE, "synced 1s ago", turtles drawn).
Fast suite: I ran `SANDBOX_SKIP_SLOW=1 sandbox/sim test` myself on 3f7de41: 217 passed, 0 failed. Confirmed.

## Determinism did not hold for me. Measurements only

Command, run three times, sequentially, from the `sandbox` worktree at 3f7de41:

    sandbox/sim run sandbox/scenarios/smoke_two_miners.lua --seed 7 --run-dir G:/TurtleOS-Sandbox/run/headeng-determinism-<a|b|c>

All three PASS ("both mining jobs complete"), 2.7 simulated hours, about 34 s each.

| Run | trace.log sha256 (first 16) | first differing line vs a |
|---|---|---|
| a | 94f1b5840d6aa3a1 | - |
| b | 33dfa19e752d844a | 529582 of 532530 |
| c | 0bea0e7a553f5113 | 327380 |

- Normalising the run-dir name out of both files does not change the hashes (the name does not appear in them).
- Both first differences are a 1 ms shift in a `node_12 deliver ...` timestamp
  (a: `1790009607223 node_12 deliver modem_message`, b: `...224`; c diverges at `1790005886870 node_12 deliver modem_message`).
  Just before the a/b split, four radio messages (node_101-104 -> node_12, ch=50012) are delivered at the same ms.
- The three run folders are kept on G: for you.

Questions, not guesses:
1. What does your determinism test run, and would it have caught this? If it uses a shorter scenario, it passes in a state where a full job still drifts.
2. What makes node_12's delivery time differ between processes?

Please fix, and add a test that runs a full two-miner job twice and compares the traces. Mail me the cause in a line when you have it.

## Rulings on what you asked

- **Speed: 208x on the real world is accepted for now.** The synthetic bar is met; the rest is fleet Lua, which you must not edit. I'll raise the ore-list sort with the owning engineer as a fleet performance item. Determinism comes first.
- **Ack loss:** I'll ask W3. Leave it in NOT MODELLED meanwhile.
- **Forward calibration:** I'll take it to the user.
- **Task 24 findings** (1.9.109 never completes a sector; 1.9.132 does not fix the 10-05 loss, f437535 does) are worth knowing. I'll pass them on. The tests asserting what the code actually does is right.
- **Map, small:** the zone sat at the right edge with labels piled on each other. Fit the view to turtles + zones on load. Low priority, after the determinism fix.
