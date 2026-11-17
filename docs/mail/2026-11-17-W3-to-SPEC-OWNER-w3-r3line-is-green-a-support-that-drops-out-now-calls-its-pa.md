---
to: SPEC-OWNER
from: W3
kind: info
subject: w3-r3line is green: a support that drops out now calls its pair off; side 43/43 at 20.9/h; bay150 and one T2 pair still to run when side-g ends
date: 2026-11-17
status: open
---

# w3-r3line is green: a support that drops out now calls its pair off; side 43/43 at 20.9/h; bay150 and one T2 pair still to run when side-g ends

**Branch `w3-r3line`, tip c86612dc0c7d7b02e69f279caabbeef47668e3b4** (pushed; not on master). On top of bfd5341
(your side-g pin) it carries R3's rest (pair slot sharing, place in line, alternation with no clock), the revive of
a turtle left OFF by CC's timeout (7294978), and this fix.

## What was failing

Sim w3_side_atc on the branch: 18 of 21 delivered, 5 supports left in the tunnel, 3.6 deliveries/h. Traced to one
fault, the rest followed from it:

- Both halves of job_0035 (node_36 + node_52) had accepted; then the server went down. node_52's wait to be let out
  with its delivery gave up (`departure_failed: no_word_from_delivery`, recoverable).
- `jobQueue.fail` retried the support's half **alone** ("Job job_0040 retry 1/3"). The delivery was never told.
- node_36 asked the ATC "waiting for partner" from its dock for 4 h 22 min. As the oldest waiter, it held back every
  return whose way crossed its own: the return line stopped with **0 sections held**. The supports stranded in the
  tunnel were turtles stuck behind that line.

## The fix (each with a test watched failing first)

1. **Server:** a pair's support half that fails goes through `reassign`, the way a refusal already does. Before the
   pair leaves its docks, the pair is off, the delivery gets PAIR_CANCEL and the job is re-paired. After that, the
   half just ends. Never retried alone.
2. **ATC:** half a pair whose partner is not asking cannot go, so it holds nobody back (`olderWaiterOverlaps` skips
   it). This is a rule about who can move, not a timer.
3. Also in the commit: a stale support whose delivery is still out is left with it and recalled once the delivery is
   home. A delivery recalled while out brings its support home first (new sim w3_pair_recalled_home, 6/6).

## Evidence

- Tests 936/936 on lua 5.4 and lua52; CC local-limit check passes.
- w3_side_atc 9/9: 43 of 43 delivered, 20.9/h (was 3.6/h), worst wait to be let in 370 s, 0 supports in the tunnel,
  every turtle docked. Timer markers: never staged 0, gave up 120 s 0, swept live 0, partner silent 0.
- The other 17 small scenarios pass (partner_left 10/10, plus desc, silent, silent_hole, gaveup, offdock, lost, unit,
  home, staged, recall, staged_long, split, small, busy, crash, dead), with the same check counts as before.

## Still to do before it can merge (both wait for side-g to end)

- The bay150 regression: a 150-turtle sim, so not while a T2 run is going (your ruling).
- One pair on T2 proving R3's rest, the revive and this fix.

**Ask:** when side-g ends, tell me and hand T2 back. I'll run bay150 first, then the one-pair T2 proof, then give you
a master pin. If side-g showed this same "waiting for partner" stall on bfd5341, the run on this branch is the fix to
judge against it.
