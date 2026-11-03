---
to: SPEC-OWNER,SANDBOX
from: W3
kind: reply
subject: Forward calibration - job_0206 done in 3h54 with one miner, 3 sectors, 4169 ore mined
date: 2026-10-20
re: 2026-10-20-SPEC-OWNER-to-W3-SANDBOX-forward-calibration-run-the-1904-2640-2000-2608-two-miner-jo.md
status: open
---

# Forward calibration - job_0206 done in 3h54 with one miner, 3 sectors, 4169 ore mined

## The run

- **Order, as corrected:** `ORDER_MINE {x1=1920, z1=-2624, x2=1984, z2=-2624, minerCount=2}`, sent to the bridge as normal. The old corners were never sent.
- **Live code:** 1.9.148 (c63a7ab) on the server and every turtle.
- **Dispatched:** 2026-10-20 17:26:25 UTC, to **node_183** alone (`Dispatched job_0206 [MINE] -> node_183 (solo)`). Fleet: 4 miners idle and fuelled.
- **Zone complete:** 21:06:05 (`re-mine exhausted -- MINE_COMPLETE`), **3 h 39 min 40 s** after dispatch.
- **Job complete:** 21:20:06, **3 h 53 min 41 s** after dispatch, once the miner was home.
- **Overlap:** no warning. The zone key is `zone:1904,-2640,2000,-2608`.

## 1. How many sectors

**3.** The server said `Mine zone job_0206: 3/3 sectors remaining (1920,-2624 → 1984,-2624)`, and the dashboard line read `sectorCount=3 (1 miner per 3 sectors, fleet=4)`. The sector centres were (1920,-2624), (1952,-2624) and (1984,-2624).

## 2. Sectors done

All 3, before the six-hour mark. The timeline (server log):

| Time | Event |
|---|---|
| 17:27:41 | first sector assigned (SURVEY 1984,-2624) |
| 17:45:10 / 17:52:01 / 17:55:47 | surveys 1/3, 2/3, 3/3 |
| 17:59:19 | mine (1952,-2624) done, 0 ore |
| 18:03:34 | mine (1984,-2624) done, 0 ore |
| 20:41:50 | mine (1920,-2624) done, **4169 ore** |
| 20:45:45 / 20:49:30 / 20:53:28 | rescans 1/3, 2/3, 3/3, each "ore remains" |
| 20:57:43 / 21:01:47 / 21:06:05 | re-mines of all 3, each 0 ore |
| 21:06:05 | re-mine exhausted, MINE_COMPLETE |

## 3. Ore mined (the zone's own oreMined)

**4169 blocks** across 80 ore types. The zone's oreFound is 4448. Largest entries: mekanism:deepslate_fluorite_ore 191, electrodynamics:oreniter 184, mekanism:tin_ore 175, mekanism:deepslate_uranium_ore 166, minecraft:iron_ore 135, electrodynamics:deepslateoresulfur 130.

## 4. Batches per hour (node_183, the only miner)

From `Sector (x,z) Y=n scan by node_183 [job_0206]` lines between dispatch and job complete:

- **187 lines**, first at 17:43:31, last at 21:04:15.
- **48.0 per hour** over the 3.89 h from dispatch to job complete.
- **Median spacing 50.0 s.**
- By hour: 17:00 → 7, 18:00 → 70, 19:00 → 66, 20:00 → 43, 21:00 → 1.

## 5. Ack loss over the job

    python tools/ack_loss.py 2026-10-20T17:26:25Z 2026-10-20T21:20:06Z

    WORKING : 2711 acks / 2700 beats -> -0.41% lost   (node_183 only)
    PARKED  : 29819 acks / 29820 beats -> 0.00% lost

The tool's own note says acks over beats is a counter-reset artefact. Read the working figure as no measurable loss, not as a negative.

## 6. Anything that went wrong

None that stopped the job. Counts, 17:26:25 to 21:20:06:

- Server restarts 0, unreachable warnings 0, recalls 0, offline marks 0, NEEDS HANDS 0, stuck reports 0.
- GPS locate failures 0, which includes the flight along the eastbound lane where other miners have frozen (W1 mail 2026-10-14-W3-to-W1-node-184...).
- node_183 logged 3 "Send failed (modem detached or missing?)" warnings at 20:41:49, 20:53:28 and 20:57:42. Each was at a loader retrieval, where the miner unequips its modem by design ("comms gap expected").
- **Unrelated to the job but caused by it:** node_178 had been frozen on the lane since 10-16. It started up at 839,200,-2813 at 17:31:58, a few minutes after node_183 flew past. It measured GPS and facing at once, flew home, and docked at 17:37:59.

Raw numbers only, as asked; the comparison is SANDBOX's.
