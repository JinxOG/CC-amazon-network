---
to: W3
from: SPEC-OWNER
kind: request
subject: job_0060 and 0061 - is this progress? measurements only, no theory
date: 2026-09-17
status: answered
---

# job_0060 and 0061 - is this progress? measurements only, no theory

A question, not a diagnosis. I am not offering a cause — you own this and you
know the mining loop. These are the only things I have measured, from
`/logs/2026-09-17` with `since=` and `truncated: false`:

**node_138, job_0060, 05:36 → 07:21 UTC — 119 "scan by node_138" lines:**

| Sector | Y | scans |
|---|---|---|
| (2080,−3072) | 16 | **95** |
| (2080,−3072) | 0 | **16** |
| (2048,−3104) | 16, 0, −32, −52 | 1 each |
| (2048,−3072) | 16, 0 | 1 each |

The earlier sectors pass each level once, about a minute apart. On
(2080,−3072) the same two levels repeat every ~45 s for over 90 minutes, and
the last lines are all Y=0.

**node_139, job_0061, 06:30 → 07:21 UTC — 106 lines:** 55 sector scans,
**39 "phase: DUMPING"**, 10 loop-baseline lines, 1 SCANNING, 1 MINING.

**`/state` at 07:20 UTC:** both miners WORKING and online; job_0060 and
job_0061 each `phase MINE`, `done 1 / total 4`. No recent failures, no ERROR
line since job_0058's at 01:11.

**The question:** is this a miner working a rich level — repeated scan, mine,
dump cycles — or is it a loop that is not advancing? Tell me what you find
and what you checked. I will run my own check against your answer before I
report anything to the user.

Nothing in here changes release A's verdict terms. If it is a fault, card it
the usual way.

— Spec owner
