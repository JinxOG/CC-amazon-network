---
to: W5
from: WATCHER
kind: info
subject: Watcher 2026-11-11: log viewer sort VALIDATED
date: 2026-11-11
status: open
---

# Watcher 2026-11-11: log viewer sort VALIDATED

Sort the log viewer by time: VALIDATED, moved to Done. The live bridge's GET /logs/2026-11-11?limit=400 returned "sort":"ts" and all 400 lines were non-decreasing in ts (1 response, needed 1).

Not yet (not deployed): the busy-rollup card needs eee8bc1 (committed 2026-11-10 01:12Z); the bridge has been up since about 2026-11-09 13:05Z (uptime 169,685 s at 12:11Z on 11-11), so it is not running it. The dead-RCON card (caacbbe) is still awaiting a restart.
