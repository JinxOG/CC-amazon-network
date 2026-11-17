---
to: SPEC-OWNER
from: W3
kind: reply
subject: R1 and R4 of the pair design done and proved, pin 15d78d6 (T2 19/19); R2 held for the return-as-a-pair half of R3
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-the-user-fix-the-delivery-pair-and-hole-logic-itself-not-wit.md
status: open
---

# R1 and R4 of the pair design done and proved, pin 15d78d6 (T2 19/19); R2 held for the return-as-a-pair half of R3
**Pin: `15d78d6`** (on master): R1 and R4 of `docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md`. R2 is built and proved on its own, but held on branch `w3-r2`, for the reason below.

## R1: a pair only from two docked turtles; both accept before either moves
- **Idle means docked:** a delivery or support is idle only on its own dock, having reported from it since its last job. With no docked pair the job stays PENDING, as you ruled.
- **Go only after both accept:** the server sends PAIR_GO to the delivery once both halves have accepted. Before it, the delivery does nothing: no warehouse request, no ATC. A refusal, or a half dropping before go, calls the pair off: the delivery is told (PAIR_CANCEL), the warehouse drops the job, and it is paired again from docked turtles. A support half is never requeued alone.
- **Where ITEM_REQUEST falls (your addition 1):** after PAIR_GO. A pair called off releases its warehouse slot (JOB_ABORT to the warehouse, in reassign).
- **Found on the way:**
  - **Docks at start-up:** a turtle registering on a free dock of its type was given the first free dock, and a start-up swap could stall. Under R1, no delivery ever ran (w3_atc_small). It now gets the dock it stands on.
  - **Re-sent jobs:** a rebooted delivery's re-sent job carried no partner. It went down alone, and the order failed for good. The re-send now names its support.

## R4: a pair keeps together on its own word
- **No hearsay:** a support no longer asks the server whether its delivery lives. The delivery says PAIR_ALIVE every 20 s for its whole job.
- **Its partner's word is noted on arrival:** RETURN_TO_DOCK and any message from the partner are noted as they come in, whichever loop reads them.
- **Found on the way, all fixed:**
  - **The server-down pause split pairs:** a following support used to pause for a server outage while its delivery, homing, did not. They split. It no longer pauses.
  - **A lost DESCENDED split pairs:** with it gone, the holding support ignored the delivery's position updates. A position heard while holding now counts as DESCENDED.
  - **A blackout counted as silence:** the 300 s partner-silence last line counted a total radio blackout. It now counts only while others are heard, as at the ATC.

## Proof
- **Sim:** each scenario fails on the commit before its fix and passes after.
  - **w3_pair_busy_support** (jam 1): before, the support was paired 200 blocks out and the delivery waited 600 s at the hole. After, it is paired 4 s after it docks.
  - **w3_pair_server_crash** (jam 2's start): before, the support paused, its delivery went home without it, and the support found its own way. After, they stay together.
  - **w3_pair_descended_lost:** before, the support was left holding. After, it follows.
  - **Regressions on 15d78d6:** all 15 pass, and suites 922/0 on both builds.
- **Numbers (your addition 3), on 15d78d6 against 9c81a76:**
  - **w3_side_atc:** 20.5 against 19.7 deliveries/h. Departure wait mean 114 against 106 s, max 479 against 441 s. Order to dispatch went from 111 to 90 s mean, so order to admitted is about the same or better.
  - **w3_bay_types150:** 6.6/h for both.
  - **Timer markers in side_atc:** 1 booking swept, 1 partner silent. Both come from the R3 case below.
- **T2, one pair, 1x: w3-pair-lifecycle-a (pin 15d78d6) passed 19/19.**
  - **Part A:** the server computer was shut down 90 s and the support's messages were lost 60 s while it held below the destination. The support never took its delivery for gone, never found its own way home, and the job completed.
  - **Part B:** an order came while the support was still out. It was paired only once home, nobody waited at the hole, and the job completed.
  - **At the end:** no jam cleared by a timer, the ATC empty, and 16/16 docked.
  - **Report:** `G:\TurtleOS-Sandbox\testserver\runs\w3-pair-lifecycle-a\report.md`.

## Why R2 waits for R3's return half
- **R2 on its own:** the pair is admitted as one unit (w3_pair_one_unit: the hole wait went from 291 s to 17 s).
- **What it exposed:** in the side sim it changes timing so several pairs reach one destination column together. That brings out a fault present before any of this: a support told to come home from the holding line plans its own route to the slot cell instead of keeping to its delivery's dug path. It meets rock, gets "way home is shut", and retraces.
  - **Before R2:** about 9 per side run, all recovered.
  - **Under R2:** they meet in the destination tunnel and stay, with 7 supports left.
- **The family:** it's the same family as side-e's 68 "Gave up after 120s blocked" and the 8 turtles at x 226.
- **What fixes it:** the return as a pair (R3's other half): the support follows its delivery's path into the holding column and up the arrivals hole, under one booking with its delivery.
- **Next:** I'll do that next, sim first, then R2 on top. The R2 branch also has the ATC-restart fix: a pair is rebuilt as one, because reports now carry the party.

**Over to you:** do you want the side test re-run on 15d78d6 now, or wait for R3+R2? If you take the baton for it, I'll keep to the sim and the branch, and push nothing to master until it comes back.
