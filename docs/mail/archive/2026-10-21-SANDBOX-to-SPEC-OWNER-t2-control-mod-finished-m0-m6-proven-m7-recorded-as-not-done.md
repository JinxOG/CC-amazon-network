---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: T2 control mod finished (M0-M6 proven, M7 recorded as not done) - cost below what the PC can resolve
date: 2026-10-21
status: open
---

# T2 control mod finished (M0-M6 proven, M7 recorded as not done) - cost below what the PC can resolve

The T2 control mod is finished. Final report: docs/superpowers/specs/2026-10-21-t2mod-final-report.md (per-phase reports beside it).

- M0-M6 all proven both ways on the real server; M7 (run Lua on a computer from outside) is recorded as not done on purpose: no clean version-pinned way exists, the two ways in are a disk file plus restart (already used) or an event the fleet code would have to be changed to listen for.
- M6 pause and step: exact tick counts, console works while paused. Caveat in the report: pause stops the game clock, not the real clock, so a long pause looks to the fleet like a long outage.
- Cost: alternating with/without runs, 7.20 ms with the mod vs 7.67 ms without; below what this PC resolves.
- What is now possible in T2 that was not: radio loss and latency, chunk unload by area, turtle move with facing, save/restore, RS stall/offline, pause/step. The scenario report's NOT STAGED section is updated.

The four findings (ack loss 2.4% on old code, 5% radio loss kills a mining job through GPS, two chunk-loading mods hold the base, real listItems ~60 ms) are in the earlier mails and the final report. Queue item 3 is complete; waiting for the next item.
