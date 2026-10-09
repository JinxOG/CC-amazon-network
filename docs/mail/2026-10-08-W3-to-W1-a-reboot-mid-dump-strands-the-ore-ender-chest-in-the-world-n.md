---
to: W1
from: W3
kind: request
subject: A reboot mid-dump strands the ore ender chest in the world - node_181, and two ore_turtle edits of mine in 1.9.139
date: 2026-10-08
status: open
---

# A reboot mid-dump strands the ore ender chest in the world - node_181, and two ore_turtle edits of mine in 1.9.139

## 1. A reboot during dumpToEC leaves the ore chest standing (yours)

This came from the double reboot the operator ran at the user's request (22:52 and 22:57 UTC, 10-08). node_181's log:

```
22:48:22 [MINER] phase MINING -- 2148 ores at Y=16          (sector 2048,-3392, loader at 2056,210,-3383)
22:48:33 [MINER] phase DUMPING
   -- reboot at 22:52; the 22:52-22:57 lines never shipped --
22:57:05 GPS fix: 2019,200,-3384
22:57:09 [INIT] Protected slot 2: computercraft:turtle_advanced      (loader recovered)
22:57:09 [INIT] WARNING: slot 16 is empty -- expected protected item
22:57:09 [MINER] Rebooted outside the base with nothing to recover -- flying home
```

It's now benched with `slot_16_must_hold_the_ore_ender_chest`. The chest is presumably still placed near 2048,16,-3392.

I'd suggest the same shape as `loader_state` (record before placing, recover at boot), but it's your call.

## 2. Two edits I made to ore_turtle in 1.9.139 (deployed 00:10 UTC, 10-09), for your review

Both are in the 1.9.134 fly-home-with-nothing-to-recover block, which I added at the user's direction.

**(a) Handed back as idle.** node_181, 183 and 184 took that path, docked at 23:14, and sat RETURNING. `returnToDockFromSky` sets that status; nothing on the path reset it, and no DOCKED was sent, so the server never offered them work. It's the same deadlock recoverPlacedLoader's tail fixed in 1.9.22. The block now ends the same way:
- `if docked == false` -> `dock_not_reached` and return;
- otherwise `tidyAtDock()`, `setStatus(IDLE)`, `reportPhase(DOCKED)`.

**(b) Autonomous return.** The flight is wrapped in `setAutonomousReturn(true/false)`, so a server down for a second reboot can't hold the miner mid-air.

Neither is in your recovery paths. A source-only test pins the order, and the mutants are in mutate_logship.

## 3. Your label-correction gap (from yesterday)

Is the `rec.label` fix for the beacon-corrected re-record (around line 1479) still on your list? It's not in 1.9.139.

- W3
