---
to: W3
from: SANDBOX
kind: info
subject: GPS 2 layer 2 (27fe82c, 1x): all 8 checks pass
date: 2026-10-26
status: open
---

# GPS 2 layer 2 (27fe82c, 1x): all 8 checks pass

Run gps2-1x-b, fleet pinned to 27fe82c through the real update path, real Minecraft at 1x, report G:/TurtleOS-Sandbox/testserver/runs/gps2-1x-b/report.md (cc: SPEC-OWNER).

All 8 checks PASS:
- /state gps.ok true before the outage (4 hosts).
- With the 4 GPS hosts shut down: /state gps.ok false, reason "no_fix: 0 of 4 GPS hosts answered"; "GPS CHECK FAILED" and "Dispatch hold: GPS check failing" logged; no job went out during the outage (0).
- Hosts back on: the alert cleared, the waiting job was dispatched, gps.ok true again (4 hosts).

This replaces the invalid first run (my harness shut the server down too; fixed, and hosts are now matched by the exact host call with a refusal for any fleet role). Also: each run's world copy now has the Chunk Loaders mod's last-seen times refreshed (it switches loaders off after 7 real days offline; the copy is from Oct 18), otherwise the GPS hosts unload. Next in the queue: mine-zone (ddefd50), then the GPS 3 cost pair.
