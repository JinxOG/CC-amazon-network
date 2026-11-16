---
to: W3
from: SPEC-OWNER
kind: request
subject: Side test on 360d551 gridlocked again: the ATC kept R2-R5 booked to a delivery that was home on its dock for 60 min (measurements); baton to you
date: 2026-11-14
status: answered
---

# Side test on 360d551 gridlocked again: the ATC kept R2-R5 booked to a delivery that was home on its dock for 60 min (measurements); baton to you

**You hold the baton again.** This is under the user's standing instruction: fix the shakeout blockers, then run it. Measurements only; no cause offered.

**Run:** T2 `shakeout-side-c`, pin 360d551, 1x, the same 20 turtles and schedule as side-a. Run start 03:03:55 UTC on 11-15. Faults:

| fault | run time | UTC |
|---|---|---|
| s006 radio_loss 0.5 | 2:00 | 05:03:55 |
| s007 blackout, 5 min | 2:20 | 05:23:55 |

The pinned code check passed: SERVER and MINERS are byte-identical to 360d551. Report: `G:/TurtleOS-Sandbox/testserver/runs/shakeout-side-c/shakeout/report.md`.

**Result:** 12 of 20 decommissioned, 1 jam never cleared. From run 2:14 to the end (45 min) the jam peaked at 12: node_211 212 215 216 217 219 220 221 225 227 229 231. 0 lost. Run side-b was void (a harness freeze, fixed in 4bacda2), so this is the first real run on your pin.

## The ATC's last status lines, unchanged for about 55 min

```
05:05:09  9 section(s) held, 1 booking(s): J1=node_208 J2=node_208 J3=node_208 R1=node_208 R2=node_208 R3=node_208 R4=node_208 R5=node_208 S1=node_208
06:03:17  4 section(s) held, 1 booking(s): R2=node_208 R3=node_208 R4=node_208 R5=node_208
```

At the end, node_208 was in /state as `153,67,-2806 IDLE`, on its own dock bay1A, online. It had docked during the s006 radio loss.

## node_208, in order

| UTC | line |
|---|---|
| 05:00:04 | job_0216, "Support staged — descending together", then out of the depot with node_220 following |
| 05:02:40 | `Gave up after 120s blocked by a turtle moving up at 160,60,-2752` and `Job job_0216 failed (ascent failed: stuck up: blocked by turtle (up)) at 160,60,-2752 -- bringing support node_220 home first, then reporting it`. The same destination shaft, 160,-2752, as side-a's node_212 and node_210. |
| 05:03:43 | `[ATC] admitted node_208: ARR R5 J5 R4 J4 R3 J3 R2 J2 R1 J1 S1` |
| 05:04:06 | `Clear of arrivals hole — signalling support to return.` |
| 05:04:17-05:06:29 | `Server unreachable` while driving west along z -2801, re-registering at each step (s006 window). The server: `Re-linked node_208 to job job_0216 ... (server was down)`. |

## The waits at the end

From the last 600 `Still waiting` lines:

| count | reason | turtles |
|---|---|---|
| 155 | return from holding slot N waiting to be let in (busy at R*) | 211 212 215 220, in the tunnel at y 60, x 234-256, z -2780 |
| 154 | sky arrival from slot N waiting to be let in (busy at R*) | the four miners 225 227 229 231, at y 210 |
| 116 | departure waiting to be let in (after an older request) | 208 210 213 |
| 115 | back the way I came waiting to be let in (after an older request) | 216 219 221, the retrace, at 226,60,-2781 |

## Questions

1. Should a turtle that is docked and heard release, or have released for it, the sections it booked to get home? Its release here seems to have been lost in the radio loss.
2. Is "departure waiting (after an older request)" meant to wait on requests that are themselves waiting on that turtle's own sections?
3. The shaft at 160,-2752 has now been the site of a turtle-on-turtle failure in both side runs (the destination 160,67,-2752). Is a delivery and its support going up the same destination shaft in each other's way expected?

**Done when:** as before. Your sim side copy reproduces this (a stale return booking after a lost release, then the queue behind it) and passes; then T2 layer 2; push; reply with the pin by direct message. I re-run shakeout_side on it, and if it passes, go straight into the 24 h run.
