---
to: SPEC-OWNER
from: W3
kind: reply
subject: Side-d hole standoff fixed: pin f4b4242 - the support waits for the hole cell to clear and repeats SUPPORT_STAGED; two more causes found; baton back
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-side-test-d-on-99a7f03-a-radio-loss-lost-support-staged-and-.md
status: open
---

# Side-d hole standoff fixed: pin f4b4242 - the support waits for the hole cell to clear and repeats SUPPORT_STAGED; two more causes found; baton back
**Pin: `9c81a76`** (not f4b4242 as the subject says: two more causes turned up after I named the file). The baton is back with you. The test server and host are free: no java process, nothing on :3000, no sim running.

## Your four questions

1. **After "Staged behind hole", should the support move forward into the hole cell while the delivery is still in it?**
   - No.
   - **Fixed:** at staging it faces the hole and waits until the cell has been **empty for 3 s in a row**. Meanwhile it repeats SUPPORT_STAGED every 5 s, so one lost in a radio loss is sent again.
   - **Why 3 s:** a rebooted delivery measuring its facing steps out of the cell and back. One look at the moment the cell was empty sent the support in behind it.
   - **When it goes home instead:** if its delivery stands it down, it is recalled, or the delivery hasn't gone in 600 s. In each case it goes home and the job goes back.
   - The delivery now takes SUPPORT_STAGED only from its current job, since the repeats leave copies behind.
2. **A support that handed its job back and went into ERROR keeps retrying the same move for over 30 minutes: meant?**
   - Inside the base, yes, by design (2026-11-03). The ATC granted the section, so whatever blocks it is a turtle that can't move. It hands its job back at STUCK_S, and carries on when the way clears.
   - The flaw was the move itself, into a cell its own delivery held. It no longer makes that move.
   - It also went silent while waiting, and the ATC dropped it at 181 s. Any turtle waiting in the base now tells the ATC every 10 s (below).
3. **Did node_216 get PARTNER_LEFT, and what is it meant to do with it in the middle of a move?**
   - I can't tell from the log whether it arrived. Nothing logs PARTNER_LEFT on arrival, and the radio loss had ended, so it most likely did.
   - Either way nothing acted on it: the flag is set as the message comes in, but the blocked-move loop never reads it.
   - Now the staging wait reads it every second, and the support never enters that blocked move.
4. **They are each blocking the other's only way out. What should break the standoff?**
   - Neither turtle should get into it now: the support never steps into its delivery's cell.
   - If the delivery gives up first, the support at staging goes home: at once on PARTNER_LEFT, or after its own 600 s if that is lost too. The delivery's way home then clears.
   - **The case tested:** the delivery rebooted in the hole cell. Its support is let home through what its own delivery holds; it was held there "busy at W1" before (sameParty below).
   - **Not solved:** a general two-turtle head-on elsewhere in the base. The ATC keeps turtles out of each other's sections, except a pair sharing DH, which is the only place this arises.

## Two more causes, found by the regressions

- **A turtle waiting in the base without a word to the ATC was taken for dead.** This was in w3_side_atc on 17d6b30.
  - node_52 was back in DH by its trail, with no GPS to measure its facing. The ATC swept its booking at 180 s, a delivery was let into W1, and the two met head-on.
  - Side-d's node_216 went silent the same way (181 s).
  - **Now:** waiting for a fix, or behind a turtle, it sends an ATC_REPORT every 10 s (`atc.keepAlive`). That keeps its booking alive, or retakes the section it stands in. With no position measured yet, an empty report still keeps it alive.
  - **Why 10 s, not 30:** with 30 s, on 9ca58c9, node_53 had every report lost in the 50% radio loss and was swept 2 s after it measured. Then its re-claimed DH and node_55's W1 held each other.
  - **Residual (yours to rule):** a live turtle swept anyway can still leave a circle when it re-claims. It now takes 180 s of total silence while others are heard.
- **detectFacing measured the position by GPS and then kept the dead-reckoned one.**
  - A support back in the building believed it stood one block west of where GPS had just put it. It drove home one cell off, into the next turtle's dock, and reported STUCK (w3_depart_off_dock).
  - **Now:** it keeps the position it measured.
- **A pair's sharing (atc.lua sameParty):** a delivery's own bookings count as its party's whatever group they carry. A reboot forgets the group. The support's own bookings likewise count as its delivery's.

## Not mine, measured on the way

**"Too long without yielding" in writeJournal** on T2 run b (17d6b30):
- node_96 logged "Journal write failed ... Too long without yielding" right after leaving the depot, and was never heard from again (turtle_timeout).
- The same error at the same call hit node_283 in shakeout-faults-c on 11-13 (pin 903f354), before any of today's changes.
- Run c's rebooted delivery stopped heartbeating once it was measured, and its last journal write left an empty journal.tmp. That's likely the same.
- I haven't chased it: a turtle that dies this way leaves its job. I'm only measuring it here, as asked. It probably needs its own card.

## Evidence

- **Layer 1, the sim.** Each check fails on the commit before it and passes after.
  - **w3_atc_staged_lost** (SUPPORT_STAGED lost until 15 s after staging):
    - on 99a7f03, 6 FAIL: the pair frozen at 143,-2813 and -2812, the ATC holding the corner, the second order never let out, exactly side-d;
    - now 8/8.
  - **W3_LONG=1** (the loss outlasts the delivery's 600 s, and PARTNER_LEFT is lost too):
    - on 99a7f03, the same standoff;
    - now 8/8, with the support giving up after 600 s.
  - **w3_atc_silent_in_base** (a delivery rebooted in J1 with GPS down 5 min, plus a computer chattering to the ATC):
    - on 17d6b30, "node_34 silent 183s: booking dropped, including W1 J1 it had entered";
    - now 8/8.
  - **W3_AT_HOLE=1** (rebooted in the hole cell):
    - on f4b4242, the pair frozen at the hole;
    - now 7/7.
- **Regressions on the final code:**
  - w3_side_atc 9/9: 42/42 delivered, worst wait 250 s, no booking swept (16 in-base waits for a fix);
  - w3_bay_types150 15/15;
  - w3_atc_partner_left 10/10, w3_atc_pair_split 8/8, w3_atc_small 6/6 (its test-only fix is in too: it now waits for the mine job);
  - w3_atc_support_gave_up 7/7, w3_depart_off_dock 9/9, w3_atc_lost_release 5/5;
  - w3_atc_staged_lost 8/8 both modes, and w3_atc_silent_in_base 8/8 and 7/7.
- **Suites:** 915/0 on both builds. New tests:
  - test_atc_turtle +1 (the keep-alive);
  - test_retrace +1 (the measured position);
  - test_atc +1 (party sharing).
  - Each fails before its change.
- **Layer 2, T2, one pair, 1x:**
  - **w3-atc-staged-lost-b** (17d6b30): the support staged inside a 90 s loss on channel 5 and repeated SUPPORT_STAGED. node_96 heard it 17 s after the loss and they went down together.
  - **w3-atc-staged-lost-f (pin 9c81a76): 19/19.** Report: `G:\TurtleOS-Sandbox\testserver\runs\w3-atc-staged-lost-f\report.md`.
    - **Part 1:** every message to the delivery on channel 5 was lost for 90 s from its departure. node_145 staged inside the loss and repeated SUPPORT_STAGED. They went down together, no STUCK, and both jobs completed.
    - **Part 2:** GPS hosts down 300 s, and node_96 rebooted inside the base. It waited 24 tries of 10 s for a fix, and the ATC never gave away a section it stood in. Its one STUCK (waiting for its support to leave) recovered, and job_0208 completed.
    - **At the end:** the ATC was empty, and 16/16 turtles were docked.
  - Run d didn't start: one turtle (node_142) missed the pin update, 15 of 16 updated. Run e passed everything except two checks of my own that were wrong. Both are fixed in f.
