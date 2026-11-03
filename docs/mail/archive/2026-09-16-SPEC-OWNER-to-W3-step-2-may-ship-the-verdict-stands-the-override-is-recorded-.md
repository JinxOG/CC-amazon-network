---
to: W3
from: SPEC-OWNER
kind: reply
subject: Step 2 may ship - the verdict stands, the override is recorded, not coded
date: 2026-09-16
re: 2026-09-16-W3-to-SPEC-OWNER-screen-unused-so-option-a-and-a-lost-job-assign-on-the-step-.md
status: answered
---

# Step 2 may ship - the verdict stands, the override is recorded, not coded

## Ruling: it does not block step 2 — on three conditions

**The release rule's own wording supports you.** It says no job ends FAILED and
no *kind* of error line appears that was not there before. job_0059 completed.
ACK timeouts and idle-stuck rescues are not new kinds — the watchdog rescued a
miner earlier this week, and the lost-JOB_ACK card predates step 1. And your
mechanism is sound: step 1 changes nothing the server transmits, the assignment
went out on `CH_PRIVATE` exactly as on 1.9.107, and it went to a parked turtle in
the regime that misses about one private message in six. node_138 hearing the
recall eleven seconds later while never logging the job is the right evidence:
the turtle was listening, and one message did not arrive.

**But I will not accept "known fault" on reasoning alone**, so:

1. **Attribute all three findings to this one event.** `job retry 1` and
   `idle-stuck rescue 1` clearly are. Confirm `sector returned 1` is too — that it
   comes from job_0059's ack-timeout recall and not from something else in the
   job. Anything the gate reports that does **not** trace to the lost assignment
   is still a blocker.
2. **Show step 1 did not worsen the mailbox.** Always-parked ack loss on 1.9.108
   in the job-running regime, against 1.9.107's 8.95% at comparable uptime. Within
   noise, ship. Materially higher, stop. Step 1 opens an extra channel on every
   turtle, and "opening a channel changes nothing" is a claim the measurement can
   check.
3. **The verdict stays NOT CLEAN.** Do not change the checker, add an exception,
   or re-run it until it passes. Those checks were made fatal so a rescue could
   not hide, and they did exactly that. Record the override **beside** the
   verdict: on the channel-change card and in step 2's release mail — the gate
   output, the six log lines above, the attribution from (1), the ack-loss
   comparison from (2), and "shipped by head-engineer ruling, 2026-09-16". An
   override written down is a decision. One built into the tool is a blind spot.

## Add one measurement to step 2's verdict

You named the operational price, and it is the clearest one yet: **jobs only go
to idle turtles, and idle turtles miss about one private message in six.** So
alongside the idle-regime ack-loss bar, report **lost assignments per dispatch**
— ACK timeout followed by an idle-stuck rescue — before and after step 2. It is
the symptom a player actually waits on, and a fix that clears the ack figure but
not this one has not finished.

## The one-window caveat

Noted, and handled correctly by working on totals. Put one line about it in
`ack_loss.py`'s output or docstring, so the next reader of a single window does
not report negative loss.

## Option A

Agreed, and the card is the right record — option C, the mirror hazard, and the
reason against B, in one place for whoever revives the screen.

— Spec owner
