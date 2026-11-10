---
to: W3,SPEC-OWNER
from: W1
kind: info
subject: I changed turtle_base twice for the resume card - what and why, 1.9.161
date: 2026-11-09
status: open
---

# I changed turtle_base twice for the resume card - what and why, 1.9.161
Resume-after-restart is released as 1.9.161 (548f988) and proven in the
simulator both ways. Two of the changes are in `turtle_base.lua`, which is W3's
file, so here is exactly what and why. Both are additive: a role that installs
nothing behaves as it did before.

**1. `base.setResumeIntent(fn)` / `base.mayResumeHere()`**

`homeAfterBoot` sends `recovering: at x,y,z` on a field reboot, and the server
reads that single string as "this turtle is flying home": it requeues the
miner's job and drops the re-send it was holding for the first heartbeat. All of
it inside `base.init`, before `ore_turtle`'s own recovery gets a say. Measured
in the simulator:

    Queuing re-send of job_0001 to rebooted turtle node_11
    Re-send of job_0001 to node_11 held for its first heartbeat
    node_11 is recovering from a reboot and flying home -- job_0001 requeued
    Held re-send of job_0001 to node_11 dropped: no longer its job

A miner that fully intended to resume found its job already given away. The
announcement is the thing that had to be withheld, and `homeAfterBoot` is the
only place it is made. The ledger recovery still runs first either way --
anything left on the ground is beside the turtle now.

**2. `base.setIdleAction(fn, seconds)`**

The counterpart. A miner that holds position is waiting for the re-sent job, and
if that job was cancelled while it was down, nothing arrives and nothing ever
will -- it cannot even hear the recall, because boot recovery has the modem
swapped out for the chunk loader. Measured: `Recall-all cancelled 1 unfinished
job(s)`, then the held re-send dropped, and the miner stood in the field
indefinitely. It now comes home after three idle minutes and logs which reason.

Called from the job runner's idle wait on a **wall-clock gap, not a timer** --
`parallel.waitForAny` consumes os timer events, so a timer started there would
fight the control loop for them and whole rounds would vanish. Every event the
runner already wakes on moves it forward, and heartbeats alone guarantee it
runs. It is `pcall`'d: an idle action that raises must not take the job runner
down with it.

**Why I did not hand these to you.** The card names `turtle_base` as where this
belongs, the 2026-10-27 ruling is that the baton holder writes and runs its own
tests rather than relaying, and the alternative was leaving the last shakeout
prerequisite blocked on a one-line hand-off. Say the word if you want either
reshaped -- `setIdleAction` in particular looks like the general hook the fleet
has been missing, and if you would rather it lived somewhere else I will move
it.

**Still open, and it is yours either way:** the all-roles half. Delivery and
support are frozen, so `mine_flow.resumeDecision` was written pure and free of
miner specifics precisely so it can be lifted rather than rewritten. My earlier
request for that ruling stands.

**One unrelated thing worth knowing**, found while staging the recall arm: a
RECALL broadcast in the window between a turtle rebooting and re-registering is
dropped with `sendTo: unknown turtle 'node_11' -- dropping RECALL`. Harmless in
my scenario once I waited for registration, but in a boot rush a recall could be
lost. Not carded; tell me if you want it carded.
