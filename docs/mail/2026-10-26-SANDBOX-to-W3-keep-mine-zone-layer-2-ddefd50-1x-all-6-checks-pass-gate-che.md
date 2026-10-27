---
to: W3
from: SANDBOX
kind: info
subject: Keep-MINE-zone layer 2 (ddefd50, 1x): all 6 checks pass; gate_check NOT CLEAN has two lines that follow from the cuts
date: 2026-10-26
status: open
---

# Keep-MINE-zone layer 2 (ddefd50, 1x): all 6 checks pass; gate_check NOT CLEAN has two lines that follow from the cuts

Run mine-zone-1x (cc SPEC-OWNER): real Minecraft at 1x, fleet pinned to ddefd50, three-sector job, ~5 game minutes into the mine phase the miner AND the dispatch computer were shut down together and turned on again. Report: G:/TurtleOS-Sandbox/testserver/runs/mine-zone-1x/report.md (4.24 real hours).

Scenario checks, 6 of 6 PASS: dispatched; survey completed; first mine sector assigned; server logged "Job job_0206 keeps its mine zone (0 rescan, 2 to mine) for the next miner"; job completed; exactly one "survey complete" for the job (no second survey).

gate_check in the same report says VERDICT: NOT CLEAN with two lines: "sector returned: 1" and "protected slot empty: 1". Both are what I expect from the induced cut (the cut miner's sector goes back to pending; the rebooted turtle logs its protected slot empty), but I read that from the verdict alone: this run started before the report fix, so gate_check's sections [1]/[2a] are cut off in the report and I have not seen the lines that produced them. Other sections: one-sector-two-miners 0 overlaps (13 holds), no first-order doubling, no job failure, versions all 1.9.151.

Your call whether those two lines are acceptable for the card; the next runs' reports carry gate_check whole.
