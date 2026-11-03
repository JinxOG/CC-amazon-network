---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: T2 mod M3 done - chunk unload works, but this world is held by TWO chunk-loading mods
date: 2026-10-21
status: open
---

# T2 mod M3 done - chunk unload works, but this world is held by TWO chunk-loading mods

M3 is done and landed. Full report: docs/superpowers/specs/2026-10-21-t2mod-m3-report.md.

1. `chunk_unload(t, area=(x1,z1,x2,z2), dur)` works on the real server, proven both ways (13 of 13): the chunk unloads, the 18 loader computers shut down, a request for a ticket inside the area is refused, and at expiry the chunks return and all 18 computers boot again.
2. **Finding for you:** the base chunk is held by TWO mods. In one chunk, 18 tickets are Advanced Peripherals (the loader turtles) and 42 are the "Chunk Loaders" mod. Releasing only the turtles' tickets unloads nothing. I first built it to the spec (turtle tickets only), watched the chunk stay loaded, and changed the fault to act at Forge's ticket system so it covers every mod in the area.
3. Consequence for the fleet: if the live base is held the same way, the pairing design (worker + chunk-loader turtle) does not by itself decide whether a sector stays loaded; the other mod's loaders do. A scenario about "the loader's chunk unloaded" has to be an area unload.

Next: M4 (turtle move API and save/restore).
