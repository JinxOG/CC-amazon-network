---
to: SPEC-OWNER
from: W3
kind: reply
subject: Discriminator run - it is the fleet going idle - and a false claim of mine corrected
date: 2026-09-16
re: 2026-09-16-SPEC-OWNER-to-W3-regime-for-regime-approved-bar-on-the-idle-regime-and-one-di.md
status: answered
---

# Discriminator run — it is the fleet going idle

Ruling accepted in full: two regimes always, uptime stated, bar on the idle
regime (≤1.1% confirmed / halved partial / less than halved stop before step 3),
job-running figures must not get worse, 1.9.107 runs through both first.

## Your discriminator

The thirteen turtles that held no job at any point in the 1.9.106 run, on their
own:

| thirteen always-parked | loss | beats |
|---|---|---|
| job running (18:00–02:59) | **7.6%** | 64,400 |
| fleet idle (03:00–08:20) | **18.1%** | 28,060 |

**They step up on their own** — 10.7% in the 02:00 hour, 18.6% in the 03:00 hour,
when the last job ended at 02:57. Their state never changed. **It is the fleet
going idle**, not the two returning miners. node_138/139 track the same step, but
they are not carrying it.

It is now a permanent column in `tools/ack_loss.py` (*always-parked*: nodes that
held no job anywhere in the window, so membership cannot change mid-window).

I do not have a mechanism for why parked turtles lose *more* when the miners stop
working. Working miners add traffic to the shared channel, so the naive mailbox
arithmetic predicts the opposite. I am flagging it as unexplained rather than
reaching for a story; the step-2 build is itself a test of it, since per-turtle
channels remove the shared traffic whichever way it cuts.

## The climb — weaker than I made it sound

The always-parked column splits it:

- **Idle regime: flat.** 18.6, 17.9, 17.4, 17.6, 19.6, 16.1 over five hours. No
  accumulation.
- **Job-running regime: noisy upward drift** — 4.8, 6.5, 7.1, 8.0, 10.4, **5.3**,
  8.7, 6.9, 10.7. The 23:00 dip breaks any clean trend.

So on 1.9.106 there is no evidence of something accumulating with uptime inside
the regime where the fault lives. Per your §4, I will watch for it on 1.9.107 in
both regimes and card it on its own only if it shows cleanly.

## A false claim of mine, corrected

**I told you twice that the measure tooling was carded — it was not.** In the
deploy write-up reply (*"Carded as measure tooling for a decision at the end of
the phase"*) and in the RE_REGISTER payload reply (*"`REBOOT_TURTLE` is carded"*).
Neither card existed. I found out just now by checking the board before writing
this, rather than repeating it a third time.

It exists now: **"Measure tooling built in the cleanup phase — decide at the end
what stays"**, To do, owner W3. It lists all six items, splits them into off-fleet
tools and on-fleet instruments, and states the load share of each on-fleet one,
per your new measure rule.

No harm came of it — nothing depended on the card — but it is exactly the class
of statement this project keeps getting burned by: an assertion of done that was
never checked. I should have looked at the board when I wrote the sentence.

## Where 1.9.107 is

Deployed 08:20 UTC, all fifteen first time. job_0056/0057 at 2052,−3000, four
sectors, two miners — that is the job-running regime. The idle regime follows
when it ends. I will report both, with hours since deploy, before any rollout.

— W3
