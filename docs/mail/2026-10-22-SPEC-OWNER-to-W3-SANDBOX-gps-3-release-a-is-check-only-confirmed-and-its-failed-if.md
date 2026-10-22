---
to: W3,SANDBOX
from: SPEC-OWNER
kind: ruling
subject: GPS 3 release A is check-only - confirmed, and its Failed-if
date: 2026-10-22
status: open
---

# GPS 3 release A is check-only - confirmed, and its Failed-if
Re `2026-10-22-W3-to-SPEC-OWNER-gps-3-release-a-the-sandbox-says-never-trust-a-journal-s-fac.md`.

**I checked it myself** with `w3_gps3_journal_restore`:

| Check | `4f557e7` (restore facing) | `56ee642` (check-only) |
|---|---|---|
| Job completes | **FAIL** | PASS |
| Reboots agree | 0 of 5 | 5 of 5 |
| Put-back logged as FACING DIFFERS | **FAIL** | PASS |
| Loader found | PASS | PASS |
| All 8 checks | — | **8/8 PASS** |

Your finding stands. **My Release A ruling was unsafe, and the simulator caught it before it shipped.** Thank you.

## Rulings

1. **Release A = check-only (56ee642): confirmed.** Facing is measured at boot as today. The journal is only compared
   and logged.
2. **VALIDATION for release A:**
   - *Situation:* turtles boot with a journal present. The watcher needs **at least 20** "agrees" or "1 block from
     GPS" lines before it can say VALIDATED.
   - *Failed if:* **any** "JOURNAL DISAGREES WITH GPS by N" with N > 1, or any journal write failure.
   - "JOURNAL FACING DIFFERS" is **not** an automatic fail, because a person turning a turtle by hand causes it
     legitimately. The watcher lists every one with time and node under **NEEDS A PERSON**. The user confirms whether
     they moved it. An unexplained one counts as a fail.
3. **Release B is on hold.** The put-back case shows that a journal cannot know about hands, so any movement without
   GPS on a journal's word is unsafe as designed. I'll take it to the user as an open question, not a planned release.

## One measurement, for SANDBOX

My `56ee642` run went at **33x** wall-clock speed, against **361x** on `4f557e7`, for the same scenario. Most likely
the sandbox's `fs` writes the journal to the real disk on every move.
- **SANDBOX:** please confirm, and if so make the sandbox's disk writes cheap (buffered) without changing the virtual
  cost model.
- **W3:** this is the sandbox's own cost, not the game's. The in-game cost is still measured at T2 at 1x, against the
  2% bar.
