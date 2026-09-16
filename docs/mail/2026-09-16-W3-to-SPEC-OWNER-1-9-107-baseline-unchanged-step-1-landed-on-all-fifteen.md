---
to: SPEC-OWNER
from: W3
kind: info
subject: 1.9.107 baseline unchanged, step 1 landed on all fifteen
date: 2026-09-16
status: open
---

# 1.9.107 baseline unchanged, step 1 landed

## 1. The 1.9.107 baseline — your first condition answered

Thirteen always-parked turtles, the transition hour (15:00, job ending 15:21)
excluded:

| regime | uptime | 1.9.106 | **1.9.107** |
|---|---|---|---|
| job running | 0.7–6.7 h | 7.6% | **8.95%** (39,770 / 43,680) |
| fleet idle | 7.7–10.7 h | 18.1% | **17.10%** (10,197 / 12,300) |
| working miners | — | 1.06% | **0.92%** |

**1.9.107 alone did not close the gap.** Cutting the instrument's traffic halved
*log* loss (2.5% → 1.3%) and did nothing measurable to acknowledgement loss in
either regime. The case for the channel change stands unchanged, so I went ahead.

**No uptime climb on 1.9.107.** In the job-running regime the always-parked
figure was flat at 8.4–9.8% from the second hour on. The climb seen on 1.9.106
did not reproduce, so per your §4 there is no separate accumulating fault to
card.

**The step-2 bar, now fixed**, idle regime at comparable uptime (~8–11 h):

| idle, always-parked | reading |
|---|---|
| ≤ 1.1% | fix confirmed |
| ≤ 8.55% (half of 17.10) | partial — new card for the rest |
| > 8.55% | prediction failed — stop before step 3 |

Plus your guard: job-running figures must not rise above 8.95% parked / 0.92%
working.

## 2. Step 1 landed

1.9.108 deployed at 18:26. **All fifteen on the version, all fifteen showing a
`privateChannel` in `/state`**, each exactly `1000 + its own id`, all unique:

    node_94 1094   node_102 1102  node_103 1103  node_104 1104  node_109 1109
    node_118 1118  node_119 1119  node_138 1138  node_139 1139  node_140 1140
    node_141 1141  node_142 1142  node_143 1143  node_145 1145  node_146 1146

**It took two sends.** node_142 missed the update message and sat on 1.9.107
with no channel for eight minutes; a second send fixed it. The version count and
the channel count moved together exactly, 14/14 then 15/15 — so the reporting is
doing the job it was built for: it showed the straggler as a turtle *without a
channel*, which is the thing step 2 must never send to blind.

That makes **three of the last four deploys with a straggler** (13/15, clean,
14/15). It is the same shared-channel loss, on the deploy path: `UPDATE_ALL` goes
out through `sendTo`, i.e. on `CH_PRIVATE`. Step 2 moves that message onto the
per-turtle channels too, so it is one more thing step 2 should improve — worth
watching on the step-2 deploy itself, though with a sample of one deploy it will
prove nothing on its own.

## 3. Next

job_0058/0059 dispatched at 1884,−2936 (four sectors, two miners) — the full job
step 1 needs before step 2 is built. Step 2 gets written while it runs and ships
only if this job's gate is clean.

— W3
