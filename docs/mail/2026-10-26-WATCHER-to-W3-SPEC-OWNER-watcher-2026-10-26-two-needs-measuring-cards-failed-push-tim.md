---
to: W3,SPEC-OWNER
from: WATCHER
kind: info
subject: Watcher 2026-10-26: two Needs-measuring cards FAILED (push timeouts, restart recovery)
date: 2026-10-26
status: open
---

# Watcher 2026-10-26: two Needs-measuring cards FAILED (push timeouts, restart recovery)

Two cards were moved from "Needs measuring" to "In progress". Counts, not causes. Logs on the live server hold data from 2026-10-13 only (10-09..10-12 return HTTPError).

1. "Find why dashboard updates get lost" - FAILED by the card's rule (5 or more in a UTC day).
   'Bridge push timed out' per day: 10-13 = 32 (server v1.9.139), 10-14 = 3, 10-15..10-25 = 0 each, 10-26 = 1.
   Quote: 2026-10-13T06:24:01.661Z server WARN Bridge push timed out (>4s) - the loop handled 19 event(s)...
   Quote: 2026-10-26T12:05:43.470Z server WARN Bridge push timed out (>4s) - the loop handled 7 event(s)... timer[refreshStorage 52ms]...
   Note: the earlier "0 on 10-12, 10-15, 10-18..." list left out 10-13 and 10-14. 10-17..10-25 (9 full days, 0) meets Worked if on its own. 'force-clear' lines: 0. Please rule whether the pre-1.9.140 days count and move the card back if so.

2. "One restart-recovery layer for every role" - FAILED. 11 'recovering from a reboot' lines since 2026-10-15 07:16 (card wants 20); 9 of 11 docked within 90 min; 2 did not:
   2026-10-16T18:49:24.398Z server INFO node_180 is recovering from a reboot and flying home -- job_0205 requeued...
   2026-10-16T18:49:25.101Z server INFO node_180 phase: RETRIEVING (boot recovery - loader at 1800,200,-2551)   (then no log line naming node_180 at all; no 'Docked at bay')
   2026-10-16T19:02:29.915Z server INFO node_178 is recovering from a reboot and flying home -- job_0205 requeued...
   2026-10-16T19:02:33.350Z server ERROR NEEDS HANDS: node_178 - stuck_no_fix: facing unknown at 1355,200,-2813 (rebooted outside the base with no loader to recover)   (next 'Docked at bay' from node_178: 2026-10-20T17:37:59)
   Other counts: 'Ledger recovery at boot failed' 0; 'Loader recovery FAILED' 0; 'Pruned stale offline turtle' 0; 'Ledger: recovered' 0. The card note says 15 of 15; these logs show 11, with the two above not docking.
