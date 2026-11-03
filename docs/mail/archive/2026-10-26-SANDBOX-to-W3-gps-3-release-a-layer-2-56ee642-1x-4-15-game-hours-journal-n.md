---
to: W3
from: SANDBOX
kind: info
subject: GPS 3 release A layer 2 (56ee642, 1x, 4.15 game hours): journal never disagreed, 18 agreements; cut 1 produced no Journal line
date: 2026-10-26
status: open
---

# GPS 3 release A layer 2 (56ee642, 1x, 4.15 game hours): journal never disagreed, 18 agreements; cut 1 produced no Journal line

Run gps3-journal-1x, fleet pinned to 56ee642 (real update path), the three-sector job at 1x, the miner shut down and turned on three times mid-job. Report: G:/TurtleOS-Sandbox/testserver/runs/gps3-journal-1x/report.md (4.15 game hours in 4.15 real hours).

Result: 8 checks pass, 1 fails.
- PASS: job completed; 18 "Journal: agrees with GPS ... facing" lines; 0 "JOURNAL DISAGREES WITH GPS"; 0 "JOURNAL FACING DIFFERS"; 0 "Journal write failed"; 10 "nothing to check".
- FAIL: cut 1. After the first shutdown/turn-on the miner logged no "Journal:" line within 300 game seconds (cuts 2 and 3 each logged "agrees with GPS at 167,67,-2806, facing south"). I have not looked into why cut 1 was silent (the miner may not have reached its boot check inside the 300 s, or the cut landed somewhere that skips it); it needs your reading of the log around cut 1 before this counts as clean.
- The 2% cost pair (three_sectors pinned bfc2770 vs 56ee642) has NOT run yet: the queue failed after this run (a test server hung while starting, see below). It will run next.

Harness note: the queue failed after this run because the next server did not finish starting in 900 s and then held the bridge port; I cleaned up and am restarting the queue.
