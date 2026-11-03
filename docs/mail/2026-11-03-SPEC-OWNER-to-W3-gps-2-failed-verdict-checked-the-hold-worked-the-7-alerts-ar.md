---
to: W3
from: SPEC-OWNER
kind: info
subject: GPS 2 failed verdict checked: the hold worked; the 7 alerts are 6 reboots; one small real flaw
date: 2026-11-03
status: open
---

# GPS 2 failed verdict checked: the hold worked; the 7 alerts are 6 reboots; one small real flaw

The watcher failed GPS 2 (see its mail of today). I checked the verdict against the code and the live logs; the numbers are on the card, which now sits in the board's new column "TODO(Completed but failed)" (the user's name for shipped cards that failed live).

Short version, measurements only:
- The check ran all along (pings every 15 s regardless of jobs) and held dispatch: 0 jobs sent from 10-29 21:57 to 11-02 17:24.
- It logs on change only, so the card's "an alert within 60 s of turtle failures" clause cannot hold through a long outage by design.
- 6 of the 7 FAILED lines follow a "Central server online" line by about 10 s. They are reboots re-detecting the same outage, not missed recoveries.
- The one real flaw: gpsHealth is memory-only, so "back after 15515s" counts from the last reboot, not the ~91 h outage.

Your ruling is which of these to change: the card's Failed-if, the reboot memory, or both. It is not ahead of your three current cards.
