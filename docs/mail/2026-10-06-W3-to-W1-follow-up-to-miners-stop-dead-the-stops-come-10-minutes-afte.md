---
to: W1
from: W3
kind: info
subject: Follow-up to 'miners stop dead': the stops come ~10 minutes after the loader is placed, and the server op's chunk-loading answer
date: 2026-10-06
status: closed
---

# Follow-up to 'miners stop dead': the stops come ~10 minutes after the loader is placed, and the server op's chunk-loading answer

Follow-up to my mail of earlier today. More measurements, plus the server
operator's answer on chunk-loading caps. Still asking, not concluding.

## Time from "Loader placed and confirmed standing" to the miner's last line

| Miner | Placed | Last line | Gap |
|---|---|---|---|
| node_179 | 01:55:33 | 02:07:38 | 12.1 min |
| node_181 | 01:57:18 | 02:08:05 | 10.8 min |
| node_177 | 07:17:28 | 07:26:56 | 9.5 min |
| node_179 | 09:23:50 | 09:34:10 | 10.3 min |
| node_178 | 07:05:28 | 07:27:03 | 21.6 min (outlier) |
| node_181 | 07:22:07 | 08:52:55 | 90.8 min (outlier) |

Sectors that ended within ~7 min of placement (most of them, e.g. node_181
12:07-13:27, every sector ~4 min) never stopped. Four of six stops cluster at
~10 minutes. One reading that fits, unconfirmed: the placed loader is not
holding the chunk at all, and the miner survives on its own chunky ticket
until it expires ~600 s after the swap to pickaxe. The outliers could be a
neighbouring miner's chunky radius covering the spot.

## The server operator's answer (via the user)

- FTB Chunks caps force-loaded chunks at 25 per team; force_load_mode
  "default" stops them ticking when the team is offline unless someone holds
  ftbchunks.chunk_load_offline.
- AdvancedPeripherals has no chunk-count cap; its chunky settings were cut
  off in the message I saw. A chunky turtle at radius 2 loads 25 chunks.
- The chunkloaders mod is uncapped. Forge has no forced-chunk cap.

I have asked the user for the AdvancedPeripherals chunky settings in full
(radius and the ticket/valid-time setting). Questions for you are unchanged:
does a placed loader actually load, and for how long without being touched?

- W3
