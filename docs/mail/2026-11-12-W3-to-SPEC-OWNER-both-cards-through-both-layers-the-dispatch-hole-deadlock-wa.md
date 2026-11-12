---
to: SPEC-OWNER
from: W3
kind: info
subject: Both cards through both layers: the dispatch-hole deadlock was TWO circles (fixed, w3_bay_types150 passes every check); NEEDS HANDS was a fleet bug AND a sim artefact
date: 2026-11-12
status: open
---

# Both cards through both layers: the dispatch-hole deadlock was TWO circles (fixed, w3_bay_types150 passes every check); NEEDS HANDS was a fleet bug AND a sim artefact

Both cards are in "Done - not server validated", each with a VALIDATION block on the board. Nothing has been deployed, and no frozen file was touched. Everything is on master up to e9d38d4.

## Card 1: the ATC deadlock at the dispatch hole (the shakeout blocker)

It was two circles, both at the hole.

1. **A pair against an older waiter.**
   - The delivery held DH while it waited for its support.
   - An older request also wanted DH and had waited past FAIR_MS, so the fairness rule kept the support out behind it.
   - That older request could not get in while the pair held DH.
   - The delivery left alone after 600 s. Its support went down after it and held DH for good.
2. **The support times out first.** I found this when the fix for circle 1 alone still froze the base: run 20261112-004658, worst wait 16,140 s.
   - Under the ATC a delivery can wait minutes to be let out of its dock.
   - Its support waits only 180 s for HOLE_READY (in the frozen support_turtle.lua), then gives up and JOB_ABORTs it.
   - The delivery ignored that abort at the hole and waited 600 s for a support that had gone, holding DH.
   - Every pair behind timed out the same way.

**The fixes**, in atc.lua, turtle_base.lua and protocol.lua only (1a77441 and f942581):

- **atc.lua:** a request whose partner already holds a booking is not held back by an older waiter (`partnerIn`). That waiter cannot move until the pair has gone anyway.
- **PARTNER_LEFT:** a delivery that goes down without its support now sends it.
  - The support stops waiting to be let in, or, if it is already at staging, goes back to its dock instead of down the hole.
  - Its job failure no longer JOB_ABORTs the delivery that is out working.
  - The partner's word is noted in `firstSight`, the one place both loops pass every message. Noted only in the job's pump, it was lost while the job slept between ATC asks.
- **The delivery's wait:** a JOB_ABORT from its own support ends the delivery's STAGE_WAIT_S wait at once.
- **Side issue:** the "Still waiting" lines now quote the latest ATC answer, not the first.

**Layer 1.** `w3_bay_types150` now passes every check:

| | master (3351d7c) | the fix |
|---|---|---|
| Turtles on a dock of their own type | — | 150 of 150 |
| Deliveries completed | 4 of 10 | 34 of 34 |
| Supports completed | 2 | 33 |
| Mine jobs completed | 0 | 16 (12 by north-side miners, 4 by moved ones) |
| Worst wait to be let in | 19,353 s | 160 s |
| Turtles over 900 s | 13 | 0 |
| STUCK | — | 0 |

The pair scenarios, each failing on the old code:

- `w3_atc_partner_left`: master fails 6 of 8; the fix passes 8/8.
- `w3_atc_support_gave_up`: the old code waits 600 s at the hole; the fix passes 6/6 and waits 0 s.

Regressions on the final code all pass: `w3_atc_base150` 8/8, `w3_atc_pair_split` 8/8, `w3_atc_small` 6/6. The suite is 878/0.

**Layer 2**, one pair each:

- `w3-atc-partner-left-a`: 11/11. The delivery went alone after 600 s, its support stood down and stayed docked, the job completed, and nobody held DH at the end.
- `w3-atc-support-gave-up-a`: 8/8. The support gave up at 180 s, and the delivery went down at once (0.0 s at the hole).

## Card 2: NEEDS HANDS "facing unknown" on healthy docked turtles

It is both.

- **A fleet bug.** A stuck_no_fix flag was cleared only by a passing hardware check, which only miners run, so it stayed on delivery and support turtles for good. Now the turtle's own "docked" report clears it, for every role. A hardware fault stays.
- **A sim artefact.** The stand-in bridge merged each turtle push with the last, so a cleared field (an absent key) lingered in /state. That explains the 4 turtles that cleared in the log but still showed the flag. server.js has taken snapshots as sent since 2026-10-02, and the stand-in now does the same (13b04c2).

**Results:**

- **150-turtle sim:** 30 flags were raised and all 30 cleared; 0 of 150 are flagged at the end. On master, 25 healthy docked turtles were still flagged.
- **T2** (`w3-stuck-flag-clears-a`, one delivery): 7/7. The flag was raised while the ATC settled and cleared 20 s later when the turtle docked, and /state shows none.

## Files outside my usual set

- `sandbox/bridge/standin.lua`, made to match server.js, plus its test.
- New scenarios: sandbox `w3_atc_partner_left`, `w3_atc_support_gave_up`; t2 `w3_atc_partner_left`, `w3_atc_support_gave_up`, `w3_stuck_flag_clears`.

**For whoever runs the shakeout's T2 proofs:** every T2 run that brings turtles home needs `forceload add 224 -2816 271 -2769`. The test world's arrivals column does not tick.

Nothing is left running. The T2 servers stopped themselves; I checked for java, for anything listening on :3000, and for lua52_det. The baton is yours.
