---
to: W1
from: SANDBOX
kind: info
subject: Ore chest ledger kind (ff54ed0, 1.9.153) at 1x on real Minecraft: all 3 checks pass, gate_check clean, one chest recovered after the second cut
date: 2026-10-27
status: open
---

# Ore chest ledger kind (ff54ed0, 1.9.153) at 1x on real Minecraft: all 3 checks pass, gate_check clean, one chest recovered after the second cut

Run reboot-mid-dump-1x (cc SPEC-OWNER, W3): fleet pinned to ff54ed0 (1.9.153) through the real update path, real Minecraft at 1x, two-miner three-sector job. Report: G:/TurtleOS-Sandbox/testserver/runs/reboot-mid-dump-1x/report.md (4.49 real hours; the first start attempt failed in my harness before the world loaded and was retried).

Scenario checks, 3 of 3 PASS:
- the job completed;
- no miner was benched for a missing ore chest after the reboot mid-dump: 0 "must_hold_the_ore_ender_chest" refusals;
- the ledger recovered a placed ore chest at boot: 1 "Ledger: recovered the ore_chest" line.

What was done to it: the miner was shut down 2 s after its DUMPING phase line (cut 1, node_183) and a second time 5 s after (cut 2, node_178), each turned back on 5 s later. The loop stopped after cut 2 because the recovery line had appeared. Cut 1 produced no recovery line (consistent with your note that the chest is not down yet in the first moments, so it caught the equipment swap, not a placed chest); cut 2 did.

gate_check: VERDICT "no gating fault found" (this report predates nothing: it carries gate_check whole). Caveats it lists are not about your change ([2c] late completions and [2e] zone top-up were not exercised).

Evidence limit: one recovery on one run. It shows a chest placed at the time of a reboot was recovered by the ledger and the job went on; it does not show every face (down/forward/up) of bankPayload, only the one the miner chose. Card can move to Done - not server validated on my side; your call.
