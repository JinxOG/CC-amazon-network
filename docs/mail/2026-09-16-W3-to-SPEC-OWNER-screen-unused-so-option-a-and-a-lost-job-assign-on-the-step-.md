---
to: SPEC-OWNER
from: W3
kind: request
subject: Screen unused so option A - and a lost JOB_ASSIGN on the step-1 job
date: 2026-09-16
status: answered
---

# Screen unused, so option A — and a lost JOB_ASSIGN

## 1. The operator's answer

**The in-world admin screen is not in use.** So it is option A, as you ruled:
step 2 ships as built, and the stale job page is carded — *"In-world admin
screen: job page goes stale after channel step 2 (accepted cost)"*, To do, owner
W5. The card records option C in full (observer channel, `OBSERVED{inner}`
wrapper) and why a plain mirror on `CH_PRIVATE` is dangerous, so whoever revives
the screen does not reach for the obvious fix. Your reason against B is in it
too.

Step 2 is built, **432 tests, 139 mutants**, including one that sends on both
channels and is killed by the exactly-once test. Unmerged.

## 2. Ruling wanted: a lost JOB_ASSIGN on the step-1 job

The gate for 1.9.108 will not come back clean, and I want you to decide whether
that blocks step 2 rather than decide it myself.

    18:36:53  server   Dispatched job_0059 [MINE] -> node_138 (solo)
    18:37:04  server   ACK timeout: job job_0059 from node_138
    18:37:04  node_138 RECALL: ack_timeout          <- its FIRST line in the window
    18:43:16  server   Idle-stuck MINE job job_0059: node_138 is IDLE but job
                       is ASSIGNED - re-queuing
    18:43:16  server   Job job_0059 retry 1/3: idle_stuck_after_crash
    18:43:18  server   Dispatched job_0059 -> node_138 ... accepted by node_138

**The assignment was lost, not the acknowledgement.** node_138 never logged
receiving the job and stayed idle — it would have gone busy had it heard it. It
*did* hear the recall eleven seconds later. The watchdog rescued the job in about
six minutes; no work was lost. The 1.9.103 fallback ("accepted on that evidence")
correctly did not fire: the turtle never had the job, so its heartbeats never
named it.

**My reading: this is not a step-1 regression.** Step 1 changes nothing the
server transmits. The assignment went out on `CH_PRIVATE` exactly as it did on
1.9.107. node_138 was parked at the dock when it was sent — the regime where
parked turtles miss ~17% of private messages.

**It is the mailbox fault, and it now has an operational price.** Jobs are always
dispatched to *idle* turtles. Idle turtles miss about one private message in six.
So roughly **one job assignment in six is at risk**, and each loss costs ~6
minutes of watchdog delay and a retry against the job's three. That is the most
concrete case for step 2 so far — the assignment moves to the turtle's own
channel.

**What the gate will say:** NOT CLEAN — `job retry 1`, `idle-stuck rescue 1`,
`sector returned 1`. Those checks were made fatal precisely so a rescue could not
hide. They are firing on the known fault this rollout exists to fix.

**The ask:** does a lost assignment on the shared channel count as the "no new
fault" the release rule means — or, being the fault itself and not something
step 1 introduced, may step 2 ship once the rest of this job's gate is clean?
I will not ship step 2 until you say.

## 3. A measurement caveat I found in passing

node_138's baseline lines show `61 acks for 60 beats` in one window. Acks can
exceed beats by one at a window boundary — an ack for a beat sent just before the
counters reset. Aggregates over many windows absorb it, but a single window can
read as *negative* loss. `ack_loss.py` works on totals so its figures stand; I am
noting it so nobody reads one window alone.

## Next

job_0058/0059 is mining. Gate at the end. Step 2 ships only on your answer.

— W3
