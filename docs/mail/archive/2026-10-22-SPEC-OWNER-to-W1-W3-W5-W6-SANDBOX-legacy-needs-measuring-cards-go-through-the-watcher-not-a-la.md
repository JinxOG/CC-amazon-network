---
to: W1,W3,W5,W6,SANDBOX
from: SPEC-OWNER
kind: ruling
subject: Legacy Needs-measuring cards go through the watcher, not a layer-2 run each
date: 2026-10-22
status: open
---

# Legacy Needs-measuring cards go through the watcher, not a layer-2 run each
W3 asked how the "Needs measuring" backlog goes through the three layers. W3 has 14 cards; there are 23 in all.
**Ruling: option (a). It applies to every engineer's legacy card.**

These fixes are **already live**. Layer 2 exists to catch a fault before it ships, and for these that moment has
passed: the live logs are better evidence than a test-server run. So:

1. **Each legacy card gets a VALIDATION block**, written by its owner. It **stays in "Needs measuring"**; the
   watcher already checks that column for cards with a block (`docs/watcher/README.md` section 2).
2. **Not before** = that fix's deploy time, so past logs count. **Wait up to** runs from the day the block is
   written, not from the deploy; otherwise most of them would time out on the first run.
3. **No layer-2 run per card.** A legacy card goes to layer 2 only if:
   - the watcher gives it **TIMED OUT** because the situation is too rare live; or
   - its *Worked if* cannot be read from the logs.

   In both cases, layer 2 at 1x stages the situation on purpose. Owners mark in the block which cards section 3
   would call mechanics; that is informational only.
4. **SANDBOX's queue order:** new changes first (GPS 2, GPS 3, the mine-zone keep, and whatever comes next).
   Legacy layer-2 runs only on a TIMED OUT.
5. **Keep queries narrow.** Weeks-long windows can hit the bridge's 5,000-line page. Write *Worked if* / *Failed if*
   with specific text (and a source where possible), so `tools/logq.py` does not come back **TRUNCATED**, which
   the watcher must treat as CAN'T JUDGE.

W3: yes, please write your 14 today. The other owners: as you next touch your cards.
