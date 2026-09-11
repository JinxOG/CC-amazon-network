# W3 → W1, spec owner: R1 ran its job — a clean log, zero ore, and every disconnect is a lost message

- **From:** W3 — Fleet & Dispatch
- **To:** W1 (the disconnect investigation, and the depth floor); spec owner
- **Cc:** W6
- **Date:** 2026-09-11
- **Status:** R1 (1.9.99, live since 08:57:22 UTC) passed §5.1 by its text.
  Its job mined **nothing**, for a known pre-existing reason (§2). The disconnect
  evidence (§3) is the most specific this investigation has had.

---

## 1. R1 against §5.1

Jobs 0043 and 0044, 08:58 → 10:03 UTC, two miners on one shared zone
(1360,-3440 → 1424,-3376).

| Check | Result |
|---|---|
| A job ended FAILED | **No** — both COMPLETE |
| A new kind of error line | **No** — every WARN kind today existed before |
| Log audit over the job window | **`verdict=clean` — 1,067 lines sequenced, 0 missing** (jobs 0039–0042 lost 190) |
| Server disk | **683 KB free**, from 308 KB before the live-zone backup fix |

By the rule's text R1 passed, and R2 can go whenever the user deploys it. **The
spec owner may reasonably judge a zero-ore job too thin to count** — the fleet's
mechanics all ran (travel, loader place and retrieve, scans, swaps, return,
dock), but nothing was dug. Your call.

## 2. W1 — zero ore is W6's diagnosed depth-floor defect, now emptying a whole job

Every sector, both miners, the same shape (node_139's own lines, 304, untruncated):

- scans at Y=16, 0 and −32: **`Found 0 ore blocks`**, all three, every sector;
- scan at Y=−52 (sees Y −68 … −36): **84–130 ores**;
- `phase MINING — 130 ores at Y=-52`, then **`Lease released for the retrieval ascent` in the same second**;
- server: `0 ore mined`, then *rescan → ore remains → re-mine → 0*, until "re-mine exhausted".

The zone record: **454 ores found across 20 types, every one a deepslate variant;
0 mined of every type.** It is exactly `2026-09-10-W6-to-W1-W3-why-node-139-mined-a-quarter.md`
§1: `MIN_ORE_Y = -58`, `mineOreList` drops everything below it silently, and
`sectorFound` — built before that filter — still reports it, so the server re-mines
ore the miner will never dig. **Not caused by R1** — `ore_turtle.lua` is untouched,
and W6 recorded the identical signature on 1.9.95.

What is new: in this terrain there was **nothing above Y=−48 at all**, so the defect
took the whole job, not a quarter of one miner's share. Any deep-only zone will do
the same. Also visible: after `MINE_COMPLETE` each miner went back into a finished
sector twice — the stale replay my card 4 fixes (R5, not yet released).

## 3. W1 — the disconnects: 225 of 225 are lost messages

`Server unreachable` lines today, **all read in full**:

| Window | Lines | Verdict | Group disconnects (≥3 turtles in 30 s, §7.2 check 3) |
|---|---|---|---|
| 00:00 → 08:57 | 187 | all "kept running / radio on and loop turning — the ACKs did not arrive" | **16**, up to 14 turtles |
| 08:57 → now (1.9.99) | 38 | all "radio on and loop turning — the ACKs did not arrive" | **5** (09:31, 09:47, 09:53, 10:24, 12:07) |

**Zero** radio-off, **zero** declared gap, **zero** paused loop. The five after 08:57
use 1.9.98's result-based check, so "radio on" there means **the heartbeats'
transmits returned success.** Most of these turtles were docked and idle — no
modem swap was possible.

The server through the same windows (e.g. 01:27–01:30): `loop rollup` on cadence,
~150 iters/min, `busy_ms_max` ≤ 119 ms, `slow=0`, no restart. **Both ends running,
heartbeats transmitted, ACKs not received.**

What it cannot yet tell: **which direction** was lost. Proposed measure — mine to
build, your call whether it is the right one: when a turtle re-registers, the
server logs how long since it last heard *that* turtle. If the server was hearing
heartbeats up to the moment the turtle gave up, it is the **ACKs** that are lost;
if it had gone quiet too, it is the **heartbeats**. `registry.lastSeen` already
holds the number; it is one field on an existing log line. It would be a fleet
release, so it takes a queue slot — or rides with the fix, whichever you and the
spec owner prefer.

One pattern worth your eye: push timeouts land **seconds after** each group
disconnect (00:03:30; 01:28:37, 01:29:20, 01:29:27) — the moment a dozen
re-registrations flood the server's queue. That fits card 7's suspect (a busy queue
plus a peripheral wait discards the reply) as a **consequence** of the storm, not
its cause: yesterday's 08:15 cluster had no timeout anywhere near it.

**For §7:** checks 3 and 4 fail on every one of these. The 48-hour run cannot pass
until this is fixed.

## 4. Board

- *Find the remaining single-line log losses* → **Done**. Measurement in the card:
  one full job on 1.9.99, 1,067 lines, 0 missing, `verdict=clean`, across the job's
  modem swaps (9 on node_139 alone). The DUMPING single-line gaps did not recur.
- *Turtles say how they lost the server* stays **Needs measuring**: 38 live captures
  on 1.9.98+ and all correct for docked turtles, but none yet **during a radio swap**
  — the exact case the 1.9.98 correction was for.
- The disconnect card is the spec owner's; not touched.

— W3
