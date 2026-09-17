---
to: SPEC-OWNER
from: W3
kind: info
subject: Release A cleared (idle 17.29%); release B 1.9.110 shipped - orphan report added first, then shipped
date: 2026-09-17
status: open
---

# Release A cleared (idle 17.29%); release B 1.9.110 shipped - orphan report added first, then shipped

## Release A (1.9.109): cleared

**Idle reading, 12:57–15:57 UTC (7.7–10.7 h of uptime), 15 turtles, no job:**
**17.29%** (15,881 acks for 19,200 beats). That is at or below your 20.9% bar
and slightly under 1.9.108's 17.88% (14,732/17,940): **no worse**, within
noise. Hourly: 19.2, 17.7, 17.5, 16.5%.

| Measure | 1.9.108 | 1.9.109 | Beats (A) |
|---|---|---|---|
| First order doubled | 21 of 22 | **0 of 2** | — |
| Parked loss, running, 0.7–2.7 h | 6.70% | **6.40%** | 14,880 |
| Working loss | 0.92–1.06% | **1.16%** | 2,760 |
| Parked loss, idle, 7.7–10.7 h | 17.88% | **17.29%** | 19,200 |
| Lost assignments per dispatch | 1 of 25 | **0 of 3** | — |

**Verdict and override, recorded as for job_0059.** The gate over job_0060/0061
(`gate_check.py 2026-09-17T05:18:00`) read **NOT CLEAN**. The fatal lines were:
- job retry, idle-stuck rescue and sector returned: **one lost JOB_COMPLETE
  from node_139** at 12:08. The same signature appeared on job_0052
  (2026-09-15), before A. Whether it was never sent or sent and lost is
  **unproven**, because the turtle does not log the send. Recorded on the
  Wave-2 card *A miner that reconnects after its last sector goes home without
  closing the job*, with the next step: an INFO line when `sendComplete` fires,
  in the next release.
- two overlapping holds on (2048,−3072): the late-completion misread plus the
  full-grid rescan, which is **release B's fault**, not A's.

**Shipped on from A by the spec owner's ruling, 2026-09-17** ("A cleared on the
idle reading; override recorded").

## Release B (1.9.110): shipped 15:58 UTC

**The orphaned sector report was added first, then B shipped.** Your question showed a
case B did not cover: a miner finished early by a held sector, whose holder
then failed while the first job was still live. It is fixed and tested
(`respawnIfOrphaned` on completion as well as failure, the WARN line, and a
fatal gate entry).

- **Contents:** phase-at-assignment counting plus the `Late completion` INFO line;
  the rescan list leaves out held sectors; no phase hands out a held sector;
  when every remaining sector is held, the asker gets MINE_COMPLETE; holds end
  with MINE_COMPLETE or when their job stops being live; the orphaned-zone
  report and respawn; every hand-out logged; the two neighbouring fixes (a
  RESCAN-phase request, a late rescan result), **found in code, not seen live**,
  each with its own log line. 449 tests, 166 mutants, all killed.
- **Deploy:** fleet idle; **15/15 turtles on 1.9.110** by 15:59. The server logged
  `Central server online v1.9.110` at 15:58:39 and `/state` reports version
  1.9.110.
- **Validating job:** job_0062 (node_139) and job_0063 (node_138), one shared
  zone at 2052,−2904, dispatched at 16:00.
- **It counts only if:**
  - `[2c]` shows at least one `Late completion`, with the MINE-assigned case
    present in `doneSectors`;
  - `[2d]` shows **0 overlapping holds in both views**;
  - no `zone left unmined`;
  - no FAILED job;
  - no "0 ore mined" for a sector never dug.

  If no late completion fires, I will say so and run another job.

**W1's query is written** (`2026-09-17-W3-to-W1-one-query-…`) with all five
known cases, including this job's two. Not rung yet; one engineer at a time.

**Next after B clears:** channel step 2 as 1.9.111, rebased and renumbered,
with the `sendComplete` INFO line added. That line is a log line only; it
changes nothing about behaviour.

— W3
