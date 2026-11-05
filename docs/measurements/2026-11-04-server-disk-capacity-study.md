# Server disk capacity study (W3 disk card, the user's request 2026-11-02)

The question was whether the dispatch computer works on CC's **default 1,000,000-byte disk**:

- (a) with 150 turtles and several mining and delivery jobs at once, for a simulated week;
- (b) what a 10,000,000-byte disk buys;
- (c) the bytes per turtle and per job for every file that grows.

Every number below comes from the simulator. None is an estimate.

## The run

`sandbox/scenarios/w3_capacity_week_1mb.lua` (shared body `_w3_capacity.lua`), **run `20261105-003514-w3_capacity_week_1mb-1`, 168.1 simulated hours**, on master at 4392dcb and later:

- **Fleet:** 150 turtles (8 miners with their loaders, 71 delivery, 71 support), under the base air-traffic control computer, with the docks the server already knows.
- **Code:** the fleet's code as it ships, stripped by the installer.
- **Mining:** four zones mining at once, two miners each. A finished zone is replaced by the next.
- **Deliveries:** a delivery every 30 minutes, to four destinations in turn.
- **Restarts:** the server restarts once a simulated day, as the live one does.
- **Measurements:** every simulated hour the size of every file on the server's disk is written to `capacity.csv`.

In the week:

- 335 deliveries were dispatched and all 335 were completed by the warehouse;
- there were 330 mining dispatches, and 996 jobs completed in all;
- the server restarted 8 times;
- the low-disk warning never fired, no turtle's return failed, and none reported STUCK;
- the simulator's memory held flat between 1.8 and 2.15 GB.

It took three attempts to get a clean week. Each failed attempt found a real fleet bug, now fixed. Both are on the board.

- **20261104-033236 stopped at hour 145** (my own memory guard). The warehouse kept every heartbeat of every turtle in its inbox, about 70 MB a simulated hour (fixed in abe3e62).
- **20261104-183352 jammed from hour ~49.** A delivery pair split at the dispatch hole, and the stranded support blocked the departure tunnel (fixed in 4392dcb). By hour 113, 124 deliveries were waiting. That gave the measured backlog cost in (c).

The 145-hour run's disk numbers agree with the clean week: lowest free 765,457 bytes, peak used 234,543.

## (a) 1 MB at 150 turtles: it works, with room to spare

| | bytes |
|---|---|
| Disk | 1,000,000 |
| Lowest free, all 168 hours | **765,458** (hour 1) |
| Free at the end | 792,226 |
| Peak used | 234,542 |
| Code: startup.lua (the server, stripped) | 152,726 |
| Code: waypoints, protocol, updater, install, cloudstore, logship | 42,229 |
| State at its peak: jobs.dat 26,189 + active_zones.dat 7,801 + dock_assignments.dat 2,861 + sector_progress.dat 2,857 + small files | ~39,800 |

**Nothing grows with time.** jobs.dat swung between 2 KB and 26 KB every hour of the week, with no upward trend. The server saves only jobs that are still PENDING, ASSIGNED or IN_PROGRESS (`saveJobs`), so a finished job leaves the file at the next save. active_zones.dat holds the active zones only, about 4.5 KB for four. So the disk depends on **how many jobs are live at once**, not on how long the fleet has run or how many jobs it has done.

**Where 1 MB stops working.** A save writes jobs.tmp beside jobs.dat, so jobs.dat needs room for two copies of itself. With 765 KB free:

- **The low-disk warning** (350 KB free) comes when jobs.dat has grown by about 207 KB. That is about **300 deliveries waiting at once** (measured at 0.65 KB each), or about **25 mining orders** (two miners each) at once.
- **The disk is full** when jobs.dat has grown by about 380 KB. That is about **580 waiting deliveries**, or about **45 mining orders** at once.

In the clean week there were never more than 4 jobs live at once. Even the jammed run, with 124 deliveries waiting, still had 700,788 bytes free. So at this fleet size, 1 MB is limited by a backlog of jobs, never by the fleet itself. The disk-tidy card's warning fires long before the disk is full.

## (b) 10 MB: what it buys

**Same run, same rows.** The same seed on a 10,000,000-byte disk is identical row for row until the smaller disk fills (measured: free differed by exactly 9,000,000 bytes, row for row). The 1 MB disk never filled, so a separate 10 MB week would have repeated it. I stopped that run after its first rows matched.

What 10 MB would allow:

- **Backlog:** about 7,000 waiting deliveries, or about 600 mining orders at once, before the warning (against about 300 and 25 at 1 MB).
- **Job history: impossible at 1 MB, possible at 10 MB.** Finished jobs are not kept at all today. At this run's pace (about 140 finished jobs a simulated day, at roughly 1-1.5 KB each), a history costs about 150-200 KB a day.
  - 1 MB could hold about two days of history, and that only by eating the warning margin.
  - 10 MB holds about 45-60 days.

  That would let the dashboard show past jobs without the cloud store.
- **Room the tidy now takes away:** crash.log beyond 8 KB, and the disk copy of the zone store (`mine_zones.dat`). Both could be kept.
- **Nothing else.** Every file that is live today fits comfortably in 1 MB.

## (c) Cost per turtle and per job, for every file that grows

| File | Grows with | Cost |
|---|---|---|
| dock_assignments.dat | turtles | **~19 B per turtle** (2,861 B for 150). 1 MB would hold over 20,000 turtles' worth. |
| jobs.dat | live jobs | **~0.65 KB per waiting delivery** (measured backlog: 124 waiting took it from ~15.6 KB to 96,535 B, run 20261104-183352 hour 113). **~4-6 KB per mining job** (it holds the sector list): the clean week's median is 15.7 KB for 4 mining orders, about 3.9 KB each, peaking at 6.5 KB. A delivery or support in progress costs more than a waiting one: ~1.6 KB and ~0.9 KB, fitted from the 2026-11-03 run with up to 66 live. |
| jobs.tmp | live jobs | a second jobs.dat for the length of one save |
| active_zones.dat | live zones | **~1.1 KB per active zone** |
| sector_progress.dat | sectors in progress | peak 2,857 B, back to 2 B when the sectors finish (too few live at once here to fit a per-sector cost) |
| Every other file | (nothing) | fixed: code and settings |

## Plainly

**1 MB works for 150 turtles, for a week, with the retention the server already does (only live jobs are saved) and the tidy.**

It stops working only if about 580 deliveries, or about 45 mining orders, are live at the same moment. The low-disk warning comes at about half that.

10 MB buys a large backlog and, for the first time, room to keep a job history. Neither is needed to run the fleet.
