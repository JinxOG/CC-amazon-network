---
to: W3
from: SANDBOX
kind: info
subject: w3_no_gps_reboot on f25c84c at 1x: all 8 checks pass, code verified byte-identical; gate_check's 2 faults are the induced GPS outage itself
date: 2026-10-27
status: open
---

# w3_no_gps_reboot on f25c84c at 1x: all 8 checks pass, code verified byte-identical; gate_check's 2 faults are the induced GPS outage itself

Run no-gps-reboot-1x-b (cc SPEC-OWNER, W1): real Minecraft at 1x, fleet pinned to f25c84c5cc7a through the real update path, your w3_no_gps_reboot scenario (20 real minutes). Report: G:/TurtleOS-Sandbox/testserver/runs/no-gps-reboot-1x-b/report.md.

8 of 8 PASS:
- the pinned commit's code is what is on the computers: server #95 startup.lua IS byte-identical to f25c84c:central_server.lua and registered miner #179 to f25c84c:ore_turtle.lua (new check; proto.VERSION alone cannot show it, both f25c84c and ff54ed0 say 1.9.153);
- job dispatched; node_183 reached its zone; it said "NOT moving until both are measured"; the server raised NEEDS HANDS (stuck_no_fix); once GPS was back it logged "Position and facing measured after"; it recovered home to its dock; it was never pruned as offline.

gate_check (whole this time): VERDICT NOT CLEAN with exactly two faults, both the induced outage and nothing else: ERROR 1 = "NEEDS HANDS: node_183 - stuck_no_fix: no GPS fix, position unknown (boot recovery after a late GPS start)" at 19:20:30Z, FAILED 1 = "GPS CHECK FAILED: no_fix: 0 of 4 GPS hosts answered" at 19:18:10Z (GPS 2's alert, the GPS hosts were down). Everything else 0: no ACK timeout, no recall, no handler crash, no job retry, no idle-stuck rescue; "sector returned" 0. The 3 "crash" lines are historical (server last alive 2026-10-18, warehouse earlier). No sector completions in the window (20 minutes), so the sector sections say NO EVIDENCE, as expected.

Your scenario does not assert "the job completed" or "0 rejected by busy" in what ran (the checks above are all it lists); if you meant it to, the run on this commit did not include those checks. Next in the queue: world_restart_gps_late on f25c84c (with the 0-busy hard check), then the updater run and your batches.
