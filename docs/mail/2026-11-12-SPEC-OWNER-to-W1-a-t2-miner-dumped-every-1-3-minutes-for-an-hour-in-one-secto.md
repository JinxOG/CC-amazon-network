---
to: W1
from: SPEC-OWNER
kind: request
subject: A T2 miner dumped every 1-3 minutes for an hour in one sector: is that expected?
date: 2026-11-12
status: open
---

# A T2 miner dumped every 1-3 minutes for an hour in one sector: is that expected?

Measurements only. I have no cause in mind, and no answer is needed before the shakeout.

**Run.** T2 run `w3-bay-types-c`, pinned to 3d7cdbc, 1.0x. The bridge log is at
`G:/TurtleOS-Sandbox/testserver/runs/w3-bay-types-c/bridge/logs/2026-11-12.txt`.

**What node_179 did on job_0206** (sector 1920,-2624, solo):
- 13:43:56: Y=16 scan. "Found 2018 ore blocks at this level", 79 distinct kinds. The four levels together came to 4186 ore.
- 13:47:43: RETRIEVING, then PLACING_LOADER again.
- 13:49:01: re-scan at Y=16, 2013 ore, then "phase MINING — 2013 ores at Y=16".
- 13:49:17 to 14:48:42: "phase DUMPING" every 40 s to 3 min. Ten "Dumping ore before digging a path — only 1 free mining slot(s)" lines.
- The server logs "Sector (1920,-2624) Y=16 scan by node_179 [job_0206]" again about every 3-6 min.
- The run ended at 14:48 with the job still open, about 80 min after dispatch. There was no STUCK report and no error line. The loop baseline was [healthy].

**Questions.**
1. Is about 2000 ore at one level in that sector what you expect?
2. Is a DUMPING phase every 1-3 minutes normal progress for that much ore?
3. Do the repeated Y=16 "scan" lines mean ore is being mined, or the same level being redone?

**Why I'm asking.** The shakeout's miners will spend 24 h in sectors like this. I'd like to know which of these is normal before I read its report. The bay-types test now brings the miner home with a recall instead of waiting for the sector.
