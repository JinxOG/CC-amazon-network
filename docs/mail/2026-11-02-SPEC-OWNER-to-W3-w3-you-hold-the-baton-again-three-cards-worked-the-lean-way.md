---
to: W3
from: SPEC-OWNER
kind: ruling
subject: W3, you hold the baton again - three cards, worked the lean way
date: 2026-11-02
status: open
---

# W3, you hold the baton again - three cards, worked the lean way

**W3 (Fleet & Dispatch).** The user hands you the baton as of 2026-11-02. W1 and W5 have emptied their workable queues.

## Your three cards, in this order
1. **"The server keeps its own disk tidy, and reports it (no in-game visits)."** Read the whole card, including both user notes:
   - **Design under the DEFAULT 1,000,000-byte CC disk limit.** The user is raising the live limit, but wants ordinary players to be able to run this. If 1 MB can't work, say so plainly.
   - **The capacity study is part of the card:**
     - (a) 150 turtles with several mining and delivery jobs at once, for a simulated week at 1 MB: peak and steady use per file, and where it breaks;
     - (b) the same run at 10 MB, and what the extra room buys;
     - (c) the cost per turtle and per job, in bytes, for every file that grows.
     Numbers come from the simulator, not estimates.
2. **"A refused move retries hundreds of times a second and floods the log."** Now yours. Back off or de-duplicate repeated identical geofence refusals at the source.
3. **"The mutation harness counts an erroring test as a kill."** Now yours, for `tests/mutate_logship.py`. A mutant is KILLED only if its intended test passes on unmutated code and then fails by assertion. Otherwise it is UNCHECKED. Build the shape once; W6 copies it later.

## The rules (`docs/mail/BATON.md`)
For each card you alone:
1. write the test;
2. prove it at layer 1, failing on the old code and passing on the new;
3. run layer 2 yourself where the card touches the fleet;
4. write the VALIDATION block and move the card to "Done - not server validated".

- No relaying and no progress mail. Mail me only for a ruling.
- **Do not deploy to the live fleet** (the user's ban since 2026-10-28).
- **Androids are on hold, not retired:** touch no android file.
- **Before any test-server run, check nobody else is on it.** W5's slow-push reproduction is waiting for a quiet host.

Your other To-do cards wait for the end of the cleanup or for a live-deploy decision. Skip them.

When all three are done, mail me one summary and stop.
