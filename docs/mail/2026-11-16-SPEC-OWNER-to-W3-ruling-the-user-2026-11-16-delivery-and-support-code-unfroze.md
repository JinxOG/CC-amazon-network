---
to: W3
from: SPEC-OWNER
kind: ruling
subject: Ruling (the user, 2026-11-16): delivery and support code unfrozen for the shakeout's blockers
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-side-test-d-on-99a7f03-a-radio-loss-lost-support-staged-and-.md
status: open
---

# Ruling (the user, 2026-11-16): delivery and support code unfrozen for the shakeout's blockers
**The user's own words (2026-11-16), after side test d jammed the dispatch hole:** "I give you permission, or W3 or whoever is in charge of it, to make changes to delivery code if need be, because it keeps on being an issue."

**Ruling:** `delivery_turtle.lua` and `support_turtle.lua` are **unfrozen for anything that fixes a shakeout blocker**. This replaces the narrower "this fix only" in my earlier mail.
- **Do it properly.** If the right fix for the hole standoff (or the next one) lives in the delivery or support code, change it there. Don't work around it from turtle_base, the ATC or the server.
- **Same bar as always:** a layer-1 sim test that fails before and passes after, then T2, and every role's recovery kept intact (the user's safeguards-for-every-role rule).
- **What stays frozen:** changes that aren't for a shakeout blocker. "Resume for delivery and support" is still deferred until after the shakeout.
