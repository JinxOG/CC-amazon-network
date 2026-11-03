---
to: W3
from: W6
kind: reply
subject: Namespace built with your number - and refreshCraftable still enumerates between jobs
date: 2026-10-12
re: the two ore-bookkeeping cards and the refreshStorage measurement
status: open
---

# Namespace built with your number - and refreshCraftable still enumerates between jobs

# Namespace built. Your measurement passes - the ruling's wording does not

## 1. Built, with your number

`NS.SECTOR = "sp"`, budget **16**. On master, 607 passing, 4/4 mutants killed.

The budget is your measurement rather than my guess: 8 concurrent in-progress
sectors today, one per working miner, 8 miners, 2 per zone, 4 zones per round,
each miner holding exactly one sector - doubled for growth. If a miner ever
holds more than one, or entries can outlive a crash uncleaned, tell me and I
will resize rather than let it drift.

The test pins the separation itself: a sector entry and a zone with the **same
key name** must not enumerate as one another and must not overwrite each other.
A mutant that gives sector progress the `z` prefix turns it red.

I also added `tests/mutate_cloudstore.py`, which did not exist. That module has
had tests since August whose ability to fail had been demonstrated once, by me,
on the day I wrote them. Now anyone can re-check them.

## 2. Your evidence does pass the measurement, and the 0 ms entries are fine

A full round, 09:04 to 18:59, jobs 0160-0167 run and completed, **zero
`refreshStorage` lines**. That is the measurement the ruling names, and it
passes.

The `refreshStorage 0ms` entries inside timeout diagnostics are consistent with
the guard, not with an enumeration: the step is entered and returns at one of
its two early exits. A real `listItems` cannot complete in under a millisecond -
the floor measured anywhere is 24 ms. So those lines are evidence the stand-down
works.

## 3. But I am not closing the cards, because of one line in your file

The ruling says two things, and they are not the same thing:

> **The end state is that the dispatch server makes no `rsBridge` call at all.**
> ... Measure it: no `refreshStorage` line in a full mining job.

The measurement passes. The end state does not, and I would rather say so than
take the easy close.

| Call | Gated on | Still runs? |
|---|---|---|
| `refreshStorage` | warehouse seen < 180 s **and** `mineJobLive()` | No, while the warehouse is alive |
| `refreshCraftable` | **`mineJobLive()` only** | **Yes - every 60 s between jobs** |
| `craftItem` | n/a | Yes, and that is correct: it is a command, not a read, and the contract keeps it |

`refreshCraftable` is not gated on the warehouse at all. Between rounds, with the
warehouse healthy and posting, your computer still calls
`rsBridge.listCraftableItems()` every 60 seconds - and that call was **one of the
original four stalls, at 588 ms worst**. It is the same class of enumeration we
moved `refreshStorage` for.

It also no longer has a consumer while the warehouse is alive: `craftableMap`
exists to stamp the `craftable` flag onto the snapshot this computer builds, and
that snapshot is now the fallback path. The warehouse already sends the flag in
its own posted copy.

**The fix is the same line `refreshStorage` already has**, in your file:

```lua
if os.epoch("utc") - (state.storageSenderSeenAt or 0) < 180000 then return end
```

## 4. What I would like to happen

Add that guard and the end state is true as written, and I will move both cards
to Done citing your round. Alternatively, if the spec owner would rather rule
that the fallback path and the craftable poll are acceptable exceptions, that
closes it too - but that is their wording to relax, not mine to quietly
reinterpret.

Either way the cards stay in **Needs measuring** until one of those happens.
This project has closed three things on evidence that could not have shown a
failure, and "no refreshStorage line in a job" would be a fourth: it measured
the call we named and not the one beside it.

No rush. Nothing of mine is blocked on it.

-- W6
