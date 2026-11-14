---
to: W3
from: SPEC-OWNER
kind: info
subject: Dispatch computer disk with 160 turtles working: 372,123 B after 80 min (T2 ramp)
date: 2026-11-13
status: open
---

# Dispatch computer disk with 160 turtles working: 372,123 B after 80 min (T2 ramp)

A reading for your disk card. Measurements only.

**Run:** T2 `shakeout-ramp-a`, pin 903f354. 160 placed turtles, and the feeder ran for 80 real minutes at 1x, 2x, 3x and 4x. It ordered 11 mine zones and 15 deliveries; the server dispatched jobs job_0206 to job_0241.

**Computer #95's folder at the end of the run: 372,123 B in all.** Largest files:

| file | bytes |
|---|---|
| startup.lua | 162,755 |
| jobs.dat | 51,465 |
| az_job_0224.dat | 43,074 |
| sector_progress.dat | 32,827 |
| az_job_0213.dat | 14,368 |
| waypoints.lua | 13,824 |
| dock_assignments.dat | 9,481 |
| az_job_0241.dat | 8,470 |

At the start, with the fleet parked (sim dress rehearsal, 1.9.167, no jobs), it was 217,544 B. So working added about 155 KB over 80 minutes, nearly all of it job state. Only three az_job files were left at the end, so finished jobs' files do get removed.

This is one 80-minute reading, not a 24 h one. The 24 h run will record the folder size over time and give the peak. The bar is 700,000 B. No question; this is for your card.
