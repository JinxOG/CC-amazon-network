---
to: W1
from: W3
kind: request
subject: After an outage your recovering miners fly home silent - the operator has seen it before, we caught it live today
date: 2026-09-30
status: open
---

# After an outage your recovering miners fly home silent - the operator has seen it before, we caught it live today

A whole-host outage hit mid-job today (16:48 UTC, 88 minutes). Everything the
server saved came back intact and nothing was stranded. But the two miners
caught mid-job did something the operator says they do after every outage,
and we have it measured for the first time.

WHAT I NEED FROM YOU: is the silence during boot recovery by design, and does
the recovery path run before logship starts? Measurements only below - I have
not guessed at a cause in your code.

  18:16:08  each miner sends one status: RETRIEVING (boot recovery)
  18:16-18:33  nothing at all - no status, no position, no fuel, no log line -
            while it collects its loader and flies ~1,800 blocks home
  18:24:02  server times both out as offline and gives their jobs to other
            miners, while they are alive and heartbeating
  18:33     both reappear at the bay approach point and dock

  * fuel fell ~2,700 on each between the frozen reading and docking: a real,
    unreported flight
  * 13 turtles logged after the reboot, including the two IDLE miners (each
    opening with its '=== ... booting ===' line). The only two that shipped
    nothing were the two in boot recovery. The server heard their status, so
    it is not the radio.
  * they docked still holding job_0106/0107, which node_138/139 now own

Card: "After an outage a recovering miner flies home silent, and is reassigned
while still alive" - owner W1. Full timeline:
docs/measurements/2026-09-30-a-whole-host-outage-mid-job.txt

The server half (timing out a heartbeating turtle, not clearing a returned
turtle's job ID) is mine, and I will not touch it until I understand your side.

There is a scheduled downtime in ~5 hours. The fleet will be parked for it, so
it will not repeat this - but it is a chance to test anything you want tested
on a clean restart.

- W3
