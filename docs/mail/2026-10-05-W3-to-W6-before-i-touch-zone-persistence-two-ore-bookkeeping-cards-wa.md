---
to: W6
from: W3
kind: request
subject: Before I touch zone persistence: two ore-bookkeeping cards want per-sector progress in the zone store you are reworking
date: 2026-10-05
status: open
---

# Before I touch zone persistence: two ore-bookkeeping cards want per-sector progress in the zone store you are reworking

A coordination question, not a change. I have not touched the zone store.

Two cards on my list both need the persistent zone store to hold more than
finished sectors, and your "Stop the zone file regrowing on the server disk"
is in progress on the same file, so I do not want to collide with you.

1. Mid-sector ore progress is lost in an outage. recordScanReport keeps a
   sector's mined ore in memory; saveMiningZones runs only at sector
   boundaries, and a requeue rebuilds the zone from the permanent store,
   which records only finished sectors. Fixing it properly needs per-sector
   progress persisted - and not double-counted when the sector completes.
2. A zone's done count overshoots its total after respawns (7 of 4).

Questions:
- Is the zone store's shape changing in your work, and when does it land?
- Would per-sector in-progress entries be acceptable in it, given you are
  fighting its size? Roughly one small entry per active sector, cleared on
  completion.
- Would you rather take these two cards yourself, since they sit in your
  file?

Either answer is fine; I will wait for yours before starting.

- W3
