---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Sandbox phases 4-5 done (tasks 16-25): the real fleet runs; four findings and one miss against the bar
date: 2026-10-20
status: open
---

# Sandbox phases 4-5 done (tasks 16-25)

All on master. `SANDBOX_SKIP_SLOW=1 sandbox/sim test`: **214 passed, 0 failed** (about 45 s); the full run, with the
whole-fleet scenarios, the speed test and the incident replays, adds a few more minutes. Task 26 (README, roster,
mail to the engineers) is next.

## What works

- The real fleet files, unchanged, install themselves with the real `install.lua` and run: server, warehouse, 15
  workers, GPS hosts, placed and retrieved loaders. A two-miner job on the synthetic world completes. Same scenario and
  seed give a byte-identical `trace.log` across separate processes.
- **418×** real time for a six-hour whole-fleet job on the synthetic world (52 s; the bar is 72 s).
- All 16 faults of section 7, each with a test that fails when the fault is a no-op; the six named scenarios; the
  full control API of 7.1, snapshots (restore reboots the computers; stated in the report), and an interactive mode
  that works from a piped shell.
- **The real world copy imports and runs.** `import_world.py` (stdlib only, no network, read-only) turns the
  2026-10-18 17:00 backup into 30 fleet computers booting from their own disks on the real depot, with the real storage
  (499 items) and ender chests. Chunk loading comes from the world's own forced-chunk list. A two-miner job on the zone
  the user named (x 1904-2000, z -2640..-2608) runs and delivers ore. Our `textutils.serialise` matches every
  CC-written data file in the copy line for line (golden test).

## Findings about the fleet, from the incident replays (Task 24)

1. **1.9.109 (8dc699c) fixed the doubled first order and broke loader beacons.** On 1.9.108 the first sector is
   reported done twice (reproduced). On 1.9.109 no duplicate - but no sector ever completes: take-once drops the
   loader beacon (live-only messages), so every sector setup fails with `loader_no_beacon`. dc65935 fixes it. The plan
   named 1.9.109 as the "good" side; the test asserts both facts and uses dc65935 as the clean reference.
2. **1.9.132 (390cb52) did not fix the 10-05 loss.** With the GPS hosts one minute late (inside the miner's two-minute
   boot wait), a miner is still lost on the code before 1.9.132 **and on 1.9.132**: `waitForPositionFix` returns at
   once because the boot wait already set `posFixed`, and the facing is never measured, so the recovery flight goes the
   wrong way (it ends 700 blocks off). **f437535 (1.9.134, "no moving on a guessed facing") fixes it**; current master
   does not lose it. The plan's "1.9.132 does not lose a miner" does not hold; the test asserts what happens.
3. With the GPS ten minutes late, current master leaves the miners stuck: they refuse to move after 120 s and never
   retry when the fix returns. Probably by design (an operator is needed), worth W1 knowing.

## Where the sandbox falls short of the spec

- **Speed on the real world copy is 208×, below the 300× bar of section 15.1.** Wall-time breakdown for the six-hour
  run (104 s): about 70% is the fleet's own Lua - the miners alone 35%, almost all of it `table.sort` of the remaining
  ore list after every ore (ore_turtle.lua, around line 1330: a comparator in Lua, thousands of ores per sector); the
  server 17%. The rest is the sandbox (JSON handling, scheduler). I sped the sandbox side up (event heap, radio
  batching, lazy busy periods, chunk-wise scans, a text-only copy of the 47 KB storage list in the stand-in) and
  stopped there rather than cut fidelity, as the plan says. A faster Lua is the one lever left: **LuaJIT 2.1** is the
  plan's own second candidate. It needs an install I have not done (and its `bit` library, `load` with an environment
  and key order would each need checking against the section 13 tests). Say if you want me to try it.
- **Ack loss is not reproduced** (calibration note, section 2): live parked turtles lose 11-18% of acks, sandbox 0%. The
  mechanism that costs the live fleet its acks is not in the model, so no disconnect card should close on a sandbox
  run yet. A finding for W3.
- Calibration (Task 25 step 1) is done from the live logs: a miner now delivers a 25-ore batch every 52-55 s against
  the live 50.6 s; `ns_per_instr` 150 reproduces `pushBuildMs` and the server loop's busy time. Step 2 needs the user to
  run the same two-miner job on the real server; the instructions are in the calibration note
  (`docs/superpowers/specs/2026-10-20-sandbox-calibration.md`).

## Assumptions I made (all in `sandbox/assumptions.lua`, printed in every report)

Only the base and chosen zones are imported; everything else is air (water, lava and plants count as air). A turtle's
chunky upgrade id is `advancedperipherals:chunky_turtle` in the world and `...:chunk_controller` as an item; the
importer translates. Chunk-loader radius: the world's forced-chunk file says 2 where the fleet's own loader record
says 1; the sandbox uses 1 (3x3), unconfirmed. The clock for an imported world starts a minute after the server's
last alive stamp.

## Things I did with the user's say-so

Installed Zig 0.17.0 (to build Lua 5.2.4). Read the live bridge's `/state` once and its `/logs` pages once, saved under
`G:\TurtleOS-Sandbox\storage\`. Nothing else touched the server.
