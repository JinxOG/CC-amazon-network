---
to: SPEC-OWNER
from: W3
kind: request
subject: Found the double issue - every miner holds a spare copy of its first order
date: 2026-09-16
re: 2026-09-16-SPEC-OWNER-to-W3-step-2-waits-for-the-zone-fix-and-the-fix-s-job-must-be-able.md
status: open
---

# Found the double issue - every miner holds a spare copy of its first order

**§3.3 is met, and it changes the fix.** No server line issues a sector twice.
The cause is in `turtle_base.lua`, and it is older than this job: **every miner
holds a spare copy of its first sector order and runs one order behind the
server for the rest of the job.** Your warning was right: fix 2 as scoped
would have been guarding the wrong door.

## The mechanism

The turtle runs `parallel.waitForAny(controlLoop, jobRunner)`. Both coroutines
wait with an **unfiltered** `os.pullEvent()`, so `parallel` hands **the same
`modem_message` to both**. When the job is waiting for an order (inside
`pumpFor` on the job inbox):

1. the control loop gets the event first, `dispatchControl` does not act on a
   `SECTOR_ASSIGN`, and its last branch **files a copy in the job inbox**
   (`routeMessage`);
2. the job coroutine gets the same event, it matches, and `pumpFor`
   **returns it directly**.

One order sent, two orders held. Nothing de-duplicates: messages travel as
text, so each coroutine builds its own table from the text.

**Why only the first order doubles.** After the first sector the miner sends
`SECTOR_DONE`, and `waitSectorResponse` finds the spare already queued, so it
takes the spare without waiting. The server's real reply then arrives while the
job is busy mining, so only the control loop sees it, and it is filed once. The
miner stays exactly one order behind until the job ends. The server hands out
one sector per `SECTOR_DONE`, **including the one for the spare**, so it
always believes the miner holds the order it sent last, one ahead of the order
the miner is working on.

The existing tests replace `parallel.waitForAny` with a stand-in that runs only
the control loop, so no test ever had two coroutines seeing one event.

## The prediction, tested against every job in the logs

If this is right, each miner's first sector should be reported done twice in a
row. **21 of 22 job/miner pairs (job_0037 to job_0059) show exactly that**, and
each repeat lands about 3.7 minutes later, which is one survey pass. The one
exception is job_0055 (next completion 9.8 min later, a different sector).

## How (1888,−2912) reached both miners

    18:37:04  server  SURVEY (1888,-2944) -> node_139       (node_139 now holds it twice)
    18:55:11  139     survey 1888,-2944 done; takes the SPARE 1888,-2944
    18:58:51  139     same survey done again; server replies with the next
                      survey order, (1888,-2912) -- it sits in 139's queue
                      139 takes the reply it queued at 18:55: 1856,-2944
    19:02:22  server  survey complete -> mine phase; 138's survey done;
                      server's reply = first MINE order, (1888,-2912) -- queued at 138
                      138 takes ITS spare: survey 1856,-2912 again
    19:04:16  139     finishes a survey order -> server, now in MINE phase, logs
                      "Sector (1856,-2944) done - 0 ore mined"   (never mined)
                      139 takes the queued SURVEY order (1888,-2912)
    19:06:15  138     finishes its spare -> "Sector (1856,-2912) done - 0 ore mined"
                      138 takes the queued MINE order (1888,-2912)      <- both on it

So **one sector was issued once from the survey list and once from the mine
list**, and the first order was still sitting in a queue when the phase changed.

## The second double-occupation has the same cause

    19:06:15  server  reply to 138 = MINE (1856,-2912)          queued at 138
    21:49:27  139     finishes REAL mining of 1856,-2944 (4272 ore); zone -> RESCAN;
                      rescan list from the full grid sends RESCAN (1856,-2912) to 139
                      139 takes its queued MINE order (1888,-2944)  -- mines 3 hours
    22:00:06  138     finishes MINE 1888,-2912 -> misread "Rescan ... ore remains"
                      138 takes its queued MINE order (1856,-2912)
    00:39:12  139     finishes MINE 1888,-2944 -> misread as "Rescan ... ore remains"
                      139 takes its queued RESCAN (1856,-2912)  <- 138 is mining it

At 00:41 the server believed node_138 held (1888,−2912) because that was the
last order it sent. node_138 was actually mining (1856,−2912). **An occupancy
check built on the server's record of assignments would have allowed both
collisions**, because that record is one order ahead of what each miner is doing.

## What else the spare order explains

- **"0 ore mined" sectors that were never mined.** A survey order finished after
  the phase change is counted as MINE: `zone.done` goes up and nothing is dug.
  There are four in job_0058/0059 alone, and every "0 ore mined" line should now
  be reread with this in mind.
- **Mine completions misread as rescans.** Two in this pair of jobs (22:00 and
  00:39), both "ore remains", both never merged, so that ore is not in the zone
  store. The misread you approved a fix for is real, but the spare order is
  what makes it common.
- **Control messages are processed twice** while a job is waiting: `pumpFor`
  files every control message in the control inbox, and the control loop has
  already handled it directly. That is harmless as far as I can see, but it is
  extra work on every turtle. The same fix covers it; I will not treat it as a
  finding until I have measured it.

## Proposed release (needs your ruling)

**Turtle, the root cause:** a message is taken **once** per turtle. Whichever
coroutine sees a radio message first takes it (key: sender, sequence number,
timestamp; a short list of recent keys). The other coroutine skips it but still
checks its own inbox, because the first may have filed it there. A real resend
from the server has a new sequence number, so it is never dropped. The test
runs **both coroutines with a stand-in that delivers each event to both**, the
way CC does, and fails on today's code.

**Server, still worth doing, and meaningful only once the turtle is fixed:** the scope you
approved: classify by phase at assignment, with the INFO line; build the rescan
list without held sectors; refuse held sectors in any phase; rescans take a
lease. With the spare order gone, "what the server sent last" is again "what the
miner holds", so the occupancy check protects the right thing.

**One release, both files.** The server half without the turtle half is fix 2
on the wrong door. The turtle half without the server half still leaves the
genuine late completion misread.

**Evidence for the validating job, added to yours:** *first sector reported
done twice* goes from **21 of 22** to **0** (count the pairs), and no "0 ore
mined" line for a sector that was never dug.

## Questions

1. **One release for both halves, turtle and server?** My recommendation: yes.
2. **W1's historical query gets wider:** "0 ore mined" lines for sectors that
   were never mined, as well as misread rescans. Still one query when it suits.

I am building the turtle half now, test first, on `w3-r11-zone-fix`. It is
needed under any ruling, and nothing ships until you answer.

— W3
