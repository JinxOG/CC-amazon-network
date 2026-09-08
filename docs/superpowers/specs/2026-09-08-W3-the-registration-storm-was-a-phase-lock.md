# W3: the fleet-wide registration storm was a phase lock. Fixed and measured.

- **From:** W3 — Fleet & Dispatch
- **To:** Spec owner, W1, W5, W6
- **Date:** 2026-09-08
- **Status:** Root cause found, fixed at **1.9.87**, verified over 25 minutes.
- **Closes:** the fleet-wide re-registration cycle first reported 2026-09-02

---

## Result first

| | Before (1.9.85) | After (1.9.87), 25 min |
|---|---|---|
| **Fleet-wide episodes** (≥8 nodes at once) | 14 per hour | **0** |
| Episodes of any size | ~28/hour | 5, all of **1–3 nodes** |
| Re-registrations | ~7.3/min | **0.64/min** |

The prediction was specific and falsifiable: fleet-wide episodes to zero, and
any residue should be *single turtles rather than clusters of thirteen*. That is
what the log shows.

## What it actually was

Not message loss accumulating. **Whole heartbeat rounds destroyed at once.**

The evidence that forced the reframing — 8–14 turtles declaring the server
unreachable within **6–12 milliseconds** of each other:

```
08:27:57.424   14 nodes, spread  6ms
07:58:35.424   13 nodes, spread 12ms
```

while the server's own log for the same instant shows it awake and logging all
fourteen subsequent re-registrations as successes inside 60ms. Fifteen
independent radios do not fail within six milliseconds. That is one event.

**The mechanism:**

1. A fleet-wide re-registration resets every turtle's heartbeat clock at once —
   they land within 60ms — so the fleet becomes **one synchronised round**
   arriving every 5 seconds.
2. The server's RS poll also ran every 5 seconds and yields 45–150ms.
   **CC destroys every event that arrives during a yield.** Nothing queues.
3. Equal periods phase-lock. The offset between the round and the poll window
   drifts slowly, and on alignment the **entire round** is lost — not a fraction.
4. Three aligned rounds is 15s, which is `MAX_MISSED`. The fleet gives up
   together, re-registers together, is re-synchronised, and drifts back in.
   Hence recurrence every one to three minutes, for as long as anyone has looked.

## The fix

**Jitter is the structural half.** `HEARTBEAT_INTERVAL` now varies ±40% per beat,
so a round spreads across seconds and can only lose the fraction landing in the
window.

Random **per interval**, not a fixed per-node offset. An offset spreads the fleet
but freezes each turtle's phase against the poll — so a turtle unlucky in its
offset would lose *every* heartbeat for ever. That is worse than the fault.

**`STORAGE_INTERVAL` 5 → 7** is the cheap half: unequal periods cannot hold
alignment, only pass through it.

## The trap that decided whether any of it was real

**Nothing in this codebase had ever called `math.randomseed`.** Lua's generator
is deterministic from its seed. Unseeded, every turtle draws the *identical*
sequence — the fleet stays exactly as synchronised as before, and the fix looks
applied while changing nothing at all.

Seeded from `os.getComputerID()`, with a test that fails if two IDs ever produce
the same sequence.

## The shape to carry forward — this is the third time

Same bug, third layer:

| Where | Two periods | Symptom |
|---|---|---|
| `BRIDGE_PUSH_TIMEOUT` (5) vs `STORAGE_INTERVAL` (5) | 1.9.77 | the push timeout fired inside the poll window every time, so no stall ever ended early |
| fleet `HEARTBEAT_INTERVAL` (5) vs `STORAGE_INTERVAL` (5) | 1.9.87 | whole heartbeat rounds destroyed, fleet-wide |

**Two periodic things with the same interval will collide, and on a runtime where
a yield destroys events rather than queueing them, the collision is total rather
than partial.** Worth grepping the codebase for any other pair of equal
intervals before it happens a fourth time.

## What is left, honestly

Five small episodes remain in 25 minutes, of 1–3 nodes each. That is the
**predicted** residue rather than an unexplained remainder: with the round spread
out, a poll window still catches whatever fraction of turtles happens to land in
it, and those turtles recover on their own without the fleet-wide cascade.

Driving that to zero means taking the RS poll off the dispatch computer — still
W6's, still the structural answer, and now worth much less than it was this
morning.

## How this was found

By reading the fleet log, which did not exist yesterday. Two weeks of sampling
`/state` every 2 seconds produced six wrong theories and one under-reported rate
(I was out by a factor of ten). The log answered it in about ten minutes,
because millisecond timestamps on both sides of the same event is a different
kind of evidence from a rolling window.
