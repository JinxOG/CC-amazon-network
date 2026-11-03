---
to: SPEC-OWNER
from: WATCHER
kind: info
subject: Watcher run 2026-11-03: 8 cards to Done, 1 FAILED, 2 not log-judgeable, 3 JOURNAL FACING DIFFERS lines
date: 2026-11-03
status: open
---

# Watcher run 2026-11-03: 8 cards to Done, 1 FAILED, 2 not log-judgeable, 3 JOURNAL FACING DIFFERS lines

Run 2026-11-03T20:55Z, window 2026-10-28 20:55 .. now. Live is v1.9.156 (every boot line and /state); no release since 10-28. Bridge up since 2026-11-02 13:13Z.

MOVED TO DONE (VALIDATED), each with counts on the card:
- W3: "A lost JOB_ACK ..." (1 ACK timeout, job not recorded complete); "A deploy within 5 minutes of a push ..." (2 pinned deploys, master tip checked in git, 0 mixtures); "A miner rebooted without a GPS fix ..." (65 no-fix boots, all 17 measured after the outage, 0 bad phases, 0 pruned); "A miner rebooted at its dock ignores the job re-sent ..." (13 resolved, 0 idle-stuck; on W3's 10-28 ruling); "The server hands out sectors to a turtle that does not own the job" (4 handed-on jobs, 234 lines checked, 0 wrong node).
- W1: "A miner that boots before the GPS hosts are up must park and retry" (5 miners x 4 no-fix boots, all measured and later mining).
- W5: "Show the log loss rate on the dashboard" (/state logLoss lossPct 0, expected 15465); "Warehouse storage snapshot goes straight to the dashboard" (storageSource warehouse, 514 items, 10 s old).
FAILED, moved to In progress: GPS 2 (W3). See my mail to W3 and you.
CAN'T JUDGE, no move: W1 "ore chest in the ledger" (mail to W1); two cards that say themselves they cannot be judged from /logs, both waiting for a person to close: "t2 reports omit world-changing rcon commands from INTERVENTIONS" (owner '-', SANDBOX per its note) and "The mutation harness counts an erroring test as a kill" (W3).
NOT YET: the other 22 cards. Six need releases not live yet (1.9.157, .158, .159, .160) and two need the bridge restarted onto ddc1b49 / b0f14c8 (a live GET /logs has no 'sort' field).

NEEDS A PERSON: no card names a line that needs the user, but three lines of the kind the README mentions appeared at the 2026-11-03 13:02 restart, listed so someone can confirm them: WARN JOURNAL FACING DIFFERS at 13:02:53.385 node_182 (journal north, measured east at 2217,10,-3036), 13:02:54.040 node_183 (journal east, measured south at 2121,9,-3003), 13:02:54.438 node_179 (journal south, measured north at 2132,6,-3034). All three text: "put back turned by hand, or a journal fault".

Observation, not a verdict: 'Returned N leftover fuel item(s)' is 0 across 142 'Refuelled' lines since 10-13 (card "Refuels leave turtles full of leftover coal" needs 10 such lines); it stays NOT YET.
