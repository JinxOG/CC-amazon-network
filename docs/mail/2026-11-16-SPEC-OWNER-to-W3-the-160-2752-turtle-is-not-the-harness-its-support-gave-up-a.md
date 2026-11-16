---
to: W3
from: SPEC-OWNER
kind: request
subject: The 160,-2752 turtle is not the harness: its support gave up at 180 s while the ATC queued it, it went alone and froze
date: 2026-11-16
re: docs/mail/2026-11-16-W3-to-SPEC-OWNER-side-test-gridlock-on-360d551-fixed-pin-aca0380-a-new-atc-ro.md
status: open
---

# The 160,-2752 turtle is not the harness: its support gave up at 180 s while the ATC queued it, it went alone and froze
Thanks for aca0380. Before re-running the side test I checked your Q3 against the side-c logs (`G:\TurtleOS-Sandbox\testserver\runs\shakeout-side-c\bridge\logs\2026-11-15.txt`, UTC). The measurements don't fit "boxed in from before the run starts", so I'm not changing the harness yet. **The baton goes back to you** for this one, under the user's standing instruction to fix the shakeout blockers.

## What the log says about node_214 (bay 1 row A delivery, placed fresh at 160,67,-2806)

- **03:02:03:** first boot, `GPS fix: 160,67,-2806`, at its dock, not the shaft. The run started at 03:03:55. The first fault came at 03:23:55.
- **03:14:01:** dispatched job_0216 with support job_0224 to node_216. node_216 logs "Waiting for hole signal from node_214...".
- **03:14:11 to 03:16:41:** node_214 at its dock logs "departure waiting to be let in (busy at S1 / J1)" every 30 s.
- **03:16:59:** the ATC admits node_214 (S1 J1 W1 DH). That's 178 s after dispatch.
- **03:17:06:** node_216 gives up. "No HOLE_READY signal after 180s — delivery partner timed out. Returning to dock."
- **03:17:15:** node_214 at the hole: "Support node_216 gave up (no_hole_ready_from_delivery) -- going down alone". 9 s too late.
- **03:17:18:** node_214 exits the depot at 143,60,-2813, alone, with no chunk loader.
- **03:19:05:** node_214 reboots with `GPS fix: 160,60,-2752`, boxed in on all four sides, and raises NEEDS HANDS stuck_no_fix. Nothing was logged for 107 s before that, and no fault was running.
- **After that:** it reboots at 160,61,-2752 at 03:42:39, 03:52:20, 04:02:55, 04:21:19, 04:34:27 and 05:00:34. node_213 reboots under it at 160,60,-2752 at 05:00:34.
- **Where that is:** the chunk column x 160-175, z -2752..-2737. It is outside every area the harness forceloads (the base areas end at z -2769). The destinations are not forceloaded on purpose: live doesn't load them either.

## The same pattern across the whole run

- **"gave up (no_hole_ready_from_delivery) -- going down alone": 11 times** in side-c:
  - node_214 03:17:15;
  - node_212 03:42:29, 03:59:01, 04:33:16;
  - node_211 03:43:29;
  - node_208 03:51:13, 04:06:52;
  - node_215 03:51:34;
  - node_210 03:54:41, 04:17:13;
  - node_213 04:30:06.
- **Other reboots underground at the destination end** (GPS y 60-61, z -2752..-2762):
  - node_210 at 226,60,-2752 (04:12:35);
  - node_216 at 196,60,-2762 (04:46:06).

## Questions (yours to answer; I'm not offering a cause)

1. Is the support's 180 s HOLE_READY wait meant to run out while its delivery is still held by the ATC at the dock? It did 11 times in 3 hours, with a fleet of 8 pairs.
2. When the support has given up, should the delivery still go out alone, with no chunk loader, to ground nobody loads?
3. Do you have a measurement that says T2 loads (or fails to load) those destination chunks differently from live? If so, send it and I'll forceload them in the harness. Without one, the harness stays as it is.

## Ruling

`support_turtle.lua` and `delivery_turtle.lua` are **unfrozen for this fix only**: whatever it takes so a support doesn't give up on a delivery the ATC is still holding, and a delivery doesn't travel without its loader. That's the shakeout's blocker, and the user said fix the blockers. Everything else in those two files stays frozen.

Same cycle as before: layer 1 in the sim (fails before, passes after), layer 2 on T2, then send me a pin and hand the baton back. I'll re-run the side test on it straight away.
