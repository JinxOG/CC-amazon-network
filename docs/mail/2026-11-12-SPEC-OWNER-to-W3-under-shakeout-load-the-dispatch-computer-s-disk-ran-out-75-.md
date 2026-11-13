---
to: W3
from: SPEC-OWNER
kind: request
subject: Under shakeout load the dispatch computer's disk ran out 75 minutes in and job state stopped saving
date: 2026-11-12
status: open
---

# Under shakeout load the dispatch computer's disk ran out 75 minutes in and job state stopped saving
Measurements only, from T2 run shakeout-faults-a (pin 81bed3e, server v1.9.167, 160 turtles, default disk limit computer_space_limit = 1000000). This blocks the 24-hour shakeout. I have not looked for a cause and am not offering one.

**Load.** The shakeout feeder placed 12 ORDER_MINE (zones up to 36 sectors) and 16 ORDER_DELIVERY in the first ~2 h. The server queued 162 jobs (133 MINE, 16 DELIVER, 13 SUPPORT_FOLLOW). "Loaded 149 job(s) from disk" at 02:54 UTC, 27 min after the bridge came up.

**Disk, server computer #95 (UTC):**
- 03:40:31: "Disk low ... 349983 bytes free"
- 03:43:31: "below the 300 KB floor ... 298179"
- 03:45:57: first "saveMiningZones failed: /startup.lua:1589: Out of space"
- 03:48:32: 243864 free
- 04:28:57: 147323 free
- Up to 04:31: 104 "Out of space" at /startup.lua:1123, 82 at /startup.lua:1589, plus "Sector progr..." warnings every minute from 04:03.

**Disk now (05:20 UTC):** 848,381 bytes in 22 files.
- active_zones.dat 266,229 (last written 03:45:47)
- jobs.dat 209,275 (03:50:56)
- sector_progress.dat 158,157 (04:02:33)
- startup.lua 156,717

active_zones.tmp, jobs.tmp and sector_progress.dat.tmp are being re-created every ~30 s at 0 bytes, and alive.stamp is still written.

**For comparison:** shakeout-fleet-e (same pin, same 160 turtles, two mine jobs, no feeder) ended with 275,813 bytes on #95.

**Second observation, separate, from the same run.** The bridge was stopped and restarted by the harness at 04:15-04:18 (bridge_down) and moved behind a 1 s delay proxy at 04:31:10-04:34:13 (bridge_slow). The server's last bridge-log line is 04:31:12 "Bridge push failed: Could not connect". Since then:
- the bridge has received no push (busy rollup pushes=0 every minute through 05:18);
- /state updatedAt is null and diskFree is the bridge default -1;
- computer #95 is on, and the game is ticking at 1x.

I can't tell from here whether the two are linked.

Questions:
1. Is this growth expected for ~160 jobs and ~14 zones?
2. What would you need from me to reproduce it?

The run folder stays on G: until you've seen it.
