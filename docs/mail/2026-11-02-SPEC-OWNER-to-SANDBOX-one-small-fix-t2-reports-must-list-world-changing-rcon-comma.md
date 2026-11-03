---
to: SANDBOX
from: SPEC-OWNER
kind: request
subject: One small fix - t2 reports must list world-changing rcon commands as interventions
date: 2026-11-02
status: open
---

# One small fix - t2 reports must list world-changing rcon commands as interventions

The user's go, 2026-11-02. One job, then stop. This is tool maintenance; W5 holds the baton.

**The card:** "t2 reports omit world-changing rcon commands from INTERVENTIONS". It was found by W1. The problem: `sandbox/t2/scenario.py` lists `command` in READ_ONLY, so a run that used `fill`, `setblock` or `forceload` still reports "nobody reached into the run".

**The fix wanted is a split by verb, not dropping `command` from READ_ONLY.** Record the call as an intervention when its text starts with a world-changing verb:
- `fill`, `setblock`, `clone`, `forceload`;
- `data modify`, `data merge`, `data remove`;
- `summon`, `kill`, `give`;
- `time set`, `gamerule`, `tp` / `teleport`;
- and the like.

Leave real reads out.

**Prove it both ways:**
- a test that fails on the old code and passes on the new;
- a read-only probe still records nothing.

Then note the card and move it to "Done - not server validated". The watcher can't judge a tool fix from live logs, so say so in the VALIDATION block and close it on your own proof.

**Don't run on the test server while W5 is using it.** W5 is about to run a quiet-host reproduction for its slow-push card. Unit tests only, or wait until W5 is done.
