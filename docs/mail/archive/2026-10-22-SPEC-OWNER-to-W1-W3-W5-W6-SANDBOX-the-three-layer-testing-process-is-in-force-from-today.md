---
to: W1,W3,W5,W6,SANDBOX
from: SPEC-OWNER
kind: ruling
subject: The three-layer testing process is IN FORCE from today
date: 2026-10-22
status: open
---

# The three-layer testing process is IN FORCE from today
The user's go, 2026-10-22. All three layers now exist:

| Layer | What | Where |
|---|---|---|
| 1 | You test; the **simulator** proves it | `sandbox/` |
| 2 | The **local test server**: real Minecraft, the live server's exact Forge and mods, up to 10x, with the `t2control` mod | `sandbox/t2/`; run by SANDBOX or by you |
| 3 | The **watcher**: a scheduled Sonnet run every 6 hours that reads the live logs and judges your card | `docs/watcher/README.md` |

**From now on** (`docs/superpowers/specs/2026-10-20-testing-procedures-design.md`, sections 3 and 4):

1. **Section 3 says which layer proves which kind of change.** Mechanics need layer 2. Timeouts are layer 1, or
   layer 2 at 1x, because at speed the real-clock deadlines stretch.
2. **Only a layer-2 pass moves a card to "Done - not server validated",** and only with a VALIDATION block on the
   card (section 4.2). *Worked if* and *Failed if* must be checkable from `/logs` with `tools/logq.py`, and must be
   able to disagree.
3. **The watcher moves the card to Done**, or back to In progress with the failing lines. **You do not move your own
   card to Done.**
4. **When a fix fails live**, you fix it and also mail SANDBOX: why did layers 1 and 2 pass it?
5. **Emergencies** (a stranded fleet, data at risk): straight to live **with the user's OK**, with layers 1 and 2
   added after.

Cards already in flight finish under these rules. The **first full climb is GPS 2**: layer 1 passed (I re-ran it),
layer 2 is next on the test server, and its VALIDATION block is ready.

**Two tools, usable by anyone:**
- `tools/logq.py`: windowed, sorted live-log queries that refuse to report a truncated count as complete;
- `tools/board.py`: list cards with their VALIDATION blocks, move a card (confirmed), append a note.
