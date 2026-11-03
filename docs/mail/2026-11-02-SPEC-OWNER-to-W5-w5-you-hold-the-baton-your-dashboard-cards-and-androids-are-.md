---
to: W5
from: SPEC-OWNER
kind: ruling
subject: W5, you hold the baton - your dashboard cards, and androids are on hold not retired
date: 2026-11-02
status: open
---

# W5, you hold the baton - your dashboard cards, and androids are on hold not retired

**W5 (Bridge & Dashboard), code side.** The user hands you the baton as of 2026-11-02. W1's queue is empty.

## Work these cards, the lean way (see `docs/mail/BATON.md`)
- Sort the log viewer by time
- Match the dashboard service file to what is actually running
- In-world admin screen: job page goes stale after channel step 2 (accepted cost) -- confirm it is still an accepted cost, close or keep
- Show the log loss rate on the dashboard (Needs measuring)
- Warehouse storage snapshot goes straight to the dashboard (Needs measuring)

Skip "DEFERRED: admin computer sends no logs" (after the cleanup).

For each card you alone do the following, with no relaying and no progress mail:
1. write the test;
2. prove it at layer 1, failing on the old code and passing on the new;
3. run layer 2 yourself where the card touches the fleet;
4. write the VALIDATION block and move the card to "Done - not server validated".

Do not deploy to the live fleet or the live bridge; the user's ban since 2026-10-28 still stands. Mail me only for a ruling or a question that only another engineer can answer.

## Androids: STOP any trimming
The user is building a refresh of the CC Androids mod. Androids are coming back as guards, drivers, turtle rescue and builders. **Do not remove, trim or change any android file (`android_*.lua`) or android dashboard entry**, and do not commit any such change you have in progress. The "Stop the dashboard offering the retired Android files" card is now on the back burner. Nothing gets built for androids until the refresh ships and the user says go.

## Check whether these are yours
The main checkout has these uncommitted:
- a modified `server.js`;
- a new `tests/bridge/test_bridge_update.js`;
- an untracked `dash.bundle`.

If they are yours, finish them inside a card or tell me. Don't leave them lying in the main checkout.
