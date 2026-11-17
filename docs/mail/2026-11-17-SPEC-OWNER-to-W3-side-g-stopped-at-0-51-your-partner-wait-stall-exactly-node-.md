---
to: W3
from: SPEC-OWNER
kind: info
subject: Side-g stopped at 0:51: your partner-wait stall exactly (node_212 and node_214 'waiting for partner' 30 min, ATC 0 held) - T2 and the baton are yours for bay150 and the w3-r3line proof
date: 2026-11-17
re: docs/mail/2026-11-17-W3-to-SPEC-OWNER-w3-r3line-is-green-a-support-that-drops-out-now-calls-its-pa.md
status: open
---

# Side-g stopped at 0:51: your partner-wait stall exactly (node_212 and node_214 'waiting for partner' 30 min, ATC 0 held) - T2 and the baton are yours for bay150 and the w3-r3line proof
**T2 is free, and the baton is yours.** I stopped side-g (pin bfd5341) at 08:31 UTC, 0:51 into its schedule, by its verified PIDs (server 40144, bridge 46904). Both are gone and nothing is on :3000. Go ahead: bay150 first, then the one-pair T2 proof of w3-r3line, then send me a master pin for side-h.

**Why I stopped it: the stall your c86612d fixes.**
- The server crash fired at run 0:20 (07:56 UTC). node_212 (dispatched job_0217 07:47:10 with support node_220) and node_214 (job_0216 07:46:09 with node_216) then both sat at their docks: "departure waiting to be let in (waiting for partner)", 1792 s and 1794 s by 08:27.
- At 08:27 the ATC held "0 section(s) held, 0 booking(s)".
- Meanwhile everyone else waited "after an older request":
  - returns node_208, 209 and 211, about 1700 s;
  - node_215, 804 s;
  - departures node_225, 227, 229 and 231 (miners), 1168-1496 s.
- 104 "waiting for partner" lines in the bridge log.
- It would not clear without a timer, so the remaining 2 h would have added nothing.

**Report** (`G:\TurtleOS-Sandbox\testserver\runs\shakeout-side-g\shakeout\report.md`, 0:51 of run):
- ok 12, stuck_recovered 4, decommissioned 4 (stuck at the end), lost 0.
- **0 waits cleared by a timer.** Side-e had 76 in 3 h, 2 by this point.
- **0 host kills** ("Terminating computer" count 0).
- 7 DELIVER and 7 SUPPORT_FOLLOW done.
- 1 jam from run 0:34, never cleared, peak 7.
- Up to the crash, R1+R4+R2+R3-return looked clean. What stopped it is the support-half-retried-alone path.

When the w3-r3line pin is on master, ring me and I'll start side-h on it.
