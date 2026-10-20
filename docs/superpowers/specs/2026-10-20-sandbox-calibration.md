# Sandbox calibration against the live fleet

- **Written:** 2026-10-20, by the sandbox builder. **Status:** step 1 (calibration from the live logs) done; step 2
  (the forward run on the real server) is waiting for the user — instructions at the end.
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

## 3. Forward calibration (spec 8.2) — what the user needs to do

The zone the user named: **x 1904..2000, z −2640..−2608**, mined with two miners.

1. In the sandbox (done, redone 2026-10-20): `sandbox/sim run sandbox/scenarios/real_world_three_sectors.lua`. The
   order must carry the sector **centres** `x1=1920 z1=-2624 x2=1984 z2=-2624`; the corners 1904,-2640,2000,-2608 are
   the footprint the dashboard draws, and ordering them makes the server cut 5 x 3 = 15 sectors (twelve outside the
   imported world). Result for the 3-sector order: survey done 24 min after dispatch, all 3 sectors mined 3 h 26 min
   after dispatch, rescan finished by 3 h 44 min; one miner did the work; 4,172 ore from the first sector, 0 from
   the others; 4,196 ore blocks in storage; 288x real time. The first (15-sector) result of 11,304 ore / 208x is void
   as a calibration number (`real_world_six_hours.lua` still exists as the speed benchmark).
2. On the real server (the user): order the same job — the same order (centres 1920,-2624 to 1984,-2624) — and let it run for the
   same six hours, from a state like the backup's (all miners docked, storage as in `state-2026-10-19.json`).
3. Compare: ore delivered, batches per hour, sectors done, messages sent and the ack loss from
   `tools/ack_loss.py`. Expected differences: ack loss (section 2), and anything in the mod world the sandbox does
   not model (the report's NOT MODELLED list).

Until step 2 is done, the sandbox's absolute numbers rest on the batch-cadence fit above and nothing else.

One artefact of starting from the backup: miner 178 was already out in the sky, mid-job, when the backup was made. In
the sandbox it reboots away from the base with no loader it can recover and its jobs fail with `reboot_recovery`; the
other four miners are docked and unaffected.
