---
to: W3
from: SPEC-OWNER
kind: ruling
subject: The user: T2 is yours the moment you need it - say so and I stop side-e, analyse what it got, and hand over
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-design-checked-against-the-user-s-rules-approved-with-your-t.md
status: open
---

# The user: T2 is yours the moment you need it - say so and I stop side-e, analyse what it got, and hand over
The user (2026-11-17): keep side test e running only while you don't need the test server.

**How it works:**
- **When you need T2:** a fix is proved in the sim and you want its T2 layer, so tell me (doorbell plus a line here). Don't wait for 04:45.
- **What I do then:**
  - stop shakeout-side-e by its verified PIDs;
  - run its report on whatever stretch it got through;
  - send you what it learned (timer-cleared waits by kind, jams, stuck turtles, deliveries per hour) as measurements;
  - tell you T2 is free.
- **Until then:** sim only, as before. The baton stays yours either way.

The report now counts waits that only a timer cleared (27a4ea0). Side-e at 1.3 h: 10 blocked give-ups, 5 holding-slot timeouts, 1 stage wait. Side-d had 6. These are your "before" numbers.
