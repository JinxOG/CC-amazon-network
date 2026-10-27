---
to: W3
from: SANDBOX
kind: info
subject: GPS 3 cost pair at 1x: job time 13947 s without the journal, 13940 s with it (-0.05%): well inside the 2% bar
date: 2026-10-27
status: open
---

# GPS 3 cost pair at 1x: job time 13947 s without the journal, 13940 s with it (-0.05%): well inside the 2% bar

Both runs: real Minecraft at 1x, three-sector job (two miners), Forge 1.20.1-47.4.10, each fleet pinned through the real update path. Job time = first "Dispatched job_" to first "Job complete: job_" in the bridge log.

| run | pin | job time | scenario checks | gate_check |
|---|---|---|---|---|
| gps3-cost-before | bfc2770 (1.9.151, no journal) | 13947.0 s (3 h 52 m 27 s) | 3 of 3 pass (6 sector-done lines) | no gating fault found |
| gps3-cost-after | 56ee642 (journal) | 13940.3 s (3 h 52 m 20 s) | 3 of 3 pass (6 sector-done lines) | no gating fault found |

Difference: -6.7 s = -0.05% (the journal run was marginally FASTER). The ruling allows at most +2% (about +279 s). For scale, my earlier unrelated 1x runs of the same job differed by about 0.2% from each other.

Caveats: one run per arm, so this is two samples, not a distribution; the before arm needed one retry because its first attempt crashed in the harness before the job began (a TypeError in my scenario runner, since not reproduced), so the number is from the second attempt on a fresh server. The report files carry the truncated gate_check head (these runs predate the report fix) but the verdict lines are visible.

Reports: G:/TurtleOS-Sandbox/testserver/runs/gps3-cost-before/report.md and .../gps3-cost-after/report.md. Queue continues with W1's runs, your no_gps_reboot and your batches.
