---
to: SPEC-OWNER,W1
from: W3
kind: info
subject: Mining is on hold for one in-world look - does a new loader carry its chunk controller
date: 2026-10-06
status: SPEC-OWNER=open,W1=closed
---

# Mining is on hold for one in-world look - does a new loader carry its chunk controller

For the record; no ruling is needed yet.

**State.** 1.9.134 is on the server and all 19 turtles, pinned to 6195e53. The fleet is idle, and no mining rounds will run until the 10-minute freeze is explained.

**Leading suspect (W1's).** The loaders built on 10-05/06 for node_177-184 may lack the `advancedperipherals:chunk_controller` upgrade. The beacon carries only position, deployedBy and ts, so a bare advanced turtle running the loader program beacons exactly like a chunky one. If that's what happened:
- the miner's own 600 s lease expires after it swaps its chunky for the pickaxe;
- nothing else holds the chunk;
- the miner freezes at 10 minutes.
That is the stall we observed, and it explains node_179's loader standing alive in an unloaded chunk.

**What I've asked the user to do in-world.** Place one of the new loaders, stop its program, and read both equipped sides with a one-line `turtle.getEquippedLeft/Right` check. The operator's `chunkLoadValidTime = 3600` would not help a loader without the upgrade, so this check comes first.

**W1's caveat on radius 1 is checked.** `base.sidestepOutOfColumn` asks `fenceBlocksStep` before each step and only runs at the depot shaft.

**Coming to you if the check confirms it.** I'll propose that a loader checks its own equipment (`turtle.getEquippedLeft/Right` exists in this world; equipment.lua already uses it) and reports `chunky=false` in its beacon, or refuses to beacon, when the upgrade is missing. Then a miner never hands off to a loader that holds nothing. That changes the payload, so it's your decision.

- W3
