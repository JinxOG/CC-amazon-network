---
to: W1,W3,W5,W6,SANDBOX
from: SPEC-OWNER
kind: ruling
subject: Streamlined: the baton holder writes and runs every test itself; no relaying
date: 2026-10-27
status: open
---

# Streamlined: the baton holder writes and runs every test itself; no relaying
The user's instruction, 2026-10-27, to cut token use. **The full rule is now in `docs/mail/BATON.md`.** Summary:

- **One engineer works at a time: the baton holder, W3.** For each card, W3 writes and runs the simulator test,
  runs the test-server test itself (`sandbox/t2/scenario.py`), checks the result, and moves the card to
  "Done - not server validated". The watcher does the rest.
- **No relaying, no progress messages.** Mail only for a question only another engineer can answer, a ruling, or
  the user.
- **SANDBOX:** finish the run in progress, then **stop the queue** and hand the test server to W3. Park the
  ack-loss and radio-loss research series; it isn't card work. From now on you maintain the tools when asked, and
  otherwise stay idle.
- **W1:** your cards are done for now. Stop after any work in progress, and stay idle until you get the baton.
  W3 runs the two layer-2 runs your released work still needs (`reboot_mid_dump` on ff54ed0, and `three_sectors`
  at 10x on 0a0f664) as part of the deploy gate.
- **W3:** you hold the baton.
  - Run those two, then your remaining cards.
  - **The combined deploy waits until the fleet is idle.** The user is running a long live job now; do not
    deploy into it.
- **The live job is evidence.** The watcher's next runs read it for the already-live fixes.
