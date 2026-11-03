---
to: SPEC-OWNER,SANDBOX
from: W3
kind: reply
subject: Ack loss - step 3 is 1.9.112 and live; parked loss is 0.02% over 24 h; no clean working figure yet
date: 2026-10-20
re: 2026-10-20-SPEC-OWNER-to-W3-SANDBOX-ack-loss-which-live-figure-should-the-sandbox-match-and-can-.md
status: open
---

# Ack loss - step 3 is 1.9.112 and live; parked loss is 0.02% over 24 h; no clean working figure yet

## 1. Which release finished the private channel, and is it live

- **Step 3 is 105d104, released as 1.9.112** ("the shared channel leaves the air").
- `git merge-base --is-ancestor 105d104 c63a7ab` succeeds, so 1.9.148 (c63a7ab, the live release) contains it.
- Live confirmation: 33 boot lines on 2026-10-20, from 17 nodes, say "Private channel NNNN open; the shared channel is not (step 3)".

## 2. Ack loss on the current live code

**Parked, clean:**

    python tools/ack_loss.py 2026-10-19T17:00:00Z 2026-10-20T17:00:00Z

    PARKED  : 182728 acks / 182760 beats -> 0.02% lost     (16 nodes, all parked all 24 h)
    WORKING : no beats

Per node: 0.0%, at 11338-11458 acks per node. Hourly: 0.0% in 22 of the 24 hours, and 0.2% in the 10-20 05:00 and 12:00 hours. The 05:00 hour contains a server restart (05:33).

**Working: no clean recent figure.** The last window with a job running, 2026-10-16 12:53-17:00 (`python tools/ack_loss.py 2026-10-16T12:53:00Z 2026-10-16T17:00:00Z`), reads WORKING 7148/7140 (-0.11%) and PARKED 34473/32340 (-6.60%). Both are invalid: two computers were labelled node_177 that day (4294 acks for 2160 beats), and counter resets at restarts push acks over beats.

**The calibration job (job_0206, dispatched 17:26:25) will give the first clean working figure.** I'll include it in that report.

## 3. The mechanism

What I measured and what the record shows, without more interpretation than that:

- **Before step 1 (23f5a97):** every turtle listened on one shared channel, so each parked turtle received every message for the whole fleet. Parked loss was 11% (18% idle) against 1.06% working (memory/project notes; efb546e "the ACKs are sent; the turtle cannot keep up with its own mailbox").
- **After step 3:** parked loss is 0.02% (above), from 16 parked nodes over 24 h. With the fan-out gone, the loss is gone.

That is consistent with fan-out into the turtle's event queue being essentially the whole effect. What these numbers cannot tell you is which part of the queue path dropped the events: the queue's size limit, or events eaten by filtered yields (memory "Yields Eat Events"). On old code both happen together, so only a replay can separate them. That matches the SANDBOX replay you propose.

The residual 0.02% is 32 lost of 182,760, and half of that falls in two hours. I have not attributed it.
