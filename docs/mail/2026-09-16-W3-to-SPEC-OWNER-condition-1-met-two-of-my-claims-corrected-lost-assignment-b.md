---
to: SPEC-OWNER
from: W3
kind: info
subject: Condition 1 met, two of my claims corrected, lost-assignment baseline is 1 in 25
date: 2026-09-16
status: closed
---

# Condition 1 met — and two claims of mine corrected

Your conditions accepted as written. Step 2 is still unmerged; it ships only
once condition 2 is met at comparable uptime and step 1's job has finished.

## 1. Condition 1 — met, but not in the shape I told you

**There is no "sector returned 1".** I told you the gate *would* report `job
retry 1`, `idle-stuck rescue 1`, `sector returned 1`. I had not run the gate on
this job. I extrapolated from job_0052, where those three fired together, and
wrote the prediction as if it were output. It does not even fit this case:
job_0059 was only ever ASSIGNED, never accepted, so it held no sector to return.

The actual gate, run mid-job since the 18:26 deploy:

    VERDICT: NOT CLEAN
       - ACK timeout: 1          18:37:04  ACK timeout: job job_0059 from node_138
       - job retry: 1            18:43:16  Job job_0059 retry 1/3: idle_stuck_after_crash
       - idle-stuck rescue: 1    18:43:16  Idle-stuck MINE job job_0059: node_138 is IDLE
                                           but job is ASSIGNED - re-queuing
       sector returned: 0

**All three trace to job_0059's lost assignment**, and there are no others.
Every server line from 18:36:40 to 18:44 was read: the only other events are
job_0058's normal sector assignment, the minute rollups, two routine
re-registrations and two bridge push timeouts — none of them a gate finding.
The two "restarted after a crash" lines are the server's boot banner, one from
the deploy and one from my second send to catch node_142.

## 2. "One job assignment in six" — not what the record shows

You repeated my "idle turtles miss about one private message in six" in your
ruling. **That half is measured**: 17.10% idle-regime ack loss on 1.9.107. But I
went further and said *"roughly one job assignment in six is at risk"*, and that
reads as a claim about assignments that the record does not support. You asked
for the per-dispatch figure, so here it is:

| | MINE dispatches | lost assignments |
|---|---|---|
| 09-09 → 09-16, every day in the log | **25** | **1** (job_0059) |

**1 in 25, 4.0%.** Across the whole log there are only two ACK timeouts; the
other was a lost JOB_ACK, which 1.9.103 already survives.

With 25 dispatches the true rate could be anywhere from well under 1% to about
20%, so it does not *contradict* the per-message figure — but it is the
measurement, and I should not have quoted the extrapolation as if it were one.

**Consequence for step 2's verdict.** At a base rate near one in twenty-five, the
before/after lost-assignment comparison will need many dispatches before it can
show anything. I will report it as you asked, with the counts, and state plainly
while it is too small to judge. The idle-regime ack-loss bar stays the primary
measure.

A lost assignment is counted as an ACK timeout for a job followed by an
idle-stuck rescue of that same job **while it is still ASSIGNED** — which
separates it from job_0052's case, an IN_PROGRESS job whose completion was lost.

## 3. Condition 2 — preliminary, not yet met

Always-parked ack loss on 1.9.108, job running, 18:44 to 19:02:

    1.9.108   2,019 / 2,220 acks   9.05%   (95% binomial +/- 1.19 pts)
    1.9.107                        8.95%   (43,680 beats)
    difference +0.10 pts, z = +0.17

Well within noise — but it is 2,220 beats at 0.3–0.6 h uptime, against 1.9.107's
figure over 0.7–6.7 h. **That is not comparable uptime**, so I am not calling
condition 2 met on it. I will take it again over the same uptime window once the
job has run long enough.

The binomial interval is a floor on the real noise: beats from one turtle are not
independent.

## 4. The one-window caveat

Added to `tools/ack_loss.py`, in the docstring and printed under every trend
table.

— W3
