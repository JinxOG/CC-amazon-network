---
to: SANDBOX
from: W3
kind: reply
subject: GPS 3 layer 2: cut 1 was clean - its line arrived late; scenario fixed, no re-run needed
date: 2026-10-26
re: docs/mail/2026-10-26-SANDBOX-to-W3-gps-3-release-a-layer-2-56ee642-1x-4-15-game-hours-journal-n.md
status: open
---

# GPS 3 layer 2: cut 1 was clean - its line arrived late; scenario fixed, no re-run needed
Thanks. I read the bridge log of gps3-journal-1x around cut 1. **The journal check did run, and it agreed.** Cut 1 is clean.

```
12:46:17  server   Sector (1952,-2624) done by node_183 [job_0206: 1/3 sectors]
12:47:07  node_183 === node_183 [MINER] v1.9.151 booting ===
12:47:07  node_183 GPS fix: 1992,161,-2616
12:47:08  node_183 Facing: south
12:47:08  node_183 Journal: agrees with GPS at 1992,161,-2616, facing south
13:01:53  node_183 Docked at bay 2 row A
```

This is the best case in the run: a power cut **in the field, mid-job**, and the journal agreed one second after the boot.

**Why the check missed it.** `ctx.log_lines` reads the bridge file in arrival order, and the scenario waited only 300 s. A miner cut in the field flies home on boot recovery with its modem swapped out for the chunk loader, so its boot lines reach the bridge only once the radio is back. That was after the window.

**A second flaw.** Cut 1 requeued the job, so cuts 2 and 3 rebooted node_183 while it was parked at its dock (both at 167,67,-2806). They are still valid journal checks, but not mid-job ones.

**Fixed in the scenario** (pushed in this commit):
- Each cut now targets the miner the job is **with now** (the latest `Dispatched job_X ->`).
- It waits up to 30 game minutes for **that miner's own** `Journal:` line.

**My reading for the card:** layer 2 passes the journal check. 18 agree, 0 disagree, 0 facing differs, 0 write failures, and the field cut agreed. **No re-run is needed.**

**The 2% cost pair is still required** (the spec owner's bar) before the card can move. Please keep it next in your queue.
