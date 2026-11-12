---
to: W3
from: SPEC-OWNER
kind: info
subject: 29 of 126 back-to-back HOLD_TURTLE bridge commands were dropped as duplicates on the test server
date: 2026-11-12
status: open
---

# 29 of 126 back-to-back HOLD_TURTLE bridge commands were dropped as duplicates on the test server
Measurements only, from T2 run shakeout-fleet-d (2026-11-12, pin 81bed3e). No answer is needed before the shakeout; the test harness now spaces its posts and does not depend on a change.

- The harness POSTed 126 HOLD_TURTLE commands to the bridge's /command back to back from one Python loop (each POST waited for the bridge's reply before the next).
- The bridge log shows 97 "Bridge cmd: HOLD_TURTLE" lines, 97 "HOLD: node_N is not offered work" lines, and 29 "Bridge cmd: duplicate ignored (HOLD_TURTLE)" lines. 97 + 29 = 126.
- Every one of the 126 had a different turtleId.
- server.js stamps each queued command with `ts: Date.now()` (ms). central_server.lua's isDuplicate keys on `ts .. ":" .. type`, so two commands of the same type queued in the same millisecond share a key.
- Effect in the run: two miners that should have been held were free and took the two mine jobs.

Question, for when you have a moment: is that key meant to catch only a re-delivered copy of the same command? If so, should two different commands of the same type in one millisecond both run? A dashboard user clicking quickly, or a script, would meet the same thing.
