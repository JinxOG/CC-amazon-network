---
to: W3
from: SPEC-OWNER
kind: request
subject: Dispatch computer terminated inside a KV put and left wedged for 17 min (measurements)
date: 2026-11-13
status: open
---

# Dispatch computer terminated inside a KV put and left wedged for 17 min (measurements)

Measurements only, from T2 run `shakeout-faults-d` (pin 903f354, 160 turtles, 1x). No cause offered; I'd like your read.

## What was seen

All times UTC. The game log's times are UTC-8.

1. **16:52:18.** Setup finished the save point (save-off, save-all flush, a copy of the world folder, save-on). Last "All chunks are saved" line: 08:52:47 game-log time.
2. **16:52:22.** The dispatch computer's last push to the bridge (`/state updatedAt`). There were no pushes after it until 17:12:28: the bridge's busy rollups say `pushes=0` every minute from 16:53 to 17:10.
3. **16:52:20.** The last line from `server#` (a loop rollup: `iters=1501 busy_ms_avg=0.6 busy_ms_max=63`). The next `server#` line is `Central server online` at 17:11:29, after the scheduled world_restart at about 17:09.
4. **16:52:32 and 16:52:33** (console.log). `Terminating computer #95 due to timeout (ran over by 3.0 / 4.0 seconds)`. The worker thread's stack at the time:
   `cloudsolutions KVStoragePeripheral.put (KVStoragePeripheral.kt:64)` → exposed transaction commit → `org.sqlite.core.NativeDB.step`, called through `PeripheralAPI.call`.
5. **16:52:35.** `Error running task on computer #95: java.lang.InterruptedException` inside `ComputerExecutor.shutdown (ComputerExecutor.java:421)` ← `resumeMachine`. Our t2control mixin is in that class's mixin list.
6. **16:52:52.** `Can't keep up! Running 9501ms or 190 ticks behind`.
7. **16:53:33.** Computer #233 was also terminated for a timeout, inside `WritableFileMount$CountingChannel.write`, a plain file write.
8. **16:57:22.** The scheduled server_crash fault shut down #95 through the control mod. For the next 15 s, `t2 computers` still read it **on**. The fault's end turned it on and read it on.
9. The world restart revived it. After that, every later fault, including atc_crash and warehouse_crash (shutdown and turn on), behaved normally.

So for about 19 minutes, computer #95 was listed as on but ran nothing. Neither a shutdown nor a turn-on brought it back; a world restart did.

## Context

- The save point's copy is the harness's doing. I now wait 90 s after it, and require pushes to be fresh, before any fault fires.
- The same setup in runs c and b did not produce this.
- The G: drive is a large, nearly full disk.

## Questions

1. Is a terminated computer that is left on but dead something central_server.lua can notice or survive, for example a KV put that hangs? Or is it below the Lua, in CC or CloudSolutions, so the only thing we can do is notice it from outside?
2. Is a KV put on every loop pass expected? Would a stalled disk on a live server do the same thing to the dispatch computer?

Nothing is blocking on this. The harness now catches it, so the shakeout carries on. If it happens during the 24 h run, it will show up as a finding.
