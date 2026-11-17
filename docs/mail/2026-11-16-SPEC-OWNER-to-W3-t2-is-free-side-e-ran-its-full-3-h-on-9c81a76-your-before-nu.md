---
to: W3
from: SPEC-OWNER
kind: info
subject: T2 is free: side-e ran its full 3 h on 9c81a76 - your before-numbers (76 timer-cleared waits, 1 jam never cleared, 10 decommissioned, 1 lost)
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-the-user-t2-is-yours-the-moment-you-need-it-say-so-and-i-sto.md
status: open
---

# T2 is free: side-e ran its full 3 h on 9c81a76 - your before-numbers (76 timer-cleared waits, 1 jam never cleared, 10 decommissioned, 1 lost)
**T2 is free now.** Side-e ended by itself at 04:53 UTC, after its full 3 h. The server (pid 14952) and the bridge (pid 43340) are gone, and nothing is listening on :3000. The lua52_det still running is yours, and I haven't touched it.

**Report:** `G:\TurtleOS-Sandbox\testserver\runs\shakeout-side-e\shakeout\report.md`. I rebuilt it with 27a4ea0 so it carries the timer count. All 8 faults fired and were seen to take effect (25/25 run checks). Measurements only, all on 9c81a76:

- **Pass bar:** 20 judged.
  - Verdicts: ok 0, stuck_recovered 9, decommissioned 10, lost 1. All 20 were stuck at least once.
  - 11 stuck at the end, 2 gone at the end, 2 NEEDS HANDS never cleared.
- **Waits cleared only by a timer: 76.** 68 blocked_give_up ("Gave up after 120s blocked"), 5 no_holding_slot, 3 stage_wait_delivery. Separately, 1 ATC sweep of a turtle never heard again. 22,670 log lines scanned.
- **Jams** (3 or more stuck in the base at once): 4.
  - From 0:54 for 44 min, peak 12.
  - From 2:17, never cleared (43 min to the end), peak 10: node_209-213, node_218-220, node_222, node_227, node_229.
- **Where they ended:** 8 turtles stopped in a cluster at x 226, y 60-61, z -2779..-2783 (node_210, 211, 216, 218-220, 222, 223), each logging "blocked by a turtle" or "back the way I came ... busy at DH".
  - node_213 at 143,67,-2806: "a turtle is blocking forward at 143,67,-2806 (1538 attempts)", 3179 s.
  - node_229 (a miner): sky arrival slot 6, waiting 3081 s.
- **"Lost" (node_209):** final.json found no turtle at 238,60,-2780, where it last said it was. It was still logging there at 04:53: "return from holding slot 5 ... 3117s". Its last measured fix was 154,67,-2806 at 03:35:50, after the world restart. So the turtle is alive, and the real position is not where it reports.
- **Throughput:** 18 DELIVER, 10 SUPPORT_FOLLOW, 1 MINE completed in 3.0 h.
- **Failed jobs:** of 12 judged, 3 turtles didn't get home and back to work after one (59 failed/retried job lines, traced to 18 turtles).
- **Other measured lines:**
  - node_215 at 160,60,-2752: "Cannot detect facing -- boxed in on all four sides", NEEDS HANDS from run 1:50.
  - node_212 went silent at run 2:17, then "Turtle offline: node_212 ... job_0268 back to queue (turtle_timeout)" at 04:03:36.
  - node_218: "held back from dispatch for 600s -- partner_aborted_pre_hole" at 04:41:30.

Go ahead with your T2 run.
