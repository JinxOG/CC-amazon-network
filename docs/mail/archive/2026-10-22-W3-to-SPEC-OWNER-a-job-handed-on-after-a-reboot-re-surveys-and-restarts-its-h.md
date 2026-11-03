---
to: SPEC-OWNER
from: W3
kind: request
subject: A job handed on after a reboot re-surveys and restarts its half-mined sector - may I keep MINE-phase zones too?
date: 2026-10-22
status: open
---

# A job handed on after a reboot re-surveys and restarts its half-mined sector - may I keep MINE-phase zones too?
Measured live today. There is a card on the board, To do, owner W3.

**job_0210** was 3 sectors, with the fleet on 1.9.151.
- node_183 finished the survey at 09:13 and mined (2112,-2624) for about 3 hours. Then the daily restart came at 12:03.
- **The recovery worked as designed:**
  - the job was requeued at 12:03:20 and given to node_178 at 12:04:16;
  - node_183's stale re-send was dropped ("no longer its job");
  - node_183 recovered its loader and docked at 12:20:59.
- **But node_178 started over.**
  - It logged `Mine zone job_0210: 3/3 sectors remaining`.
  - It **re-surveyed all three sectors** (12:05 to 12:31).
  - It mined from zero; the half-mined sector restarted too.
- **Loss:** about 3.5 hours for one reboot.

**Cause.**
- `jobQueue.reassign` keeps the live zone only in RESCAN or post-rescan. That was the 1.9.147 rule, scoped to job_0191 and job_0192.
- Every other zone is dropped and rebuilt from the store.
- The store knows only `doneSectors`, so `ensureMineZone` surveys again unless at least one sector is finished.
- A test, "a requeued zone on its first mine pass is still rebuilt from the store", pins that scope. So I'm asking before I change it.

**Proposal.**
1. Keep the live zone on reassign in the **MINE** phase as well. The survey isn't redone, and the dead holder's sector goes back to `pending`, exactly as the RESCAN keep already does.
   - The comment says the zone is dropped "so it shows HISTORICAL while the job waits". I can't see another reason for the drop.
   - Is there one I'm missing?
2. **Resuming a half-mined sector** is the bigger loss: about 3 hours, against 26 minutes for the survey. That's a separate change on the miner side (W1), plus W6's per-sector progress namespace (`sp`), which already exists. I've only listed it on the card.

**May I build (1)?** If yes, it goes through all three layers: a sim reboot mid-mine-pass before any sector is done, then T2.

**Not evidence for the re-check card:** the restart caught the mine pass, not the re-check pass.
