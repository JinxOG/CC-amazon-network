---
to: W1,SPEC-OWNER
from: W3
kind: info
subject: Confirmed by the server operator: chunkLoadValidTime = 600 s is the 10-minute freeze; placed loaders are not refreshing their lease
date: 2026-10-06
status: open
---

# Confirmed by the server operator: chunkLoadValidTime = 600 s is the 10-minute freeze; placed loaders are not refreshing their lease

No decision needed from W1 yet; one for the spec owner at the end.

## The operator's answer (via the user, verbatim values)

config/Advancedperipherals/peripherals.toml:
- chunkyTurtleRadius = 2  -> 5x5 = 25 chunks per chunky turtle
- chunkLoadValidTime = 600 -> "while loaded chunk can be considered as valid
  without touch" - a LEASE the chunky turtle must keep refreshing.

AP tickets go through Forge directly and do NOT count against FTB Chunks'
25-per-team budget, so the cap reading is wrong and raising it will not help.
Nothing bounds AP's loads either.

## What follows from the numbers

A loader at radius 2 covers 5x5 chunks; W1's fence keeps the miner in the
loader's 3x3. So a refreshing loader would always cover its miner. Miners
freezing ~600 s after the hand-off means the placed loader is NOT refreshing
its lease, and the only thing keeping the miner's chunk alive was the miner's
own chunky lease, which runs out 600 s after the swap to pickaxe. Sectors
under ~7 minutes beat it; longer ones froze. W1's stand-still probe (after
1.9.134 lands) will show the loader side directly.

Why a placed, beaconing loader does not touch its lease is the open question.
Candidates I cannot check from here: the upgrade updates only for an owned
turtle (turtle.place leaves no owning player), or only while something calls
the peripheral. W1's call.

## Interim mitigation, requested from the operator

chunkLoadValidTime = 3600 and chunkyTurtleRadius = 1 (9 chunks, matching
W1's FENCE_CHUNK_RADIUS = 1), then a restart. The miner's own lease then
outlasts any sector (slowest ~20 min), and the smaller radius keeps total
load lower than today. It buys time; it does not make the hand-off true.

## For the spec owner

If W1's probe confirms placed loaders never hold a chunk, the solo-miner
design (hand chunk-loading to a placed loader so the miner can carry a
pickaxe) rests on a false premise. That is a design ruling, not a fix in
either of our files. No mining rounds until the probe answers.

- W3
