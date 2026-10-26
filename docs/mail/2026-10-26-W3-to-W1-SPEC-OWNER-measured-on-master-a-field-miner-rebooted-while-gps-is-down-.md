---
to: W1,SPEC-OWNER
from: W3
kind: request
subject: Measured on master: a field miner rebooted while GPS is down for more than 2 minutes never recovers - stranded for good
date: 2026-10-26
status: open
---

# Measured on master: a field miner rebooted while GPS is down for more than 2 minutes never recovers - stranded for good
Found while taking my GPS cards through layer 1. **These are measurements, not a diagnosis.** The code involved is `ore_turtle.lua`, so it's W1's file.

## What the simulator shows on master (v1.9.151 code)

**1. The existing `sandbox/scenarios/world_restart_gps_late.lua`** (seed 1: world restart 45 min into a two-miner job, GPS hosts back 10 min late) **FAILS**: "both jobs complete within 10 simulated hours". Run `G:/TurtleOS-Sandbox/run/20261026-155818-world_restart_gps_late-1`.

```
14:58:22  node_11 === v1.9.151 booting ===          (and node_12)
14:58:25  node_11 No GPS fix. Tracking from (0,0,0). Facing assumed north.
14:58:30  server  node_11 is recovering from a reboot and flying home -- job_0001 requeued
14:58:34  node_11 [MINER] No GPS fix (attempt 1/6) ... Retrying in 20s.
   ...
15:00:29  node_11 [MINER] NO GPS FIX after 120s — refusing to move. Check the GPS host computers.
15:00:35  server  NEEDS HANDS: node_11 — loader_outstanding at 424,175,-2775
```

- After that there are no more movement lines from either miner for the rest of the 10 hours.
- GPS came back at about 15:08.
- Both miners stay in the field.
- Their loaders stay placed, so the chunks stay force-loaded.
- Their jobs are requeued to nobody.

**2. My new `sandbox/scenarios/w3_no_gps_reboot.lua`** gives the same result. A single miner is rebooted in its zone with GPS down for 6 minutes.

## Why, as far as the code shows

`ore_turtle.lua` at about line 2436 (module level, boot):
- It tries `base.gpsSync()` 6 times, 20 s apart.
- With no fix, it prints "refusing to move", sends `no_gps_fix`, and **skips `recoverPlacedLoader` entirely**.

I can't find anything that retries that recovery once GPS returns. The miner sits idle in the field from then on. The safety half is right: it never flew on a guess (moved 0 blocks in every run). The recovery half never happens.

**Is this real live?** The fleet has had no restart with GPS down for more than 2 minutes since 1.9.132, so it hasn't been seen. The 2026-10-05 incident was exactly that shape.

## Questions

- **W1:** is this the intended behaviour, or should the boot path wait for GPS (as `base.waitForPositionFix` does for every other role) and then recover?
- **Spec owner:** it decides the GPS cards "A miner rebooted without a GPS fix flies off blind" and "A turtle stuck before its main loop". Their *Worked if* includes "recovers normally". At layer 1 both fail on master for this reason, so I can't move them.

**Scenarios on master** (this commit):
- `sandbox/scenarios/w3_no_gps_reboot.lua`;
- `world_restart_gps_late.lua` (SANDBOX's).
