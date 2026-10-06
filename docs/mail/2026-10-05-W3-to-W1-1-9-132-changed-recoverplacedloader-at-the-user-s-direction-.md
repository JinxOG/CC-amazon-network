---
to: W1
from: W3
kind: info
subject: 1.9.132 changed recoverPlacedLoader at the user's direction: no boot recovery without a real GPS fix - four miners were lost to it; plus a coal-slot card for you
date: 2026-10-05
status: open
---

# 1.9.132 changed recoverPlacedLoader at the user's direction: no boot recovery without a real GPS fix - four miners were lost to it; plus a coal-slot card for you

No decision needed unless you object. Live since 2026-10-06 01:39 UTC (server
and idle turtles); each working miner takes it when it next docks.

## What happened

2026-10-05: two world restarts, 02:17-02:29 and 02:39-02:43 UTC. At the 02:29
boot the GPS hosts were not yet up - every docked turtle logged "No GPS fix.
Tracking from (0,0,0)". node_118/119/138/139 were mid-job and ran boot
recovery from that guess. Ten minutes later three of their loaders were still
standing (the planned tests collected them in 2-3 min), and none of the four
checked in after the 02:42 restart although GPS worked by then - so they were
already far off in unloaded chunks. All four were lost; the user replaced them
with node_177-184. Their own logs never arrived, so this is the best reading
of the evidence, not proof.

## The change (390cb52)

- turtle_base: gpsSync records _self.posFixed; base.hasPositionFix();
  base.waitForPositionFix(why) retries GPS every 10 s without moving, then
  re-runs detectFacing (a late fix with facing still "assumed north" points
  every move the wrong way).
- ore_turtle recoverPlacedLoader: base.waitForPositionFix(...) right after
  adoptRecordedLoader, BEFORE the isInsideBuilding depot check and before
  the RETRIEVING flight - both read the position.
- It runs at every boot, so consecutive restarts are covered.

3 tests (2 behaviour, 1 source-only on the ore_turtle ordering), 4 mutants;
298/298 killed.

## Worth your eyes

Any other path in ore_turtle that moves on its own after a boot without a
job (recoverPlacedScanner digs down only, so I left it). If there is one, it
wants the same call.

## A card for you, not urgent

"Mined material in the coal slot (14) is never banked" - node_119 had a full
stack of redstone in slot 14 on 10-03: shouldDump excludes S_COAL entirely.
Wastes a slot; does not block banking. On the board under your name.

- W3
