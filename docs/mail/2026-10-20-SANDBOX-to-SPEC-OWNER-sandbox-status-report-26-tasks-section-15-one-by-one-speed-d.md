---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Sandbox status report: 26 tasks, section 15 one by one, speed, determinism, calibration, deviations
date: 2026-10-20
status: open
---

# Sandbox status report: 26 tasks, section 15 one by one, speed, determinism, calibration, deviations

All on master, last commit d25ca99. `SANDBOX_SKIP_SLOW=1 sandbox/sim test`: 217 passed, 0 failed.
Map and STALE request: both in (d25ca99).

## 1. The 26 tasks

| Task | State | Commit |
|---|---|---|
| 1 interpreter, layout, safety tests | done | 1b1402e |
| 2 rng, clock, heap | done | 4eecc3f |
| 3 computers, event queues | done | 6ac422d |
| 4 os, timers, cost | done | c17edae |
| 5 fs, textutils, shell, settings | done | dff70c8 |
| 6 parallel, peripheral | done | ead2d15 |
| 7 world, synthetic world | done | 8f15963 |
| 8 turtle API | done | bd7c7f4 |
| 9 radio | done | 710d3e8 |
| 10 GPS | done | f1506c9 |
| 11 chunk loading | done | b0bd7a8 |
| 12 peripherals | done | 0d92e65 |
| 13 HTTP and network rules | done | f0539b9, b9a8456 (fix) |
| 14 stand-in bridge | done | 21532e1 |
| 15 file server, BRIDGE_URL | done | 66c2a5f |
| 16 provisioning, first job | done | 110ec09, ff0e4be |
| 17 scenarios, determinism | done | f37f5e6 |
| 18 reports | done | f37f5e6 |
| 19 faults | done | fe9b58f |
| 20 control API | done | 9d29c9a |
| 21 speed 300x | partial: synthetic met (418x), real world not (208x) | d4e8046, 09e9658 |
| 22 importer | done | 09e9658 |
| 23 golden fidelity, real-world run | done | 09e9658 |
| 24 two incidents | done, with two differences from the plan (below) | 73205e9 |
| 25 calibration | partial: step 1 done, step 2 (forward calibration) not started | d3e549f, timings fitted |
| 26 README, roster, hand-over | done: README d3e549f, roster row in the shared memory file (not in git), mail to W1,W3,W5,W6 3de07c4 | |

"Part" in d3e549f's message meant only task 25 step 2. Task 26 has nothing missing. Step 2 needs an agreed zone (the user gave 1904,-2640 to 2000,-2608) and the user running the same job on the real server; the instructions are in `docs/superpowers/specs/2026-10-20-sandbox-calibration.md`.

## 2. Section 15, one by one

1. Two-miner real-world job end to end, 300x: **end to end met, 300x NOT met.** `sandbox/sim run sandbox/scenarios/real_world_six_hours.lua` completes, delivers ore, 208x.
2. Every section 7 fault exists, tested, test can fail: **met.** `tests/test_faults.lua`: each fault has a no-op counterpart that must fail; all in the 217.
3. Forward calibration on the real server: **NOT met** (needs the user). Incidents reproduce on old code and not on the fix: **met**, `tests/test_incidents.lua` (slow set).
4. gate_check and ack_loss against a sandbox run, changed only by the bridge-address option: **met.** `test_fileserver.sh` "gate_check/ack_loss completes against the fixture" and "default address unchanged"; the report runs both.
5. Section 10 safety rules each tested: **met** (`tests/test_safety.lua`, static tests).
5a. Every 7.1 control action exists, tested, usable from a scenario and a plain shell: **met** (`tests/test_control.lua`; `printf ... | sandbox/sim repl` works). Interventions listed in the report.
6. New board column: the spec owner's. The card moves to it at the end of each task I close.
7. README, run in under five minutes: **met** (`sandbox/README.md`).

## 3. Speed

Synthetic six-hour two-miner whole-fleet job: 52 s, **418x** (bar 72 s). Real world copy: 104 s, **208x** (bar 300x, 72 s). Breakdown of the real-world run: about 70% is the fleet's own Lua (miners 35%, nearly all `table.sort` of the remaining ore list after each ore in ore_turtle.lua around line 1330; server 17%), the rest is the sandbox. I optimised the sandbox side (heap, radio batching, lazy busy periods, chunk-wise scans, text-only storage copy) and stopped before cutting fidelity. Only lever left is a faster Lua, see 4.

## 4. Determinism

Same scenario and seed give a byte-identical `trace.log` across separate processes (test in the slow set). Interpreter: **Lua 5.2.4 built with Zig 0.17.0**, patched to a fixed hash seed (stock 5.2 `pairs` order differs between processes). LuaJIT 2.1 was built and tried (about 8x faster on pure Lua) but its `pairs` order differs between processes, which breaks reproducible runs. **Lua 5.2 stays.** Notes in `G:\TurtleOS-Sandbox\interpreter\BUILD-NOTES.txt`.

## 5. Calibration

Compared against saved live logs and one `/state` read (with the user's say-so): miner batch cadence, `pushBuildMs`, server loop busy time, RS list time. After fitting (movement/dig 300 ms, `ns_per_instr` 150, `rs_list_ms` 65): a miner delivers a 25-ore batch every 52-55 s against live 50.6 s; `pushBuildMs` and the server's busy time reproduced. Not matching: `rsBuildMs` comes out about 3x too low (the CC ROM's serialiseJSON costs more than ours); **ack loss: live parked turtles lose 11-18%, sandbox 0%**. Unverified: everything marked `unverified` in `timings.lua` (scan, reboot, turtle commands, cloud store calls), sector duration over a full run, and the whole forward comparison.

## 6. Deviations, assumptions, NOT MODELLED

Deviations from plan/design:
- Task 24: 1.9.109 (8dc699c) does not double the first order but never completes a sector (`loader_no_beacon`, fixed by dc65935), so the "good" reference in the test is dc65935. 1.9.132 (390cb52) does **not** fix the 10-05 miner loss; f437535 (1.9.134) does. Tests assert what the code does.
- Lua 5.2.4 built from source with a patch, instead of an installed Lua.
- Restore reboots computers (coroutines cannot be saved); the report says so.
- Live view (today): `serverTime` in `/state` stays simulated (gate_check and ack_loss date their windows from it); `updatedAt`, `storageTs`, `storageAt` are shifted to the wall clock; the file on disk is untouched. The map's sector shading is approximate: `/state` carries counts per zone, not a per-sector list, so done cells are the first N in grid order.

Assumptions: all in `sandbox/assumptions.lua`, printed in every report. The ones that could matter: chunk-loader radius 1 (world file says 2, fleet record says 1); non-air only in the base, chosen zones; water/lava/plants count as air; turtle.dig with a full inventory drops overflow; imported clock starts a minute after the last alive stamp.

NOT MODELLED that matters: the mechanism behind live ack loss; real server lag/TPS interplay beyond the two faults; ROM serialiseJSON cost; most of the world outside the base and zones.

## 7. What I need

- **User:** run the same two-miner job on the real server for the forward calibration (task 25 step 2).
- **You:** a ruling on speed (accept 208x, or approve more work: a faster comparator in ore_turtle.lua is W-owned, I may not edit it). W3 to explain the ack-loss gap. Review of the build.
