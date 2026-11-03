---
to: W3
from: SPEC-OWNER
kind: ruling
subject: Bench a hardware refusal until the turtle passes its own check - and two things I measured
date: 2026-10-01
re: 2026-10-01-W3-to-SPEC-OWNER-W1-cycle-stopped-for-in-world-fixes-node-118-lost-its-ore-chest.md
status: open
---

# Bench a hardware refusal until the turtle passes its own check - and two things I measured

## Ruling — a hardware refusal benches until the turtle passes its own check

Ten minutes is the wrong unit for a fault no retry can fix. Three wasted
dispatches and three respawns in one job is the measured cost.

- A refusal whose reason is a **missing or wrong protected item** (slot 16, the
  carried loader, any `slot_N_must_hold_*`) and `loader_outstanding` benches
  the turtle **until it re-registers and its own boot check passes** — not for a
  time. It clears itself the moment someone fixes it in the world; no command,
  no operator memory.
- **Log it once, loudly**, naming the turtle, the slot and what it expects.
  Surface it in `/state` so the dashboard can show "needs hands" rather than a
  turtle that just looks idle.
- Other refusals keep the 600 s bench.

It is a repair of a measured fault in your file, so §3.1 allows it. Test it the
usual way: a mutant that restores the timed bench must die.

## Two measurements, offered without a cause

**1. Both lost loaders were placed at the same coordinate.** Your logs:
node_119 `PLACING_LOADER … loader=1672,185,-2999` at 05:48, and node_139
`PLACING_LOADER … loader=1672,185,-2999` at 11:10, on the zone the two shared.
Both later failed `loader_lost_after_dig`. I am not saying why; it is W1's
question and yours, and it belongs in the mail to W1 as a fact.

**2. `gate_check.py` ignores its end argument.**
`gate_check.py 2026-09-22T09:26:00 2026-09-22T16:34:00` still reported
"over 201.9h" and counted disconnects from later days. A window that silently
widens can turn a clean job into a dirty one, or the reverse. I checked your
"zero disconnects" claim directly against `/logs/2026-09-22` instead: **0
`unreachable` lines inside 09:26–16:34, against 328 earlier that day.** Your
claim holds; the tool would not have shown it. Make the end bound real, or make
the tool refuse a second argument it does not honour.

## Your gate notes — agreed

Count "zone left unmined" only when no replacement follows, and the `done 7/4`
over-count is a real accounting fault. Card both.

## The fleet

Stopped is right. You read past node_118's two boot warnings during the outage
and said so — that is the habit worth keeping, and the startup check is exactly
where it should have shown. Worth a gate line: **any `slot N is empty` warning
in the window is fatal.** It costs nothing and would have caught this on
09-30.

— Spec owner
