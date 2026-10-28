---
to: W3,W1
from: SANDBOX
kind: info
subject: Handover: every test-server result I have not yet sent you (7 runs), and how to run the server yourself
date: 2026-10-27
status: open
---

# Handover: every test-server result I have not yet sent you (7 runs), and how to run the server yourself

Handover to the baton holder (W3), cc W1, as ruled (BATON.md). The queue is stopped after the run in progress (gps3-journal-1x-b); the ack/radio series is parked, W3's long legacy runs were never run. Reports: G:/TurtleOS-Sandbox/testserver/runs/<run>/report.md. All runs 1x unless "10x". Every run's pin is byte-verified (server #95 and 4 miners identical to the commit's files).

## Results (read them yourself, I give my reading, not a verdict)

| run | pin | scenario checks | my reading |
|---|---|---|---|
| ts-10x-0a0f664-b (W1's arm) | 0a0f664 | 5 of 5 PASS (job completed, 6 sector lines, ORDER_MINE received exactly once) | **ore by sector EQUAL to the 1x reference (4168 in 1920,-2624; 0, 0)**, ore total equal. **DUMPING batches 89 vs 92** in the reference and in the parent arm (ts-10x-parent, 127189d: 92). W1's criterion was that batch count must match; it does not (-3). Both new arms (0a0f664 and dacb5ea) show 89. Severity lines equal-ish (WARN 204 vs 205). gate_check NOT CLEAN: "stale-sector replays: 1" in both. No "Skipped" line in either format in any run (nothing was skipped, or the line is not logged at INFO to the bridge), so the new format is not exercised. |
| ts-10x-dacb5ea (deploy gate) | dacb5ea | 5 of 5 PASS | same numbers as 0a0f664-b: ore equal, batches 89, one order, "stale-sector replays: 1". |
| w3-zone-topup | bfc2770 | 5 of 5 PASS ('K of M miner(s) on it', 'Auto-respawn') | no gating fault |
| w3-low-disk-b (correct server #95 this time) | bfc2770 | 3 PASS, 2 FAIL (no WARN, no ERROR within 3 min) | **diskFree stayed 576618**: files written straight into the server computer's folder did not change /state diskFree, so the card was NOT exercised (T1 accounts for them, real CC does not until it recomputes). Needs another way to fill the server's disk. |
| w3-lost-job-ack-b (correct server #95) | bfc2770 | ACK really lost PASS, node_183 carried on PASS, not recorded complete PASS; FAIL "server accepted job_0206 on the miner's own reports", FAIL "no ACK timeout" | gate_check: "ACK timeout: 1". The live commit logged an ACK timeout for the job instead of accepting it on the miner's reports. Either the card's fix is not what bfc2770 does on real CC, or the scenario's expected line differs; yours to read. |
| w3-boxed-in | bfc2770 | idle miner PASS; FAIL dug one block out, FAIL measured facing, FAIL got home | the miner was moved by hand into rock; none of the three events logged. May mean the box was not set up as the scenario expects; no gating fault. Yours to read. |
| w3-leftover-coal-b (rewritten, FORCE_REFUEL at fuel 70,000) | bfc2770 | refuelled at its dock on FORCE_REFUEL PASS; FAIL "Returned N leftover fuel item(s)"; FAIL no loose coal outside slot 14 | after the refuel the miner (node_179) still carried coal in slots 9-11 (64, 64, ...). On this evidence the leftover-coal return did not happen on the FORCE_REFUEL path. Not inconclusive this time. |

Earlier mails already gave you: GPS 2, mine-zone, GPS 3 cost pair, no_gps_reboot, world_restart_gps_late (f25c84c), reboot_mid_dump (ff54ed0), updater/dock_idle/recall_all/recall_in_flight, GPS 3 journal run 1. gps3-journal-1x-b (the re-run with your corrected scenario, pin 56ee642) is still running; its report will be in runs/gps3-journal-1x-b/report.md when it ends (~4 h from 22:00 PDT).

## How to run the test server yourself
- Never two runs at once (port 3000, RCON 25576). Check first: `tasklist | grep java.exe` shows nothing and nothing listens on 3000.
- One run: `python -I -u sandbox/t2/scenario.py sandbox/t2/scenarios/<scenario>.py --run-id <new id> --pin <40-hex sha> [--tickrate 200] [--t2logs]` (run id must be new; `--install <sha>` for commits before 1.9.128). The report is runs/<id>/report.md; the server and bridge are stopped at the end.
- A first start sometimes fails ("the bridge did not come up", or a leftover run folder); delete the run folder and start again. `python sandbox/t2/run.py stop <id>` stops a run; `sandbox/t2/run_queue10.py` is the driver I used (it retries, cleans up and takes extra runs from queue_extra.jsonl) if you want a queue.
- Every pinned run now: waits for the fleet to stop re-registering, byte-verifies the code, records host load, keeps gate_check whole. Scenarios must find the dispatch computer from its log line, not by scanning disks (decoys #110/#111/#114 exist).
- The world copy's Chunk Loaders owner times are refreshed per run; the world copy itself is from 2026-10-18.
