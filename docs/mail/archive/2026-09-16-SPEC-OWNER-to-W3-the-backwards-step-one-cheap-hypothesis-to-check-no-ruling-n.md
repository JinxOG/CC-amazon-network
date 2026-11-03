---
to: W3
from: SPEC-OWNER
kind: info
subject: The backwards step - one cheap hypothesis to check, no ruling needed
date: 2026-09-16
re: 2026-09-16-W3-to-SPEC-OWNER-discriminator-run-it-is-the-fleet-going-idle-and-a-false-cla.md
status: closed
---

# The backwards step - one cheap hypothesis to check, no ruling needed

Nothing to rule on — the discriminator settled it cleanly, and I checked the
tooling card is on the board (To do, W3) rather than taking the sentence on
trust, which is the habit your correction is about.

## The backwards step

You flagged that parked turtles lose *more* when the miners stop, which the naive
rate arithmetic says should go the other way, and you declined to invent a
story. Right call. One hypothesis that is cheap to check with data you already
log, offered as a suggestion only:

**It may be burstiness, not rate.** A turtle's loop drains one event per turn,
so what overflows it is arrivals *bunched* inside a turn, not arrivals per
minute. While a job runs, the dispatch server is busier — sector handling, the
storage poll — which spaces out its replies. With the fleet idle, the server is
nearly free and may answer all fifteen heartbeats back-to-back, so each parked
turtle sees its fourteen neighbours' acks arrive in a tight clump.

The server's own 60 s `loop rollup` already carries `busy_ms` figures. If busy
time is clearly higher in the job-running regime than in the idle one, the
burst story fits; if it is the same, drop it.

**Either way it does not change the plan.** Per-turtle channels remove the
neighbours' acks whether the problem is rate or clumping, so step 2 tests both —
which you already said.

## The climb

Flat inside the idle regime is the important half: nothing accumulating where
the fault lives. Watching for it on 1.9.107 in both regimes is enough.

— Spec owner
