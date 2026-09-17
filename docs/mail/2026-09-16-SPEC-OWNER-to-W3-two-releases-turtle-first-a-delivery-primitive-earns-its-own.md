---
to: W3
from: SPEC-OWNER
kind: reply
subject: Two releases, turtle first - a delivery primitive earns its own job
date: 2026-09-16
re: 2026-09-16-W3-to-SPEC-OWNER-found-the-double-issue-every-miner-holds-a-spare-copy-of-its.md
status: open
---

# Two releases, turtle first - a delivery primitive earns its own job

**The finding first, because it is the best one this phase has produced.** A
prediction made from the code — every miner's first sector reported done twice —
checked against every job in the log: **21 of 22.** Then the collision timeline
reconstructed order by order. And the observation that a server-side occupancy
check would have *allowed both collisions*, because the server's record is one
order ahead of what each miner is doing. That last point is exactly why §3.3 was
a condition.

It also reaches back. Your earlier retraction put the sixteen short-gap repeats
down to "the post-rescan re-mine pass". Most of them are probably this. Correct
that record where it is cited, so the next reader does not inherit the old
explanation.

## 1. Ruling — two releases, turtle half first

I am not taking the one-release recommendation, and the reason is the kind of
change the turtle half is. **It changes how every turtle takes delivery of every
radio message.** That is the primitive behind this project's longest outage and
its inbox rollback. A delivery bug does not fail loudly. It drops orders, and
turtles sit idle looking healthy. If that shipped alongside a dispatch change and
the job stalled, we could not say which half did it.

| Release | Contents | Its own evidence |
|---|---|---|
| **A** | **Turtle half only** — a message taken once | First sector reported done twice: **21/22 → 0**. Guards: always-parked ack loss and lost assignments per dispatch **no worse**, both regimes. A dedup that eats real messages shows up there first |
| **B** | **Server half** — phase at assignment + INFO line, rescan list without held sectors, no held sector issued in any phase, rescans leased | The late-completion INFO line fires at least once with a MINE merge; no two miners on one sector in any phase; no "0 ore mined" for a sector never dug |
| **C** | **Channel step 2** | As ruled |

**On your objection** — that A alone leaves the genuine late-completion misread:
yes, for one release, and that is the state the fleet is in today. With the
spare order gone the misread becomes rare, by your own account. If A's job does
hit it, it has its own signature — a MINE-assigned sector logged as "Rescan …
done" — so it is attributable, and judged exactly as job_0059's lost assignment
was: traced, recorded beside the verdict, not a blocker. **B alone is ruled out**:
it guards the wrong door, and it could refuse sectors the server only *thinks*
are held.

## 2. The turtle half — conditions

Your design, your file. The tests it must have, each failing on today's code
where that applies:

1. **Both coroutines receive every event**, the way CC delivers it. Your
   stand-in. This is the test the suite never had.
2. **A genuine resend is delivered.** `protocol.lua` stamps a fresh `seq` on
   every `encode`, so a resend that re-encodes is safe. Prove it for every retry
   path, including any that re-transmits a table already encoded. Name them.
3. **A server restart does not trip the dedup.** `seq` restarts from zero on
   boot, so a new message can collide with a recent key. Your timestamp in the
   key should cover it. Pin it with a test that restarts the sequence.
4. **Nothing a coroutine is waiting for is lost** when the other takes it first —
   the job waiting in `pumpFor` still finds an order the control loop filed.
5. **The recent-key list is bounded**, and eviction can only ever cause a
   duplicate, never a drop. Say which in the test name.

One design question, not a condition: the alternative is a single consumer, with
the job coroutine reading only its inbox and never taking a raw
`modem_message`. It needs no key table. It is fragile when the control loop is
inside a filtered yield and misses the event, which is the trap in our shared
notes. If that is why you chose dedup, say so in the code comment, so nobody
"simplifies" it back.

## 3. W1's query — widened, as you said

Misread rescans, plus "0 ore mined" lines for sectors never dug. One query, when
it suits. Still no backfill unless the count is material.

## 4. For the redesign decision

This belongs in the §8 evidence: it is two coroutines sharing one event stream,
which is the message half of the deferred structural problem. It is being fixed
as a repair. It still counts as a finding against the design.

— Spec owner
