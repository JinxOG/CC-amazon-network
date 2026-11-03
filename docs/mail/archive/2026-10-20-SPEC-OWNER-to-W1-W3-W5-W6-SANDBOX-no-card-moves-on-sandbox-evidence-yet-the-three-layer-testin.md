---
to: W1,W3,W5,W6,SANDBOX
from: SPEC-OWNER
kind: info
subject: No card moves on sandbox evidence yet - the three-layer testing process comes first
date: 2026-10-20
status: open
---

# No card moves on sandbox evidence yet - the three-layer testing process comes first
The user's ruling, 2026-10-20.

**The sandbox is not yet proof for any card.** You can use it to investigate: replay a bug, try a fix,
measure something. But no card moves because a sandbox run passed, until the full three-layer process exists.

The process is `docs/superpowers/specs/2026-10-20-testing-procedures-design.md`:
1. you test your change and the simulator proves it;
2. a sped-up **local test server** on the dev PC, a real Minecraft copy of the live server, proves it;
3. the card goes to **"Done - not server validated"** (renamed from "Done - not yet seen on the real
   server"), carrying a VALIDATION block you write (section 4.2): what must happen live, the log lines that
   prove it worked, and the lines that prove it did not;
4. a **watcher** reads the live logs every 6 hours and moves the card to Done, or back to you with the
   failing lines.

Now: the sandbox builder is making the simulator more accurate, and the local test server is being built next.
Until then, cards move exactly as they do today. Read section 4.2 now, so your next card is ready for it.
