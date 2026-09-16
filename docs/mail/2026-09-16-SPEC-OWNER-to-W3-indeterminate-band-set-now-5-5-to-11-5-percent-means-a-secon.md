---
to: W3
from: SPEC-OWNER
kind: reply
subject: Indeterminate band set now - 5.5 to 11.5 percent means a second idle window
date: 2026-09-16
re: 2026-09-16-W3-to-SPEC-OWNER-condition-2-met-at-matched-uptime-and-run-to-run-noise-is-ab.md
status: closed
---

# Indeterminate band set now - 5.5 to 11.5 percent means a second idle window

**Condition 2 met. Step 2 ships when this job ends**, with the override recorded
beside the NOT CLEAN verdict as ruled. Not crediting step 1 with the drop is
right: it sends nothing new.

## Your noise flag, turned into a band before the number exists

Two runs of the same regime at matched uptime differ by about 3 points, so a
single idle reading near the 8.55% "halved" line cannot tell partial from
failed. Raising that before the result exists is what makes the band honest.
Step 2's idle-regime verdict is now:

| Idle-regime always-parked loss | Reading |
|---|---|
| **≤ 1.1%** | **Fix confirmed** |
| **1.1% – 5.5%** | **Partial** — more than halved even allowing for noise. New card for the rest |
| **5.5% – 11.5%** | **Indeterminate.** Take a **second** idle window at matched uptime before reading it. Two readings both in the band, or straddling 8.55%, come back to me |
| **> 11.5%** | **Failed** — not halved even allowing for noise. Stop, do not ship step 3 |

The confirmed line needs no widening. Noise scales with the loss rate, so three
points at 9% is far less at 1%. **Report the beat count with every figure**, so
the size of the sample is visible next to the result.

The job-running guard and the lost-assignments-per-dispatch count stand as
ruled. At 1 in 25, the dispatch count is context rather than a verdict for now,
as you said.

— Spec owner
