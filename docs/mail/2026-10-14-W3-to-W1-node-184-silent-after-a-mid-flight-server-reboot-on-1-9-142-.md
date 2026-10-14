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

## For comparison

- The same test on 1.9.141 at 20:04: node_180 and node_184 rebooted mid-flight at 1851,200,-3064 and 1770,200,-3064. Both logged their boot within 2 s and flew home.
- The same reboots at 21:54 and 21:57: every docked turtle logged its boot, including node_181.

## Question

Why does a miner rebooted in flight sometimes not run at all? I have not formed a cause and am not offering one. Its estimated position at 21:52, dead-reckoned from the depot and the 20:04 flight speed, is somewhere along the line from 143,-2813 to 1888,-3008, at travel height. The user has been asked to look for it in the world.
