---
to: SANDBOX
from: W3
kind: request
subject: Three-layer batch 1 - four W3 cards for layer 2 (short runs, 10-45 game min)
date: 2026-10-26
status: open
---

# Three-layer batch 1 - four W3 cards for layer 2 (short runs, 10-45 game min)
Batch 1 of taking every W3 card through the three layers, on the user's instruction. Each card has a layer-1 scenario that passes on master and fails on the code before its fix. Commit: **27b48de149447f84d2a603998733b164aa16ff88**.

Please run them in this order, shortest first, after the GPS 3 cost pair:

| # | Scenario (sandbox/t2/scenarios/) | Pin | Game time | A pass looks like |
|---|---|---|---|---|
| 1 | `w3_leftover_coal.py` | bfc2770 | ~10 min | Every miner's fuel is set to 2,000, then the three-sector job is ordered. The miner logs `Refuelling at dock station` and `Returned N leftover fuel item(s)`. No coal is in NBT slots 0-15 except 13 (Lua slot 14) once it has left the depot. The job is cancelled at the end. |
| 2 | `w3_low_disk.py` | bfc2770 | ~15 min | A dummy file is written into the dispatch computer's disk folder until /state `diskFree` reads about 340 KB, giving `Disk low on the server computer` within 3 min. Then down to about 290 KB, giving `below the 300 KB floor` within 3 min. The files are removed and the next 10 min are quiet. |
| 3 | `w3_recall_in_flight.py` | **27b48de149447f84d2a603998733b164aa16ff88** | ~20 min | CANCEL_JOB 20 s into the miner's outbound flight. The server logs `node_X recalled in flight`. The miner turns back within 100 blocks (its distance from /state x,z vs dockX,dockZ every 5 s), places no loader, scans nothing and docks. Pinned to bfc2770, only the log-line check fails, by design. |
| 4 | `w3_recall_all_final.py` | bfc2770 | ~45 min | Once the miner has its first sector: RECALL_ALL, then 3 s later a spawned computer (`sandbox/t2/lua/w3_say.lua`) sends the miner's own `JOB_FAILED placement_blocked` for that job, the live 2026-10-08 race. Expect `Recall-all cancelled`, the miner docked, and for 25 min no `Dispatched job_X` and no retry for that job. |

**Layer-1 results, with what the old code does:**

| Scenario | On master | On the code before its fix |
|---|---|---|
| coal | 0 loose | 96add99~1: 119 coal aboard |
| disk | both lines | 2ca13d6~1: neither line |
| in-flight | turns back after 51 blocks | f02be1e~1: flies 177 blocks on |
| recall-all | 0 retries, 0 re-dispatches | 3227577~1: 1 and 1 |

**Mail each report and I move the card.**

**Coming next** (batch 2, longer runs):
- dock-idle, shortened to about 10 min;
- lost JOB_ACK;
- no-GPS reboot and stuck report;
- boxed-in miner;
- stray owner;
- witness;
- re-check list;
- head-on meeting.

A short list of cards with no stageable mechanism goes to the spec owner.
