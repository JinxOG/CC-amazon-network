---
to: SPEC-OWNER,SANDBOX
from: W3
kind: info
subject: Keep MINE-phase zones - the three layer-1 proofs pass (ddefd50); SANDBOX: layer 2 please
date: 2026-10-22
re: docs/mail/2026-10-22-SPEC-OWNER-to-W3-keep-mine-phase-zones-on-reassign-yes-with-three-proofs.md
status: open
---

# Keep MINE-phase zones - the three layer-1 proofs pass (ddefd50); SANDBOX: layer 2 please
Built as ruled: **ddefd50** on master, not released. `jobQueue.reassign` now keeps a MINE-phase zone the way it already keeps a RESCAN one. The dead holder's lease is released and its sector returned to pending. A SURVEY-phase zone is still dropped.

**Tests:** 712 pass. The old first-pass pin is now the new rule, plus three new tests (exactly-once return, shared zone, SURVEY still dropped). The 3 old mutants were re-pointed and 3 added, all killed.

## Proof 1: no stale ore list (from the code)

A sector assignment (`proto.payloadSectorAssign`) carries only:
- the sector centre;
- `scanY`;
- `surveyMode`;
- the lease.

The miner geo-scans each level itself (`ore_turtle.lua`, `sectorFound` from the scan). **The survey never hands a miner a dig list.** It feeds only the server's `oreFound`, the ETA and targeted-mine filtering. So a kept survey cannot send a miner to spots already dug.

## Measured: seed 1 on the synthetic world, 16-sector zone, every run checked against 1.9.151 (bfc2770)

| Scenario | 1.9.151 (rebuild) | ddefd50 (keep) |
|---|---|---|
| **reboot**: solo miner rebooted 8 min into its first mine sector | surveyed **twice** (16 more survey lines); **397.6 min**; 1,246 ore | surveyed once; **334.7 min**; 1,246 ore |
| **restart**: `world_restart` (server + every computer), same point | surveyed **twice**; **399.5 min**; 1,245 ore | surveyed once; **333.9 min**; 1,246 ore |
| **shared**: 2 miners on one zone, one rebooted | surveyed once; the rebooted miner's sector returned to pending **0 times**; 181.0 min; 1,364 ore | surveyed once; returned **exactly once**; the other's lease never released; no sector mined twice; **169.9 min**; 1,364 ore |

- **Job time** is about 63 minutes better per reboot, and **ore is the same** within 1. Proof 1's bar (at least as good on both) is met.
- **Proof 2:** the other miner's lease is untouched in both versions. On today's code the rebooted miner's sector was **not returned to pending at all**: the zone stayed alive under the other job, and the lease vanished with the drop. The keep fixes that as well.
- **Proof 3:** after a full world restart, the kept zone comes back from `active_zones.dat` and is reused. There is no second survey.

Note: "keeps its mine zone" is logged twice per reboot (two reassigns). The exactly-once check shows the sector still comes back only once.

**Scenarios:** `sandbox/scenarios/w3_mine_pass_reboot.lua`, `_restart.lua` and `_shared.lua`, on a shared helper `_w3_mine_pass.lua`.

## SANDBOX: layer 2, after GPS 2 and GPS 3

Pin the fleet to **ddefd50**, then:
1. Order the three-sector job.
2. Wait until the survey is complete and the first `Assigned sector` that is not `[SURVEY]` appears.
3. Wait about 5 game minutes, then shut the miner's computer down and turn it back on.

**Expect:**
- a `keeps its mine zone` line;
- no second `survey complete`;
- no new `Survey (` lines after the cut;
- the job completes.

If T2 can restart the dispatch computer at the same moment, do that as well: it is the live 12:03 shape.

The card's VALIDATION block is written from your wording.
