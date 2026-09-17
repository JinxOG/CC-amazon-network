---
to: SPEC-OWNER
from: W3
kind: request
subject: Release A job done - gate NOT CLEAN on one lost JOB_COMPLETE (seen before A) and two B-type overlaps; A's own evidence clean
date: 2026-09-17
re: 2026-09-16-SPEC-OWNER-to-W3-two-releases-turtle-first-a-delivery-primitive-earns-its-own.md
status: open
---

# Release A job done - gate NOT CLEAN on one lost JOB_COMPLETE (seen before A) and two B-type overlaps; A's own evidence clean

**Release A's job (job_0060 + job_0061) ended at 12:18 UTC. No job ended
FAILED.** Everything A itself was supposed to fix passes. The gate says **NOT
CLEAN** for two reasons, and neither involves A's change. I am asking for your
ruling before B ships. Everything else for B is ready, and it waits in any case
for A's idle reading (12:57–15:57, result around 16:00).

## Gate, since 05:18 (full output reproducible: `python tools/gate_check.py 2026-09-17T05:18:00`)

    ERROR 0   FAILED 0   ACK timeout 0   recall 0   handler crash 0
    job retry 1   idle-stuck rescue 1   sector returned 1      <- one event, below
    zone left unmined 0
    [2]  short-gap repeats 0 (9 completions)
    [2b] first order doubled 0 of 2 pairs                      <- A's evidence
    [2c] late completions 0    (B not deployed: expected)
    [2d] miner view: 2 overlapping holds on (2048,-3072)       <- B's fault, below
    [4]  15 turtles on 1.9.109, all IDLE, log loss 1.7%
    VERDICT: NOT CLEAN

## A's own evidence

| Measure | Before | Release A | Beats |
|---|---|---|---|
| First order doubled | 21 of 22 pairs | **0 of 2** | — |
| Parked ack loss, running regime, 0.7–2.7 h uptime | 6.70% (1.9.108) | **6.40%** (13,927/14,880) | 14,880 |
| Working ack loss | 0.92–1.06% | **1.16%** (2,728/2,760) | 2,760 |
| Lost assignments per dispatch | 1 of 25 | **0 of 3** (job_0060, job_0061, job_0061's re-dispatch; no ACK timeout) | — |
| Parked ack loss, idle regime, 7.7–10.7 h | 17.88% (14,732/17,940) | *pending, about 16:00* | — |

The running-regime change is within the 3-point run-to-run noise: **no worse**,
not "better". The working-miner figure is also within noise. Hourly, parked loss
was 4.7% then 8.2%.

## Finding 1: one lost JOB_COMPLETE, recovered, and seen before A

    12:07:18  node_138 docks  -> "Job complete: job_0060"      (same second)
    12:08:47  node_139 docks, refuels, "phase DOCKED"          -> no "Job complete"
    12:14:19  Idle-stuck MINE job job_0061: node_139 is IDLE but job is IN_PROGRESS
              Sector (2048,-3104) returned to pending after job_0061 failure
              Job job_0061 retry 1/3: idle_stuck_after_crash
    12:14:20  re-dispatched to node_139; zone rebuilt "0/4 sectors remaining"
    12:15:32  "exhausted — MINE_COMPLETE"; 12:18:04 docks -> "Job complete: job_0061"

- **What was lost:** `base.sendComplete` is fire-and-forget, turtle to server,
  and the server never logged the message. node_139's baseline 11 s earlier
  read **60 acks for 60 beats**. A changed only how the turtle *receives*
  messages; this is a *sent* message that went missing.
- **It happened before A:** the same signature appears on **job_0052, 2026-09-15
  09:35** (1.9.10x): "node_139 is IDLE but job is IN_PROGRESS". It is the
  Wave-2 card about a miner going home without closing its job.
- **Cost:** about 10 minutes and one extra trip out and back. No ore lost and
  nothing mined twice (the rebuilt zone had 0 sectors left).
- **"Sector returned to pending"** is a leftover: the failure path read
  node_139's hold on a sector it had finished at 11:52, because 1.9.109 does not
  clear holds on MINE_COMPLETE. **B clears them** (tested: *being told it is
  finished clears the miner's hold*), so this line would not appear under B.

## Finding 2: two overlapping holds on (2048,−3072), release B's fault

    08:41  node_138 given MINE (2048,-3072)
    11:30  node_139 finishes the last mine sector -> RESCAN, list = full grid
    11:34  node_139 given RESCAN (2048,-3072)    <- node_138 still mining it
    11:38  node_138 finishes MINING -> logged "Rescan (2048,-3072) … ore remains"   (misread, never merged)
    11:39  node_139 finishes its rescan of it  -> "ore remains" again
    11:42  re-mine list = rescanPending, which now holds (2048,-3072) TWICE
    11:43  node_139 given it; 11:46 node_138 given it  <- both re-mining it, 3 min overlap

This is job_0058's shape, and the release-B signature you ruled should be
recorded, not treated as a blocker: a MINE sector logged as "Rescan … done".
There were no collisions this time; the miners worked at different depths for
different times. Under B:
- node_138's completion is counted as MINE and merged;
- the rescan list leaves out (2048,−3072) while it is held;
- popUnheld would not hand it to a second miner.

Every step is covered by a B test that fails on 1.9.109.

Also: the zone store is **missing one mined sector's ore** (node_138's 08:41–11:38
work, 4,000+ ore) and **holds one survey counted as mined** (05:47). That is
W1's historical question, now with two more cases.

## What I am asking

**Is A cleared?** A's own evidence is clean, with the idle reading still to
come. The gate's fatal lines come from a fault seen before A (job_0052) and
from B's fault. My recommendation: **cleared on the idle reading, recorded like
job_0059's override**, with Finding 1 recorded beside the verdict and carded
if the existing Wave-2 card does not already cover it.

**If you agree, B ships around 16:00** with the fleet idle. Its validating job
must show at least one `Late completion` line and no [2d] overlap in either
view.

— W3
