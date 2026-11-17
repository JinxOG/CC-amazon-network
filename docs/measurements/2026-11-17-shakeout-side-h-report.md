# Shakeout report

- Run folder: G:/TurtleOS-Sandbox/testserver\runs\shakeout-side-h (T2)
- Length: 3.00 h on the run's clock; seed 1; schedule G:/TurtleOS-Sandbox/testserver\runs\shakeout-side-h\schedule.json
- Evidence: 22986 fleet log lines (0 unparsed), 178 fresh /state snapshots (2 stale), 19 fault-log lines, 8 fault windows, 20 turtles judged

- Not judged: 4 chunk loader(s), which hover over their miner's sector by design: loader_224, loader_226, loader_228, loader_230

## Pass bar

Every count is of 20 turtles judged (evidence: 178 snapshots, 22986 log lines).

- No turtle lost: **0 lost**
- Everything recovered: **0 turtle(s) not recovered** (each counted once; of them 0 stuck at the end, 0 gone at the end, 0 NEEDS HANDS never cleared -- one turtle can be several); and **0 jam(s) never cleared**
- A turtle that fails a job gets itself home and back to work: **0 of 5** judged did NOT (on its dock after the failure AND given a later job); 0 too late to judge (evidence: 19 failed/retried job lines, traced to 5 turtles)
- No turtle decommissioned: **0 decommissioned** (and 0 expected hands, counted apart)
- No wait cleared only by a timer (the user, 2026-11-17): **5 wait(s) cleared only by a timer** -- atc_sweep_live 3, blocked_give_up 1, no_holding_slot 1 (evidence: 22986 log lines scanned; 0 ATC sweep(s) of a turtle never heard again, counted apart as dead)
- Verdicts: ok 12, stuck_recovered 8, decommissioned 0, lost 0, expected_hands 0; stuck at least once: 8

## Stuck or failed turtles

8 turtle(s) not ok, of 20 judged (rule: off its dock with no progress for over 10 real min outside its faults).

- **node_214** stuck_recovered at [246, 60, -2780]: stuck from 1:37 (stopped 1:27) until 1:37, recovered in 16 min from 1:20, faults s004
    `2026-11-17T22:19:33.945Z  node_214#340   WARN   [node_214][WARN] Still waiting 550s — ATC: return from holding slot 9 waiting to be let in (busy at R2) at 246,60,-2780`
    `2026-11-17T22:20:03.946Z  node_214#341   WARN   [node_214][WARN] Still waiting 580s — ATC: return from holding slot 9 waiting to be let in (busy at J1) at 246,60,-2780`
- **node_215** stuck_recovered at [252, 60, -2780]: stuck from 0:36 (stopped 0:26) until 0:37, recovered in 16 min from 0:20, faults s001
    `2026-11-17T21:19:35.795Z  node_215#153   WARN   [node_215][WARN] Still waiting 550s — ATC: return from holding slot 12 waiting to be let in (busy at ARR) at 252,60,-2780`
    `2026-11-17T21:20:05.796Z  node_215#154   WARN   [node_215][WARN] Still waiting 580s — ATC: return from holding slot 12 waiting to be let in (busy at J1) at 252,60,-2780`
- **node_216** stuck_recovered at [242, 60, -2780]: stuck from 1:38 (stopped 1:28) until 1:38, recovered in 18 min from 1:20, faults s004
    `2026-11-17T22:20:30.195Z  node_216#269   WARN   [node_216][WARN] Still waiting 580s — ATC: return from holding slot 7 waiting to be let in (busy at ARR) at 242,60,-2780`
    `2026-11-17T22:21:00.195Z  node_216#270   WARN   [node_216][WARN] Still waiting 610s — ATC: return from holding slot 7 waiting to be let in (busy at R1) at 242,60,-2780`
- **node_217** stuck_recovered at [254, 60, -2781]: stuck from 0:40 (stopped 0:30) until 0:40, recovered in 20 min from 0:20, faults s001
    `2026-11-17T21:10:04.596Z  node_217#71    WARN   [node_217][WARN] Still waiting 160s — ATC: departure (with my delivery) waiting to be let in (busy at J1) at 154,67,-2797`
    `2026-11-17T21:23:03.696Z  node_217#89    WARN   [node_217][WARN] Still waiting 10s — ATC: return from holding slot 13 waiting to be let in (busy at J3) at 254,60,-2780`
- **node_218** stuck_recovered at [234, 60, -2780]: stuck from 1:06 (stopped 0:54) until 1:10, recovered in 10 min from 1:00, faults s003
    `2026-11-17T21:52:29.245Z  node_218#234   WARN   [node_218][WARN] Still waiting 912s — ATC: return from holding slot 3 waiting to be let in (busy at R4) at 234,60,-2780`
    `2026-11-17T21:52:59.245Z  node_218#235   WARN   [node_218][WARN] Still waiting 942s — ATC: return from holding slot 3 waiting to be let in (busy at J1) at 234,60,-2780`
- **node_219** stuck_recovered at [238, 60, -2780]: stuck from 1:08 (stopped 0:56) until 1:11, recovered in 11 min from 1:00, faults s003
    `2026-11-17T21:53:09.696Z  node_219#188   WARN   [node_219][WARN] Still waiting 824s — ATC: return from holding slot 5 waiting to be let in (busy at J1) at 238,60,-2780`
    `2026-11-17T21:53:39.696Z  node_219#190   WARN   [node_219][WARN] Still waiting 854s — ATC: return from holding slot 5 waiting to be let in (busy at R4) at 238,60,-2780`
- **node_222** stuck_recovered at [232, 60, -2780]: stuck from 1:37 (stopped 1:27) until 1:38, recovered in 18 min from 1:20, faults s004; stuck from 2:34 (stopped 2:19) until 2:34, recovered in 14 min from 2:20, faults s007
    `2026-11-17T22:20:50.397Z  node_222#238   WARN   [node_222][WARN] Still waiting 10s — ATC: return from holding slot 9 waiting to be let in (busy at J3) at 246,60,-2780`
    `2026-11-17T22:21:20.395Z  node_222#240   WARN   [node_222][WARN] Still waiting 40s — ATC: return from holding slot 9 waiting to be let in (busy at ARR) at 246,60,-2780`
    `2026-11-17T23:16:41.609Z  node_222#206   WARN   [node_222][WARN] Still waiting 850s — ATC: return from holding slot 2 waiting to be let in (busy at ARR) at 232,60,-2780`
    `2026-11-17T23:17:11.609Z  node_222#207   WARN   [node_222][WARN] Still waiting 880s — ATC: return from holding slot 2 waiting to be let in (busy at J5) at 232,60,-2780`
- **node_223** stuck_recovered at [230, 60, -2780]: stuck from 1:07 (stopped 0:55) until 1:09, recovered in 9 min from 1:00, faults s003; stuck from 2:35 (stopped 2:20) until 2:35, recovered in 15 min from 2:20, faults s007
    `2026-11-17T21:51:14.897Z  node_223#224   WARN   [node_223][WARN] Still waiting 762s — ATC: return from holding slot 4 waiting to be let in (busy at ARR) at 236,60,-2780`
    `2026-11-17T21:51:44.896Z  node_223#225   WARN   [node_223][WARN] Still waiting 792s — ATC: return from holding slot 4 waiting to be let in (busy at R1) at 236,60,-2780`
    `2026-11-17T23:17:40.708Z  node_223#177   WARN   [node_223][WARN] Still waiting 852s — ATC: return from holding slot 1 waiting to be let in (busy at ARR) at 230,60,-2780`
    `2026-11-17T23:18:10.708Z  node_223#178   WARN   [node_223][WARN] Still waiting 882s — ATC: return from holding slot 1 waiting to be let in (busy at R1) at 230,60,-2780`

## Jams

1 jam(s), 0 never cleared (rule: 3 or more stuck at once inside world.BASE_AREAS; evidence: 10 stuck episodes in the base).
Detector control: G:/TurtleOS-Sandbox/run/20261103-181857-w3_atc_base150-1 -- W3's 150-turtle simulator boot rush on code without the ATC (rev 4fb6b50): 1 jam(s), 1 uncleared, 126 stuck turtles.

- from run 1:08, cleared at 1:09 after 1 min, peak 3: node_218 node_219 node_223

## Jobs completed by type

Evidence: 22986 fleet log lines.

| type | completed |
|---|---|
| DELIVER | 56 |
| MINE | 1 |
| SUPPORT_FOLLOW | 49 |

Long-running sites (feeder.LONG_SITES lanes, from /state jobs' zoneKey):

| site | jobs | open h | snapshots |
|---|---|---|---|
| long1 | 8 | 3.0 | 177 |
| long2 | 0 | 0.0 | 0 |
| long3 | 0 | 0.0 | 0 |

## Faults fired by type

Evidence: 19 fault-log lines.

| fault | planned | begun | failed | undone | ended | latest begin (s late) |
|---|---|---|---|---|---|---|
| atc_crash | 1 | 1 | 0 | 0 | 1 | 4 |
| radio_latency | 2 | 2 | 0 | 0 | 0 | 13 |
| radio_loss | 3 | 3 | 0 | 0 | 0 | 12 |
| server_crash | 1 | 1 | 0 | 0 | 1 | 1 |
| world_restart | 1 | 1 | 0 | 0 | 0 | 7 |

## Decommissioned turtles and why

0 decommissioned, 0 lost, of 20 judged.

## Expected hands

0 turtle(s): an item was taken by a remove_item fault and it asked for hands (counted apart from decommissioned). Evidence: 0 remove_item fault window(s), 20 turtles judged.

## First 6 h against last 6 h

The run is 3.0 h: no separate first and last 6 h, every hour shown.

| hour | log lines | snapshots | jobs done | sectors | stuck onsets | jams begun | faults fired | unseen min | note |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 7183 | 58 | 36 | 0 | 2 | 0 | 2 | 0 |  |
| 1 | 6930 | 59 | 30 | 0 | 6 | 1 | 3 | 0 |  |
| 2 | 7474 | 60 | 40 | 0 | 2 | 0 | 3 | 0 |  |
| 3 | 5 | 0 | TRUNCATED | TRUNCATED | TRUNCATED | TRUNCATED | 0 | 0 | TRUNCATED: no fresh /state snapshot in this hour |

Judged (fails if it grows steadily):

- disk_used: **TRUNCATED** (evidence: 147 samples) -- a run of 3.0 h has no separate first and last 6 h
- lua_memory: **TRUNCATED** (evidence: 0 samples) -- no computer publishes its Lua memory in /state: no source, so it cannot be judged (TRUNCATED)
- queue: **TRUNCATED** (evidence: 147 samples) -- a run of 3.0 h has no separate first and last 6 h
- recovery_ms: **TRUNCATED** (evidence: 10 samples) -- a run of 3.0 h has no separate first and last 6 h

## Housekeeping

35 HOUSEKEEPING lines: clear-delivery-spot 30, storage-headroom-ok 5. 0 storage-headroom-low (a FINDING unless inside a scheduled storage fault); 0 unknown readings (TRUNCATED).

## EXPECTED (board cards open at run time)

None matched.

## Draft board cards

3 card(s), each with its replay seed and schedule.

### Timer-cleared waits: 3 x atc_sweep_live

- Replay: seed 1, schedule G:/TurtleOS-Sandbox/testserver\runs\shakeout-side-h\schedule.json; at run 0:43
- Faults within 30 min before: s001 server_crash, s002 radio_loss
- Why: a wait that only a last-line timer ended (the user, 2026-11-17: a FAILURE, not a recovery)
- Turtles (3): node_215 node_219 node_225
    `2026-11-17T21:27:15.245Z  atc#148        -      [ATC] node_215 silent 180s: booking dropped, including DH it had entered`
    `2026-11-17T21:27:20.645Z  atc#149        -      [ATC] node_219 silent 180s: booking dropped, including W1 DH it had entered`
    `2026-11-17T22:47:22.409Z  atc#80         -      [ATC] node_225 silent 182s: booking dropped, including W1 DH it had entered`

### Timer-cleared waits: 1 x blocked_give_up

- Replay: seed 1, schedule G:/TurtleOS-Sandbox/testserver\runs\shakeout-side-h\schedule.json; at run 0:28
- Faults within 30 min before: s001 server_crash
- Why: a wait that only a last-line timer ended (the user, 2026-11-17: a FAILURE, not a recovery)
- Turtles (1): node_221
    `2026-11-17T21:12:08.850Z  node_221#87    WARN   [node_221][WARN] Gave up after 120s blocked by a turtle moving down at 226,61,-2783`

### Timer-cleared waits: 1 x no_holding_slot

- Replay: seed 1, schedule G:/TurtleOS-Sandbox/testserver\runs\shakeout-side-h\schedule.json; at run 1:02
- Faults within 30 min before: s002 radio_loss, s003 atc_crash
- Why: a wait that only a last-line timer ended (the user, 2026-11-17: a FAILURE, not a recovery)
- Turtles (1): node_217
    `2026-11-17T21:45:52.797Z  node_217#163   WARN   [node_217][WARN] Cannot dig and the way home is shut (no holding slot of mine in 120 s) -- retracing the 192 step(s) I came by`


## Evidence and gaps

0 fleet-log gap(s) over 5 min, 0 /state gap(s) over 5 min: every count over a gap is TRUNCATED (a lower bound), never zero; the stuck and gone clocks do not run over a /state gap.
