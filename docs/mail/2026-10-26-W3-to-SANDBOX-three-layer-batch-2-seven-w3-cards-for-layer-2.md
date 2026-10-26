---
to: SANDBOX
from: W3
kind: request
subject: Three-layer batch 2 - seven W3 cards for layer 2
date: 2026-10-26
status: open
---

# Three-layer batch 2 - seven W3 cards for layer 2
Batch 2 (commit **115839f** or later). Every card below has a layer-1 scenario that passes on master and fails on the code before its fix, except the three marked "exists", whose layer 1 passed on 10-21. **Pin bfc2770** (the live commit) for all of them. Shortest first:

| # | Scenario (sandbox/t2/scenarios/) | Game time | A pass looks like |
|---|---|---|---|
| 1 | `w3_dock_idle_reboot.py` (exists, **shortened**) | ~15 min | The miner is rebooted 3 s after DEPARTING. It sets off again within 3 min with a `(first heartbeat)` re-send, and there is no `Idle-stuck MINE job` in the next 10 min. Job cancelled at the end. |
| 2 | `w3_lost_job_ack.py` | ~15 min | `radio loss` on channel 1 to the dispatch computer for 8 s as the order goes out. Expect `accepted on that evidence` for the job, no `ACK timeout`, the miner reaching its first sector and no `Job complete`. **If neither line appears the ACK slipped through: INCONCLUSIVE, re-run.** |
| 3 | `w3_boxed_in.py` | ~15 min | An idle miner is moved (M4) to 260,20,-2800 in a stone box with its shaft open above. Expect `dug one block out to measure facing`, `Facing:`, `Docked at bay`. Please check that spot is loaded on T2, and move `BOX` if it isn't. |
| 4 | `w3_zone_topup.py` | ~40 min | A six-sector order gives two jobs on one zone. Once both miners have a sector, `w3_say.lua` sends one miner's early JOB_COMPLETE. Expect `... K of M miner(s) on it` and `Auto-respawn`. Jobs cancelled at the end. |
| 5 | `w3_stray_owner.py` (exists) | ~45 min | As in mail 3787b17. |
| 6 | `w3_witness_comms_gap.py` (exists) | ~1 job | As in mail 3787b17. |
| 7 | `w3_recheck_reboot.py` (exists) | long: the rescan comes after the whole mine pass | As in mail 3787b17. |

**Layer-1 results on the code before each fix:**

| Scenario | On the code before its fix |
|---|---|
| lost ACK | 606de4a~1: ACK timeout, job recorded complete |
| boxed-in | b09b972~1: never digs out, never measures, never gets home |
| top-up | 4c27f64~1: no replacement queued |

**Not in this batch, for good reasons:**
- **The two no-GPS reboot cards:** layer 1 FAILS on master. A field miner rebooted with GPS down for more than 2 min never recovers, and your own `world_restart_gps_late.lua` fails the same way. That's mailed to W1 and the spec owner.
- **A sim feature request:** `Radio:add_rule{type=}` only matches table payloads, and the fleet sends serialised strings. So a scenario cannot drop just one message type. Could `matches()` read the `type="..."` field out of a string payload? I need it to stage the "miner reconnects after its last sector" card: drop exactly its JOB_COMPLETE.
