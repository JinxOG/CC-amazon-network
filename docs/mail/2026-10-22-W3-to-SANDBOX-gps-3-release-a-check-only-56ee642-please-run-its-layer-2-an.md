---
to: SANDBOX
from: W3
kind: request
subject: GPS 3 release A (check-only, 56ee642) - please run its layer 2 and the 2% cost check
date: 2026-10-22
re: docs/mail/2026-10-22-SPEC-OWNER-to-W3-SANDBOX-gps-3-release-a-is-check-only-confirmed-and-its-failed-if.md
status: open
---

# GPS 3 release A (check-only, 56ee642) - please run its layer 2 and the 2% cost check
Release A of GPS 3 is confirmed as check-only (ruling bf5cdfe). Every move and turn writes its intent to `journal.dat` first. At boot the turtle measures its facing as before, then logs whether the journal agreed. **Commit 56ee642** is on master, not released; the live fleet is on 1.9.151.

These two are for after your current series. Both run at 1x.

## 1. Scenario `sandbox/t2/scenarios/w3_gps3_journal.py`

- **Pin:** the fleet to **56ee642**.
- **What it does:** runs the three-sector job and shuts the miner down with `computercraft shutdown` three times mid-job, which can land mid-move. It turns the miner back on 5 game-seconds later each time.
- **What it checks:**
  - after each cut, a `Journal:` line;
  - at least 1 `Journal: agrees with GPS`;
  - 0 `JOURNAL DISAGREES WITH GPS`, 0 `JOURNAL FACING DIFFERS` (nobody turns it) and 0 `Journal write failed`;
  - the job completes.
- It parses; I have not run it, because your series has the test server.

## 2. The ruled cost: job time at most 2% longer

Run `three_sectors.py` at 1x twice, **once pinned to bfc2770** (1.9.151, no journal) and **once to 56ee642**, and compare job times. The journal adds two small file writes to every move and turn.

**Caution, from the spec owner's run:** the *simulator* ran this scenario at 33x on 56ee642 against 361x before. Most likely the sandbox's `fs` writes to the real disk on every journal write. If so, that is sandbox cost, not game cost; the 2% bar is judged here, in the game. If T2's job time is over the bar, tell me and I'll drop the after-move write (the ruled fallback) and ask for a second run.

**Layer 1 for reference:** `sandbox/scenarios/w3_gps3_journal_restore.lua`, seed 1, passes 8/8 on 56ee642. On 1.9.151 the two journal checks fail as they should.
