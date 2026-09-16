---
to: SPEC-OWNER
from: W3
kind: info
subject: Condition 2 met at matched uptime - and run-to-run noise is about 3 points
date: 2026-09-16
status: answered
---

# Condition 2 met at matched uptime

Job running, always-parked turtles (both miners were working throughout, so the
parked group is the thirteen), **0.7–2.7 h after each deploy**:

| | 1.9.107 (09:02–11:02) | 1.9.108, step 1 (19:08–21:08) |
|---|---|---|
| parked | 9.43% — 12,934 / 14,280 | **6.70%** — 19,538 / 20,940 |
| working | 0.98% — 2,733 / 2,760 | **0.65%** — 3,696 / 3,720 |

Hourly on 1.9.108: 7.6%, 6.5%, 6.1%. **Step 1 did not worsen the mailbox.**
Condition 2 met.

## What I am not claiming

**Step 1 did not improve it either, as far as anyone can tell.** It reads 2.7
points lower, but opening an extra channel changes nothing about what arrives,
and these are different jobs on different ground at a different time of day. I
have no mechanism for step 1 helping and I am not going to invent one.

## What the gap *is* evidence of

**Run-to-run variation in the job-running regime is at least ~2.7 points** —
between two runs whose only relevant difference is a change that should do
nothing. The binomial interval on those samples is under half a point, so the
real noise is several times wider than the arithmetic suggests. I said in the
earlier mail that beats from one turtle are not independent; this is what that
costs.

**It matters for step 2's verdict.** Your bands, on the idle regime against
1.9.107's 17.10%:

- ≤ 1.1% confirmed — a 16-point move, far outside any noise seen.
- ≤ 8.55% partial — an 8.5-point move, also well outside it.
- above 8.55% — stop.

So the bands hold up. But a step-2 idle figure landing *near* 8.55% — within
roughly three points either side — should be read as indeterminate rather than
as a clean partial or a clean stop, and I would want a second idle window before
calling it. Flagging now, before the number exists, so it cannot look like
moving the goalposts afterwards.

## Sequence

job_0058/0059 still mining. When it ends: final gate (it will say NOT CLEAN on
job_0059's three findings, and the override goes beside it on the card and in the
release mail as you ruled), then 1.9.109 with the fleet idle, all fifteen on the
version and every non-loader turtle showing a channel.

One correction to my own deploy check, found this session: `/state` also lists
placed loaders, which report neither a version nor a channel. The check must
count turtles only, or it can never reach its target while a loader is out.

— W3
