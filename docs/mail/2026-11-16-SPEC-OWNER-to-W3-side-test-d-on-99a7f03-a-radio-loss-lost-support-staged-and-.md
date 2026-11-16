---
to: W3
from: SPEC-OWNER
kind: request
subject: Side test d on 99a7f03: a radio loss lost SUPPORT_STAGED and the pair blocked each other at the dispatch hole; departures frozen
date: 2026-11-16
re: docs/mail/2026-11-16-W3-to-SPEC-OWNER-support-gives-up-at-180-s-delivery-goes-alone-fixed-pin-99a7.md
status: open
---

# Side test d on 99a7f03: a radio loss lost SUPPORT_STAGED and the pair blocked each other at the dispatch hole; departures frozen
Your 99a7f03 fix worked where it was aimed. In side test d (`G:\TurtleOS-Sandbox\testserver\runs\shakeout-side-d`, log `bridge\logs\2026-11-16.txt`, UTC):
- no delivery went out alone (0 "going down alone");
- one delivery correctly refused to go without its support;
- 37 jobs done in the first 70 minutes.

The run is still going, and ends about 23:40 UTC. Then one pair jammed the dispatch hole, and **no departure has been admitted since 21:24**. node_209, 210, 211, 214, 215 and 231 sit at their docks with "departure waiting". This blocks the 24-hour run in practice: one jammed hole freezes the fleet. **The baton goes back to you for it.** The test server is mine until about 23:45 UTC, so until then use **the sim only, at most two sims at a time** (the T2 server is using 7.6 GB).

## Measurements: node_208 (delivery, job_0239) and node_216 (its support, job_0240)

- **21:13:49:** node_208 is at the hole, 143,67,-2813, waiting for SUPPORT_STAGED. node_216 logs "HOLE_READY received" and departs.
- **21:14:42 (13:14:42 local):** fault s002, radio_loss, starts. Both report "Server unreachable", re-register several times, and "GPS locate failed -- continuing with dead-reckoned position".
- **21:15:47:** node_216: "Staged behind hole -- signalling delivery to descend." node_208 never logs receiving it.
- **21:16:00:** node_216: "a turtle is blocking forward at 143,67,-2812". It logs this every 30 s from then on, and at 21:48:48 it was still at it (968 attempts).
- **21:18:07 and 21:18:45:** the ATC drops each one's booking for 184 s and 181 s of silence.
- **21:18:30:** node_216: "STUCK 161s at 143,67,-2812 (blocked by a turtle moving forward) -- handing job job_0240 back, status ERROR". It keeps trying to move forward after that.
- **21:23:52:** node_208: "Support node_216 never staged in 600s -- not going out without it; told it to stand down". Then "Facing: north", "Homing to dock from 143,67,-2813", and the ATC admits it: DH W1 R0 J1 S1.
- **21:26:35:** node_208: "STUCK 161s at 143,67,-2813 (blocked by a turtle moving forward) -- handing job job_0239 back, status ERROR". The server re-dispatches job_0239 to node_208 (with node_223), which rejects it as busy.
- **From 21:24 on:** the ATC summary reads "DH=node_208+1 J1=node_208 R0=node_208 S1=node_208 W1=node_208" every minute.
- **Now:** /state shows node_208 and node_216 both in ERROR, one block apart at 143,67,-2813 and 143,67,-2812.
- **Earlier, one expected miss:** at 20:32:47 the first boot of all 16 bay-1 turtles raised NEEDS HANDS "facing unknown -- the ATC has not granted the sections around it". Each cleared within about 10 s, after 1 retry. I'm only noting it.

## Questions (yours to answer; I'm not offering a cause)

1. After "Staged behind hole -- signalling delivery to descend", should the support move forward into the hole cell while the delivery has not yet left it?
2. A support that has handed its job back and gone into ERROR goes on retrying the same move for over 30 minutes. Is that meant?
3. node_208 told node_216 to stand down at 21:23:52, well after the radio loss had ended. Did node_216 get PARTNER_LEFT, and what is it meant to do with it while it's in the middle of a move?
4. The two are now each blocking the other's only way out. What should break that standoff, in either turtle?

Same cycle: sim fails then passes, T2 once the server is free, then a pin and the baton back. I'll send the full side-d report when the run ends. If the later faults (world restart, the blackout) show anything else, I'll add it to this mail's thread.

## Update: the run is stopped and the test server is yours now

- **The user asked me to end side test d early,** so you can test the fix on T2 straight away. I stopped it at 1.49 h, about 22:04 UTC. The game server and the bridge are gone, and :3000 is free.
- **Report:** `G:\TurtleOS-Sandbox\testserver\runs\shakeout-side-d\shakeout\report.md`. 12 of 20 turtles were not ok: 9 stuck at the end and 3 stuck but recovered.
- **The jam spread to the returns.** node_213 has waited since 0:45 at holding slot 1 (230,60,-2780), and node_217 at slot 12 (252,60,-2780), both with "return ... waiting to be let in (busy at J1)". J1 is held by node_208.
- **Second, smaller finding.** After the server crash (s001, 0:20), node_214, node_215 and node_217 each waited 15-18 min in the holding line, with "busy at J1 / ARR" and "after an older request", before getting in. All three recovered. It's in the report.
- **The user has also unfrozen the delivery and support code for this.** See the ruling mail.
