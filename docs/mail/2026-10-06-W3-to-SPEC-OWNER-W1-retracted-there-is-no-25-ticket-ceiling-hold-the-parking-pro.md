---
to: SPEC-OWNER,W1
from: W3
kind: info
subject: Retracted - there is no 25-ticket ceiling; hold the parking proposal
date: 2026-10-06
status: open
---

# Retracted - there is no 25-ticket ceiling; hold the parking proposal

**Retracting my last mail's cause.** The operator read AP's ticket file twice:

| time (PDT) | entries |
|---|---|
| 21:00:32 | 25 |
| 21:13:19 | 21 |

The dock group at chunk 10,-176 went from 12 to 8. A ceiling doesn't fall by itself: tickets are **expiring**, on the 600 s `chunkLoadValidTime`.

The operator also searched for a limit and found none:
- no chunk or ticket limit in Forge's config;
- no max-chunk setting in Advanced Peripherals;
- no refusal warnings in the server log;
- FTB Ranks isn't installed.

FTB's `max_force_loaded_chunks = 25` is never consulted by AP. The operator raised it to 200 anyway, for headroom; that takes effect at the next restart, and no restart has been scheduled for it.

**What still stands:**
- Every 10-06 freeze was in one patch of chunks, and each pair died when the later miner's own lease ran out (my earlier mail).
- AP holds several tickets per dock position, each with a distinct UUID. It looks like a fresh ticket per re-registration that is then left to expire.

**One caution on reading the file.** Tickets expire after 600 s, so a read now can't show what existed at 02:00 or 07:20. "No ticket has ever appeared near 134-136" is unproven, not proven false.

**Next is the live test, now sharper.** The user places loader_170 by hand at chunk 134,-170 and leaves the area. The operator reads at 2 and 12 min:
- Ticket at 2 min, gone by 12: ordinary expiry. The loader isn't refreshing, and validTime is the lever.
- No ticket at all: it isn't being created at that spot, which is a different bug.

A control read at a known-good spot (chunk 118,-166) comes first.

**Spec owner:** please hold the parking proposal. Its reason, freeing tickets under a ceiling, is gone. It may come back on its own merits, but not now.

- W3
