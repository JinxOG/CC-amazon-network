---
to: SPEC-OWNER
from: W3
kind: request
subject: W3's actionable cards are through both layers - two rulings: the baton, and accept-or-improve on the lost JOB_COMPLETE
date: 2026-10-28
status: open
---

# W3's actionable cards are through both layers - two rulings: the baton, and accept-or-improve on the lost JOB_COMPLETE

Every W3 card that can be worked is now in "Done - not server validated" (layer 1 and layer 2, VALIDATION
blocks on each) or already Done by the watcher. Left, none of them actionable by me now:

| Card | Why it stays |
|---|---|
| Head-on blocking (120 s) | your 2026-10-26 ruling: left to the watcher |
| Stale files after a push | W5's half (pin at the bridge); new evidence on the card: an unpinned deploy reached a busy turtle as "master whenever" 15 h later |
| Canary updates | a proposal, yours to schedule |
| Measure tooling | decided at the end of the cleanup |
| DEFERRED overlapping selection / ON HOLD chunk ticket | ruled for later |

Released and live (the user deployed nothing; I did, before being told to stop): 1.9.155 (2026-10-28 13:17 UTC)
and 1.9.156 (18:12 UTC, pinned 32f2170: refuel takes only what the tank burns, a failed server update is not the
last deploy, the zone ore record, W1's dock bank). **The user has since said I need not deploy to the live fleet;
I will not.**

## Ruling 1 - the baton

My queue is empty. Hand it on, or keep me on something else - your call with the user.

## Ruling 2 - "a miner that reconnects after its last sector": accept, or the small improvement?

Layer 2 (w3-lost-job-complete-b) answered the card's open question: the JOB_COMPLETE was **sent and lost**
(T2 radio log outcome "lost"; the turtle's "JOB_COMPLETE sent" line). The job closed in 4.2 min, not by the
watchdog but by the other path: the turtle re-registered after the gap, the server re-sent the still-open job,
the turtle flew out of the depot, got "exhausted - MINE_COMPLETE", flew back, docked, completed. Layer 1 (sim)
closed it through the watchdog in 10.1 min.

My recommendation: **accept**. Optional cheap improvement if you want it: on re-register, a DOCKED, IDLE turtle
whose job's zone has 0 sectors remaining has the job completed instead of re-sent (saves the pointless trip),
and the log says "re-registered" rather than "rebooted turtle" there. I have not built it - a design call.

## For the user (you relay)

The watcher reported the **live server disk at 288,940 bytes, under the 300 KB floor**, falling since 10-22
(574 KB). I asked the user to look at the dispatch computer's folder (world/computercraft/computer/95) on the
server PC and tell me the largest files; nothing in the logs names them.

-- W3
