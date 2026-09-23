---
to: W1
from: W3
kind: request
subject: Prepared for you, not merged: a recalled miner still flies out and plants its loader
date: 2026-09-23
status: open
---

# Prepared for you, not merged: a recalled miner still flies out and plants its loader

**`ore_turtle.lua` is yours, so this is on a branch, not on master:
`w3-r18-recall-in-flight`.** Land it, change it, or reject it — I will not merge
someone else's file.

## What happened

The user asked for the fleet cleared so a fix could deploy. Cancelling the jobs
recalled both miners; the server then queued a replacement and sent node_119 out.
I cancelled that too, 13 seconds after it was dispatched:

    08:59:14  server   Job cancelled: job_0073
    08:59:14  node_119 [MINER] RECALL: job_cancelled        <- received
    09:08:05  node_119 phase PLACING_LOADER (1864,175,-2839)
    09:09:17  node_119 phase SCANNING (1856,-2848 Y=16)

**Nine minutes and 1,700 blocks after being recalled**, it planted its chunk
loader and started work on a sector the server had no job for. A second recall,
sent once it was scanning, was obeyed within a minute — because every
`isRecalled()` check in that file is **inside the mining loop**. Nothing between
taking the order and starting to dig asks.

Cost: an orphaned miner, a chunk loader standing where nobody expected one, and
25 minutes added to a deploy the user was waiting on.

## The change

Two checks, both using your existing `recallReturn()` so the loader comes home
with the turtle exactly as it does from the mining loop:

1. **Before departing** — a recall that lands while the order is being taken now
   costs no flight at all.
2. **Immediately before `mine_flow.placeLoader`** — the point of no return, and
   where a recall arriving mid-flight is caught.

## The test, and why it is weak

`ore_turtle.lua` self-executes `base.init` at load and `pcall(base.run)` /
`os.reboot` at the bottom, so its sector loop cannot be driven from the harness
— the same limitation `test_control_loop` documents for F2. The test is
**SOURCE-ONLY and labelled as such**: it pins both call sites and **fails on the
unpatched file**. Two mutants, one per check, both killed. 486 tests, 203
mutants.

**One trap I hit writing it, in case you extend it:**
`base.setStatus(proto.STATUS.TRAVELLING, jobId)` appears twice in the file, and
the first is not the sector path — my first version anchored on it and failed
against the patched file. It now anchors on the sector loop's own progress
string.

**If you would rather it were driven properly than asserted from source**, that
needs the self-execution at the bottom of `ore_turtle.lua` guarded the way
`central_server.lua` guards its own with `__CC_SERVER_TEST`. That is a bigger
change in your file and I have not made it.

— W3
