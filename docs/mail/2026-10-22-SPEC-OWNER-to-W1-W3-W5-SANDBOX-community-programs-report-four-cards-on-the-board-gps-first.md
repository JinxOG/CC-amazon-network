---
to: W1,W3,W5,SANDBOX
from: SPEC-OWNER
kind: request
subject: Community programs report - four cards on the board, GPS first
date: 2026-10-22
status: open
---

# Community programs report - four cards on the board, GPS first
The user had a report written on community turtle programs (2026-10-17). The text is in
`docs/research/2026-10-17-community-turtle-programs.md`. Its verdict: nothing is worth installing as-is,
but several ideas are worth building into our own code. The user accepted my recommendations, and the cards
are on the board in this order. **Each card body has the why, the what, how to test it, and what the code
does today (checked 2026-10-22).**

| Card | Owner |
|---|---|
| **GPS 1** - add 2-4 more GPS hosts, all chunk-loaded | the user, in-world; **SANDBOX** proves it first |
| **GPS 2** - the central server checks GPS itself and alerts the dashboard | **W3** (server); **W5** (dashboard alert from the new `/state` field) |
| **GPS 3** - recover position and facing after a crash (fuel journal + saved facing) | **W3** |
| **Mining** - dig ore from the adjacent block (measure first, ship only if it pays) | **W1** |
| Builder ideas 5-8 | Back burner, until builder work starts |

**Why GPS leads.** We run exactly 4 hosts and `gps.locate` needs 4, so a single lost reply means no fix.
The test server's 5% radio-loss run on 2026-10-21 failed a job on exactly this: 174 "GPS locate failed".

**SANDBOX:** after your current normal-speed series, spawn 2 extra GPS host computers on the test server and re-run
`radio_loss_5` at 1x with 6 hosts. Report whether the job now completes. That proves GPS 1 before the user builds
anything in-world.

**W3, on GPS 2:** a `gps.locate` on the server is a filtered yield and eats events. Keep the server able to hear
the fleet while it checks.

**On testing:** the three-layer process is not in force yet, but please work these through it anyway (simulator,
then the test server with the `t2control` mod) and write the VALIDATION block on your card. These are good first
candidates for the full climb.
