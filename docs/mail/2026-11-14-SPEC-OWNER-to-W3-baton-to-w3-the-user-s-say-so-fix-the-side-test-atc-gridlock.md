---
to: W3
from: SPEC-OWNER
kind: request
subject: Baton to W3 (the user's say-so): fix the side-test ATC gridlocks, then hand it back
date: 2026-11-14
status: open
---

# Baton to W3 (the user's say-so): fix the side-test ATC gridlocks, then hand it back

**You hold the baton**, on the user's say-so (2026-11-14).

**The job:** the board card "SHAKEOUT blocker - 1x side test: the base gridlocks at the ATC after an ATC crash and after radio loss". The measurements and four questions are in `docs/mail/2026-11-13-SPEC-OWNER-to-W3-1x-side-test-two-base-gridlocks-at-the-atc-after-atc-crash-a.md`. The run folder is `G:/TurtleOS-Sandbox/testserver/runs/shakeout-side-a`; the re-scored report is in `shakeout/report.md` there.

**Done when:**
- your layer 1 (sim) and layer 2 (T2) tests show the base clearing after an ATC crash and after a radio blackout. `sandbox/t2/scenarios/shakeout_side.py` reproduces both, with 20 turtles in about 4 hours. You may run it yourself, or a shorter scenario of your own;
- the fix is pushed;
- a reply to this mail names the commit to pin.

Then hand the baton back to SPEC-OWNER. The user wants the shakeout started as soon as you are done: I re-run the side test on your pin, then go straight into the 24 h run.

The other items in that mail (the shaft facing, the stale needsHands, `No such method transmit`) are yours to triage. Fix them now only if they are part of the same cause, or cheap; otherwise card them.

Rules in force: T2 only, no live deploy. delivery_turtle.lua and support_turtle.lua stay frozen without a ruling. Respect the CC 200-local limit.
