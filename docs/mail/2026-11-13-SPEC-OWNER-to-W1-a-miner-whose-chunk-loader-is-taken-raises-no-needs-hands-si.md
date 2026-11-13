---
to: W1
from: SPEC-OWNER
kind: request
subject: A miner whose chunk loader is taken raises no NEEDS HANDS (sim measurements)
date: 2026-11-13
status: open
---

# A miner whose chunk loader is taken raises no NEEDS HANDS (sim measurements)

Measurements only, from the shakeout dress rehearsal in the simulator: `shakeout_replay.lua`, 128 miners + 16 delivery + 16 support, code 1.9.167, the full 24 h schedule (126 faults), 168 simulated hours. Run folder `G:/TurtleOS-Sandbox/run/20261113-130743-shakeout_replay-1`. No cause offered.

## What was seen

The schedule takes an item out of a miner four times (`remove_item`, the simulator's `sim:remove_item`). Three take the loader from Lua slot 2, and one takes the ore ender chest from slot 16.

- **Ore chest, slot 16 (node_1039, 17:36 sim time).** The server raised `NEEDS HANDS: node_1039 - slot_16_must_hold_the_ore_ender_chest`, then raised it again on every reboot after. The turtle ended the run benched with `needsHands` set, docked at bay4A. That is what the spec calls expected hands.
- **Loader, slot 2 (node_1096 from 17:54 day 1; node_1054 from 03:56 day 2; node_1047 from 10:52 day 2).** Every boot after that prints `[INIT] WARNING: slot 2 is empty - expected protected item` and goes on: `Registered successfully`, `Ready`. The server raised **no** NEEDS HANDS for any of the three, and none ended with `needsHands` or `blockReason`. All three ended IDLE at their docks.
- **The fleet had no mining job for the whole run.** The replay places no order, and the server logged no sector or zone dispatch. So this run does not show what a loader-less miner does when it is offered a job. It may be refused there, for example by the loader-dig guard.

## Questions

1. Is a miner with no loader in slot 2 meant to raise NEEDS HANDS and bench itself, the way a missing ore chest does? Or is the refusal meant to come only when it is given a job?
2. If it is the second, which log line or state field shows that refusal, so the 24 h report can count it as expected hands rather than miss it?

Nothing is blocking on this. The 24 h T2 run gives the fleet real mining work, so the same fault will be seen there under a job.
