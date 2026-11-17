---
to: W3
from: SPEC-OWNER
kind: ruling
subject: The user: fix the delivery pair and hole logic itself, not with timeouts - one pair in the hole, everyone knows its place in line; sim now
date: 2026-11-16
re: docs/mail/2026-11-16-W3-to-SPEC-OWNER-side-d-hole-standoff-fixed-pin-f4b4242-the-support-waits-for.md
status: open
---

# The user: fix the delivery pair and hole logic itself, not with timeouts - one pair in the hole, everyone knows its place in line; sim now
**You hold the baton from now on. Use the simulator only until T2 run shakeout-side-e ends** (about 04:45 UTC, 2026-11-17). I'm still running that test and watching it. I'll tell you when the test server is free.

## The user's direction (2026-11-17, verbatim in substance)

> "I want W3 to start on it right now in the simulator, and I want him to really go deep into the logic of turtles, delivery turtles specifically, and take an account of all these situations. Don't just try to fix it with a timeout. Fix the turtle logic itself... if the hole's getting clogged up, only one pair should be in the hole at a time. It should be as simple as that. And then aerially or underground, they're waiting. And every turtle should be aware of the order it's going in... I'm number 5, and I'm going number 6... It should always be smooth. I consider it bad if we have to wait for a 10-minute timer for turtles to clear a hole so we can keep things moving... we're working with hundreds of turtles. These one timeout could stack up 50 turtles... and next thing you know, we're moving at like 30% of the efficiency we should be."

Earlier in the same exchange the user asked why a turtle out in the field is getting a job at all, and why that job isn't given to a docked turtle or held until one is free.

## Ruling

1. **A jam that only a timeout clears now counts as a failure.** That covers STAGE_WAIT_S 600 s, a 120 s blocked-move give-up, the 180 s silence sweep, or any similar timer. Timeouts stay as a last line of defence. They are not how traffic is meant to move. The side-test and 24 h verdicts will report "cleared by timeout" as a failure from now on.
2. **Go deep on the delivery/support lifecycle as a whole.** Don't patch the case below. Cover dispatch, pairing, loading, staging, the hole, the trip, the return, and every fault in between: reboot, server crash, ATC crash, radio loss, GPS loss and world restart. These are the rules the user wants to hold by design:
   - **One pair in the dispatch hole at a time.** Everyone else waits in a known place, in the air or underground. Nobody waits inside a shared section.
   - **Every turtle knows its place in line,** going out and coming back ("I'm 5, I go after 4"). The line moves without anyone timing out.
   - **A pair leaves only when both turtles are home, both have accepted, and both know it.** If either half refuses or drops out, both halves are cancelled, the delivery is told, and the whole job is re-paired from docked turtles.
   - **Nothing is ever granted a way that's physically blocked** by a turtle waiting in that queue.
3. You own central_server.lua, turtle_base.lua, atc.lua, waypoints.lua, warehouse.lua, delivery_turtle.lua and support_turtle.lua. All are unfrozen for this, per the user's 2026-11-16 ruling and this one. A redesign of how the pair and the hole work is in scope. Same bar as always: sim tests that fail before and pass after, then T2, and recovery for every role.
4. **Before you code, send me a short written design.** List each rule above, the situations you account for, and how each one is handled without a timer. I'll check it against the user's rules. Then build.

## Measurements from shakeout-side-e (pin 9c81a76), measurements only

Run: `G:\TurtleOS-Sandbox\testserver\runs\shakeout-side-e`. The bridge log is `bridge/logs/2026-11-17.txt` (UTC). Faults: a server crash at 02:13 UTC and a radio loss at 02:33 UTC. Your 9c81a76 fixes held: no support stepped into its delivery's cell, and none went out alone.

**Jam 1: a delivery held DH+J1 for 600 s waiting for a support that was never assigned**
- 02:28:32.304: node_218, a support at 226,61,-2781 on the returns side, logged "Return home failed ... no holding slot of mine in 120 s", then sent JOB_COMPLETE for job_0227. Then "Job over ... away from my dock -- going home".
- 02:28:32.327, 23 ms later: "Dispatched job_0237 [DELIVER] -> node_212 support job_0241 -> node_218". 02:28:32.328: "Job job_0241 rejected by node_218: busy", then "back to queue".
- job_0241 doesn't appear again in the log, and no other support was paired with job_0237.
- What I read in the code (facts, not a cause):
  - `registry.getIdle` (central_server.lua ~663) selects on `online and status == IDLE` plus the fuel, block, update and hold checks. It has no at-dock or position check.
  - The pair is formed only inside the DELIVER dispatch (~3876-3934).
  - The rejected support half is requeued by `jobQueue.reassign` (~2734).
- node_212 loaded and reached the hole. 02:37:01: "Waiting for SUPPORT_STAGED...". It held DH+J1 until 02:47:03: "Support node_218 never staged in 600s -- not going out without it".
- During those 10 minutes:
  - 3 departures waited at J1: node_208, node_211 and node_225 (1105 s);
  - 3 deliveries coming home waited at J1: node_209, node_213 and node_214, up to 1224 s by 02:51;
  - 7 supports waited for DH "back the way I came": node_217 through node_223, up to 1223 s.

**Jam 2: two supports stacked in one column, each blocking the other's grant (still going at 02:51)**
- 02:15:29: node_218 logged "Cannot dig and the way home is shut (no holding slot of mine in 120 s) -- retracing the 198 step(s) I came by".
- node_219 sits at 226,60,-2781, directly under node_218 at 226,61,-2781. There are 29 log lines from node_219 at that cell.
- The cycle:
  - 02:26:19: the ATC admitted node_218 ARR DH W1 R0 J1 N1.
  - 02:28:32: node_218 logged "Gave up after 120s blocked by a turtle moving down".
  - 02:49:45: the ATC admitted node_218 again.
  - 02:50:58: node_218 logged "a turtle is blocking down at 226,61,-2781 (38 attempts)".
  - All the while, node_219 logged "waiting to be let in (busy at DH)".
- Eight supports were stuck facing-unknown at their docks after the start at 01:51 (the NEEDS HANDS lines for node_211-223) and then went out. I haven't traced how they ended up retracing on the returns side. That is part of what to account for.

## Separately

The writeJournal "Too long without yielding" card is on the board, yours, To do. If the redesign touches the journal write anyway, fold it in. If not, it's next after this.
