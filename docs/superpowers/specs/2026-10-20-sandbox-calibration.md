# Sandbox calibration against the live fleet

- **Written:** 2026-10-20, by the sandbox builder. **Status:** step 1 (calibration from the live logs) done; step 2
  (the forward run on the real server, W3's job_0206 of 2026-10-20) done, compared in section 3.
- **Data:** the live bridge's `/state` read once and its log pages read once, both with the user's say-so on
  2026-10-20, saved under `G:\TurtleOS-Sandbox\storage\`. Nothing in the sandbox itself contacts the server. The
  figures can be re-derived: `python sandbox/tools/calibrate.py G:/TurtleOS-Sandbox/storage/live <run-folder> ...`.

## 1. What was measured, and what the sandbox now does

| Quantity | Live fleet | Sandbox before | Sandbox now | Source |
|---|---|---|---|---|
| Time per 25-ore batch, one miner (median) | **50.6 s** (7,873 batches, 2026-10-08/09/14/15/16; p25 42.9, p75 61.7) = 29.6 ores/min | 59–70 s (21–26 ores/min) | 52–55 s | The server logs `Sector (x,z) Y=n scan by node_N` once per 25-ore batch; consecutive lines of one node |
| Turtle move / turn / up / down / dig / place | not measured directly | 400 ms each (a guess) | **300 ms each** | One shared value fitted so the batch cadence above matches (scales 1.0 / 0.75 / 0.6 gave 58.9 / 50.3 / 43.1 s) |
| `rsBridge.listItems` | **65 ms** median (904 idle probes, 2026-10-17; range 7–94; the 2026-09 figure of 267 ms was for a different storage size) | 267 ms | 65 ms | warehouse log lines `RS probe: listItems Nms` |
| `pushBuildMs` (building the bridge push) | **13 ms** (live `/state`; documented range 11–21) | 3–4 ms | 17–20 ms | `ns_per_instr` 50 → **150** |
| Server loop busy time per iteration (median of rollups) | **1.9 ms** | 0.3 ms | 1.7 ms | `loop rollup: busy_ms_avg=` |
| `rsBuildMs` (rebuild + `serialiseJSON` of 499 items) | **64 ms** | 6 ms | 19 ms | still about 3× too low: the CC ROM's `serialiseJSON` costs more instructions than the sandbox's |

The movement/dig value of 300 ms is a fit, not a measurement of each action: the live logs record batches, not single
moves. It makes the cadence right; it does not prove 300 ms is what a move takes in the game.

## 2. Still unverified (listed as such in every report)

Geo scan time (1 s), reboot time (1 s), the cost of a turtle command such as `detect` (one tick), cloud-store calls
(50 ms), attack time, and — more important — the **radio and mailbox behaviour behind ack loss**.

**Ack loss: compared against the right figure, and the old fault is reproduced.** The 11-18% parked loss was the
fleet *before* the per-turtle private channel (23f5a97 step 1, 105d104 step 3 = 1.9.112, which the live 1.9.148
contains). The live parked loss now is **0.02%** (182,728 acks of 182,760 beats over 24 h, 16 parked nodes; W3,
f817162). Replay in the sandbox, whole fleet parked at the base, no job, 8 simulated hours, synthetic world,
`sandbox/scenarios/ack_loss_parked.lua --code rev:<sha>`, `tools/ack_loss.py` through `BRIDGE_URL`:

| code | parked ack loss |
|---|---|
| before 23f5a97 (1.9.107) | **9.08%** (per node 2.1-12.3%; live: 11% parked, 18% idle) |
| 23f5a97 (step 1, listens on both channels) | 9.16% |
| 105d104 (step 3, 1.9.112) | 1.15% (live today: 0.02%) |
| current master | **0.03%** (live today: 0.02%) |

So the sandbox shows the old fault, a little smaller than live (9% against 11-18%), shows it gone after step 3, and
matches the live figure on current code. It does not match the live figure at 1.9.112 (1.15% against 0.02%): the
remaining 1% went away between 105d104 and master. The sandbox's own message-loss counters for the old code show that
**the acks are not lost at the event queue**: for each parked worker every ack addressed to it was queued (about
3,400 over 8 h, matching the beats) and every one was handed to its program; none was dropped by the 256-event queue
(0 overflows anywhere) or by a filtered yield (0 acks; 1-7 of 22,000 messages per worker). The turtle's own counter
still reads 9% fewer acks than beats, so the loss is after the hand-off, inside the program's receive/handling
(consistent with the "drain-first" behaviour of `base.receive`, not confirmed here). The server computer, by
contrast, does lose messages to filtered yields on the old code (2,135 of 22,255, 9.6%). Open question for W3: where in
turtle_base's loop the acks go. The sandbox's turn rate for a parked worker is 0.9 turns/s on the old code and 0.34
after step 3; check that against live logs of both eras.

**The 1.9.112 loose end, bisected (2026-10-20).** At 1.9.112 the sandbox still showed 1.15% parked ack loss where live shows
0.02%. `ack_loss_parked.lua` (4 simulated hours, fleet parked) over all 78 commits that touch `turtle_base.lua`,
`protocol.lua` or `central_server.lua` between 105d104 and master gives two steps and nothing else:

| from | to | parked loss | what the commit is |
|---|---|---|---|
| 105d104 .. 678580c (1.9.112-1.9.115) | | 1.1-1.65% | |
| **3aabd51** (1.9.116, 2026-09-22) | | **0.53%** | `proto.encode` defaults `to` to "server": the warehouse's log batches, keepalives and storage digests had been rejected at the server's door for nine days |
| 3aabd51 .. 92f7d34 (1.9.116-1.9.140) | | 0.50-0.56% | |
| **59ccebd** (1.9.140, 2026-10-12) | | **0.05%** | `refreshCraftable` stands down while the warehouse is alive: the server computer no longer calls `listCraftableItems` every 60 s (a 588 ms stall per W6's measurement) |
| 59ccebd .. master | | 0.05% | live today 0.02% |

Both steps are the server computer being busy (peripheral stalls, work on messages that could not be handled), i.e. the
server missing acks, which is the mechanism the sandbox models (a busy computer queues events and a filtered yield discards
them). Master now agrees with live (0.05% against 0.02%) and the 1.15% was code that no longer exists; nothing is left to
fix in the model for this. Run folders: `G:\TurtleOS-Sandboxunis-<sha>\`.

## 3. Forward calibration (spec 8.2): sandbox against the live server, 2026-10-20 (Task 25 step 2, done)

Same job both sides: `ORDER_MINE x1=1920 z1=-2624 x2=1984 z2=-2624 minerCount=2` (sector centres; the footprint
1904,-2640,2000,-2608 is what the dashboard draws, and ordering the corners makes 15 sectors, see the mail of
2026-10-20). Sandbox: `sandbox/scenarios/real_world_three_sectors.lua` on the 2026-10-18 17:00 world copy, current
master. Live: W3's job_0206 on 1.9.148 (c63a7ab), dispatched 2026-10-20 17:26:25 UTC, report 2026-10-20 (7d98599).
Both are one-miner jobs: the server gives one miner per 3 sectors and `minerCount` is only a ceiling.

| | live | sandbox | sandbox vs live |
|---|---|---|---|
| sectors the zone was cut into | 3 | 3 | same |
| miners dispatched | 1 (node_183) | 1 (node_178) | same count |
| survey of 3 sectors done, after dispatch | 29 min 22 s | 24 min 16 s | -17% |
| the two 0-ore sectors mined (each) | 3 min 32 s, 4 min 15 s | 3 min 10 s, 3 min 02 s | -20% |
| the ore sector (1920,-2624) mined | 2 h 38 min | 2 h 56 min | +11% |
| all 3 sectors mined, after dispatch | 3 h 15 min 25 s | 3 h 26 min 20 s | +5.6% |
| rescan of 3 sectors | 11 min 38 s | 8 min 39 s | -26% |
| re-mine of 3 sectors | 12 min 37 s | 9 min 24 s | -25% |
| zone complete, after dispatch | 3 h 39 min 40 s | 3 h 44 min 24 s | +2.2% |
| job complete (miner home), after dispatch | 3 h 53 min 41 s | 3 h 55 min 12 s | +0.6% |
| `scan by` batch lines | 187 | 187 | same |
| batches per hour (dispatch to job complete) | 48.0 | 47.7 | -0.6% |
| median batch spacing | 50.0 s | 56.9 s | +14% |
| ore mined (zone's own count) | 4,169 in 80 ore types | 4,172 in 81 types | +0.07% |
| ore found | 4,448 | 4,458 | +0.2% |
| ore by sector | 4,169 / 0 / 0 | 4,172 / 0 / 0 | same shape |
| parked ack loss | 0.00% (29,819/29,820) | 0.03% (46,124/46,140) | within noise |
| working ack loss | -0.41% | -0.43% | both counter artefacts: no measurable loss |
| server restarts, unreachable warnings, recalls | 0 | 0 | same |
| "Send failed (modem detached)" warnings | 3, each at a loader retrieval | 0 | **not reproduced** |

(Live figures from W3's report; sandbox figures from the logs of the run in `G:/TurtleOS-Sandbox/run/rw3`. The sandbox's mining order of
the three sectors differs from live (the server shuffles with the run's random numbers): live did the two 0-ore sectors
first and the ore sector last, the sandbox the ore sector first. That does not change the totals.)

What this says: the totals that matter for planning (time to finish the zone, ore, batches, ack loss) agree to within
a few per cent; the phases do not agree as well (the sandbox's survey, scan-only phases and rescans run 17-26% faster,
its ore-mining phase 11% slower, and its median batch spacing is 14% longer), which cancel in the total. Do not read
the phase times as fitted. The 300 ms movement fit was made from batch cadence, so per-phase errors of this size are
expected. A correction to an earlier note of mine: "sim 6% fast" compares the sandbox's *all sectors mined* (3 h 26 min)
with the live *zone complete* (3 h 39 min); like for like, all sectors mined is 5.6% *slower* in the sandbox and zone
complete is 2.2% slower.

**A live behaviour the sandbox reproduces, for W1 to study there.** In both, the whole zone's ore came from one sector
(1920,-2624: 4,169 live, 4,172 sandbox) and the other two sectors yielded 0; the rescan of all three said "ore remains";
the re-mine of all three yielded 0. W3 mailed W1 on 2026-10-14 about 0-ore sectors (jobs 0191-0193). The sandbox
produces it on the real world copy with the real fleet code, so it can be replayed and instrumented there. Measured,
not explained: `sandbox/sim run sandbox/scenarios/real_world_three_sectors.lua`, then the server log lines
`Sector (x,z) done by ... N ore mined`, `Rescan ... ore remains` and `Zone ... re-mining`.

Still unverified after this comparison: the single-miner run does not test two-miner contention; the ack-loss
comparison is the parked regime plus one working miner; the 3 "Send failed" warnings at loader retrievals are not
reproduced (the sandbox does not log them).

One artefact of starting from the backup: miner 178 was already out in the sky, mid-job, when the backup was made. In
the sandbox it reboots away from the base with no loader it can recover and its jobs fail with `reboot_recovery`; the
other four miners are docked and unaffected.
(Seen in the first, 15-sector run. In the 3-sector run of section 3 the server dispatched to node_178 itself and it completed
the whole job, so this artefact did not stop it there; live, node_178 was the frozen miner on the lane and W3's job went to node_183.)
