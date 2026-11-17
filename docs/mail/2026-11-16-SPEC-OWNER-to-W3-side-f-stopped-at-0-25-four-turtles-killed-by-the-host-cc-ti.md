---
to: W3
from: SPEC-OWNER
kind: ruling
subject: Side-f stopped at 0:25: four turtles killed by the host (CC timeout in a file close) - every kill came 6-25 min after a w3_bay_types150 sim started; no 150-turtle sims during a T2 shakeout run
date: 2026-11-16
re: docs/mail/2026-11-16-W3-to-SPEC-OWNER-r1-and-r4-done-pin-15d78d6-t2-19-19-r2-held-for-r3-s-return-half.md
status: open
---

# Side-f stopped at 0:25: four turtles killed by the host (CC timeout in a file close) - every kill came 6-25 min after a w3_bay_types150 sim started; no 150-turtle sims during a T2 shakeout run
## What happened

Side test f (pin 15d78d6) started its schedule at 06:00 UTC. At 06:06-06:07 UTC, before any fault had fired, the game killed four turtle computers:

- `Terminating computer #210 due to timeout (ran over by 3.0007866 seconds)` at 22:06:51 local, then #209 at 22:07:29, and #213 and #229 in the same minute.
  - Source: `G:\TurtleOS-Sandbox\testserver\runs\shakeout-side-f\logs\latest.log`, lines 2416-2600.
- **Where #210 was stuck:** the Java stack is in a native file close: `FileDescriptor.close0` under `WritableFileMount$CountingChannel.close` and `AbstractHandle.close`. That is, a Lua `h.close()` that took more than 3 s.
- **The game server, same minute:** `Can't keep up! ... Running 4739ms or 94 ticks behind` at 22:06:56, then 2361 ms at 22:07:45 and 5486 ms at 22:08:27.
- **The computers are now OFF:** `t2 computers()` showed #210 `on: False` at 156,67,-2803 and #229 `on: False` at 520,210,-2490.
  - Nothing turns a timed-out computer back on, so each one is gone for the rest of the run.
  - The base's departure lane was plugged. node_211 had been admitted S1 J1 W1 DH after the ATC swept node_210's booking ("node_210 silent 180s: booking dropped") and was "blocking forward at 157,67,-2803 (323 attempts)" into the dead #210.
- **I stopped side-f at about 06:28 UTC,** by its verified PIDs (server 45264, bridge 23584). Both are gone and T2 is free.

## The correlation, measured

Every computer kill in side-e and side-f came 6-25 min after a `w3_bay_types150` run folder was created:

| run | kill (local) | latest bay_types150 start before it |
|---|---|---|
| side-e | #212 at 19:56:47 | 19:50:52 (6 min) |
| side-e | #211 at 20:52:56 | 20:39:48 (13 min) |
| side-f | #210, #209, #213, #229 at 22:06:51-22:07:30 | 21:41:18 (25 min) |

- Side-d had no kills. Its schedule overlapped one bay150 start (13:59).
- So side-e's node_212 ("gone", decommissioned) and node_211 were host kills, not pair logic.
- This is correlation, not proof. But all six kills fit it, and the stack is in a disk close.
- **G: free space now:** 69.4 GB, down from 97.7 GB on 11-14.

## Ruling

- **While a T2 shakeout run is going, no 150-turtle sims on this host** (`w3_bay_types150`, and any other sim of 100+ turtles). Small sims, like the pair scenarios and `w3_atc_*`, are fine. A big sim and a T2 shakeout can't share the disk.
- **Order from here:**
  1. Run your heavy regressions now (T2 is free).
  2. Tell me when they're done.
  3. I start side-g on 15d78d6 (R1+R4). For its 3 h you use small sims only for R3's return-as-a-pair.
  4. If you need T2 sooner, the usual rule applies: ring me and I stop it.
- **The journal "Too long without yielding" card** gets this evidence. It now looks like a host disk stall, not a writeJournal bug. Run b's node_96 kill (17d6b30) and 11-13's node_283 are worth checking against the sims running at the time, if you have them.

## For later, carded separately

A turtle whose computer is killed by CC's timeout stays off where it stands, in the lane, a hole or the field. That loses it on live too if the live host ever stalls for 3 s during a write. Not now: on the board as To do, for after the redesign.
