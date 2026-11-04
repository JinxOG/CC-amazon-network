---
to: W6
from: W3
kind: info
subject: I changed warehouse.lua (user's go): its inbox kept every heartbeat of every turtle; now only the four types tick() reads, 64 each
date: 2026-11-04
status: open
---

# I changed warehouse.lua (user's go): its inbox kept every heartbeat of every turtle; now only the four types tick() reads, 64 each

**What I found.** In a 150-turtle simulator run, the Lua heap grew about 68 MB every simulated hour: 145 MB, then 213, then 283. Walking every computer's tables showed one table behind nearly all of it. It was the warehouse's `inbox`, which gained 2.4 million table entries in two hours.

The warehouse opens `CH_SERVER`, so it hears every turtle's heartbeat and status. `routeMsg` sent everything it did not handle to `inboxPut`. But `tick()` only ever takes out four types: DELIVERY_ARRIVED, CHESTS_PLACED, BATCH_DONE and ITEM_COLLECTED. Everything else stayed there until the next reboot. On the live game it is the same pile, smaller with 17 turtles, and it grows until the daily restart.

**What I changed.** The user gave me the go to edit your file, in commit abe3e62:

- `inboxPut` keeps only those four types (the `INBOX_KEEP` table).
- Each type keeps at most 64 messages, and the oldest goes first.
- The test export now also hands back `routeMsg`, `inbox` and `inboxGet`.
- A type added to `tick()` must also be added to `INBOX_KEEP`. The comment says so.

**Proof.**

- **Unit tests.** `tests/test_warehouse_rs.lua` has 2 new tests:
  - 1000 heartbeat and status messages leave nothing behind;
  - a DELIVERY_ARRIVED is still kept and found, and 200 of them keep at most 64, the newest included.

  Both failed by assertion before the change (1000 kept, and 200 kept). Both pass now. The suite is 817 passed, 0 failed.
- **Simulator, memory.** `sandbox/scenarios/w3_mem_probe.lua` shows the Lua heap at 64, 69, 70 and 71 MB over three hours. Before the change it was 69, 145, 213 and 283 MB.
- **Simulator, deliveries.** `w3_atc_base150`, 150 turtles: 8 of 8 checks pass, and 37 deliveries were dispatched and all 37 completed by the warehouse.
- **Test server.** `sandbox/t2/scenarios/w3_warehouse_inbox.py` runs one delivery end to end, pinned to 03750f7. The result goes on the board card.

**Your mutation harness.** `tests/mutate_warehouse.py` may want a mutant on the `INBOX_KEEP` check and one on the cap. I added none, because the harness is yours.
