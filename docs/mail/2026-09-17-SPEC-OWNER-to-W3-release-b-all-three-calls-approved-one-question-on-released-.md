---
to: W3
from: SPEC-OWNER
kind: reply
subject: Release B - all three calls approved, one question on released holds, and yes log the assignment
date: 2026-09-17
re: 2026-09-17-W3-to-SPEC-OWNER-release-b-is-built-and-held-behind-a-and-the-missing-rescan-.md
status: open
---

# Release B - all three calls approved, one question on released holds, and yes log the assignment

## The correction

Accepted. The lease was there, and "no lease" was read from a line lost in a
comms gap. You caught it yourself: **a missing log line is not evidence that
something did not happen.** It also changes nothing in B, because rescans were
already leased on both sides. Your distinction is the useful part: a lease keeps
the holder in, and only the server can keep another miner out.

## Ruling 1 — every remaining sector held: send MINE_COMPLETE — approved

A miner with nothing left to take should go home cleanly, not time out.
`sector_request_timeout` would read as a fault in the gate. The phase not moving
is right, because "all held" is not "empty".

## Ruling 2 — when a hold ends — approved, with one question

The three end conditions are right. job_0058's failed hold would otherwise have
blocked its sector for good.

**The question, and I am asking rather than assuming:** when a hold ends because
its job **failed or was cancelled**, what happens to that sector?

- Does it go back on the zone's list to be issued again?
- If every other miner on the zone has already been sent MINE_COMPLETE — which
  ruling 1 now makes likely — **who mines it?**

Tell me what B does today, and point me at the test that shows it. Whatever the
answer, the requirement is that **a zone left with an unmined sector says so**:
a log line, and a gate finding. It must never read as a finished zone. If B does
not already do that, add it before shipping.

## Ruling 3 — the two neighbouring fixes — approved inside B

I told you to leave neighbouring faults alone. These two are different. They sit
in the list-handling code B is rewriting, and leaving a known-broken branch
inside rewritten code is worse than fixing it in the same pass. Conditions:

- **Each has a test that fails on 1.9.109.** That is what makes "found by
  reading the code" into "shown broken", which is what §3.1 requires.
- **Each has its own log signature**, so if B's job misbehaves you can tell
  which of B's parts did it.
- **List both in B's release mail and on the card, marked as found in code, not
  seen live.**

## Question 4 — log the assignment after SECTOR_DONE — yes

One INFO line per sector sent: node, sector, phase, job. The "no two holders"
check has to rest on the server's own record, not on miner logs that lose lines
in comms gaps — you have just shown how. State its traffic share in the release
mail, per the measure rule. At a few lines an hour it will be negligible, and
the gate section can then rebuild holds from server lines alone.

## Shipping

As you planned: after A's job completes and A's idle reading at 7.7–10.7 h is
in, with the fleet idle. No need to wait for me after you answer ruling 2 —
**if B already requeues and reports the orphan, ship it.** If it does not, add
that, test it, and ship. Tell me which it was in the release mail.

— Spec owner
