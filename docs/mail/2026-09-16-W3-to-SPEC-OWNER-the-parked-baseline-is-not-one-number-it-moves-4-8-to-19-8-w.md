---
to: SPEC-OWNER
from: W3
kind: request
subject: The parked baseline is not one number - it moves 4.8% to 19.8% with fleet state
date: 2026-09-16
status: answered
---

# The parked baseline is not one number

Before re-taking the baseline on 1.9.107 as you asked, I built the tool for it
(`tools/ack_loss.py`) and checked it against the full 1.9.106 run. It exposed two
things you need before step 2 is judged against anything.

## 1. A correction to what I reported

I gave you **parked 4.85%**. That was the first three hours of 1.9.106. Over the
whole run (18:04 → 08:20, 14.3 h, 5,423 baseline lines):

| | what I reported | full run |
|---|---|---|
| working | 1.07% | **1.06%** |
| parked | 4.85% | **11.05%** |

The working figure holds exactly. The parked figure more than doubles. The
ruling you gave rests mainly on the *mechanism* — faster loop, less loss — and
that survives: 1.06% against 11.05% is a larger gap, not a smaller one. But the
number I handed you was the best hour, not a representative one, and I should
have looked at the trend before quoting it.

## 2. Parked loss depends on what the rest of the fleet is doing

    hour           working   parked
    09-15 18:00      0.9%     4.8%   <- job_0054/0055 running
    09-15 19:00      0.6%     6.5%
    09-15 20:00      1.4%     7.1%
    09-15 21:00      1.0%     8.0%
    09-15 22:00      1.3%    10.4%
    09-15 23:00      1.0%     5.3%
    09-16 00:00      1.4%     8.6%
    09-16 01:00      0.9%     6.9%
    09-16 02:00      1.2%    10.6%   <- job ends 02:57
    09-16 03:00        -     18.6%   <- whole fleet idle
    09-16 04:00        -     17.7%
    09-16 05:00        -     17.6%
    09-16 06:00        -     17.6%
    09-16 07:00        -     19.8%
    09-16 08:00        -     16.5%

**Working loss is flat** — 0.6% to 1.4% in every hour it exists.

**Parked loss is not.** Two things are visible and I cannot yet separate them:

- **A step at 03:00**, exactly when the job ended — from ~5–10% while two miners
  worked to ~18% once all fifteen were idle.
- **A climb before it**, 4.8% → 10.6% over nine hours with the job running the
  whole time — which looks like degradation with uptime.

Both are compatible with the mailbox mechanism, and I am not going to pick one
on this evidence.

## 3. Why this matters for step 2

Your success criterion is parked loss at or below the working level (~1.1%) on
the step-2 build, against the 1.9.107 baseline. The criterion is fine. **The
comparison is not safe unless fleet state and uptime match**, because the
baseline alone moves by a factor of four with them.

Concretely: measure 1.9.107 parked loss during a job in its first hours and you
get something near 5%. Measure step 2 during a job in its first hours and get
3%, and it looks like the fix helped. It might have. Or step 2 might have been
measured in the easy regime and the baseline in the hard one, and the fix did
nothing.

## What I propose, and ask you to rule on

1. **Baseline and step-2 figures are both reported in two regimes**: *job
   running* and *fleet idle*, each with hours-since-deploy. Compared only
   regime-for-regime.
2. **The success bar applies to the hard regime** — fleet idle — because that is
   where the fault lives and where the dock-side disconnects happen. A fix that
   only helps while miners are working has not fixed the thing we found.
3. **1.9.107 runs long enough to show both regimes** before rollout starts: the
   current job (job_0056/0057, started 08:20) plus a few idle hours after it.
   That also answers whether 1.9.107 alone moved the numbers — your first
   condition — in both regimes rather than one.
4. I will **try to separate uptime from fleet state** on 1.9.107 in passing: if
   parked loss climbs while the job runs and then steps up again when it ends,
   both effects are real.

If you would rather keep the single figure and just require the match to be
stated, say so — but I would not trust a step-2 verdict without it.

## Tool

`tools/ack_loss.py <since> [until]` — per-line classification (a node counts as
working only while it holds a job, taken from the server's own accepted/complete
lines), per-turtle table in both states, hourly trend, and it refuses to compute
on a capped `/logs` result.

Its first version classified a node as working for the *whole* window if it had
accepted a job at any point — which scored node_138/139's five idle hours as
working and made the working figure read 6.30%. That is what sent me looking.

— W3
