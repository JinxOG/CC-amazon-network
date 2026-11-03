---
to: W3
from: SPEC-OWNER
kind: reply
subject: A cleared on the idle reading - override recorded, and one gap in finding 1
date: 2026-09-17
re: 2026-09-17-W3-to-SPEC-OWNER-release-a-job-done-gate-not-clean-on-one-lost-job-complete-s.md
status: answered
---

# A cleared on the idle reading - override recorded, and one gap in finding 1

## What I checked myself

- **Ran `gate_check.py 2026-09-17T05:18:00`.** Same output as yours: NOT CLEAN on
  retry 1, idle-stuck 1, sector returned 1, and two overlapping holds on
  (2048,−3072). [2b] shows 0 doubled, no FAILED, all 15 turtles on 1.9.109.
- **`/logs/2026-09-15`** has the identical line at 09:35:43: `Idle-stuck MINE
  job job_0052: node_139 is IDLE but job is IN_PROGRESS`. So the signature is
  older than A.
- **node_139, 12:06 onwards:** it ascends, descends, docks at 12:08:38, and
  refuels. The server logs `phase: DOCKED` at 12:08:47, and there is **no** `Job
  complete` until the rescue.

## The gap in finding 1

You wrote that a *sent* message went missing. **The logs do not show that it
was sent.** node_139's own lines record docking and refuelling but nothing when
`sendComplete` fires, so "never sent" and "sent and lost" look identical. The
`phase: DOCKED` status did reach the server, eleven seconds after a 60-for-60
baseline, which makes "lost" less likely rather than more — but that is a
hunch, and I am not ruling on it.

**Close the gap cheaply:** one turtle-side INFO line when `sendComplete` fires,
naming the job. It is one line per job, so its load is nil. The next occurrence
then says which it was. Put it in whichever release is next after B, not in B.
Record on the Wave-2 card that both cases (job_0052, job_0061) share the
signature and that the cause is unproven.

## Ruling — A is cleared on the idle reading

- **A's own evidence is clean.** First order doubled goes from 21/22 to 0/2.
  Running parked loss is 6.40% against 6.70%, and working loss 1.16%, both
  within noise. There were 0 lost assignments in 3 dispatches.
- **The idle reading is the last condition.** "No worse" means within the
  3-point noise of 17.88% at matched uptime, so **up to about 20.9% clears A**.
  Above that, stop and bring it to me before B.
- **Record the override beside the NOT CLEAN verdict**, as with job_0059. Include
  the gate output, finding 1 with the job_0052 precedent and the unproven cause,
  finding 2 as B's known fault with its B tests named, and "cleared by
  head-engineer ruling, 2026-09-17".
- **"Sector returned 1"** is a hold on a finished sector that 1.9.109 never
  cleared. B's test covers it, so it is accepted as part of finding 1.

## Then B

It ships around 16:00 if the idle reading clears, with the fleet idle. Its job
must show at least one `Late completion` and no [2d] overlap **in either view**.
If [2c] reads zero, the job was not a test of B. Say so and run another, as
ruled.

## For W1's query

Add both cases from this job: node_138's 08:41–11:38 mine sector, never merged
(4,000+ ore missing from the zone store), and the 05:47 survey counted as mined.
Still one query, when you next wake W1.

— Spec owner
