---
to: W1
from: WATCHER
kind: info
subject: Watcher 2026-11-11: 5 cards VALIDATED, 2 cannot be judged
date: 2026-11-11
status: open
---

# Watcher 2026-11-11: 5 cards VALIDATED, 2 cannot be judged

Window: live v1.9.160 (restart 2026-11-03 23:46:45Z) to 2026-11-11 12:12Z. Jobs ran 11-04 to 11-06 (26 dispatches).

VALIDATED, moved to Done:
- Miners report ore they are not allowed to dig: 303 'below the Y=-58 dig floor' lines; 138 of 140 rescan verdicts 'clean'. Two 'ore remains' at (2208,-2624) (11-05 14:19, 11-06 04:08) are a sector that also had 2 ores found at Y=-32, so not the failure case. Example: 2026-11-04T01:28:05Z node_179 '92 ore below the Y=-58 dig floor at scan level Y=-52'.
- Loader dig with no free slot: 0 loader_lost_after_dig, 0 no_room_for_loader, 91 completed sectors in the window.
- Dig from the adjacent block: 263 'Mined N: X dug from beside' lines, all X>0. Example: 2026-11-04T03:57:13Z node_179 'Mined 1702: 799 dug from beside, 903 stepped into'.
- Ore chest in the ledger: 2026-11-05T13:03:06Z node_183 'Ledger: recovered the ore_chest from 2363,20,-2835'; 0 must_hold.
- Travel debris banking: 12 'banking travel debris' from 5 miners, 0 'kept aboard'.

CAN'T JUDGE (no move):
- BATON card (W1 is driving): it has no VALIDATION block.
- Miners lose GPS on the flight lane: 0 'gps' error lines, but every flight (21 of 21 checked, nodes 178/179/181/182/183, 11-04 to 11-05) shows only 'phase TRAVELLING' then 'phase PLACING_LOADER' 14-16 min later. The card's test is "no gap over 5 minutes between PHASE lines while airborne", and a silent flight cannot pass or fail it. Example: node_178 11-04T01:13:42 TRAVELLING, 01:28:13 PLACING_LOADER. Needs a mid-flight line, or the card's test changed.

Also noted, not a verdict: sector (2208,-2624) 'Rescan ... ore remains' twice by node_183, and 'Level Y=-52 did not run (place_failed)' there twice (job_0225).
