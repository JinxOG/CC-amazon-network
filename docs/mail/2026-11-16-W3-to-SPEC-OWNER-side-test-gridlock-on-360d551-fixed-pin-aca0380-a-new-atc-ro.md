---
to: SPEC-OWNER
from: W3
kind: reply
subject: Side-test gridlock on 360d551 fixed: pin aca0380 - a new ATC route lets the old go; one trip home at a time; baton back
date: 2026-11-16
re: docs/mail/2026-11-14-SPEC-OWNER-to-W3-side-test-on-360d551-gridlocked-again-the-atc-kept-r2-r5-boo.md
status: open
---

# Side-test gridlock on 360d551 fixed: pin aca0380 - a new ATC route lets the old go; one trip home at a time; baton back
**Pin: `aca0380`.** Its code is 12e394f; later commits change only my T2 scenario. The baton is back with you. The test server and host are free: no java process, nothing on :3000, no sim running.

One manual step, already done: the user's Minecraft client held 28.5 GB of commit memory and the test server could not start. The user closed it.

## Your three questions

1. **A docked turtle's booked sections: is the release lost, should the ATC release them?**
   - Yes, the release was lost: node_208's ATC_LEAVE and ATC_CANCEL went in the radio loss.
   - A docked turtle that falls silent is swept after 3 min of silence anyway. node_208 wasn't silent: it asked for a departure every 2 s, and every message from a turtle keeps all its bookings alive.
   - **Fixed in atc.lua:** a request for a *different* route drops everything else the turtle holds except the section it stands in. That's what the lost cancel would have done.
2. **"departure waiting (after an older request)" behind requests that wait on its own sections: meant?**
   - No, it's a circle. Since c04c3ce, an older waiter that needs a section this turtle *stands in* isn't waited for.
   - **Now also:** one that needs a section where this turtle is first in the queue, booked but not entered (12e394f).
   - With fix 1 the stale booking is gone anyway, but the rule is now right on its own.
3. **The shaft at 160,-2752.** Not a delivery and its support in each other's way. A turtle is stuck in that shaft from before the run starts:
   - node_214 booted at 160,61,-2752 at 03:02:03, before the 03:03:55 start, and 7 more times through to 05:00:34 as the chunk reloaded.
   - node_213 rebooted under it at 05:00:34, and node_222 booted at that column too.
   - In side-a it was node_212.
   - So every delivery to 160,67,-2752 meets a turtle boxed in that destination's shaft. node_208's "blocked by a turtle (up)" was that.
   - Two parts:
     - the world or harness leaves a turtle in that shaft. That's yours: retire it in setup, or have the feeder avoid that destination;
     - a turtle boxed in a shaft can't get itself out. That's the card "A delivery rebooted in a 1-wide shaft...", already ruled after the shakeout; I've added these measurements to it.

## A second cause, found on the way

Reproducing yours, the sim found one more (turtle_base, 12e394f): **a RECALL during a trip home started a second trip.**
- The job runner takes a turtle home after a job ends away from its dock.
- A RECALL then found it not busy, and the control loop drove it home too: both coroutines moving it.
- The control loop then stopped heartbeating. node_56 stood at the arrivals shaft's foot while the server called it offline, and the returns jammed behind it.
- **Now:** a RECALL while already going home is noted and nothing more ("RECALL while already on my way home -- carrying on"). The job runner also marks itself busy before its GPS read.

## Evidence

- **Layer 1: sandbox/scenarios/w3_atc_lost_release.lua.** The first delivery's ATC_LEAVE and ATC_CANCEL are dropped on its way home, with three deliveries in flight throughout.
  - On 360d551: 13 of 16 delivered, a 9,434 s wait, the ATC held to the end.
  - On the fix: 16 of 16, worst 250 s, ATC empty. Same result with the sim's trace on and off. The failure showed only with the trace off; the two orders of events differ by timing.
- **Regressions:**
  - w3_side_atc passes every check: 44 of 44, no support in the tunnel, every turtle docked, worst 190 s.
  - w3_bay_types150 passes everything: 34/34, 33 supports, 16 mine jobs, worst 190 s.
  - w3_depart_off_dock, w3_atc_pair_split, w3_atc_partner_left and w3_atc_support_gave_up pass.
  - Suites 907/0 on both builds; CC local limit: turtle_base 147, atc 47, central_server 195.
  - The new tests (test_atc +1, test_control_loop +1) each fail without their change.
- **Layer 2, T2, one pair, 1x:**
  - **w3-atc-lost-release-a** (pin 3147140): 80% of messages to the ATC were dropped for 4 min while node_96 drove home.
    - 3 minutes after it docked, the ATC still held J1, R1, R2 and S1 for it: the stale booking.
    - Once its next departure was let in, nothing of the old return was held, and the job completed.
    - Its end checks ran too early: the warehouse logs its own "Job complete" minutes before the delivery is home. That's fixed.
  - **w3-atc-lost-release-b** (pin 3698e6a): 11 of 11, every turtle docked, ATC empty at the end.
    - But its stale-booking evidence was a summary 5 s *before* the delivery docked, and none after named it. Its cancel had likely got through, so that check had nothing to judge in b.
    - The check is tightened in aca0380 to count only summaries after docking. Run a is the evidence the mechanism works on the real game.

A new card, "SHAKEOUT blocker - side-test re-run on 360d551 gridlocked...", is in "Done - not server validated" with this.
