---
to: W5
from: SPEC-OWNER
kind: request
subject: You hold the baton: the bridge slow-push card, a prerequisite for the shakeout stress test
date: 2026-11-09
status: open
---

# You hold the baton: the bridge slow-push card, a prerequisite for the shakeout stress test

**The user hands you the baton, 2026-11-09.** W3's cards are all through both layers. BATON.md is updated.

## Your card: "Bridge: 107 slow pushes in one test-server run, cause unknown"

**Why now.** The user's next goal is a 24-hour shakeout stress test on the local test server: 160 turtles, constant faults, and the ATC computer. That is about ten times today's bridge traffic. The shakeout's report reads its numbers through the bridge. A push that takes 143 s is 143 s the CC server spends deaf, so this has to be understood before the test.

**One cause is ruled out, by my own measurement.** Host sleep did not cause the 10-27 run.
- I searched the Windows event log for Kernel-Power 42/107/131 from 2026-10-27 00:00 to 10-28 12:00 local. It found nothing.
- That window includes the run's slow-push stretch, 10:18Z to 11:12Z, which is 03:18 to 04:12 local.
- The check can find a sleep when there is one: the same query finds 434 sleep events in the log, which goes back to June, including 10-29, 10-30 and 11-02.

Sleep on mains power has been "never" since 11-03. The one later sleep event, on 11-06 at 05:57, was requested by an application, and a printer driver aborted it within 8 seconds. So the host is quiet now unless someone is using it.

**What I'd like, in your usual cycle (you write and run both layers yourself):**
1. **Reproduce or bound it on the test server.** Use a run with the host otherwise idle, and with as many turtles as you can place (`control.spawn_turtle`) so the load moves toward the shakeout's. Report slow pushes per hour against turtle count.
2. **If it reproduces,** find the cause and fix it.
3. **If it doesn't,** state the bound you measured: turtles, hours, worst push. Then the card can close as "not reproduced at N turtles", with the numbers.

`sandbox/t2/watch_run.py` already fails a run that the host voids, so use it.

## After you

W1 is next, on "After a restart, turtles resume the job where they stand". When your card is done, mail me one summary and stop. I move the baton.
