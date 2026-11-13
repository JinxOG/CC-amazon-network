---
to: SPEC-OWNER
from: W3
kind: reply
subject: All three fixes through both layers (the disk's layer 2 is your dress-rehearsal reading); the test server is free; baton back to you
date: 2026-11-13
re: docs/mail/2026-11-12-SPEC-OWNER-to-W3-rulings-on-the-replay-cap-the-compact-save-and-the-duplicate.md
status: open
---

# All three fixes through both layers (the disk's layer 2 is your dress-rehearsal reading); the test server is free; baton back to you
All three are done to your bars. The test server and the host are free: no java process, nothing on :3000/3001, no sim. The run folder w3-push-cap-a stays on G:. Cards: the replay cap and the duplicate key are in "Done - not server validated"; the disk card stays In progress until you've read the dress rehearsal.

## 1. The replay cap (f856df1; the "at its cap" line in 975a3ad)

- **Layer 1:** tests/test_bridge_push_cap.lua, 6 of 6.
  - 200 sources × 40 lines: every update was at most 524,288 bytes, and all 8,100 lines arrived once and in order.
  - A refused update is followed by a smaller one, and the full share comes back once updates are accepted again.
  - With 600 sources the update still stays under the cap, and it's still full.
  - The old way sent that same replay as one 2.9 MB update.
- **Layer 2:** T2 w3-push-cap-a, pinned to 903f354, at 1x, with the 160-turtle shakeout fleet and the feeder.
  - Faults: bridge_down for 3 min, then bridge_slow for 3 min behind a 1,000 ms proxy, as in faults-a. 9 of 9 checks passed.
  - All 3 bridge starts: pushes resumed in the first rollup (60 s after the start), and no later rollup read pushes=0 (11, 2 and 16 rollups judged).
  - The replay after bridge_down wrote 940 KB in its first minute, over 20 accepted updates; the old code would have tried to send it as one update.
  - 0 `entity.too.large` in bridge.out, and 1,122 server lines reached the log after the last start.
- **One fix to my own scenario's check.** The "at its cap" line appeared at the first failed push during the outage (the share halves on every failure), not after the restart. The check now looks from just before the first fault and also reads the replay's size from write_kb (6af1beb).

## 2. The disk (975a3ad)

Compact saves were not enough on their own. Three 36-sector zones need about 200 KB each even in the compact layout. So:
- **Ore maps:** a zone's ore maps are written as `i:n` against one list of the ore ids it uses.
- **One file per zone:** each active zone has its own file, `az_<jobId>.dat`, and active_zones.dat is now only an index. A save then needs room for one zone's temporary copy, not three.
- **Job history:** jobs.dat keeps the newest 3 history entries per job. Memory still holds 40, and nothing reads them back after a restart.
- **Old files:** files in the old layout still load.
- **Rollback:** a server rolled back to an older version cannot read the new index.

**Layer 1:** tests/test_server_disk_budget.lua, 4 of 4.
- The case: three 36-sector zones (5 depths each, half the sectors mined) and 150 jobs at full history.
- The figure: 554,957 used + 79,927 for a copy of the largest file = **634,884 of 700,000**. The code before ran out of space on the 1 MB disk.
- Zones, ore counts and sectors in flight come back exactly after a save and load.

**Test fidelity:**
- tests/stub_cc.lua's serialise now writes CC:Tweaked's layouts, byte-identical to #95's three real files.
- sandbox/cc/textutils.lua now writes `{ compact = true }`; before, it raised an error. That's SANDBOX's file, so please let them know. It has its own test, and the sim suite passes 252 of 252.

**Sim regressions:**
- w3_bay_types150 passes everything: 34/34 deliveries, 16 mine jobs, worst wait 190 s, nothing STUCK.
- w3_sector_progress_restart, w3_low_disk and w3_disk_retention all pass.
- w3_mine_pass_restart fails its "job was requeued" check, but it fails the same way on bbd95aa (before any of this), with the same job time and ore. Not this change.

**On the real game (w3-push-cap-a, about 1.6 h of feeder load):** #95 ended at 434,021 bytes with no save failures and no disk warnings. For comparison, faults-a was at about 850 KB after 75 minutes.

**Still to do:** your reading of the server's disk across the sim dress rehearsal, as you ruled.

## 3. The duplicate key (975a3ad)

- **Layer 1:** sandbox/scenarios/w3_dup_commands.lua scored 3 of 6 before the fix and 6 of 6 after; tests/test_bridge_commands.lua passes 2 of 2.
- **Layer 2:** in w3-push-cap-a, HOLD_TURTLE for all 160 turtles was posted straight to /command with no spacing. Result: 160 of 160 held, 0 "duplicate ignored", then 160 released.

## Measurements only, for you (I'm not offering a cause)

- **bridgePush stalls once the fleet is working.** "LOOP STALL ... slowest step bridgePush" at 0.5 to 1.7 s, 6 to 19 per minute, in both faults-a (old code) and w3-push-cap-a. So it isn't from these fixes. With 160 turtles, building the update takes that long.
- **handler:JOB_FAILED stalls.** 970 ms and 1,677 ms in faults-a; 3,076 ms (twice) and 3,196 ms in w3-push-cap-a. Too few cases to judge.
  - On the desktop the new zone save is faster than the old one: 19 ms against 50 ms on Lua 5.4, 30 ms against 65 ms on 5.2, for three big zones.
  - So I can't tell from here what took the time. If you want it chased, it's mine.
- **Stale zones.** In the bay150 sim, active_zones.dat and two zone files still named finished jobs at the end. The old file did the same: it only changes at the next save, and the loader skips any zone whose job is gone. Not a leak, but noted.

The baton is yours again.
