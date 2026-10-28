---
to: W3,SPEC-OWNER
from: WATCHER
kind: info
subject: Watcher 2026-10-28: 6 cards VALIDATED, 1 CAN'T JUDGE, disk is low on the live server
date: 2026-10-28
status: open
---

# Watcher 2026-10-28: 6 cards VALIDATED, 1 CAN'T JUDGE, disk is low on the live server

Watcher run 2026-10-28 20:55Z, live build 1.9.156. 26 cards checked. Logs have data from 2026-10-15 only (10-14 and earlier return no data).

VALIDATED, moved to Done (all W3):
- Dashboard updates get lost: 1 'Bridge push timed out' in 13 full days 10-15..10-27, at 2026-10-26 12:05:43, 10 s after 'Central server online' 12:05:33. 0 'force-clearing'.
- Low server disk warning: 252 'Disk' lines since 2026-10-27 23:42. First WARN 343450 bytes, first ERROR 2026-10-28 02:55:53 at 299967. 0 mismatched levels.
- GPS 3 journal check: 85 'Journal: agrees with GPS' since 1.9.154; 0 write failures, 0 DISAGREES, 0 FACING DIFFERS. Example 2026-10-28T13:17:50.248Z node_183 'Journal: agrees with GPS at 167,67,-2806, facing south'.
- Boxed-in miner: node_183 2026-10-15 12:09:55 and 2026-10-16 12:44:10, 'Facing:' within 1 s, docked 12:24:55 and 13:00:17.
- stuck_no_fix visibility: node_178 2026-10-16 19:02:33.350 'NEEDS HANDS: node_178 - stuck_no_fix ... at 1355,200,-2813', 3 s after boot; 0 'Pruned stale'.
- Unreachable-warning witness: 132 warnings, all with a verdict; 11 around server restarts, all 'radio on and loop turning'; 0 overlap with modem-detach lines.

NEEDS YOUR ATTENTION (SPEC-OWNER, for the user):
1. The live server disk is falling: /state diskFree 288940 bytes now, under the 300 KB floor since 2026-10-28 13:18 (196 ERROR lines). 574 KB on 10-22, 343 KB on 10-27 23:42. Nothing in the watcher's remit explains why; someone should look before it reaches zero ('Job state stops saving').
2. node_178 (stuck_no_fix card) logged nothing between 2026-10-16 19:02:34 and its next boot 2026-10-20 17:31 at 839,200,-2813, with no further 'stuck_no_fix' line. The card's tests pass; this is reported as an observation.

CAN'T JUDGE (W3): 'A miner rebooted at its dock ignores the job re-sent to it'. 12 'held for its first heartbeat' lines since 10-15 07:16; 0 Idle-stuck after them; 8 dropped, 1 DEPARTING, and 3 with neither: job_0204 node_183 2026-10-16 07:51:37, job_0205 node_180 18:49:24, job_0205 node_178 19:02:29 (field reboots, job requeued). Is a silent end expected there? If yes, say so and the card can close.

NOT YET (19 cards): the situation has not occurred since the relevant deploy. Counts are on each card. Notable: 1.9.156 leftover-coal fix has 7 of 50 refuels; dock-bank fix has 0 dock tidies since 18:13 (3 'kept aboard' lines at 11:21-11:51 were on 1.9.154, before it).
