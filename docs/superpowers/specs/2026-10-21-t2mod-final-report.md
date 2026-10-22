# T2 control mod - final report (M0 to M7)

Date: 2026-10-21. Forge 1.20.1-47.4.10 (matches live), CC:Tweaked 1.120.2, Advanced Peripherals 0.7.46r, mod t2control 0.1.0 (server-only, lives only in `G:\TurtleOS-Sandbox\testserver\server\mods`).

## Phases

| phase | what | proof | report |
|---|---|---|---|
| M0 | toolchain, load guard, placement guard | guard refuses 3 ways; cost -0.4% | 2026-10-21-t2mod-m0-report.md |
| M1 | radio log, event log, interventions log | proven both ways; 0 lines dropped at 10x | ...-m1-report.md |
| M2 | radio loss and latency | 12 of 12 | ...-m2-report.md |
| M3 | chunk unload under a loader | 13 of 13 | ...-m3-report.md |
| M4 | turtle move (facing), save / restore | 9 of 9 | ...-m4-report.md |
| M5 | peripheral stall and fail | 9 of 9, on the real warehouse | ...-m5-report.md |
| M6 | pause and step | 9 of 9 | ...-m6-report.md |
| M7 | run Lua on a computer from outside | **not done, on purpose** (below) | this file |

## Cost of the finished mod (the bar: no visible effect on tick time)

Alternating runs (with the mod, without, with, without), the fleet booted and idle at 1x, 30 `forge tps` samples each (`sandbox/t2/cost_ab_mod.py`): mean tick time **7.20 ms with the mod, 7.67 ms without**; medians 7.06 and 7.58. The mod run was faster, so the cost is below what this PC can resolve (run to run the same setup varies by about 0.4 ms). An earlier single run read +10% with the mod; it is a reminder that one run proves nothing here, and the alternating pair is the measurement.

## M7: `eval` on a computer - not done

The spec allowed it only "if a clean, version-pinned way exists". None does. CC:Tweaked has no entry point for running new Lua inside a computer that is already running a program: the only ways in are (a) a file in the computer's disk plus a restart, which needs no mod and is already `control.py`'s way of installing probe programs, and (b) an event the running program has been written to listen for, which means changing the program under test and so no longer testing the fleet's real code. Reaching into the Lua machine from Java would be a hook into CC internals with nothing to anchor it to a version. Recorded as not done.

## What the scenario report's NOT STAGED section now says

Supported with the mod: radio loss and latency, chunk unload (overworld, every mod's Forge tickets), turtle move and save/restore, peripheral stall and fail, pause and step. Unchanged: Citadel and Alex's Mobs left out at speed, five client-only jars, the speed caveat (real-clock deadlines run N times longer in game time), no exact replay. New caveats from the proofs: stalls proven only up to 2.5 s; pausing does not pause the real clock; the base is held by two chunk-loading mods, so a loader-only unload does nothing (use the area form).

## Findings the mod produced (also mailed)

1. Old-code ack loss on real Minecraft at 10x (1.9.107, 16 parked turtles, 4 game hours): 2.42%; current master at 8x: 0.64%. These ran at speed and should under-state the loss; the 1x series that counts is running (results by mail).
2. 5% radio loss made a mining job fail on the real server at 5x (174 "GPS locate failed", repeated "server unreachable" pauses, job permanently failed) where the same job without the fault is clean. Cause not isolated (see the M2 report); the 1x re-run is pending.
3. The base is held by Advanced Peripherals AND the Chunk Loaders mod.
4. A real `listItems` on this world's RS network takes about 60 ms (495 kinds of item).
5. The real update path cannot pin a commit older than 1.9.128; `--install` copies one in instead.
