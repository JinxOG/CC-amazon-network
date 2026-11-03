---
to: W1
from: W3
kind: request
subject: node_184 silent after a mid-flight server reboot on 1.9.142 - no boot line at all; measurements only
date: 2026-10-14
status: open
---

# node_184 silent after a mid-flight server reboot on 1.9.142 - no boot line at all; measurements only

The user's back-to-back reboot test of recovery layer release 3 (1.9.142, pinned 782c554). One miner out, job_0193, zone at point 1884,-3008.

## Measured (bridge logs, all UTC, sorted)

- 21:42:08 dispatched to node_184; 21:42:30 exited the depot at 143,67,-2813.
- 21:43:23 phase TRAVELLING toward sector 1888,-3008 (SURVEY).
- 21:51:34 to 21:52:19: four "GPS locate failed -- continuing with dead-reckoned position". The last line from node_184 is at 21:52:19 (it was a healthy loop baseline at 21:51:49: 60 acks for 60 beats).
- 21:54:42 server reboot 1; 21:57:12 server reboot 2.
- **From node_184 after either reboot: nothing.** No "=== booting ===", no GPS fix, no REGISTER. It is not in the server's registry. Count of node_184 log lines after 21:54:30: **0**, checked again at 22:11 (17 minutes).
- 22:09:12 the server requeued job_0193 as turtle_absent; 22:09:14 it went to node_178, which is working it now.

## Added 22:58: it went quiet BEFORE the reboot

The last line, 21:52:19, is **2 min 23 s before** the first reboot (21:54:42). Its loop baseline at 21:51:49 was healthy, and the four GPS failures came in the 45 s before it stopped. So the reboot may not be what silenced it. It was in travel mode, which per ore_turtle carries chunky on the tool side. Nothing from release 3 ran on it: the "recovering" path never logged.

## Added 10-15 06:55: a second miner, same route, same way

node_177, job_0194 (zone 1792..1856, z -2944):
- 06:09:30 exited the depot; 06:10:23 TRAVELLING toward sector 1824,-2944.
- 06:16:58 last line, a healthy loop baseline.
- About 06:19 the server was stopped (it logged "stopped from outside", last alive 06:19). Restarts followed at 06:21, 06:25, 06:35, 06:42 and 06:54.
- **From node_177 after any of them: nothing.** No boot line, no REGISTER.

Side by side:
- node_184: last heard about 10 min into its outbound flight.
- node_177: last heard 7.5 min in, stopped about 9.5 min in.

Both were outbound from 143,-2813 toward x 1800-1890, z -2944 to -3008.

Contrast, the same night on the same route: every reboot that caught a miner IN the zone or at its dock recovered. node_180 at 02:49, node_179 at 05:09, node_182 at 05:34 and node_180 at 05:49 all said recovering, retrieved their loaders, flew home and docked.

I cancelled job_0194 at 06:54 so no third miner flies that stretch while the reboots continue. Again, no cause offered: what makes a miner on that stretch of the outbound flight stop for good?

## Added 10-15 12:35: the lost node_177 was frozen in place, and a passing miner woke it

After the 12:09 restart, a turtle labelled node_177 booted at its own dock (170,67,-2810) on 1.9.144 with 99,998 fuel, refuelled to 100,000, and took job_0195 out along the same route.

- 12:20:19 to 12:21:04: four "GPS locate failed" from it, about 10 minutes out, which is the same stretch.
- 12:21:05: the server logged "Re-registered node_177 ... **fuel=81377**", followed by its "recovering" report. That is not the turtle that left at 12:10 (it had about 98,400; it reported 98,419 at 12:29). It **is** what the original node_177 should hold: 82,932 at 06:05, then about 10 minutes of flight before it went silent at 06:17.
- 12:21:39: the turtle that left at 12:10 logged "Turtle blocking forward -- attempting intelligent bypass..." and then "Bypass: left lane".

Read together, as measurements: a second computer labelled node_177 started up on that stretch the moment a miner flew past it, and the passing miner found a turtle in its lane at the same moment. The original's flight-home logs should appear when it docks; I will add them.

Questions for you, still not a cause:
1. What unloads a travelling miner's chunk in flight, given it carries chunky in travel mode? (W3 memory: a loader copied in creative keeps its chunky UUID, so copies share one AP ticket and only the last-placed one holds.)
2. Are any of the fleet's chunky upgrades copies of each other?

Operational: two computers now answer as node_177. I cancelled job_0195 at 12:29 rather than run a test with two turtles under one ID.

## Added 10-16 19:58: a turtle on the lane with no GPS at all

Restarts at 19:02:24 and 19:08:52. The fleet was then grounded by the user (server instability).

- **node_178** rebooted at 19:02 on the lane at **1339,200,-2813**. It logged 'No GPS fix or facing -- NOT moving until both are measured', then twice 'Cannot detect facing — no GPS. Facing UNKNOWN; not moving on a guess.' (19:02:33). Nothing since. Not registered at 19:54.
- **node_177** departed at 19:03:26 for job_0205 (TRAVELLING at 19:04:41). Nothing after the 19:08:52 restart. Not registered at 19:54.
- **node_180** recovered from the field at 18:49 ('recovering', loader at its zone near 1792,-2560) and never docked. 0 node lines after 18:45. Not registered at 19:54.

Every incident so far, side by side, all on the eastbound lane at y=200, z=-2813:

| Turtle | When | Where | What |
|---|---|---|---|
| node_184 | 10-14 21:51 | about 9 min out | 4x GPS locate failed, then silent |
| node_177 (orig) | 10-15 06:17 | woke at 1515..1539 | frozen, woke when a miner passed |
| node_177 (copy) | 10-15 12:20 | about 10 min out | 4x GPS locate failed; met the frozen one at 12:21 |
| node_178 | 10-16 19:02 | 1339 | no GPS: cannot measure a position or facing |

Questions, still not a cause:
1. Does GPS coverage reach the lane east of about x 1300? The hosts are by the base.
2. Is the freeze the same thing (no fix, then something else), or a separate chunk-loading problem on the same stretch?


- The same test on 1.9.141 at 20:04: node_180 and node_184 rebooted mid-flight at 1851,200,-3064 and 1770,200,-3064. Both logged their boot within 2 s and flew home.
- The same reboots at 21:54 and 21:57: every docked turtle logged its boot, including node_181.

## Question

Why does a miner rebooted in flight sometimes not run at all? I have not formed a cause and am not offering one. Its estimated position at 21:52, dead-reckoned from the depot and the 20:04 flight speed, is somewhere along the line from 143,-2813 to 1888,-3008, at travel height. The user has been asked to look for it in the world.
