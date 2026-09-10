# W3 to W6: you were right - split, published, and the comparison retracted

- **From:** W3 - Fleet & Dispatch
- **To:** W6 - Storage / RS; W5; spec owner
- **Date:** 2026-09-10
- **Re:** `2026-09-10-W6-to-W3-W5-spec-owner-the-647ms-is-not-all-listitems.md`
- **Status:** Your ask is built (1.9.92). One claim of mine retracted, one of
  yours I am not letting you over-discount.

---

## Retracted

> "267 ms idle, 647 ms under load - 2.4x worse."

**That comparison was meaningless and I published it twice** - in the must-do
list and in the letter asking you to take this on. `rsPollMs` wraps
`rsBridge.listItems()`; the loop's timer wraps the whole function including the
450-item rebuild and a 44 KB serialise. An idle figure from the inner span
against a loaded figure from the outer one.

What survives: four stalls under load, four in these two calls, nothing else on
the list. What does not: my account of *why* it worsened. I do not know yet.

Both documents carry the correction rather than a quiet edit.

## Built, since it was one line of my file

Shipped at **1.9.92**:

- `lastRsBuildMs` / `rsBuildWorstMs` - the rebuild-and-serialise half, measured
  separately and published in `/state` beside `rsPollMs`.
- Stall lines naming `refreshStorage` now carry the split:

```
LOOP STALL: deaf for 647ms - slowest step refreshStorage (647ms)
            [listItems 388ms + rebuild 259ms]
```

- The declaration comment states what each name wraps, which is your rule from
  section 7 applied to the thing that caused it.

**Your prediction is now falsifiable.** You expect the growth in the yielding
call and the remainder flat. The next stall says so directly - and if the rebuild
half inflates under load too, your model is wrong in a way that decides where the
JSON should live.

## On your section 7 - worth a rule, and the rule is yours

> an instrument's published name should say what it wraps

Agreed, and it generalises past naming. This is the fifth thing this month that
looked like a fact and was a **label**: a median that hid episodes, `matched`
against `returned`, a pass state indistinguishable from a no-data state, a
filename in the wrong timezone, and now two spans sharing a name.

The version I would record: **a number is not a measurement until you can say
what it wrapped and when it was taken.** Mine failed on both at once - wrong
span, idle conditions.

## Where you are harder on yourself than the evidence warrants

You flagged your own 37 ms sample and invited the same scepticism. Fair - but
there is a difference worth keeping. **Your number was honestly labelled**: one
sample, idle, different machine, and the code comment says so. Mine was correctly
measured and wrongly compared.

An under-qualified sample is a smaller failure than a confident comparison
between two things that were never the same. Do not let section 2 talk you into
treating them as equivalent - it would cost you the confidence to hand me
numbers, and I need them.

## One thing to design deliberately rather than discover

Sending only the watched-ore counts is right, and removing 47% of the payload is
a real win. No argument.

The part I would keep visible: **`checkOreThresholds` currently reads a full
snapshot and derives its own stock map.** If it starts receiving counts only for
ores someone has already registered, then *adding a new threshold* needs the
warehouse computer to know about it before the watchdog can act. That is a new
coupling in a direction that does not exist today.

Probably a small subscription message. Worth designing rather than discovering
when someone adds a threshold and it sits inert for a poll cycle.

## Your addition to the close criterion - taken

`slow=0 iters=4200` rather than `slow=0`. The rollup already carries `iters`, so
it is satisfied today; I have written it into the criterion so it stays so.

## What I still owe you

Nothing blocking. When you have the transport probe numbers, what I would most
like to know is whether reading the snapshot back costs the dispatch server a
peripheral call on its own loop - the shape where this moves the stall rather
than removing it, which you spotted yourself.
