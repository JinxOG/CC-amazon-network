---
to: SPEC-OWNER
from: W3
kind: reply
subject: job_0060/0061 are progressing - the scan-by lines are mined-ore batches, not scans
date: 2026-09-17
re: 2026-09-17-SPEC-OWNER-to-W3-job-0060-and-0061-is-this-progress-measurements-only-no-theo.md
status: open
---

# job_0060/0061 are progressing - the scan-by lines are mined-ore batches, not scans

**They are progressing. This is a rich level being mined, not a loop.** Each
check below says what I looked at, so you can repeat it.

## 1. "scan by" does not mean a scan

The server writes `Sector (x,z) Y=n scan by …` for every **SECTOR_SCAN**
message (`central_server.lua`, the SECTOR_SCAN handler). A miner sends that
message in two cases:
- **once per scan level** with ore *found*, which is the single lines on the
  surveyed sectors;
- **once per 25 ores *mined*** while it works a level (`ore_turtle.lua`,
  `SCAN_BATCH = 25`, `flushScanBatch`). The `Y` is the level being mined, not a
  new scan.

The actual scans are the miner's own `[SCAN] Scanner placed` / `Found N ore
blocks` lines. There are **6 per miner** since 05:40: 2 or 4 survey levels,
then one per mine level. So the 95 lines at Y=16 are 95 batches of mined ore.
A repeat scan would show up as repeated `Found` lines, and there are none.

## 2. The ore count matches the level being finished (node_138, 2080,−3072)

| Time | Miner's own line | Server "scan by" at that level |
|---|---|---|
| 05:47:14 | `[SCAN] Found 2363 ore blocks` at Y=16 | 95 batches, 05:47:14 → 07:07:47 → **95 × 25 = 2,375 ≈ 2,363** |
| 07:08:27 | `[SCAN] Found 786 ore blocks` at Y=0 (a new level) | 17 batches so far, 07:08:27 → 07:21:41 → 425 of 786 |

It worked through level Y=16 until the ore was used up, then **moved down to
Y=0** 40 seconds later and scanned it once. That is the advance you asked about.
Your table has the Y=0 lines last for the same reason. node_139 on (2080,−3104)
shows the same shape: 97 batches at Y=16 until 07:09:55, then its Y=0 batches.
Its four single lines at 05:43–05:44 are the **survey** of that sector.

## 3. The rates agree with each other and with earlier jobs

- One batch every ~45 s is **~33 ores/min per miner**.
- The zone store (`/state` mineZones, `oreMined`) at 07:25 reads **5,417**,
  about 110 batches each × 25, so the two miners' reports account for it.
- Previous full sectors: 4,000–4,500 ore in 2.5–3 h (job_0048: 4226, 4126,
  4009; job_0058/9: 4272, 4513). Both miners are about 1.5 h in, so
  **done 1 of 4 is expected**. The 1 is the survey misread from my last mail,
  not a mined sector.

## 4. DUMPING every ~2 min is a full inventory

39 DUMPING lines in 50 min is one every ~77 s–2 min. It starts after a run of
batches and is followed by more batches, so the miner fills up, empties into
its ore chest, and carries on. At 33 ores/min, a few stacks fill in that time.
It would only be a fault if it were **not** followed by more batches, and every
one is.

## 5. Nothing else is wrong

No ERROR, FAILED, recall or ACK timeout since 05:18. Both miners report
**57–59 acks for 60 beats** in their loop baselines. The watcher shows the zone
total rising every 3 minutes without a gap since 05:49.

## One correction on my side

My watcher's "mined" figure adds the two jobs' zone entries together. They are
one shared zone, so it shows **twice the real total** (10,484 vs 5,417 at
07:20). The rate is right; the absolute number is doubled. That only affects my
progress line, not any verdict figure.

**Answer: advancing, level by level.** It would be a loop if the same level
had repeated `Found` lines, or batches continued past the found count with
no new level. Neither is true.

— W3
