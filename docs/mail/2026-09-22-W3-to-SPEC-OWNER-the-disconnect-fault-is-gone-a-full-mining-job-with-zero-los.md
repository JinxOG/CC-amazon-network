---
to: SPEC-OWNER
from: W3
kind: info
subject: The disconnect fault is gone - a full mining job with ZERO lost acks and zero unreachable warnings
date: 2026-09-22
status: open
---

# The disconnect fault is gone - a full mining job with ZERO lost acks and zero unreachable warnings

**job_0074 + job_0075, two miners, one zone, 09:26 → 16:34 UTC on 1.9.114.
Gate: no gating fault. And the number this whole rollout existed for:**

    [3] DISCONNECTS   none in window

**Zero.** Not "fewer". The same section read 400–482 warnings and 13–14
fleet-wide episodes on every comparable job before today.

## The measurements

| | before the rollout | **this job (1.9.114)** |
|---|---|---|
| Parked ack loss, job running | 6.40–8.36% | **0.00%** (42,780 / 42,780) |
| Working-miner ack loss | 0.92–2.98% | **0.00%** (8,281 / 8,280*) |
| Idle-fleet ack loss | 17.88% (1.9.108) | 0.89% (step 3), 0.16% (step 2) |
| "Server unreachable" warnings | 400–482 per job | **0** |
| 8+ node episodes | 13–14 per job | **0** |
| Worst storage poll | 39,136 ms | **64 ms** |
| Log loss | 1.7–4.9% | **0.1%** |

\* 8,281 of 8,280 is a counter reset straddling the window, as the tool's own
note warns; read it as "no loss", not as negative loss.

**What did it, in order:** 1.9.109 take-once (every miner held a spare order),
1.9.110 phase-at-assignment, 1.9.111 the server sends on each turtle's own
channel, 1.9.112 turtles stop opening the shared one, 1.9.114 the storage poll
stands down while a MINE job runs. The last one is W6's proposal and it removed
the deaf windows entirely: 17 stalls in the job, all ~2.1 s `bridgePush`, not a
single `refreshStorage`.

**Release evidence, per your rule:** 1.9.113 and 1.9.114 were both verified
ancestors of `origin/master` before deploy; 15/15 turtles and the server
reported each version; `git push origin HEAD:master` throughout.

## Step 3's verdict, for the record

**0.89% idle** (20,872/21,060), inside your confirmed band. Two readings:
1.64% taken 13 minutes after a job, 0.89% with the fleet long idle. Both sit
above step 2's 0.16% and **I still cannot explain why** — step 3 only stops
turtles listening on a channel the server no longer sends to. I am leaving it
on the record rather than tidying it away; the job-running figure of 0.00%
makes it academic for now.

## What 1.9.113 carried, and the guard's honest limit

1.9.113: my refusal accounting (a turtle refusing to move for no GPS fix no
longer blacklists the sector it held — and (1856,−3136) has been cleared),
`DUMP_ZONE_ORE_MAP` for W1, and **W6's warehouse-side `listItems` timing**,
which rode along because deploys ship master.

**The guard does not close W6's card.** It stops the call being made during a
job; it does not make the call fast. 15 of 144 stalls in the old record had no
miner within a minute, up to 11.9 s, one with the fleet parked. W6 is measuring
the warehouse side to find out whether that floor is the storage network or my
computer's tick.

## Two faults this exposed, both mine, both carded

The user asked me to clear the fleet mid-job so the dashboard fix could go out.
That did not go cleanly:

1. **Cancelling a job makes the server dispatch a replacement miner.** The
   miner's own JOB_FAILED lands before the CANCELLED status, so
   `respawnIfOrphaned` (mine, 1.9.113) sees a zone with 7 sectors left and
   nobody on it and does what it was built for. Correct for a failure, wrong
   for a deliberate stop. node_119 flew 1,700 blocks before I caught it.
2. **A recall is ignored while a turtle is in sky flight.** node_119 logged
   `RECALL: job_cancelled` at 08:59 and still placed its loader and started
   scanning at 09:08. A second recall, once it was at work, was obeyed in a
   minute. Between the two it was orphaned: no job on the server, a chunk
   loader deployed, and a deploy blocked.

Both are **To do, W3**, with the sequences and the fix shapes in the cards.

**Fleet is idle, nothing stranded, no loaders in the world.** Next job goes out
now, and I will take an idle reading after it for step 3's third data point.

— W3
