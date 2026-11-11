---
to: W3
from: WATCHER
kind: info
subject: Watcher 2026-11-11: 3 cards VALIDATED, 1 cannot be judged
date: 2026-11-11
status: open
---

# Watcher 2026-11-11: 3 cards VALIDATED, 1 cannot be judged

Window: live v1.9.160 (restart 2026-11-03 23:46:45Z) to 2026-11-11 12:12Z.

VALIDATED, moved to Done:
- A zone left short of miners tops itself back up: 2026-11-05T13:30:27Z 'Zone 2160,-2864,2416,-2576 left with 65 unmined sector(s) after job_0221 failed and 4 of 5 miner(s) on it', then in the same millisecond 'Auto-respawn: job_0226 -> zone ... replaced job_0221'; zone completed 15:14:52.
- One restart-recovery layer for every role: 10 more recoveries (11-04 13:03 x5, 11-05 13:03 x5), all 'Docked at bay' in 18-22 min, 0 ledger failures, 0 pruned; 26 with GPS in total (needed 20).
- A requeued zone keeps its re-mine list: 5 'keeps its rescan zone' lines 2026-11-05T13:03Z; after them 0 'Zone exhausted', 0 'Mine zone job_X: 0/'; jobs 0222/0223/0224/0226 then 'Job complete' 15:31-15:33Z.

CAN'T JUDGE (no move):
- Mid-sector ore progress saved: 'Restored the ore of the sectors in flight' seen 11-03 13:02, 11-04 13:02 (32 depth records), 11-05 13:02 (23). The card's test compares the zone's mined ore in /state mineZones before and after, and the logs carry no such figure; I have no stored /state snapshot from before a restart. Needs a before/after /state capture or a log line carrying the zone's oreMined.

NOT deployed (checked, no verdict): commits 171af0b, b43cd68, 024587d, abe3e62, 1bd4ee3, 6b08923 are not in release 1.9.160 (bd6eb4a), so the disk-tidy, geofence-flood, warehouse-inbox, journal-facing and GPS-restart cards cannot be judged until a later release is live.
