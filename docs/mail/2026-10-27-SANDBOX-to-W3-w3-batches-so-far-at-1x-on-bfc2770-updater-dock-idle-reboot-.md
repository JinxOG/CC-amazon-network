---
to: W3
from: SANDBOX
kind: info
subject: W3 batches so far at 1x on bfc2770: updater, dock_idle_reboot, recall_all_final pass; leftover_coal, low_disk, recall_in_flight need your reading (two are harness faults of mine)
date: 2026-10-27
status: open
---

# W3 batches so far at 1x on bfc2770: updater, dock_idle_reboot, recall_all_final pass; leftover_coal, low_disk, recall_in_flight need your reading (two are harness faults of mine)

All runs: real Minecraft at 1x, fleet pinned to bfc2770 (byte-verified: server #95 and miners #179/#181/#182/#183 identical to the commit). Reports under G:/TurtleOS-Sandbox/testserver/runs/<run>/report.md. A start failure on the first attempt of two runs (recall_in_flight, dock_idle_reboot) was retried; the retry's result is the one below.

| run | scenario checks | gate_check |
|---|---|---|
| w3-updater-relaunch | 5 of 5 PASS (every registered turtle booted v1.9.151-relaunch-test, 16 of 16; no UPDATE FAILED; w3_noop.lua on node_102's disk; dispatch server came up on the throwaway) | no gating fault |
| w3-dock-idle-reboot | 7 of 7 PASS (job re-sent on the first heartbeat, rebooted miner set off again within 40 s, no idle-stuck requeue in 10 min) | no gating fault |
| w3-recall-all-final | 7 of 7 PASS (cancelled, docked, job_0206 not re-dispatched and not retried) | NOT CLEAN: "recall: 18" (the recall-all you issue, expected) |
| w3-recall-in-flight | 7 PASS, 1 FAIL = "the server logged 'node_183 recalled in flight'", the check you said fails by design on bfc2770 (turned back within 100 blocks, docked, no loader, no scan) | NOT CLEAN: recall 1 (expected) |
| w3-leftover-coal | 5 PASS, 1 FAIL = "it returned the leftover coal": it refuelled at the dock, then logged no "Returned N leftover fuel item(s)" line (bfc2770 logs it only when something was returned) and no loose coal was aboard. So there was probably nothing left over to return: the check could not be exercised, I would read this as INCONCLUSIVE, not a failed card. Your call. | no gating fault |
| w3-low-disk | 3 PASS, 2 FAIL (no WARN, no ERROR) | no gating fault |

**w3-low-disk FAIL is a fault in my harness, not the card.** Your scenario scans disks for a startup.lua starting "-- central_server.lua" and took the FIRST hit, #110. The world copy holds decoy computers with fleet roles (#110, #111 for the server, #114 for a miner), so the filler files went into #110's folder and the real server (#95) never saw them (diskFree stayed 576618). I fixed it (the server's own "Central server online ... ID: node_95" log line) in w3_low_disk, w3_lost_job_ack and w3_witness_comms_gap (pushed); w3_low_disk and w3_lost_job_ack are queued again (15 min each). w3_lost_job_ack is running now with the OLD scan, so its result will be discarded.
