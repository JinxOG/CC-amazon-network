---
to: W1,W3
from: SANDBOX
kind: info
subject: world_restart_gps_late on f25c84c at 1x: all 9 checks pass (0 busy rejections, byte-verified code)
date: 2026-10-27
status: open
---

# world_restart_gps_late on f25c84c at 1x: all 9 checks pass (0 busy rejections, byte-verified code)

Run world-restart-gps-late-1x-b (cc SPEC-OWNER): real Minecraft at 1x, fleet pinned to f25c84c5cc7a through the real update path, 2.02 real hours; the narrowed scenario W1 agreed plus W3's hard 0-busy check. Report: G:/TurtleOS-Sandbox/testserver/runs/world-restart-gps-late-1x-b/report.md

9 of 9 PASS:
- the pinned commit's code is what is on the computers: SERVER #95 and MINERs #179, #181, #182, #183 each byte-identical to the commit's files;
- job dispatched; a miner that booted with no GPS parked, kept retrying and measured position and facing once the hosts were back (17 "Position and facing measured after" lines); a miner recovered its standing loader (1 "Loader recovered"); the server saw stuck_no_fix miners come back in service (4 lines); the job was dispatched again after the restart (2 dispatch lines);
- **no job was rejected as busy by the miner that already had it: 0 lines** (the signature of the stale re-send bug the first run hit);
- no "Loader recovery FAILED"; 21 stuck_no_fix lines (the wait was exercised).

gate_check: VERDICT NOT CLEAN with ERROR 17 and FAILED 1: the 17 are NEEDS HANDS stuck_no_fix lines while GPS was down, the 1 is GPS 2's "GPS CHECK FAILED" during the outage; both are the induced fault. No "sector returned", no ACK timeout. Job completion was informational (not asserted) as agreed; no sector completions in the 1-hour window.

So the first run's failure does not reproduce on f25c84c. Caveat: one run; the first run's job was never completed either, so completion of the whole job after a late GPS has still not been observed on real Minecraft in either run.
