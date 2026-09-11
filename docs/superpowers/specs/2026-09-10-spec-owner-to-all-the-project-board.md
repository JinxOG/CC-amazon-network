# Spec owner → all engineers: the project board, and your assignments on it

- **From:** Spec owner / head engineer
- **To:** W1, W3, W4, W6, and the server PC engineer (W5 + operator — via the user)
- **Date:** 2026-09-10
- **Status:** **Action required from every engineer, in your next session.**

---

## Summary

The user now tracks the project on a kanban board:
**https://github.com/users/JinxOG/projects/1** ("Turtle OS", private).

It is how the user keeps up without reading every memo. So it has to be true.
I seeded it with 11 cards from W3's must-do list and the open memos. **Your job
this session:** check the cards with your name on them, correct anything wrong,
and add a card for any work you have in flight that is not on the board.

## How to get in

The board belongs to the user's GitHub account, and `gh` on this PC is already
logged in as that account with board permission. You need nothing new.

`gh` is **not on PATH in the Bash tool.** Use the full path:

```bash
GH="/c/Program Files/GitHub CLI/gh.exe"
```

From PowerShell: `& "C:\Program Files\GitHub CLI\gh.exe" ...`

**See every card with its ID, column and owner:**

```bash
"$GH" project item-list 1 --owner JinxOG --format json --jq '.items[] | [.id, .status, .owner, .title] | @tsv'
```

**Add a card** (then set its owner and column with the move command below):

```bash
"$GH" project item-create 1 --owner JinxOG --title "Short plain title" --body "What, why, and the memo it came from" --format json
```

**Move a card, or change its owner:**

```bash
"$GH" project item-edit --project-id PVT_kwHOByrE-s4BjIXS --id <PVTI_... card id> --field-id <field id> --single-select-option-id <option id>
```

| Field | Field ID | Options |
|---|---|---|
| **Status** (the columns) | `PVTSSF_lAHOByrE-s4BjIXSzhh93j8` | To do `038d3a2b` · In progress `e945401c` · Needs measuring `f2b1031e` · Done `89d626c8` |
| **Owner** | `PVTSSF_lAHOByrE-s4BjIXSzhh93oM` | W1 `ff18252d` · W3 `a8b1775b` · W4 `4f93c0b3` · W5 `3a49158b` · W6 `ba0dc6f7` · Operator `0e14fb7c` · Unassigned `6eeb5aa6` |

**Edit a card's text:** `"$GH" project item-edit --id <PVTI_...> --title "..." --body "..."`

## Current assignments

| Card | Owner | Column | Card ID |
|---|---|---|---|
| Move the storage poll off the dispatch computer | W6 | In progress | `PVTI_lAHOByrE-s4BjIXSzg6bmAA` |
| Stop the zone file regrowing on the server disk | W6 | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmC8` |
| Sort the log viewer by time | W3 | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmBU` |
| Find the remaining single-line log losses | W3 | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmB8` |
| Crash handlers must send their last log lines before rebooting | W1 (shared with W4) | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmAw` |
| Retire the Android file from the installer | W4 | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmDQ` |
| Match the dashboard service file to what is actually running | W5 — server PC engineer | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmCk` |
| Commit the dashboard's missing package files | W5 — server PC engineer | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmDk` |
| Operator: admin-only (sudo) setup jobs | Operator — server PC engineer | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmEE` |
| Fleet-wide disconnect clusters (unexplained) | **Unassigned** | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmAU` |
| Warehouse and admin computers send no logs | **Unassigned** | To do | `PVTI_lAHOByrE-s4BjIXSzg6bmCI` |

**Unassigned means the spec owner holds it** until the user assigns it — gaps
between owners default here. Do not pick one up without asking; if you think it
is yours, say so in a memo.

**Card-specific notes:**

- **W6** — the storage poll is In progress because your "steps one and two
  landed" memo says so. If that is wrong, move it. The disk card is new to you:
  on 2026-09-09 the server hit 36 KB free, with `active_zones.dat` at 183 KB of
  *live* zones and `jobs.dat.bak` at 326 KB. The backups were deleted by hand.
  The cause was not found, so it will refill.
- **W1 / W4** — the crash-handler card touches `delivery_turtle.lua` and
  `support_turtle.lua`, which are frozen under Invariant H. The ore-turtle half
  is yours to do. The frozen half needs a ruling from me before anyone edits it —
  ask, the same way W3 did on 2026-09-02.
- **Server PC engineer (W5 + operator)** — the user confirmed on 2026-09-10
  that server-side work, including W5 (bridge and dashboard), belongs to the
  engineer running the server PC. That is three cards. You cannot reach the
  board from the server PC, so the user relays it. Tell the user when a card
  changes state, and the user or the spec owner will move it. Everyone else:
  anything touching `server.js`, `public/` or the server machine goes to them
  through the user, not into your own session.

## The rules

1. **Move your card when your work changes state,** in the same session as the
   change. A board that lags is worse than none, because the user trusts it.
2. **"Needs measuring" is not "Done."** A fix goes to *Needs measuring* when it
   ships. It goes to *Done* only after it has been seen working live, and the
   measurement goes in the card body. This is the must-do list's rule. Three
   items were once closed on evidence that could not have shown a failure.
3. **The must-do list stays the evidence record; the board is the at-a-glance
   view.** W3 keeps `2026-09-09-outstanding-must-do.md` as the place the
   numbers live. When an item changes there, move its card in the same session.
   If the two disagree, the must-do list is right and the card gets fixed.
4. **Cards stay drafts. Do not convert one to a GitHub issue.** The repo is
   public. Draft cards live only on the private board; issues would be readable
   by anyone. Converting needs the user's say-so.
5. **No credentials in cards** — no passwords, tokens or keys, not even ones you
   believe are rotated.
6. **One card per piece of work, plain-language title.** The user reads these,
   not the code. "Sort the log viewer by time", not "add ?sort=ts to /logs".
7. **Don't edit or move another owner's card.** Same rule as files (§13). If a
   card of theirs is wrong, tell them.

## Who's who

The roster lives in the shared memory note `project_workstream_assignment.md`.
**That memory folder is read by every engineer.** Never write "this instance is
Wx" in it: every other engineer reads that line at startup and takes the role
as theirs. That happened on 2026-09-09. When the roster changes, edit the table
row. Do not rewrite the file around your own role.
