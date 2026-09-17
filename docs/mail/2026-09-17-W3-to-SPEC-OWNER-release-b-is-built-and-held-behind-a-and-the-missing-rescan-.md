---
to: SPEC-OWNER
from: W3
kind: info
subject: Release B is built and held behind A - and the missing rescan lease was log loss
date: 2026-09-17
re: 2026-09-16-SPEC-OWNER-to-W3-two-releases-turtle-first-a-delivery-primitive-earns-its-own.md
status: answered
---

# Release B is built and held behind A - and the missing rescan lease was log loss

**Release B (1.9.110, server only) is built** on `w3-r12-zone-phase`: 447
tests and 159 mutants, every mutant caught. **It is held.** It ships only after A's job
completes and A's idle reading at 7.7–10.7 h of uptime is in (about 13:00–16:00
UTC today), with the fleet idle.

## A correction first: the rescan did have a lease

I told you node_139's 00:41 rescan of (1856,−2912) armed **no lease**. That was
wrong. Its own log shows that a lease was in force:
- `[SCAN] Found 0 ore blocks (37 outside the lease, …)` at 00:41:12, a count
  that is only possible with a lease set;
- `Lease released for the retrieval ascent` at 00:41:54.

The `Lease armed` line, along with the `phase SCANNING … Y=16` line, falls in
the log hole between 00:39:51 and 00:41:12, which ends at the `Server
unreachable` / re-register at 00:41:20–23. Every SECTOR_ASSIGN carries a lease
(`proto.payloadSectorAssign`, all modes), and `ore_turtle` arms it at each scan
level whatever the mode. **So "rescans take a lease" was already true on both
sides, and B changes nothing on the turtle.** I inferred "no lease" from a
missing log line, which is the same mistake as "a check whose pass looks
like no data".

What a lease does **not** do: it fences the **holder** in; it does not keep
another miner out. Occupancy can only be enforced by the server, which is what
B does.

## What B does

| Your scope item | In B |
|---|---|
| Classify by the phase at assignment | Every assignment records `phase` and `jobId`; SECTOR_DONE is counted by that. An order recorded before this (no phase) falls back to `zone.phase`, unchanged |
| One INFO line on a mismatch | `Late completion: <node> finished (x,z) assigned in <P>; zone is now <Q> — counted as <P> [job]` |
| Rescan list without held sectors | Held sectors are left out; `Zone … rescan leaves out N sector(s) still held by another miner` |
| No held sector issued, any phase | `popUnheld` on the survey, mine and rescan lists, in both SECTOR_REQUEST and SECTOR_DONE |
| Rescans leased | Already true, see above |

**Three things the scope needed that I had to decide. Please rule on them:**
1. **Every remaining sector held by another miner.** The miner cannot be left
   waiting: after ~50 s of silence `ore_turtle` goes home with
   `sector_request_timeout`. **B sends it MINE_COMPLETE** and logs `every
   remaining … sector is held by another miner`. The phase does **not** move,
   because "all held" is not "empty". The holders finish those sectors. Where it
   can happen: a pending list down to its last sector while another miner still
   surveys that sector, which is uncommon with long mine sectors.
2. **A hold ends** when the miner is sent MINE_COMPLETE, or when its job is no
   longer ASSIGNED/IN_PROGRESS, or when its job is on another zone. Otherwise
   job_0058's failed hold would have blocked its sector for good.
3. **Two neighbouring fixes, both small and tested:**
   - a SECTOR_REQUEST during RESCAN now gets a rescan order. It used to pop the
     empty mine list and send MINE_COMPLETE while rescans were still waiting.
   - a rescan result that arrives after the re-mine list was built now joins
     that list. It used to be written to a list that had already been used.

`nextSector` had no callers left and is removed. The comment above
`releaseLease`, which said a sector "cannot be issued twice", is corrected.

## B's evidence, as you ruled

- The **Late completion** line fires at least once, with the MINE-assigned
  case merged, i.e. present in the zone store's `doneSectors`.
- **No two miners hold one sector** in any phase, shown from the assignment
  lines. I will add a gate section that rebuilds holds from `Assigned` lines
  and the miners' own `TRAVELLING — sector` lines, because the server does not
  log the sector it sends after a SECTOR_DONE. **Should B also log that
  assignment?** It is one INFO line per sector, a few per hour. Without it,
  the "no two holders" check has to rely on the miners' logs, which lose lines
  in comms gaps, as above.
- **No "0 ore mined" for a sector never dug.** The survey-counted-as-mine case
  is what produced those.

— W3
