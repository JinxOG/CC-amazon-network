---
to: SPEC-OWNER
from: W3
kind: reply
subject: R2 and R3's return half done, pin bfd5341 (T2 13/13 with a total blackout during the return); side-g pin
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-the-user-fix-the-delivery-pair-and-hole-logic-itself-not-wit.md
status: open
---

# R2 and R3's return half done, pin bfd5341 (T2 13/13 with a total blackout during the return); side-g pin
**Pin: `bfd5341`** (on master): R1, R4, R2 and R3's return half of `docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md`. The baton is back with you for side-g.

## What R2 and R3's return half add on top of 15d78d6
- **R2, the pair's departure admitted as one unit:**
  - Each half asks from its dock, naming its partner. Neither is let in until both have asked and both ways are free. A message from either keeps the pair's bookings alive.
  - A support dropping out while its delivery still waits on its dock calls the pair off, and it is re-paired.
  - After an ATC restart a pair is rebuilt as one: reports carry the party, and fairness counts the delivery's own booking.
- **R3's return half:**
  - At the holding line the delivery sends the last 60 cells of its path. A support that lagged walks those dug cells up behind it, rather than planning its own way through rock.
  - RETURN_TO_DOCK is repeated every 10 s, after the job too, until the support answers HOME_HEARD (bounded at 10 min).

## Proof
- **Sim, each failing before and passing after:**
  - **w3_pair_one_unit:** the hole wait went from 291 s to 17 s.
  - **w3_pair_home_lost:** come-home lost for 90 s. Before, the support waited out the 300 s rule. After, it came home on a repeat.
  - **w3_side_atc:** "way home is shut" went from 9 per run to 0.
  - **Tests:** test_atc +5, test_retrace +1.
- **Regressions on the same code, 17/17:**
  - **w3_side_atc:** 9/9, 40/40 delivered, 19.4/h, all four timer markers 0.
  - **w3_bay_types150:** 15/15, 6.6/h, markers 0.
  - **Suites:** 928/0 on both builds.
- **Numbers on side_atc (order to out the hole, mean):** 361 s on 9c81a76, 356 s on 15d78d6, 316 s and 371 s on two runs of the branch.
  - **The worst case (1554 s, job_0045):** almost all of it was the server's "destination already has an active delivery" (side_atc orders the same destinations again and again), not the pair or the hole.
- **T2, one pair, 1x: w3-pair-unit-return-a (pin bfd5341) passed 13/13.**
  - The ATC logged "admitted pair node_96 + node_141", and the hole wait was 17 s.
  - **Total blackout (your check):** a total radio blackout of 60 s from the delivery's call-up. Its first RETURN_TO_DOCK fell inside it, and the support heard a repeat at 07:10:01, after the blackout. Before the call-up, the support walked 1 cell of its delivery's path.
  - **At the end:** no partner silent, no retrace, both jobs completed, no jam cleared by a timer, the ATC empty, and 16/16 docked.
  - **Report:** `G:\TurtleOS-Sandbox\testserver\runs\w3-pair-unit-return-a\report.md`.

## Not done yet
- **R3's line:** "place in line" in every answer, and the alternation rule for shared sections, replacing FAIR_MS.
- **A pair should share its holding slot:** a support at the holding line is refused its own delivery's slot ("slot 14 is node_33's"). It waits until the delivery leaves. No timer, but a pair should share it.
- **I'm on small sims only while side-g runs, at most two.** (Your ruling is now a standing memory.)
