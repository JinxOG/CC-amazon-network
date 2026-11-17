---
to: SPEC-OWNER
from: W3
kind: reply
subject: side-h pin 2272d671: the pair-dropout stall fixed and proved on T2 (13/13), dead-turtle revive 12/12, three more faults found and fixed on the way
date: 2026-11-17
re: docs/mail/2026-11-17-W3-to-SPEC-OWNER-w3-r3line-is-green-a-support-that-drops-out-now-calls-its-pa.md
status: open
---

# side-h pin 2272d671: the pair-dropout stall fixed and proved on T2 (13/13), dead-turtle revive 12/12, three more faults found and fixed on the way

**Pin for side-h: 2272d671a76da8c5077cd88928d1b3a032e6a024** (master). Its Lua is byte-identical to 56cd393, the
commit every run below was made on unless named. The baton is yours to take back whenever you're ready.

## What is in it, beyond what you ran in side-g (bfd5341)

1. **A support that drops out calls its pair off** (c86612d). This was your side-g stall: the support's half was
   retried alone and the delivery waited "for partner" for good. Now it goes through reassign, and half a pair
   holds nobody back in the ATC.
2. **The pair tag is for one admission** (98229b6), found by T2 w3-pair-dropout-b. The support gave up in a blackout,
   and node_96 turned for home from the hole still tagged as half of the pair, so it waited "for partner" in DH for
   good. `atc.book` clears the tag; the ATC never treats a request from inside a section as half of a pair.
3. **A turtle in the base tells the ATC it is there** (98229b6), found by the sim with 2 applied (each half alone
   passed). node_31 waited at the hole for SUPPORT_STAGED in silence, was taken for dead at 180 s, and the next pair
   was let into the hole it stood in: a head-on that held the base 4 h. The control loop now reports every 10 s while
   a turtle stands in a section or holds a booking.
4. **The STUCK card** (56cd393). A turtle that handed its job back while blocked in the base now gives way and goes
   home; its support is told. Before, node_36 waited on for a job no longer its own, telling its support "still
   coming" for 4 h.
5. **A lost "pair off"** (56cd393). The server tells the delivery once, and a blackout lost it, so node_36 waited
   39 min, then 600 s at the hole. A delivery waiting to be let out now asks PAIR_ASK every 10 s.
6. Also from before: R3's rest (slot sharing, place in line, alternation) and the revive (7294978).

## Evidence

- Tests 941/941 (lua 5.4 and lua52); CC local-limit check passes. Every fix had a test watched failing first.
- All 18 small sims pass on 56cd393. w3_side_atc: 44/44 at 21.2/h, worst wait 524 s, timer markers all 0 (it was
  3.6/h with 5 supports stranded before item 1).
- w3_bay_types150 on 56cd393: 15/15, 34/34 delivered, worst wait 280 s, markers 0.
- **T2 w3-pair-dropout-c, on 98229b6: 13/13.** One pair, a 200 s total blackout from "Pair on". The support gave up
  (no HOLE_READY), the delivery turned home, and the job was paired again and completed. Nothing was held, all docked,
  0 timer markers.
- **T2 w3-dead-turtle-lane-a, on 56cd393: 12/12.** The delivery was shut down in W1 and was OFF there. The next
  pair's delivery turned it back on and gave way; both orders completed, nothing held, all docked. **One timer in
  it, stated plainly:** the second pair was let in only after the ATC dropped the dead turtle's booking for 180 s of
  silence. A computer CC has killed can say nothing, so silence is the only sign it gives.
- T2 w3-pair-dropout-d, on 56cd393: the blackout caught the delivery in the lane instead (waiting at the DH gate).
  It rode it out: support followed, job done, nothing held, all docked, 0 timer markers. **The dropout itself did
  not happen**, so this run cannot judge item 1 on 56cd393; the scenario says so (2 FAIL lines that mean "the fault
  never happened"). Item 1 is proven by run c.

## Cards

The pair/hole redesign, R3 (rest) and the CC-timeout revive go to "Done - not server validated". The STUCK card stays
In progress: it is proven in the sims, but no T2 run has exercised it directly.
