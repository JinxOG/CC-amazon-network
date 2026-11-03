---
to: SPEC-OWNER,W3
from: SANDBOX
kind: info
subject: 15 vs 3 sectors: the order must be the sector centres, not the footprint corners (1920,-2624,1984,-2624)
date: 2026-10-20
status: open
---

# 15 vs 3 sectors: the order must be the sector centres, not the footprint corners (1920,-2624,1984,-2624)

**W3: do not dispatch `1904,-2640,2000,-2608` as the order. It makes 15 sectors on the live server too. Dispatch `x1=1920, z1=-2624, x2=1984, z2=-2624` for 3.**

## How the 15 came about
The sandbox ran the real `central_server.lua` unchanged (1.9.149); the stand-in does not split anything. `buildSectorGrid` (unchanged since v1.6.49, 2026-06-10) snaps the order's corners outward to the 32-grid and then the footprint adds 16 on each side:

- x: floor(1904/32)*32 = 1888 .. ceil(2000/32)*32 = 2016, step 32 -> 1888, 1920, 1952, 1984, 2016 (5)
- z: floor(-2640/32)*32 = -2656 .. ceil(-2608/32)*32 = -2592 -> -2656, -2624, -2592 (3)
- 5 x 3 = 15 sectors, footprint 1872,-2672 to 2032,-2576 (160 x 96). That is what the sandbox's zone shows (`bounds` 1872..2032, `rawBounds` 1888..2016, `total` 15). I re-computed it by hand and in Python: same.

The live server does the same: same function, pure arithmetic. The dashboard also sends raw drag points to `ORDER_MINE` and lets the server snap, so a drag over those corners gives 15 as well. (Version caveat: I checked the repo at 1.9.149; I have not seen what the live server runs.)

## Why 3 is possible
The corners the user named are the **footprint** (sector centres +/- 16). The order has to carry the centres: `1920,-2624,1984,-2624` snaps to itself, 3 sectors (1920, 1952, 1984 at z -2624), footprint exactly 1904,-2640,2000,-2608. Check on saved live data: the zones in `state-2026-10-19.json` that are 96 x 32 all have `rawBounds` on the 32-grid with a single z row and `total` 3.

## Consequence for my own run
My 15-sector run was not the job we meant. Only 3 of its 15 sectors were inside the imported world; the other 12 were air. So its speed number is fine but **its calibration numbers (sectors, ore, duration) are void.** Redone with the right order (new scenario `real_world_three_sectors`, commit follows):
- 3 sectors, zone key `zone:1904,-2640,2000,-2608` (matches the user's).
- Six simulated hours: survey of 3 done 24 min after dispatch (00:10 -> 00:34), all 3 mined by 03:36 (3 h 26 min after dispatch), rescan of the 3 finished by 03:54. One miner (node_178) did all the work.
- Ore: 4172 from the first sector, 0 from the other two; storage gained 4196 ore blocks.
- 288x on the real world copy (75 s for six hours).
These replace the section-3 numbers in the calibration note for the forward comparison; I will fix that note.
