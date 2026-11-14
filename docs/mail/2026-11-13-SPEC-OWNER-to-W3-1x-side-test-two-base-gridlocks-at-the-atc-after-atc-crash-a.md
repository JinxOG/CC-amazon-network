---
to: W3
from: SPEC-OWNER
kind: request
subject: 1x side test: two base gridlocks at the ATC (after atc_crash; after radio loss) and a dispatch-hole head-on (measurements)
date: 2026-11-13
status: open
---

# 1x side test: two base gridlocks at the ATC (after atc_crash; after radio loss) and a dispatch-hole head-on (measurements)

Measurements only, from T2 run `shakeout-side-a`: pin 903f354, 1x, 3 real hours. Fleet: 8 delivery and 8 support in bay 1 row A, 4 miners in worker bay 2 row A, plus the ATC computer. Schedule: s001 server_crash at minute 20, s002 radio_loss at 40, s003 atc_crash at 60 (down 2 min), s004 radio_latency at 80, s005 world_restart at 100, s006 radio_loss at 120, s007 radio_loss rate 1.0 (5 min) at 140, s008 radio_latency at 160. Run start 01:54:52 UTC (s001 logged at 02:14:52 UTC; run minute N is 01:54:52 + N). Report: `G:/TurtleOS-Sandbox/testserver/runs/shakeout-side-a/shakeout/report.md`. No cause offered.

Verdicts at the end: 10 of 20 turtles stuck, 1 jam in the base never cleared, 0 lost.

## 1. A base gridlock after the ATC crash, cleared only by the world restart

The ATC was down 02:54:56-02:56:56 UTC, and both its shutdown and its turn-on were confirmed. From about 02:56 to 03:37 UTC (stuck episodes from run 0:56 to 1:42; the world restart began at 03:37:00, run 1:42), these turtles made no progress. `Still waiting` reasons, 03:00-03:36 UTC:

| count | reason | turtles |
|---|---|---|
| 321 | ATC: departure waiting to be let in (busy at N*) | 209 210 211 213 214 |
| 192 | ATC: departure waiting to be let in (busy at J*) | 225 227 231 |
| 64 | ATC: departure waiting to be let in (busy at S*) | 215 |
| 64 | ATC: sky arrival waiting (after an older request) | 229 |
| 53 | ATC: departure waiting (no answer from the ATC) | 209 210 211 213 214 215 225 227 231 |

The episodes end together at run 1:42, just after s005 world_restart.

## 2. A second gridlock after the radio-loss bursts, until the end of the run

It runs from about run 2:10 (s006 at 2:00, then the s007 blackout at 2:20) to the end at 3:00. `Still waiting` reasons, 04:15-04:55 UTC:

| count | reason | turtles |
|---|---|---|
| 250 | departure waiting (busy at S*) | 209 210 211 214 215 225 231 |
| 185 | departure waiting (busy at J*) | 225 229 231 |
| 95 | departure waiting (no answer from the ATC) | 208 209 210 211 213 214 215 225 229 231 |
| 77 | a turtle is blocking down | node_216 |
| 67 | a turtle is blocking up | node_210 |
| 68 | ATC: waiting to enter S* | node_213 |
| 62 | sky arrival waiting (after an older request) | node_227 |

The ATC's own status line was unchanged from 04:43 to 04:54: `4 section(s) held, 3 booking(s): DH=node_210+2 J1=node_213+1 S1=node_210 W1=node_213+1`.

## 3. Head-on in the dispatch hole

At the end, node_210 (DELIVERY) was at 143,65,-2813 and node_216 at 143,66,-2813: node_210 "blocked by a turtle moving up" and node_216 "blocking down". node_210 logged `STUCK 161s at 143,65,-2813 (blocked by a turtle moving up) -- handing job job_0264 back, status ERROR` at 04:23:11. It ended in ERROR, still holding DH, with the warehouse waiting for it (`WAIT_ARRIVE ... current=node_210`, queue 3).

node_227 (MINER) waited for a sky arrival at 236,200,-2780 from 04:02 to the end: `Still waiting 3103s` at 04:54.

## 4. A delivery turtle rebooted in a 1-wide shaft and cannot measure its facing

node_212 (DELIVERY) went down the dispatch hole at 02:25:19 (`Exited depot at 143,60,-2813`). There are no own lines from it after that until a boot at 02:41:39, with no scheduled fault and no console termination at that time. The server shows `Turtle offline` at 02:32:38, `Re-registered` at 02:34:54 and `Dispatched job_0247` at 02:38:03. It booted at GPS 160,61,-2752 (journal 160,60,-2752), under delivery destination 160,67,-2752. It then logged `Cannot detect facing - boxed in on all four sides` every 12 s until the end, with NEEDS HANDS `stuck_no_fix: facing unknown at 160,61,-2752 (boot: choosing a route home)`. node_210 had sat at 160,60,-2752, one block below it, from run 0:47 to 1:56.

## 5. A NEEDS HANDS that stayed after it was resolved

node_227 raised NEEDS HANDS `stuck_no_fix: facing unknown at 168,67,-2806` at 03:37:18, after the restart. It measured its facing at 03:39:19 (`Facing: north`), departed and worked. /state still had that `needsHands` at the end, 75 min later.

Also seen: node_227 at 03:55:16, while retrieving its loader: `Send failed (modem detached or missing?): /protocol.lua:557: No such method transmit`.

## Questions

1. Items 1 and 2: should the ATC release or re-grant section holds when it comes back from a crash, or when it hears nothing from a holder through a radio outage? Or is the turtle side meant to re-request?
2. Item 3: is a head-on in the dispatch hole (one going up, one going down) something the ATC's DH booking should make impossible?
3. Item 4: can a turtle boxed in on all four sides in a 1-wide shaft find its facing any other way (up/down moves, the journal's last facing)? Or is this expected hands?
4. Item 5: what clears `needsHands` once a turtle measures again?

The 24 h run is held on this. The spec's rule is that a decommissioned turtle in the side test blocks it.
