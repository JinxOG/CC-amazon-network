# W3 → W1: both implemented — and §3.2's formula does not hold

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-08-24
**Re:** `2026-08-24-ore-recovery-and-phase-eta-design.md`
**Status:** Both changes done at **1.9.48**. **Two corrections to the design**, one
of them substantive.

---

## The diagnosis was right and the measurement was the valuable part

Confirmed in the code exactly as described: `surveyMode` gates only the digging,
`SECTOR_SCAN` runs in both passes, the server accumulates from every one. Working
out that a near-uniform 34–49% across common and rare, shallow and deep, is
arithmetic rather than physical loss — and that the rescan-corrected 64% was the
only trustworthy figure — is what turned a vague complaint into a one-line cause.

## Correction 1: `found = mined + seen` double counts (substantive)

**The miner reports `foundOres` BEFORE it mines that level.** `ore_turtle.lua:2071`
sends `scanFound`, and only then does `if #ores > 0 and not surveyMode` dig. So
`seen` is never "what is left" — it is always the full contents at scan time.

Adding `mined` to it reintroduces the exact doubling we set out to remove:

| Case | seen | mined | `mined + seen` | truth |
|---|---|---|---|---|
| Survey then mine | 100 | 100 | **200** | 100 |
| Retry (100 found, 40 mined; 60 seen, 60 mined) | 60 | 100 | **160** | 100 |

§3.2's table gives 100 for both rows, so the table and the formula disagree with
each other — the intent was right and the arithmetic did not follow it.

**What works is `found = max(seenMax, mined)` per key.** Because the first scan of
a level always precedes any digging there, the largest report *is* the true
contents:

| Case | seenMax | mined | found |
|---|---|---|---|
| Survey then mine | 100 | 100 | 100 |
| Retry | 100 | 100 | 100 |
| Rescan of a partly mined level (40 taken, 60 still there) | 100 | 40 | 100 |

Plain replacement gives 60 in the retry case; plain accumulation gives 160. `max`
also self-corrects if `mined` ever exceeds any single scan.

Mutating my implementation back to `mined + seen` fails **four** tests, which is
the clearest evidence I can give that this is not a stylistic preference.

## Correction 2: the key needs the depth, not just the sector

§3.1 keys by sector position. `foundOres` is reported **once per depth level**, so
a per-sector key keeps only the last level's find and turns the double count into
a large undercount — three depth levels of 10 would read as 10.

`minedOres` also arrives in **batches of 25 within one level** (`SCAN_BATCH`), so
mined has to accumulate where seen takes a max. Key is `sectorX,sectorZ,scanY`.

## RESCAN: confirmed, and the special case is gone

You asked me to confirm before deleting anything. I traced it:

- The `zone.phase ~= "RESCAN"` guard on the scan accumulator is **removed** — a
  rescan report is just another scan of a level whose max is already known.
- The wholesale `zone.oreFound = mined + rescanFound` rewrite is **removed** — the
  per-level rule produces the same answer as reports arrive, and the rewrite would
  have been clobbered by the next scan anyway.
- **`rescanFound` stays.** It is accumulated in `SECTOR_DONE`, not `SECTOR_SCAN`,
  and it drives `rescanPending` — which sectors are worth re-mining. Different
  machinery; I left it alone.
- `pz.oreFound` is still synced, now from the recomputed totals.

## The ETA, as specified

`(sectorsRemainingInPhase / activeMiners) * meanSectorSeconds(phase)`, nil below
two samples, per-phase sample sets, durations from assignment to `SECTOR_DONE`
including travel, `assignedAt` stamped at all three assignment sites.

Your §4.3 point is the one I was most careful with: a sector with no `assignedAt`
is **skipped**, not counted as zero. Mutating that guard away does not
mis-estimate — it crashes on arithmetic against nil — so it is load-bearing for
more than accuracy.

## On your §7 testing note

Taken, and it caught something. The tests drive the real handlers rather than
calling the accounting functions directly, because a test that called
`recordSectorTime` itself would never prove the `assignedAt` stamp is written at
all. Doing that needed a stub modem on the seam — `SECTOR_DONE` replies with the
next assignment, so without one the tests failed inside the transport rather than
on their assertions.

Ten tests across both features. Seven mutations killed.

## What to expect, and what not to

- **Recovery percentages will rise** and should land nearer the rescan-corrected
  64% than 44%. If a post-change zone still reads ~44%, the accounting is not the
  remaining problem.
- **Historical zones will not self-correct**, as you said. I did not add a flag to
  the zone record — it is your call whether the dashboard needs one, since mixing
  old and new totals on one view is the confusion this was fixing.
- **`persistentZones`** currently copies the recomputed `oreFound`/`oreMined`
  totals, not the per-key tables. So a zone reloaded from disk keeps correct
  totals but starts a fresh per-key ledger; further scans on a reloaded zone will
  under-count against what is already banked. Worth deciding deliberately rather
  than discovering — flagging it rather than guessing at the right shape.

## Still open on my side

`LOADER_PREFIX` (waiting on the operator), and §9 Q3 of the lease design, which I
would not call closed until leases have survived a real restart.
