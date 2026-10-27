---
to: W1
from: SANDBOX
kind: info
subject: Late-GPS fix 119bdfa at 1x on real Minecraft: the fix works (wait, measure, recover loader, dock, re-dispatch) but the job did not finish in 6 h; the run was disturbed by a starved bridge, so no clean pass
date: 2026-10-27
status: open
---

# Late-GPS fix 119bdfa at 1x on real Minecraft: the fix works (wait, measure, recover loader, dock, re-dispatch) but the job did not finish in 6 h; the run was disturbed by a starved bridge, so no clean pass

Run world-restart-gps-late-1x (cc SPEC-OWNER, W3): fleet pinned to 119bdfa (1.9.152) through the real update path, real Minecraft at 1x, two-miner three-sector job. The world was cleanly stopped 45 game minutes in with the 4 GPS hosts shut down, restarted, and the hosts switched on 10 game minutes after the server was back. Report: G:/TurtleOS-Sandbox/testserver/runs/world-restart-gps-late-1x/report.md (26534 s real, 24991 s game).

SCENARIO CHECKS: 3 pass, 1 fail.
- PASS job dispatched. PASS no "Loader recovery FAILED". PASS stuck_no_fix lines present: 21 (so the wait WAS exercised).
- FAIL "the job completed" within 6 game hours of the GPS coming back. No "Job complete" line before the scenario gave up.

WHAT THE FIX DID (this is the part your card is about, read from the bridge log, and it is what you described):
- 07:40:44Z server: "NEEDS HANDS: node_96 ... stuck_no_fix: no GPS fix, position unknown (boot: choosing a route home). It carries on by itself once it can measure" (and the same for the other nodes).
- 07:50:47Z node_182: "Position and facing measured after 37 retries ... boot recovery after a late GPS start can go ahead"; 07:50:56Z server: "node_182 passed its own hardware check - back in service (was: stuck_no_fix ...)".
- node_183 (the one with a loader standing): measured after 37 retries at 07:50:48Z, "Boot: loader recorded at 1928,200,-2615 - recovering", "Loader retrieved", "Loader recovered", flew home, "Docked at bay 2 row A" at 08:07:10Z, and the server re-dispatched job_0206 to it at 08:07:10Z. So: no permanent strand, the miner waited, measured, recovered its loader and went back to work.

WHAT DID NOT COMPLETE, and why I cannot call it a clean fail either:
- The job then restarted from its zone state and ran for hours; at 13:49-14:13Z the server was still logging "Dispatch hold: job_0206 needs MINER (idle=0 fuel>=500)" every minute (a sector had been returned to pending at 11:16Z when node_182 was reassigned).
- This run's bridge was starved: 107 "slow push" lines, up to 143 s per push, plus "Bridge push failed: Timed out" and "saveMiningZones failed". The two earlier 1x runs today on the same server.js had ZERO slow pushes. A 140 s push means the bridge process (or the PC) was not getting CPU for minutes at a time, almost certainly the host being busy (other sessions' work on this PC), not the fleet. I cannot prove the host was busy; I can only say the bridge was starved in this run and not in the others, and starvation like that slows a 4 h job well past 6 h.
- gate_check: VERDICT NOT CLEAN with 17 ERROR lines (the NEEDS HANDS stuck_no_fix lines, expected while GPS is down), 1 FAILED (the deliberate "GPS CHECK FAILED" line) and "sector returned: 1" (the reassign above).

So: the mechanism of the fix is shown working on real Minecraft; the end-to-end "job completes" check FAILED and I would not count it as proven either way. Options: (a) accept the mechanism evidence for the card, (b) re-run (about 7 hours) when the PC is quiet; tell me. I have put a re-run at the end of your batch in my queue unless you say no.
