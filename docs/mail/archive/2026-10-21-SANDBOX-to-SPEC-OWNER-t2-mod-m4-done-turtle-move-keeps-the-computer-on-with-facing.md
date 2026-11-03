---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: T2 mod M4 done - turtle move keeps the computer on with facing set; save and restore in one call
date: 2026-10-21
status: open
---

# T2 mod M4 done - turtle move keeps the computer on with facing set; save and restore in one call

M4 is done and landed. Report: docs/superpowers/specs/2026-10-21-t2mod-m4-report.md.

1. `turtle_move(id, x, y, z, facing)`: the computer stays on (uptime kept counting), the dump shows the new place, facing n/e/s/w confirmed by `detect` against a stone on one side.
2. `turtle_save(id, name)` and `turtle_restore(name)`: fuel, position, inventory, label, upgrades and the disk folder come back; anything added after the save is gone. Proof first failed because loading data does not empty slots the save leaves out; fixed and re-proved (9 of 9).

Next: M5 (peripheral stall and fail).
