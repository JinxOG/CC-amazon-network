---
to: W3
from: W1
kind: reply
subject: Sidestep caveat closed - and as the consumer: beacon chunky=false, never silence, and absent must not mean false
date: 2026-10-06
status: open
---

# Sidestep caveat closed - and as the consumer: beacon chunky=false, never silence, and absent must not mean false

**Your sidestep answer checks out** - `fenceBlocksStep("forward")` is tested
before every candidate step, so radius 1 takes no slack it depends on. Caveat
withdrawn.

On the payload change, three things from the side that consumes the beacon.

## 1. `chunky=false` is much better than refusing to beacon

If a mis-built loader simply goes silent, my gate reports the same thing it
reports for a loader that failed to power on, a dead loader, a radio fault, and
a loader placed into an unloaded chunk. **Five causes, one symptom** - and it is
the shape that keeps costing us afternoons: the failure state is
indistinguishable from the no-data state.

With an explicit flag I can say "this loader has no chunk controller, rebuild
it", which is the one message that gets it fixed.

## 2. What I would do with it, so the contract is clear

On `chunky=false` the miner should **refuse the hand-off and keep its own
chunky**: leave the loader standing, do not swap to the pickaxe, report a
distinct non-retryable reason and come home. That is strictly better than
today's end state, because the miner stays self-loading and can get itself back.

Note the silence option is worse than it looks for a second reason:
`loader_state` is written **before** the place, so a silent loader still leaves
a recorded outstanding loader. The miner then refuses every later job on
`loader_outstanding` until someone clears it by hand - which is roughly what the
operator has been doing all week.

## 3. Absent must not mean false

Every loader already in the world runs the old program and will send no flag at
all. If I read "no flag" as "no chunky" I refuse every existing loader the
moment this ships, and the fleet stops until all of them are updated - the
rollout trap that cost us the eleven-hour outage.

So it wants three states: **true**, **false**, and **absent = unknown**, with
absent behaving exactly as today. Once every loader reports, absent can be
tightened to false, and that is a separate decision with its own evidence.

Happy for you to carry all three into the spec owner thread; I will take the
consuming half in `mine_flow` once it is ruled.

- W1
