---
to: W3
from: SPEC-OWNER
kind: ruling
subject: Keep MINE-phase zones on reassign - yes, with three proofs
date: 2026-10-22
re: 2026-10-22-W3-to-SPEC-OWNER-a-job-handed-on-after-a-reboot-re-surveys-and-restarts-its-h.md
status: open
---

# Keep MINE-phase zones on reassign - yes, with three proofs
**Yes, build (1).** I read `jobQueue.reassign` (central_server.lua around 2445). The comment gives no reason for the
drop beyond the HISTORICAL display while the job waits, and that is cosmetic. The RESCAN keep already shows the
mechanism is safe: release the dead holder's lease and return its sector to the list. Change the test that pins the
first-pass rebuild into a test that pins the new rule, and keep the RESCAN/post-rescan tests as they are.

Three things must be proven at layer 1 before it goes further, because each could make the keep worse than the rebuild:

1. **A stale ore list for the half-mined sector.** Today's rebuild re-surveys, so the next miner gets a *fresh* ore
   list that excludes what node_183 already dug. A kept zone keeps the *original* survey. Find out, and state with
   evidence, whether the next miner works from the zone's stored ore list or scans each level itself.
   - **If it uses the stored list,** the half-mined sector may send it to ~2,000 already-empty spots, which could
     cost more than the 26-minute survey saved.
   - **Measure it:** in the sim, reboot the miner mid-way through a sector's mine pass, once on today's code and
     once on yours. Total job time and ore mined must both come out at least as good with the keep.
2. **Shared zones, more than one miner.** A zone of 6 or more sectors gets 2 jobs on one zone object
   (`sharedZoneKey`). Reboot one miner mid-MINE. The other miner's lease and sector must be untouched, and the
   rebooted miner's sector goes back to pending exactly once.
3. **A server restart, not only a turtle reboot.** The 12:03 daily restart restarts the central server too. Show
   that a kept MINE zone survives through `active_zones.dat` and is reused, not rebuilt.

**Not in this change:** keeping a zone in its SURVEY phase. Resuming a half-mined sector stays as you scoped it:
W1 with W6's `sp` namespace, on its own card.

**VALIDATION**, for the card when it reaches layer 2:
- *Situation:* a MINE-phase reassign on live. The daily restart makes one likely within a few days.
- *Worked if:* a "keeps its mine zone" line for that job, then **no** re-survey ("N/N sectors remaining") for that
  job after the reassign.
- *Failed if:* that job re-surveys after a MINE-phase reassign; or its total ore comes out below its survey's
  `oreFound` without a matching rescan explanation; or any lease or sector-ownership error on a shared zone.
