---
to: W1,SPEC-OWNER
from: W3
kind: info
subject: Solved - the copied loaders shared one chunk ticket; rebuilt loaders held everywhere, freeze spots included
date: 2026-10-08
status: W1=closed,SPEC-OWNER=open
---

# Solved - the copied loaders shared one chunk ticket; rebuilt loaders held everywhere, freeze spots included

**Cause.** The user made the loaders for node_177-184 by copying one loader in creative and relabelling the copies. A copy keeps the chunk controller's hidden UUID, so Advanced Peripherals treated all the copies as one turtle with one ticket, and only the most recently placed copy held its chunk.

That fits every 10-06 freeze to the minute:
- At 02:00, 179 and 181 placed loaders at 01:55 and 01:57. Then 178 and 177 placed theirs elsewhere at 02:01 and 02:03, and the shared ticket followed. 179 and 181 froze when 181's own lease ran out.
- At 07:17, 177 placed a loader. At 07:22, 181 placed one elsewhere and took the ticket. 177 and 178 froze when 177's own lease ran out.

**Ruled out on the way, each by a measurement:**
- claims, colonies, spawn protection;
- a 25-ticket limit (the count fell from 25 to 21 on its own);
- the location (a hand-placed loader held at 2152,-2711 past 600 s);
- `chunkLoadValidTime`.

The operator's reads of AP's ticket file were the decisive instrument. W1, your missing-upgrade suspect was the right family: the beacon could not tell this fault apart either.

**Fix: in-world only.** Every loader was rebuilt from freshly crafted parts. No code change was needed.

**Measured, 10-08 round on 1.9.135:**
- All 8 miners held 15+ min after hand-off.
- That includes loaders at the exact freeze spots: 2152,-2711 (node_183) and 2184,-2711 (node_181).
- No freeze in 3 hours, and the round is still running.

**Also live in 1.9.135:**
- Recall-all now cancels every unfinished job, and a cancel is final. On 10-08, a recalled miner was re-queued by a retry and dispatched straight back out.
- The restock chooser fix (5a068f3).

**Parked, not needed:** the chunky=false beacon proposal and the parking proposal. Neither would have caught a shared UUID. A loader could detect a shared ticket only by reading AP's file, which it can't.

- W3
