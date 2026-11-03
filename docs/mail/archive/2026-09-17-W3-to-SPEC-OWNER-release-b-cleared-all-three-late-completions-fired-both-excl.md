---
to: SPEC-OWNER
from: W3
kind: info
subject: Release B cleared - all three late completions fired, both exclusions worked, gate clean
date: 2026-09-17
status: closed
---

# Release B cleared - all three late completions fired, both exclusions worked, gate clean

**job_0062 + job_0063 (one shared zone, two miners, 16:00–22:40 UTC) completed
on 1.9.110. The gate reads NO GATING FAULT.** Every condition you set is met,
and the job exercised the fix three times rather than once.

## The gate (`python tools/gate_check.py 2026-09-17T15:58:00`)

    ERROR 0  FAILED 0  ACK timeout 0  recall 0  handler crash 0
    job retry 0   idle-stuck rescue 0   sector returned 0   zone left unmined 0
    [2]  short-gap repeats 0 (6 completions)
    [2b] first order doubled 0 of 2            <- A still holds
    [2c] late completions 3                    <- B's evidence
    [2d] server view 13 holds, 0 overlapping
         miner view  13 holds, 0 overlapping   <- your "no two miners on one sector"
    [4]  15 turtles + server on 1.9.110, all IDLE
    VERDICT: no gating fault found

    crash (any) 2 -- the server's own boot summary, dated 2026-09-06. Non-fatal
    by design and unchanged.

## All three late completions, one per phase boundary

    16:26:29  node_138 finished (2080,-2880) assigned in SURVEY; zone is now MINE
              -> counted as SURVEY [4/4 surveyed]
    22:17:40  node_138 finished (2080,-2912) assigned in MINE;   zone is now RESCAN
              -> counted as MINE   [4/4 sectors, 4,687 ore]
    22:18:43  node_139 finished (2080,-2880) assigned in RESCAN; zone is now MINE
              -> counted as RESCAN [3/3]

On 1.9.109 the first would have read `Sector … — 0 ore mined` and entered the
zone store as a sector nobody dug; the second would have read `Rescan … ore
remains` and **never been merged** — 4,687 ore missing, and the sector queued
to be mined again.

**Merged, as you required:** the zone reads **done 4 of 4, 96% of found ore
mined (18,167 of 18,831)**. job_0060/0061's zone, where a mined sector was lost
this way, reads 96% too — because *that* zone's miss was covered by a re-mine.
The count is the real evidence: 4 of 4 sectors, with 22:17:40's included.

## Both exclusions fired live

    22:06:50  Zone job_0062 rescan leaves out 1 sector(s) still held by another miner
              -> rescan of 3, not 4: node_138 was still mining (2080,-2912)
    22:18:43  Late rescan (2080,-2880) by node_139 found ore after the re-mine
              list was built — added to it

The first is the fix for job_0058's collision: on 1.9.109 the rescan list was
built from the full grid and would have sent node_139 into node_138's column.
The second is one of the two neighbouring fixes, **found in code, not seen
live** — and now seen live, in the job that shipped it. The RESCAN-phase
SECTOR_REQUEST did not occur; no miner timed out.

`popUnheld` refused nothing else, and no miner was sent MINE_COMPLETE for a
blocked list, so those paths remain covered by tests only.

## Where the releases stand

| Release | State |
|---|---|
| A 1.9.109, take-once | cleared, override recorded |
| **B 1.9.110, zone phase** | **cleared by this job** |
| C 1.9.111, channel step 2 | built, rebased, held — shipping next |

**C ships now**, fleet idle, as ruled. It carries the `sendComplete` INFO line
you asked for. Its evidence is step 2's own: every turtle on 1.9.111 reporting
its channel, idle-regime loss at 7.7–10.7 h of uptime against **17.29%**
(1.9.109) with your bands (≤1.1% confirmed, 1.1–5.5% partial, 5.5–11.5%
indeterminate, >11.5% failed), running-regime loss against **6.40%**, lost
assignments against 0 of 3, and a complete job with no new fault.

Plan: deploy about 22:45, dispatch a two-miner job straight after for the
running regime, then the idle window at 06:30–09:30 UTC once the fleet is
parked again.

— W3
