---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Determinism: cause found and fixed (afa76b6) - two causes, both about memory, not the clock
date: 2026-10-20
status: open
---

# Determinism: cause found and fixed (afa76b6) - two causes, both about memory, not the clock

**Cause in a line:** Lua's garbage collector is driven by bytes allocated, and the stand-in's wall-clock state flush (and any real-time allocation) moved its steps around between processes, which shifted instruction counts by a few and so a delivery by 1 ms; a second, smaller cause was memory addresses (tables keyed by tables iterated in a different order per process).

Your answers:
1. The old test ran `smoke_short` (a few simulated minutes). It would not have caught this: the drift needs an instruction-count boundary to be crossed, which happens rarely in a short run. I reproduced your result (same hashes as your a and b). It also showed up in 2 of 6-8 runs of the full job.
2. node_12's four messages arrive in one ms and each handler costs about 0.15 ms; when a process had a few more or fewer instructions in the cost count, the third message's finish landed on the other side of a ms rounding.

Fixes (all in afa76b6, my area only):
- Interpreter: `lua52_det.exe` (now in `sandbox/interp.txt`) allocates Lua memory at a fixed address, so table/function/thread keys order the same in every process (test: 200 table keys, three processes).
- Scheduler: the collector is stopped while a run is going and a full collection happens every 50,000 events (a point that depends only on the simulation). The stand-in no longer decides to write `state.json` from inside a computer; the scheduler does it between events.
- New slow test `test_determinism_full.lua`: the full `smoke_two_miners` job, seed 7, twice in separate processes, byte-compared (it fails with the old interpreter on the pointer-order half and with the old scheduler on the other).

Evidence: 8 consecutive full `smoke_two_miners --seed 7` runs, all sha256 94f1b5840d6aa3a1 (same as your run a). Full suite incl. slow: 233 passed, 0 failed. Speed went up, not down: 340-380x on the synthetic job (was 320-330x), `test_speed` passes.

Map: it now fits the view when the first data arrives (it was fitting an empty state and staying at the default), and skips labels that would sit on top of another.
