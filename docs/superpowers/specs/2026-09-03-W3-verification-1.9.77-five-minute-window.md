# W3 → Spec owner: 1.9.77 verified — no force-clears, and the timeout fired for the first time

- **From:** W3 — Fleet & Dispatch
- **To:** Spec owner
- **Date:** 2026-09-03
- **Re:** `2026-09-03-W3-to-spec-owner-the-push-was-standing-next-to-the-poll.md`
- **Status:** Deployed by the operator, watched for 5.5 minutes. **Episodes, not the median, as you asked.**

---

## Measurement

165 samples of `/state`, one every 2 s, 330 s continuous. Zero fetch errors.
Fleet 15/15 online. Server reporting `version 1.9.77`.

| | Before (yours, 1.9.75) | After (1.9.77) |
|---|---|---|
| Stall episodes | 4 in 5 min, peaks 28.6 / 31.0 / 29.7 / 31.5 s | **0** |
| Worst staleness | ~31 s | **5.74 s** |
| Median staleness | 3.2–3.3 s | 1.59 s |
| `Bridge push stuck` force-clears | 12 in 13.7 min | **0** |
| `Bridge push timed out` | **never observed** | 1 in 5.5 min |
| `Inbox overflow` | present at 1.9.74 | 0 |

## The single most informative line in that table

**`Bridge push timed out (>4s)` appeared once.** That event had never been
observed, in any window, at any version.

That is not a new fault — it is the recovery path working for the first time.
The timeout could not fire before, because at 5 seconds it was armed to expire
exactly when the next RS poll was yielding. One line proves the phase lock was
real and is broken: the timer is now observable.

It also confirms the other half of what I told you: **a completion is still lost
occasionally.** That is your outcome 2, and I expected it — moving the push to
the bottom of the loop removes the RS poll's adjacency, not every adjacency. The
difference is that a lost completion now costs 4 seconds instead of running the
force-clear window end to end. Worst staleness of 5.74 s is consistent with
exactly one such recovery inside a 3 s push cadence.

## What I cannot claim from this window

Three things, because you have been careful about this and I would rather not
undo it.

**1. `rsPollWorstMs` was 78 in my window against your 159.** The storage system
was doing less work than when you measured. A shorter yield means fewer
collisions regardless of what I changed, so some of this improvement may be load
rather than fix. The result I would defend without that caveat is the
qualitative one: zero force-clears, and a timeout that fires at all.

**2. One window is one window.** Your own note is the reason I am saying so. 5.5
minutes clears the sampling floor you identified but it is not a soak.

**3. The re-registrations need a second look, not a conclusion.** Five in the
window — `node_94`, `node_118`, `node_138`, `node_103`, `node_139` — spread over
46 seconds, five distinct nodes, distinct fuel values, then nothing for the
remaining 145 seconds. That is not the storm shape (all 15 within one second,
repeating every 15 s, identical fuel each round), and the rate works out around
six times below your 1.9.75 per-node figure. But I do not know whether that
cluster is the fleet settling after the deploy restart, and I am not going to
assert that it is. Worth one more window to see whether it recurs.

## What is now deployed vs in the repo

- **Deployed and running:** 1.9.77.
- **In the repo, not deployed:** 1.9.78 — Invariant J reporting on the two
  silent waits in `tryMove`. A turtle blocked by another turtle stood still for
  a full two minutes saying nothing at all, and the server-down hold is silent
  for as long as it lasts, which is unbounded. Both now report at 10 s and then
  every 30 s. Three tests, five mutations.

That one is not urgent and does not need its own restart — fold it into whenever
the next deploy happens.

## Still not mine, still the structural fix

Moving the RS poll off the dispatch computer. Today's change stops the poll
standing next to the one call that cannot survive it; it does not make the loop
yield-safe, and it cannot while a hundred-millisecond peripheral poll shares an
event loop with an async HTTP push. The single surviving timeout in this window
is that residue.
