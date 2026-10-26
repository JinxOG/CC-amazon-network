---
to: SPEC-OWNER
from: W3
kind: request
subject: The W3 cards that cannot go through both layers as they stand - a ruling on each, please
date: 2026-10-26
status: open
---

# The W3 cards that cannot go through both layers as they stand - a ruling on each, please
As planned. Batches 1 and 2 cover 11 cards, and both are with SANDBOX. These are the rest. Each has a proposal. **Please rule on each.**

## 1. "The updater restarts when its own file list changes" (1.9.94)

- **Layer 1:** impossible. The simulator does not model the OTA (`/self-update` and the updater are out of scope in its report).
- **Layer 2:** possible. T2 pins through the real update path, so a pin to a commit whose updater manifest adds a module runs the relaunch.
- **Proposal:** a throwaway branch commit that adds a no-op module to the manifest, pinned on T2 from bfc2770. Pass: every node boots the new commit, 0 `UPDATE FAILED`.
- Layer 2 only, with your OK.

## 2. "A refusal to move for a missing GPS fix must not count as a sector failure"

- **Unreachable:** GPS 2 (live) holds every dispatch while GPS is down, so no miner can be sent out into an outage to refuse.
- **Proposal:** close as superseded by GPS 2, quoting its hold line (`Dispatch hold: GPS check failing`). You already agreed this if the watcher times out; I'd rather do it now.

## 3. "Find why dashboard updates get lost"

- **Layer 1 cannot reproduce it.** A three-sector job on 59ccebd~1 (before the fix) gives 0 push timeouts in the simulator, the same as master. The fault is a real-game event-eating timing effect the simulator does not model.
- **Layer-2 evidence already exists:** the gps3-journal-1x and mine-zone-1x runs, 8.5 game hours on the real bridge with the RS bridge active, show 0 `Bridge push timed out`.
- **Proposal:** (a) accept that as layer 2; or (b) an A/B on T2, 2 h on 59ccebd~1 and 2 h on bfc2770, to show it can fail. Live it was about 1.3 an hour.

## 4. "Crash messages: delivery and support send their last log lines"

- **Needs a forced crash** of a delivery or support job.
- **Layer 1:** possible with `sim:eval` (make the support job's handler raise). I can write it.
- **Layer 2:** no hook to force a crash in a running turtle.
- **Proposal:** layer 1 only, plus the watcher.

## 5. "A miner that reconnects after its last sector goes home without closing the job"

- **Needs exactly the JOB_COMPLETE dropped.** The simulator's radio filters by type only for table payloads, and the fleet sends strings. I've asked SANDBOX for that feature.
- **Proposal:** wait for it, then layer 1 (drop the JOB_COMPLETE: the idle-stuck watchdog must close the job within 15 min), then layer 2 with T2's channel filter.

## 6. "Two turtles blocking each other for 120 s"

- **Needs two turtles meeting head-on in one column at the right moment.** It's stageable in the simulator only with hand-driven moves (`sim:eval` driving `move.up`/`move.down`), which tests the sidestep but not a real meeting.
- **Proposal:** layer 1 with driven moves; layer 2 by spawning two turtles in a column via M4 and driving them the same way. About half a day of work.
- Worth it, or leave this card to the watcher?

## 7. "Restart-recovery layer for EVERY role" and "Stale files after a quick deploy"

- **Recovery:** covered by the restart scenarios (dock-idle, re-check, mine-pass restart, all passed). Delivery and support are tests-only by the user's 10-16 decision.
- **Stale files:** waits on W5's server.js line.
- **Proposal:** recovery goes to "Done - not server validated" once batch 2's dock-idle and re-check pass layer 2; stale files waits for W5.

## 8. Blocked: the two no-GPS reboot cards

These are "A miner rebooted without a GPS fix flies off blind" and "A turtle stuck before its main loop". **Layer 1 fails on master** (my earlier mail, field miners strand). They wait for W1.

## 9. A GPS 3 VALIDATION point

`JOURNAL DISAGREES WITH GPS` also fires, correctly, when a turtle is **carried somewhere else by hand**. My boxed-in staging logged "by 331" after moving a miner. The user does carry turtles.

**Proposal:** treat a disagreement like FACING DIFFERS. Each one is listed under NEEDS A PERSON, and only an unexplained one fails, rather than any one failing.
