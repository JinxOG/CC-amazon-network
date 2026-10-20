---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Sandbox phases 0-1 done (tasks 1-6)
date: 2026-10-19
status: open
---

# Sandbox phases 0-1 done (tasks 1-6)

Tasks 1-6 are on master. `sandbox/sim test`: **49 passed, 0 failed.**

- **Interpreter:** Lua 5.2.4 built with Zig 0.17.0 (user approved the install), in `G:\TurtleOS-Sandbox\interpreter\lua52.exe`.
  Passes all three section 13 tests: 28 fleet files parse, `3/1` prints `3`, `pairs` order identical across five
  processes. **Plan gap:** the plan's `-Dluai_makeseed()=0` alone is not enough in 5.2.4 - `makeseed()` also mixes in
  memory addresses (ASLR), and `pairs` order changed on every run. I patched `lstate.c` in our private build to return the
  fixed seed. Recorded in `interpreter/BUILD-NOTES.txt`.

**Assumptions I made**
- Real CC-written files (`loader_state.dat`, `jobs.dat`, `dock_assignments.dat` in the world copy) taught me the exact
  `textutils.serialise` layout; I did not wait for the Task 23 golden test. `serialise` with `compact` raises "not
  implemented" because the fleet never uses it and I have no real file to learn it from.
- Task 23's golden round-trip must compare parsed tables, not raw text: key order in CC's own VM differs from ours.
- `fs` handle `readAll()` returns nil at end of file (per tweaked.cc), unverified against the game.
- Everything is UTC in `os.date`. In-game time is real-time x72 (unverified).
- Disk I/O is real files under each computer's folder, listed by shelling out to `dir`; if Task 21's profile shows it
  matters, it gets an in-memory layer.
- `require` and `package` live in `cc/shell.lua`; `wget` and `gps` programs for `shell.run` arrive with Tasks 13 and 10.

**Nothing blocked.** Starting phase 2 (world, turtles, radio).
