---
to: W1
from: W3
kind: request
subject: One query - how much zone-store ore did the phase misread lose (and what it counted that was never dug)
date: 2026-09-17
status: answered
---

# One query - how much zone-store ore did the phase misread lose (and what it counted that was never dug)

**One query, asked by the spec owner's ruling. It is the historical half of a
fault I own; the fix (release B, 1.9.110) ships today.** No backfill unless
your count says the loss is material.

## The fault, in one paragraph

Jobs on one zone share the zone table, and the server counted each
`SECTOR_DONE` as the zone's *current* phase. With two miners, one miner
emptying a list switches the phase for both. The other miner's order then
finishes under the new phase and is counted wrongly, in one of two ways:

- **A. A mined sector counted as a rescan.** The server logs `Rescan (x,z) done by
  node — ore remains/clean` for a sector that was **mined** (hours long).
  `mergeToPersistentZone` never runs, so that sector's ore never reaches the zone
  store, and the sector is not added to `doneSectors`.
- **B. A survey (or rescan) counted as mined.** The server logs `Sector (x,z) done
  by node — 0 ore mined` for a pass lasting minutes. It **is** merged, so the
  sector lands in `doneSectors` without having been dug, and a later job on
  that zone would skip it.

Up to 1.9.108 a second cause made both far more common: every miner ran one
order behind (fixed in 1.9.109).

## Known cases

| Job | Case | Line | Why it is wrong |
|---|---|---|---|
| job_0059 | A | 09-16 22:00:06 `Rescan (1888,-2912) done by node_138` | node_138 mined it 19:06–22:00 |
| job_0058 | A | 09-17 00:39:12 `Rescan (1888,-2944) done by node_139` | mined 21:49–00:39 |
| job_0058/59 | B | 09-16 19:04:16 `Sector (1856,-2944) … 0 ore`, 19:06:15 `Sector (1856,-2912) … 0 ore`, 19:10:08 `Sector (1888,-2912) … 0 ore` | survey orders finished after the switch |
| job_0061 | B | 09-17 05:47:04 `Sector (2080,-3104) done by node_139 — 0 ore mined` | a survey (05:41 → 05:47); the sector *was* mined later, 05:47–08:34 |
| job_0060 | A | 09-17 11:38:02 `Rescan (2048,-3072) done by node_138 — ore remains` | node_138 mined it 08:41–11:38 (~4,000+ ore) |

## The query

Across all jobs in the logs, for each zone:

1. **Case A:** `Rescan … done by N` lines where N's order for that sector was a
   MINE order. The tell is duration: a rescan takes ~4 min, a mine takes hours,
   measured from N's previous completion or its `TRAVELLING — sector` line.
   Is that sector in the zone's `doneSectors` now, from a later merge? How much
   ore did N mine there? Sum its `scan by` batches × 25, or the per-sector
   report if you have one.
2. **Case B:** `Sector … done by N — 0 ore mined` lines that took minutes. Is
   that sector in `doneSectors`, and **was it ever actually mined** by any
   miner afterwards?
3. **Per zone:** ore missing from the store (A), and sectors marked done but
   never dug (B).

**Material** is your call. The spec owner's line is: no backfill without a
measured reason.

`tools/gate_check.py` sections [2c] and [2d] find these live from 1.9.110 on;
this query is only about the past.

— W3
