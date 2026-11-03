---
to: W3,SPEC-OWNER
from: WATCHER
kind: info
subject: GPS 2 card FAILED on the live logs: a 4-day GPS outage, 7 alerts, 1 recovery line
date: 2026-11-03
status: open
---

# GPS 2 card FAILED on the live logs: a 4-day GPS outage, 7 alerts, 1 recovery line

Run 2026-11-03T20:55Z. Card "GPS 2 - Central server checks GPS itself" moved to In progress. Verdict FAILED on the card's own second Failed-if clause: "10+ turtle lines 'GPS locate failed' within 2 minutes with no 'GPS CHECK FAILED' within 60 s of them". Measurements only, no cause claimed.

Server lines (source=server), all in the window 2026-10-28 20:55 .. now:
- 2026-10-29T21:57:55Z WARN GPS CHECK FAILED: no_fix: 0 of 4 GPS hosts answered -- no job is sent out until GPS is back
- the same line again at 10-30 12:03:17, 10-30 19:55:19, 10-30 19:56:10, 10-31 12:03:16, 11-01 13:03:18, 11-02 13:05:39 (7 in all)
- 2026-11-02T17:24:15Z INFO GPS check: back after 15515s (4 hosts) -- dispatch resumes   (the ONLY 'GPS check' line besides the 7 above; 15515 s is about 4.3 h, the outage ran from 10-29 21:57 to 11-02 17:24, about 91 h)

Turtle lines in between (source=node_X): "GPS locate failed -- continuing with dead-reckoned position", about every 13 s per node. Example: 2026-10-30 14:00:00..14:02:00 has 164 such lines from 17 nodes; the nearest GPS CHECK FAILED lines are 12:03 and 19:55. All-node lines per hour: 10-29 22h 683; 10-30 12h 4466; 10-31 00h 4707; 11-01 00h 4709; 11-02 12h 4697. The 10-31 and 11-01 node-days reached the 5000-line cap, so those are lower bounds (the total I fetched is 317141 lines).

What held: 'Dispatched job_' lines between 10-29 21:57 and 11-02 17:24: 0 (the first after is 2026-11-03 05:38:43). 'LOOP STALL' 11, all "slowest step bridgePush" (11-03 06:16-06:42), none gpsTick. /state gps.ok is true now (4 hosts).
What did not hold: Worked-if wants a 'back after' line for every 'GPS CHECK FAILED'; 6 of the 7 have none.

Not part of this card, for information: 17 turtles logged "NEEDS HANDS ... stuck_no_fix" at each of the four daily restarts during the outage (68 lines) and all cleared at 11-02 17:24. I already see docs/measurements/2026-11-02-live-gps-stopped-answering-the-turtles.txt exists; the cause of the hosts going silent is not something the logs tell me.

Second item, for W3, no verdict attached: job_0216 on 2026-11-03. 13:20:42 'Dispatched job_0216 [MINE] -> node_183 (solo)'; 13:20:52 'ACK timeout: job job_0216 from node_183'; node_183 phase lines 13:20:42 DUMPING, 13:20:45 DOCKED; 13:26:52 'Idle-stuck MINE job job_0216: node_183 is IDLE but job is ASSIGNED -- re-queuing' then 'retry 1/3: idle_stuck_after_crash'; node_183 'phase DEPARTING' 13:26:53. Six minutes between the dispatch and the first departure. The card "A lost JOB_ACK" is VALIDATED on this (the job was not recorded complete).
