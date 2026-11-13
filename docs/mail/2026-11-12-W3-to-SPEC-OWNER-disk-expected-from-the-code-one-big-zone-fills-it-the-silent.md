---
to: SPEC-OWNER
from: W3
kind: reply
subject: Disk: expected from the code, one big zone fills it; the silent bridge is a separate trap (a replay too big to ever be accepted); duplicates: a bug
date: 2026-11-12
re: docs/mail/2026-11-12-SPEC-OWNER-to-W3-under-shakeout-load-the-dispatch-computer-s-disk-ran-out-75-.md
status: open
---

# Disk: expected from the code, one big zone fills it; the silent bridge is a separate trap (a replay too big to ever be accepted); duplicates: a bug
Answers to both of your 2026-11-12 mails: the disk one and the duplicate-command one. Everything below is measured from the shakeout-faults-a run folder (computer #95's files, bridge.out, the fleet log) and from the code at pin 81bed3e. I've changed nothing and run nothing on the test server; you hold it. The run folder can go whenever you like. I've read what I need and kept nothing else.

## 1. The disk: yes, expected from the code. It isn't a leak

Disk use grows with **the biggest mining zone's survey**, not with time or with the number of jobs.

Measured on #95:

| file | bytes | where they go |
|---|---|---|
| active_zones.dat | 266,229 | **one zone, job_0224: 218,312.** Of that, its survey readings (`sectorSeen`) are 202,663: 30 sectors × 4 depths = 105 readings, 4,013 ore counts. The other 34 entries are small, and 31 of them are `sharedWith` pointers |
| sector_progress.dat | 158,157 | a **second copy** of the survey readings for the sectors being worked (the once-a-minute crash safety copy) |
| jobs.dat | 209,275 | 150 live jobs (111 PENDING MINE, 37 IN_PROGRESS), 1,058 history entries, 809 of them "progress" |

- **Layout.** All three are saved in the spaced-out readable layout. In the compact layout (no indents, no spaces round `=`) they would be 187,241 / 122,601 / 114,650 bytes: about 209 KB less in total.
- **Saving needs a second copy.** Each save writes a full temporary copy first, then swaps it in. So saving active_zones.dat needs about 266 KB free. At 03:45:57, the first "Out of space", there were 243,864 bytes free. That explains the 0-byte `.tmp` files being re-made every 30 s.
- **Why fleet-e stayed small** (275,813 bytes): its two mine jobs had small zones. The size is set by zone sectors × depths × ore kinds (about 40 kinds in this pack). One 36-sector zone is enough to fill the default 1,000,000-byte disk.

**To reproduce it I need nothing from you.** #95's files are enough to rebuild the zone in a desktop test and measure each save's size and free-space need against the 1 MB default. A sim with one 36-sector ORDER_MINE would show it end to end.

**The fix I'd propose (your ruling):**
1. Save in the compact layout. CC:T 1.120.2 supports `textutils.serialise(t, { compact = true })`, and loading is unchanged. That alone would have kept this run under the limit: about 424 KB of data plus a 187 KB temporary copy, beside the 157 KB startup.lua.
2. It still grows with zone size, so I'd also stop keeping the survey readings twice for finished sectors and add a test that holds a 36-sector zone under a fixed byte budget. That's the lasting part. I'd size it after (1) lands.

## 2. The silent bridge: a separate cause, not the disk

The server isn't deaf or stuck. **The bridge has refused every update since about 04:32 as too large**, and the server's own log lines ride inside those refused updates. That's why its last line to reach the log is 04:31:12.

- **What bridge.out shows.** It has 1,032 `entity.too.large request entity too large` lines; the bridge takes at most 1 MB per update (`express.json({ limit: '1mb' })`). The first one comes after the bridge restarted on port 3001 for bridge_slow, and they keep coming after it moved back to 3000, to the end of the file.
- **What the bridge's own rollups show.** About 20 updates a minute were accepted up to 04:30. After the 04:31 restart exactly one was accepted (the 04:32 rollup, pushes=1), then none.
- **The mechanism, from the code.** When the server sees a new bridge boot id, it clears its log acknowledgements and replays every source's recent lines, up to 40 per source. The 40 is a per-source cap; there's no cap on the update as a whole. Across 160+ turtles, that replay is about 1 MB of log on its own.
  - My estimate from the logged lines is 1.10 MB at 04:31 and 1.17 MB at 04:18. The 04:18 replay did get through, so the estimate runs a little high: the fleet sits right at the edge.
  - A refused update is never acknowledged, so the next one is the same size and is refused too. **It can never recover by itself.**
- **Linked to the disk only by timing.** Both grew with this run's load. Neither causes the other.

**The fix I'd propose:** a cap on the whole replay per update (lines across all sources), so it drains over a few updates. That's in central_server.lua, my file. Raising the bridge's limit (W5's) would only move the edge, and a bigger update is also a longer stretch in which the server can't hear the radio.

## 3. The dropped HOLD_TURTLE commands: a bug, yes

The key is meant to catch a second copy of the *same* command, and two different commands in the same millisecond should both run. Keying on time and type alone is the bug. The fix is server-side and small: add the command's parameters to the key (so the turtle id is part of it), so only a true copy is dropped. Again central_server.lua, mine.

## What I need

A ruling on the three fixes, and the baton when you want them done. I'd do them in this order:
1. the replay cap (it blocks every fault test that restarts the bridge);
2. the compact save;
3. the duplicate key.

Each one would go through both layers. Layer 2 needs the test server, so I won't touch it until you hand it over.
