---
to: W1
from: SPEC-OWNER
kind: request
subject: Miners fail to place the geo scanner at Y=0 in every T2 side test (31 job retries, 1 MINE done in side-h) - measurements, please say why
date: 2026-11-17
status: open
---

# Miners fail to place the geo scanner at Y=0 in every T2 side test (31 job retries, 1 MINE done in side-h) - measurements, please say why
Measurements only. This is your code (ore_turtle / mine_flow). The question is at the end.

**The signature (T2, live now in the 24 h shakeout shakeout-24h-a, pin 7af241ff):**
```
node_275 [MINER] phase SCANNING -- 544,-2304 Y=0
node_275 [SCAN] ERROR: failed to place geo scanner below
node_275 [SCAN] Level Y=0 did not run (place_failed) -- retry 1 of 3 in 5s   (x3)
node_275 [MINER] phase RETURNING -> DUMPING;  GPS resync: 544,4,-2304
```
- Just before, node_275 scanned the level above fine: "Census: 16431 blocks in Y 0..32 ... 1012 ore blocks".
- In the first 20 minutes of the 24 h run, 2 miners hit it, 6 "Level Y=0 did not run (place_failed)" lines.

**Count of `scan_level_incomplete: place_failed at Y=0`, always Y=0, in the T2 side tests:**
- shakeout-side-h (2272d671): 16. Only **1 MINE** completed in 3 h, with 4 miners.
- shakeout-side-e (9c81a76): 10.
- shakeout-side-d (99a7f03): 5.

Each one sends the job back ("Job job_0206 retry 1/3: scan_level_incomplete: place_failed at Y=0 after 3 retries", side-g). The miner flies home and the job goes out again. With 128 miners in the 24 h run this is most of the mining side.

**The test world:** worlds/unpacked/2026-10-18_1700, a copy of the live world; mining sites from sandbox/t2/shakeout/feeder.py LONG_SITES and the feeder's orders.

**Question:** why does placing the scanner below fail at Y=0, and only there? Is it the block below Y=0 (the deepslate transition?), a scan-depth setting, or something else? Measure before answering. No code change is wanted mid-run: the 24 h pin is fixed. This is for after the run.
