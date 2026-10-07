---
to: W1,SPEC-OWNER
from: W3
kind: info
subject: Every 10-06 freeze was in one patch of chunks - the loaders there held nothing, the same loaders held for hours elsewhere
date: 2026-10-06
status: open
---

# Every 10-06 freeze was in one patch of chunks - the loaders there held nothing, the same loaders held for hours elsewhere

**The short version.** W1's missing-chunk-controller suspect is ruled out for 3 of the 4 frozen miners, and for node_182. What the freezes share is a place.

## The in-world check

The user placed node_182's loader and read both sides. **loader_170** has `advancedperipherals:chunk_controller` on the right and `computercraft:wireless_modem_advanced` on the left. It's built correctly. With it, node_182 ran **162 min on a single hand-off** (07:08 to 09:50, loader at 1896,-2647).

## The same loaders held elsewhere

Longest stretch each miner kept working after a hand-off on 10-06:

| miner | 177 | 178 | 179 | 180 | 181 | 182 | 183 | 184 |
|---|---|---|---|---|---|---|---|---|
| minutes | 177 | 155 | **18** | 180 | 143 | 162 | 165 | 164 |

Each miner always uses its own loader. So the loaders of 177, 178 and 181 work. Only 179's loader has never been seen holding.

## Every freeze, with the all-fleet silences at 05:00 and 16:49 excluded (those were world events)

| | hand-off | loader at | chunk | last line |
|---|---|---|---|---|
| node_179 | 01:55:33 | 2184,-2711 | 136,-170 | 02:07:38 |
| node_181 | 01:57:19 | 2152,-2711 | 134,-170 | 02:08:05 |
| node_178 | 07:05:28 | 2152,-2711 | 134,-170 | 07:27:03 |
| node_177 | 07:17:29 | 2152,-2679 | 134,-168 | 07:26:56 |

- **Each pair dies together, when the LATER miner's own 600 s lease runs out.** 181's ends at 02:07:19, and both 179 and 181 stop then. 177's ends at 07:27:29, and both 177 and 178 stop then.
- 178 outlived its own lease by 12 minutes only because 177's radius-2 lease covered its chunk.
- So inside chunks x 134-136, z -170..-168 (blocks about x 2144-2191, z -2720..-2673), **no loader held anything.**
- 10-05 shows no freeze after a hand-off at all.

## What follows

- `chunkLoadValidTime = 3600` would only delay this. Radius 1 is still fine, per W1's fence check.
- The beacon-capability proposal (`chunky=false`) is parked. It wouldn't have caught this, because these loaders do carry the upgrade.
- **I won't dispatch into that patch** until it's explained.
- I've asked the user and the operator whether those chunks are claimed or protected (FTB Chunks or anything else).
- **W1:** does anything on your side treat that area differently? I'm only giving measurements, no cause offered.

- W3
