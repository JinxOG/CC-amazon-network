---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Ack loss replay: old code 9.08% parked, step 3 1.15%, master 0.03%; acks reach the program, loss is after the queue
date: 2026-10-20
status: open
---

# Ack loss replay: old code 9.08% parked, step 3 1.15%, master 0.03%; acks reach the program, loss is after the queue

**The two figures you asked for** (fleet parked at the base, no job, 8 simulated hours, synthetic world, 6 workers + 2 miners' worth of parked nodes, `tools/ack_loss.py` through BRIDGE_URL; commit 9a07f6b; scenario `sandbox/scenarios/ack_loss_parked.lua --code rev:<sha>`):

| code | parked ack loss |
|---|---|
| before 23f5a97 (`23f5a97^`, 1.9.107) | **9.08%** (20,400 beats; per node 2.1% to 12.3%) |
| 105d104 (step 3, 1.9.112) | **1.15%** (21,660 beats; per node 0.6% to 1.8%) |

Extra, same method: 23f5a97 itself (step 1) 9.16%; current master (worktree) **0.03%** against live 0.02%. Calibration note section 2 now compares against 0.02% and no longer lists ack loss as a gap.

**Which mechanism the sandbox shows** (counters added to the computers: lost events by cause, and heartbeat acks counted at each stage):
- Queue overflow: **0**, anywhere, on every revision.
- Filtered-yield discards: **0 acks**; only 1-7 of ~22,000 messages per worker on the old code.
- For each parked worker on the old code, every ack addressed to it was queued (about 3,400 over 8 h, matching the beats) and every one was handed to the program. Yet the turtle's own counter reads 9% fewer acks than beats. So **in the sandbox the loss is after the event queue, inside the program's handling of messages** (the loop does ~0.9 turns/s on the old code, 0.34 after step 3, which fits fan-out load on each turtle). I have not located the line in turtle_base.lua; the project's "drain-first" note on `base.receive` is the likely area, unconfirmed. That is W3's to look at with this evidence.
- The server computer does lose messages to filtered yields on the old code: 2,135 of 22,255 (9.6%).

**Caveats:** (1) the old fault reproduces smaller than live (9% against 11-18%; idle live 18%), probably because the synthetic fleet has 8 parked computers not the live 16-17, and fan-out grows with fleet size; I did not tune to match. (2) At 1.9.112 the sandbox still shows 1.15% where live shows 0.02% on 1.9.148: something between 105d104 and master removed the last ~1%, which I have not bisected (say if you want it). (3) No working-regime figure: the replay is parked only.
