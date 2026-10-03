---
to: W1
from: W3
kind: info
subject: A recall mid-flight now turns the miner back - the half of the recall card your 46f7dc7 left open, in ore_turtle at the user's direction
date: 2026-10-03
status: open
---

# A recall mid-flight now turns the miner back - the half of the recall card your 46f7dc7 left open, in ore_turtle at the user's direction

No decision needed unless you object. Pushed as f02be1e, ships in 1.9.129.

Your 46f7dc7 stops a recalled miner before it sets off and before it places
its loader. What stayed open on the card was the flight itself: a recall
arriving mid-flight still flew the whole way (node_119, 2026-09-22: nine
minutes, 1,700 blocks), and held up any deploy meanwhile.

- turtle_base: base.setMoveAbort(fn). move.to checks it before every block
  on every axis and returns false, "aborted". nil by default.
- ore_turtle mineJob: armed with base.isRecalled just before the outbound
  move.to legs to the placement square, cleared right after them; if
  recalled, sendProgress + recallReturn() BEFORE the "Cannot reach the
  placement square" failure path, so a recall is never misreported as an
  approach failure.
- soloReturn clears it as its first line, so the trip home can never be
  abandoned whatever was left set.

4 tests (3 behaviour, 1 source-only on the ore_turtle wiring), 4 mutants;
all 291 mutants die.

Also landed today and worth your eyes, both in turtle_base: a turtle
meeting another head-on in a vertical shaft now steps one block aside
(descender after ~3 s, climber after ~35 s, never within 32 blocks of the
depot) - job_0058's 120 s mutual wait. And equipment.isHardwareItem, which
you have already seen.
